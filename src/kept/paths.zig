//! Names inside the kept store: the id every marker is filed under, the
//! rules a kept path must satisfy, the collision check across a key's
//! paths, and gitignore escaping for the lines holt writes.

const std = @import("std");
const tables = @import("unicode_tables.zig");
const testing = std.testing;

/// Hex SHA-256 of `s`: the file name of every marker that describes `s`.
pub fn id(s: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// How a filesystem compares names: whether two names that differ only in
/// case, or only in Unicode normalization, name one file there.
pub const Folding = struct {
    case: bool,
    norm: bool,

    pub const none: Folding = .{ .case = false, .norm = false };
    pub const all: Folding = .{ .case = true, .norm = true };

    pub fn folds(self: Folding) bool {
        return self.case or self.norm;
    }

    /// A string equal for two valid UTF-8 names exactly when a filesystem
    /// comparing names this way finds one file under both.
    pub fn key(self: Folding, alloc: std.mem.Allocator, s: []const u8) ![]u8 {
        if (self.case and self.norm) return foldKey(alloc, s);
        if (self.norm) return nfd(alloc, s);
        if (self.case) return caseKey(alloc, s);
        return alloc.dupe(u8, s);
    }
};

/// Test seam: every filesystem compares names this way, whatever a probe
/// of it finds.
pub var folding_for_test: ?Folding = null;

/// True for a name holt reserves inside the kept store.
pub fn isReserved(component: []const u8) bool {
    return std.mem.startsWith(u8, component, ".holt-");
}

/// The name of the temporary holt keeps beside `<rel>` in a working tree
/// while it replaces what is there: `.holt-tmp-<id(rel)>` in `rel`'s
/// directory, `/`-joined.
pub fn tempRel(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    const rid = id(rel);
    if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| return std.fmt.allocPrint(alloc, "{s}/" ++ temp_prefix ++ "{s}", .{ rel[0..i], &rid });
    return std.fmt.allocPrint(alloc, temp_prefix ++ "{s}", .{&rid});
}

const temp_prefix = ".holt-tmp-";
const probe_prefix = temp_prefix ++ "probe-";
const probe_suffix = "-\u{e9}";

/// The name of a file that probes how a filesystem compares names,
/// `.holt-tmp-probe-<suffix>-\u{e9}`: it has letters to swap the case of
/// and a precomposed letter to decompose. `isTempRel` recognizes it, so it
/// can stand under a block line while it exists.
pub fn probeName(alloc: std.mem.Allocator, suffix: [16]u8) ![]u8 {
    return std.fmt.allocPrint(alloc, probe_prefix ++ "{s}" ++ probe_suffix, .{&suffix});
}

fn isHex(s: []const u8) bool {
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// True for a name `tempRel` or `probeName` produces.
pub fn isTempRel(s: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const base = if (slash) |i| s[i + 1 ..] else s;
    const temp = base.len == temp_prefix.len + 64 and std.mem.startsWith(u8, base, temp_prefix) and isHex(base[temp_prefix.len..]);
    if (!temp and !isProbeBase(base)) return false;
    return if (slash) |i| check(s[0..i]) == null else true;
}

/// True for a temporary (`isTempRel`) whose name `probeName` produces.
pub fn isProbeRel(s: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
    return isTempRel(s) and isProbeBase(base);
}

fn isProbeBase(base: []const u8) bool {
    return base.len == probe_prefix.len + 16 + probe_suffix.len and std.mem.startsWith(u8, base, probe_prefix) and
        std.mem.endsWith(u8, base, probe_suffix) and isHex(base[probe_prefix.len .. probe_prefix.len + 16]);
}

pub const Invalid = enum {
    empty,
    absolute,
    empty_component,
    dot_component,
    backslash,
    not_utf8,
    control,
    dotgit,
    reserved,
    collision,
    git_reads_unlinked,

    pub fn describe(self: Invalid) []const u8 {
        return switch (self) {
            .empty => "empty path",
            .absolute => "absolute path",
            .empty_component => "empty path component",
            .dot_component => "'.' or '..' component",
            .backslash => "backslash in path",
            .not_utf8 => "not valid UTF-8",
            .control => "control character in path",
            .dotgit => "component git treats as .git",
            .reserved => "reserved .holt- name",
            .collision => "equal to another kept path under case folding or Unicode normalization",
            .git_reads_unlinked => "git reads it only as a regular file, never through a link",
        };
    }
};

/// Why `rel` cannot be a kept path, or null when it can. Collisions between
/// paths are a property of a set; see `collisions`.
pub fn check(rel: []const u8) ?Invalid {
    if (rel.len == 0) return .empty;
    if (rel[0] == '/') return .absolute;
    if (!std.unicode.utf8ValidateSlice(rel)) return .not_utf8;
    for (rel) |c| {
        if (c == '\\') return .backslash;
        if (c < 0x20 or c == 0x7f) return .control;
    }
    if (rel.len >= 2 and rel[1] == ':' and std.ascii.isAlphabetic(rel[0])) return .absolute;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return .empty_component;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return .dot_component;
        if (isNtfsDotGit(comp) or isHfsDotGit(comp)) return .dotgit;
        if (isReserved(comp)) return .reserved;
    }
    return null;
}

/// Why `rel` cannot be kept, or null when it can: `check`'s reasons, then
/// `git_reads_unlinked` when its last component is a file git opens without
/// following a link (`gitReadsUnlinked`). A directory holding such a file
/// may be kept: git never reads inside a directory link.
pub fn keepable(rel: []const u8) ?Invalid {
    if (check(rel)) |inv| return inv;
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    return if (gitReadsUnlinked(base)) .git_reads_unlinked else null;
}

/// The files git reads only as regular files, with git's hashed prefix of
/// each one's NTFS short name.
const unlinked_names = [_]struct { name: []const u8, short: []const u8 }{
    .{ .name = "gitignore", .short = "gi250a" },
    .{ .name = "gitattributes", .short = "gi7d29" },
    .{ .name = "mailmap", .short = "maba30" },
};

/// True when `comp` is `.gitignore`, `.gitattributes`, or `.mailmap` under
/// git's own aliasing rules (`is_ntfs_dot_generic`, `is_hfs_dot_generic`).
pub fn gitReadsUnlinked(comp: []const u8) bool {
    inline for (unlinked_names) |n| {
        if (isNtfsDot(comp, n.name, n.short) or isHfsDot(comp, "." ++ n.name)) return true;
    }
    return false;
}

/// True when `rel`, joined to a directory, names a place strictly inside
/// it on every platform: relative, with no drive prefix or NUL, and no
/// empty, `.`, or `..` component, taking `\` as a separator too. On Windows,
/// which drops trailing dots and spaces from a name, no component may be
/// made of dots and spaces alone. Names that fail only `check`'s other rules
/// are contained.
pub fn contained(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\') return false;
    if (rel.len >= 2 and rel[1] == ':' and std.ascii.isAlphabetic(rel[0])) return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
        if (@import("builtin").os.tag == .windows and std.mem.trimEnd(u8, comp, " .").len == 0) return false;
    }
    return true;
}

/// True when a component of `rel` is one Windows opens as something other
/// than a file of that name: a device (`CON`, `PRN`, `AUX`, `NUL`,
/// `CONIN$`, `CONOUT$`, `COM` or `LPT` followed by a digit 1 to 9 or by a
/// superscript one, two, or three (U+00B9, U+00B2, U+00B3), in any case,
/// with or without an extension or trailing spaces), a name holding `:`,
/// which names a stream, or a name ending in a dot or a space, which
/// Windows trims.
pub fn windowsUnsafe(rel: []const u8) bool {
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |comp| {
        if (std.mem.indexOfScalar(u8, comp, ':') != null) return true;
        if (comp.len > 0 and (comp[comp.len - 1] == '.' or comp[comp.len - 1] == ' ')) return true;
        const stem = std.mem.trimEnd(u8, comp[0 .. std.mem.indexOfScalar(u8, comp, '.') orelse comp.len], " ");
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |d| {
            if (std.ascii.eqlIgnoreCase(stem, d)) return true;
        }
        if (stem.len < 4 or !(std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT"))) continue;
        const n = stem[3..];
        if (n.len == 1 and n[0] >= '1' and n[0] <= '9') return true;
        for ([_][]const u8{ "\u{b9}", "\u{b2}", "\u{b3}" }) |sup| {
            if (std.mem.eql(u8, n, sup)) return true;
        }
    }
    return false;
}

/// True when a component of `rel`, split at `/` or `\\`, is one git treats
/// as `.git` on some filesystem.
pub fn hasDotGit(rel: []const u8) bool {
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |comp| {
        if (isNtfsDotGit(comp) or isHfsDotGit(comp)) return true;
    }
    return false;
}

/// True when git's walk of a working tree skips the entry `comp` as
/// `.git`: `.git` itself, or `.git` in any ASCII case when the tree's
/// `core.ignorecase` is true (`ignore_case`, `clone.ignoresCase`). git
/// lists every other name. Narrower than `hasDotGit`, which holds for a
/// name any filesystem would treat as `.git`.
pub fn isWalkDotGit(comp: []const u8, ignore_case: bool) bool {
    if (std.mem.eql(u8, comp, ".git")) return true;
    return ignore_case and std.ascii.eqlIgnoreCase(comp, ".git");
}

/// git's NTFS rule, widened: `.git` or its short name `git~1` in any case,
/// followed only by spaces and dots, or by an alternate data stream.
fn isNtfsDotGit(comp: []const u8) bool {
    for ([_][]const u8{ ".git", "git~1" }) |name| {
        if (comp.len >= name.len and std.ascii.eqlIgnoreCase(comp[0..name.len], name) and ntfsTail(comp[name.len..])) return true;
    }
    return false;
}

/// git's `is_ntfs_dot_generic`: `.<name>` in any ASCII case, or an NTFS
/// short name of it, followed only by spaces and dots, or by an alternate
/// data stream. A short name is the first six letters of `name`, `~`, and
/// a digit 1 to 4, or, within eight characters, a leading part of `short`
/// (git's hashed prefix), `~`, a digit 1 to 9, and digits.
fn isNtfsDot(comp: []const u8, name: []const u8, short: []const u8) bool {
    if (comp.len > name.len and comp[0] == '.' and std.ascii.eqlIgnoreCase(comp[1 .. name.len + 1], name)) return ntfsTail(comp[name.len + 1 ..]);
    if (comp.len >= 8 and std.ascii.eqlIgnoreCase(comp[0..6], name[0..6]) and comp[6] == '~' and comp[7] >= '1' and comp[7] <= '4') return ntfsTail(comp[8..]);
    var saw_tilde = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (i >= comp.len) return false;
        const c = comp[i];
        if (saw_tilde) {
            if (c < '0' or c > '9') return false;
        } else if (c == '~') {
            i += 1;
            if (i >= comp.len or comp[i] < '1' or comp[i] > '9') return false;
            saw_tilde = true;
        } else if (i >= 6 or c >= 0x80 or std.ascii.toLower(c) != short[i]) return false;
    }
    return ntfsTail(comp[i..]);
}

/// True when `rest` holds only spaces and dots up to its end or a `:`.
fn ntfsTail(rest: []const u8) bool {
    for (rest) |c| switch (c) {
        ':' => return true,
        ' ', '.' => {},
        else => return false,
    };
    return true;
}

/// git's HFS+ rule: `.git` in any case once the code points HFS+ ignores
/// are dropped.
fn isHfsDotGit(comp: []const u8) bool {
    return isHfsDot(comp, ".git");
}

/// git's `is_hfs_dot_generic`: `want` in any ASCII case once the code
/// points HFS+ ignores are dropped.
fn isHfsDot(comp: []const u8, want: []const u8) bool {
    var view = std.unicode.Utf8View.init(comp) catch return false;
    var it = view.iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (hfsIgnorable(cp)) continue;
        if (i == want.len or cp > 0x7f) return false;
        if (std.ascii.toLower(@intCast(cp)) != want[i]) return false;
        i += 1;
    }
    return i == want.len;
}

fn hfsIgnorable(cp: u21) bool {
    return switch (cp) {
        0x200c...0x200f, 0x202a...0x202e, 0x206a...0x206f, 0xfeff => true,
        else => false,
    };
}

/// The paths of `rels` equal to another member under case folding or
/// canonical normalization. Every member of a colliding group is returned.
pub fn collisions(alloc: std.mem.Allocator, rels: []const []const u8) ![]const []const u8 {
    var groups: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (rels) |rel| {
        if (!std.unicode.utf8ValidateSlice(rel)) continue;
        const key = try foldKey(alloc, rel);
        const gop = try groups.getOrPut(alloc, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |seen| {
            if (std.mem.eql(u8, seen, rel)) break;
        } else try gop.value_ptr.append(alloc, rel);
    }
    var out: std.ArrayList([]const u8) = .empty;
    var it = groups.valueIterator();
    while (it.next()) |g| {
        if (g.items.len > 1) try out.appendSlice(alloc, g.items);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// Byte order of strings, for `std.mem.sort`.
pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// True when `list` holds a string byte-equal to `s`.
pub fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Canonical decomposition (NFD) of valid UTF-8 `s`.
pub fn nfd(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return encode(alloc, try nfdScalars(alloc, s));
}

fn nfdScalars(alloc: std.mem.Allocator, s: []const u8) ![]u21 {
    var cps: std.ArrayList(u21) = .empty;
    var view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try decompose(alloc, &cps, cp);
    canonicalOrder(cps.items);
    return cps.items;
}

/// A string equal for two inputs exactly when they are equal under simple
/// case folding and canonical normalization: NFD, folded, then NFD again,
/// as case-insensitive filesystems compare names.
pub fn foldKey(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    for (s) |c| {
        if (c >= 0x80) break;
    } else return std.ascii.allocLowerString(alloc, s);
    var out: std.ArrayList(u21) = .empty;
    for (try nfdScalars(alloc, s)) |cp| {
        if (lookup(&tables.fold_keys, cp)) |i| {
            try out.appendSlice(alloc, tables.fold_vals[tables.fold_offsets[i]..tables.fold_offsets[i + 1]]);
        } else try out.append(alloc, cp);
    }
    canonicalOrder(out.items);
    return encode(alloc, out.items);
}

/// A string equal for two valid UTF-8 inputs exactly when they are equal
/// scalar by scalar under simple case folding, with no normalization.
fn caseKey(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    var buf: [4]u8 = undefined;
    while (it.nextCodepoint()) |cp| {
        const n = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(alloc, try foldKey(alloc, buf[0..n]));
        try out.append(alloc, 0);
    }
    return out.items;
}

fn decompose(alloc: std.mem.Allocator, out: *std.ArrayList(u21), cp: u21) !void {
    const s_base = 0xAC00;
    const l_base = 0x1100;
    const v_base = 0x1161;
    const t_base = 0x11A7;
    const n_count = 21 * 28;
    if (cp >= s_base and cp <= 0xD7A3) {
        const s_index = cp - s_base;
        try out.append(alloc, l_base + s_index / n_count);
        try out.append(alloc, v_base + (s_index % n_count) / 28);
        const t = s_index % 28;
        if (t != 0) try out.append(alloc, t_base + t);
        return;
    }
    if (lookup(&tables.nfd_keys, cp)) |i| {
        return out.appendSlice(alloc, tables.nfd_vals[tables.nfd_offsets[i]..tables.nfd_offsets[i + 1]]);
    }
    try out.append(alloc, cp);
}

fn lookup(keys: []const u21, cp: u21) ?usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] == cp) return mid;
        if (keys[mid] < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn combiningClass(cp: u21) u21 {
    const r = &tables.ccc_ranges;
    var lo: usize = 0;
    var hi: usize = r.len / 3;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < r[mid * 3]) {
            hi = mid;
        } else if (cp > r[mid * 3 + 1]) {
            lo = mid + 1;
        } else return r[mid * 3 + 2];
    }
    return 0;
}

/// Stable-sorts every run of nonzero combining class by class.
fn canonicalOrder(cps: []u21) void {
    var i: usize = 1;
    while (i < cps.len) : (i += 1) {
        const c = combiningClass(cps[i]);
        if (c == 0) continue;
        var j = i;
        while (j > 0) {
            const p = combiningClass(cps[j - 1]);
            if (p == 0 or p <= c) break;
            std.mem.swap(u21, &cps[j - 1], &cps[j]);
            j -= 1;
        }
    }
}

fn encode(alloc: std.mem.Allocator, cps: []const u21) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4]u8 = undefined;
    for (cps) |cp| {
        const n = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.items;
}

/// `s` escaped as a gitignore pattern that matches exactly `s`: a backslash
/// before `[`, `]`, `*`, `?`, `\`, a leading `#` or `!` when
/// `escape_leading`, and each trailing space.
pub fn escapePattern(alloc: std.mem.Allocator, s: []const u8, escape_leading: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const trailing_from = std.mem.trimEnd(u8, s, " ").len;
    for (s, 0..) |c, i| {
        const special = switch (c) {
            '[', ']', '*', '?', '\\' => true,
            '#', '!' => i == 0 and escape_leading,
            ' ' => i >= trailing_from,
            else => false,
        };
        if (special) try out.append(alloc, '\\');
        try out.append(alloc, c);
    }
    return out.items;
}

/// The inverse of `escapePattern`: every `\x` becomes `x`.
pub fn unescapePattern(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) i += 1;
        try out.append(alloc, s[i]);
    }
    return out.items;
}

test "tempRel: beside the path, named by its id, and recognized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const top = try tempRel(a, ".clasp.json");
    try testing.expectEqualStrings(".holt-tmp-" ++ id(".clasp.json"), top);
    const nested = try tempRel(a, "android/app/x.json");
    try testing.expectEqualStrings("android/app/.holt-tmp-" ++ id("android/app/x.json"), nested);
    try testing.expect(isTempRel(top) and isTempRel(nested));
    try testing.expect(!isTempRel(".holt-tmp-abc"));
    try testing.expect(!isTempRel("../.holt-tmp-" ++ id("x")));
    try testing.expect(!isTempRel(".clasp.json"));
}

test "probeName: recognized as a temporary, beside no other name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const name = try probeName(a, "0123456789abcdef".*);
    try testing.expectEqualStrings(".holt-tmp-probe-0123456789abcdef-\u{e9}", name);
    try testing.expect(isProbeRel(name) and isProbeRel(try std.fmt.allocPrint(a, "d/{s}", .{name})));
    try testing.expect(!isProbeRel(try tempRel(a, "x")));
    try testing.expect(isTempRel(name));
    try testing.expect(!isTempRel(".holt-tmp-probe-0123456789abcdef"));
    try testing.expect(!isTempRel(".holt-tmp-probe-0123456789ABCDEF-\u{e9}"));
}

test "Folding.key: names are one exactly where the filesystem folds what tells them apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { f: Folding, x: []const u8, y: []const u8, same: bool };
    for ([_]Case{
        .{ .f = .all, .x = "README", .y = "readme", .same = true },
        .{ .f = .all, .x = "caf\u{e9}", .y = "CAFE\u{301}", .same = true },
        .{ .f = .none, .x = "README", .y = "readme", .same = false },
        .{ .f = .none, .x = "caf\u{e9}", .y = "cafe\u{301}", .same = false },
        .{ .f = .{ .case = false, .norm = true }, .x = "caf\u{e9}", .y = "cafe\u{301}", .same = true },
        .{ .f = .{ .case = false, .norm = true }, .x = "README", .y = "readme", .same = false },
        .{ .f = .{ .case = true, .norm = false }, .x = "CAF\u{c9}", .y = "caf\u{e9}", .same = true },
        .{ .f = .{ .case = true, .norm = false }, .x = "caf\u{e9}", .y = "cafe\u{301}", .same = false },
    }) |c| try testing.expectEqual(c.same, std.mem.eql(u8, try c.f.key(a, c.x), try c.f.key(a, c.y)));
}

test "id: hex SHA-256" {
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &id(""),
    );
}

test "check: accepts ordinary kept paths" {
    for ([_][]const u8{ ".clasp.json", "android/app/google-services.json", ".claude/settings.local.json", ".superpowers", "a b/c", "\u{65e5}\u{672c}.txt", ".gitignore-local", "git~2" }) |rel| {
        try testing.expectEqual(@as(?Invalid, null), check(rel));
    }
}

test "check: refuses every malformed or dangerous path" {
    const cases = [_]struct { rel: []const u8, want: Invalid }{
        .{ .rel = "", .want = .empty },
        .{ .rel = "/etc/passwd", .want = .absolute },
        .{ .rel = "C:/x", .want = .absolute },
        .{ .rel = "a//b", .want = .empty_component },
        .{ .rel = "a/", .want = .empty_component },
        .{ .rel = "./a", .want = .dot_component },
        .{ .rel = "a/../b", .want = .dot_component },
        .{ .rel = "a\\b", .want = .backslash },
        .{ .rel = "a\x00b", .want = .control },
        .{ .rel = "a\nb", .want = .control },
        .{ .rel = "a\x7fb", .want = .control },
        .{ .rel = "\xff", .want = .not_utf8 },
        .{ .rel = ".git", .want = .dotgit },
        .{ .rel = "sub/.GIT/config", .want = .dotgit },
        .{ .rel = ".git. . ", .want = .dotgit },
        .{ .rel = ".git::$INDEX_ALLOCATION", .want = .dotgit },
        .{ .rel = "GIT~1", .want = .dotgit },
        .{ .rel = ".g\u{200c}it", .want = .dotgit },
        .{ .rel = "\u{feff}.Git", .want = .dotgit },
        .{ .rel = ".holt-tmp", .want = .reserved },
        .{ .rel = "a/.holt-paths/x", .want = .reserved },
    };
    for (cases) |c| try testing.expectEqual(@as(?Invalid, c.want), check(c.rel));
}

test "gitReadsUnlinked: .gitignore, .gitattributes, and .mailmap under git's NTFS and HFS+ aliasing, and no other name" {
    for ([_][]const u8{
        ".gitignore",     ".GitIgnore",     ".gitignore.",           ".gitignore ",      ".gitignore. . ",
        ".gitattributes", ".GITATTRIBUTES", ".gitattributes::$DATA", ".mailmap",         ".MailMap:stream",
        "GITIGN~1",       "gitatt~4",       "mailma~2 ",             "gi250a~1",         "GI7D29~9",
        "maba3~12",       "gi250a~1.",      ".git\u{200c}ignore",    "\u{feff}.mailmap", ".Git\u{200d}Attributes",
    }) |comp| {
        if (!gitReadsUnlinked(comp)) {
            std.debug.print("not matched: {s}\n", .{comp});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{
        ".gitignore-local", "gitignore",        ".gitignorex", "x.gitignore", ".mailmap2",   "gitign~5", "gitign~0",
        "gi250a~0",         "gi250a~10",        "gi250b~1",    "gi250a~",     ".gitmodules", ".git",     "git~1",
        "gi250\u{e9}~1",    ".git\u{e9}ignore",
    }) |comp| {
        if (gitReadsUnlinked(comp)) {
            std.debug.print("matched: {s}\n", .{comp});
            return error.TestUnexpectedResult;
        }
    }
}

test "keepable: check's refusals first, then a last component git reads only as a regular file" {
    try testing.expectEqual(@as(?Invalid, .git_reads_unlinked), keepable("x/.gitignore"));
    try testing.expectEqual(@as(?Invalid, .git_reads_unlinked), keepable(".mailmap"));
    try testing.expectEqual(@as(?Invalid, .git_reads_unlinked), keepable("a/b/GITATT~1"));
    try testing.expectEqual(@as(?Invalid, null), keepable(".gitignore/x"));
    try testing.expectEqual(@as(?Invalid, null), keepable(".husky/_"));
    try testing.expectEqual(@as(?Invalid, .dotgit), keepable(".git/.gitignore"));
    try testing.expectEqual(@as(?Invalid, .reserved), keepable(".holt-x/.gitignore"));
    try testing.expectEqual(@as(?Invalid, null), check("x/.gitignore"));
}

test "hasDotGit: a .git component anywhere, split at either separator" {
    for ([_][]const u8{ ".git", ".git/config", "a/.GIT/x", "a\\.git\\x", "sub/git~1", ".g\u{200c}it/HEAD", "a\\b/.git" }) |rel| {
        try testing.expect(hasDotGit(rel));
    }
    for ([_][]const u8{ ".gitignore", "a/.github/x", "git", "a\\b" }) |rel| {
        try testing.expect(!hasDotGit(rel));
    }
}

test "isWalkDotGit: `.git` itself, and other ASCII cases only under core.ignorecase" {
    try testing.expect(isWalkDotGit(".git", false));
    try testing.expect(!isWalkDotGit(".GIT", false));
    try testing.expect(isWalkDotGit(".GIT", true));
    try testing.expect(isWalkDotGit(".Git", true));
    for ([_][]const u8{ ".gitignore", "git~1", ".git. ", ".g\u{200c}it", ".G\u{200c}IT", ".git/" }) |name| {
        try testing.expect(!isWalkDotGit(name, true));
    }
}

test "contained: accepts any relative name that stays inside, refuses escapes" {
    for ([_][]const u8{ "a", "Icon\r", "a\\b", "sub/.git/config", ".holt-x", "a b/c" }) |rel| {
        try testing.expect(contained(rel));
    }
    for ([_][]const u8{ "", "/x", "\\x", "C:x", "a//b", "a/", "./a", "a/../b", "a\\..\\b", "a\x00b" }) |rel| {
        try testing.expect(!contained(rel));
    }
}

test "windowsUnsafe: device names with or without an extension, in any case, any stream, and names Windows would trim" {
    for ([_][]const u8{ "CON", "con.txt", "d/Prn", "d/aux.tar.gz", "NUL", "com1", "COM9.log", "lpt1", "d/LPT9/x", "CON ", "a:b", "d/x:stream", "CONIN$", "conout$.txt", "COM\u{b9}", "com\u{b2}.log", "LPT\u{b3}", "d/lpt\u{b9}/x", "x.", "d/x /y", "notes." }) |rel| {
        try testing.expect(windowsUnsafe(rel));
    }
    for ([_][]const u8{ "CONSOLE", "d/icon", "com10", "COM0", "lpt", "auxiliary.txt", "nul-device", "d/x" }) |rel| {
        try testing.expect(!windowsUnsafe(rel));
    }
}

test "nfd: decomposes precomposed Latin, kana, and Hangul, and orders marks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("e\u{301}", try nfd(a, "\u{e9}"));
    try testing.expectEqualStrings("\u{304b}\u{3099}", try nfd(a, "\u{304c}"));
    try testing.expectEqualStrings("\u{1112}\u{1161}\u{11ab}", try nfd(a, "\u{d55c}"));
    try testing.expectEqualStrings("a\u{323}\u{301}", try nfd(a, "a\u{301}\u{323}"));
    try testing.expectEqualStrings("plain", try nfd(a, "plain"));
}

test "collisions: case and normalization variants collide, distinct names do not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try collisions(a, &.{ "README", "readme", "caf\u{e9}", "cafe\u{301}", "other", "\u{304c}.txt", "\u{304b}.txt", "\u{212a}", "k" });
    try testing.expectEqual(@as(usize, 6), got.len);
    for ([_][]const u8{ "README", "readme", "caf\u{e9}", "cafe\u{301}", "\u{212a}", "k" }) |w| {
        try testing.expect(contains(got, w));
    }
}

test "foldKey: simple case folding, as filesystems fold names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(!std.mem.eql(u8, try foldKey(a, "Stra\u{df}e"), try foldKey(a, "STRASSE")));
    try testing.expectEqualStrings(try foldKey(a, "\u{df}"), try foldKey(a, "\u{1e9e}"));
    try testing.expectEqualStrings(try foldKey(a, "\u{3c3}"), try foldKey(a, "\u{3a3}"));
}

test "foldKey: marks are put in canonical order before folding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(try foldKey(a, "a\u{301}\u{345}"), try foldKey(a, "a\u{345}\u{301}"));
}

test "escapePattern: escapes gitignore metacharacters and round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("a\\[b\\]\\*\\?\\\\c", try escapePattern(a, "a[b]*?\\c", false));
    try testing.expectEqualStrings("\\#x", try escapePattern(a, "#x", true));
    try testing.expectEqualStrings("\\!x", try escapePattern(a, "!x", true));
    try testing.expectEqualStrings("#x", try escapePattern(a, "#x", false));
    try testing.expectEqualStrings("a b\\ \\ ", try escapePattern(a, "a b  ", false));
    for ([_][]const u8{ "a[b]*?\\c", "#x", "a b  ", "plain" }) |s| {
        try testing.expectEqualStrings(s, try unescapePattern(a, try escapePattern(a, s, true)));
    }
}

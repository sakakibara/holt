//! Normalizes a git remote URL into a repo Identity ("<host>/<owner>/<repo>")
//! and derives its clone path. String parsing only - no filesystem or
//! subprocess I/O.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const testing = std.testing;

/// `host`/`owner`/`repo` are allocator-owned when built by `fromUrl` and
/// borrowed/static when built by `local`. holt allocates per command in an
/// arena and never frees returned values field-by-field, so there is no
/// `deinit` - the arena reclaims both cases uniformly.
pub const Identity = struct {
    host: []const u8,
    owner: []const u8,
    repo: []const u8,

    pub fn isLocal(self: Identity) bool {
        return std.mem.eql(u8, self.host, "local");
    }

    /// "<host>/<owner>/<repo>" or "local/<repo>": a portable, display-only
    /// logical key, always `/`-joined regardless of platform - never an
    /// on-disk path. Caller owns the returned memory.
    pub fn relPath(self: Identity, alloc: std.mem.Allocator) ![]u8 {
        if (self.isLocal()) return std.fmt.allocPrint(alloc, "local/{s}", .{self.repo});
        return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ self.host, self.owner, self.repo });
    }

    /// `code_root` joined with the native on-disk clone location. `relPath`
    /// is already the `/`-joined logical key (including a GitLab subgroup
    /// `owner`, itself `/`-separated), so re-splitting it via `joinSlashy`
    /// nests each segment with the platform separator instead of leaving an
    /// embedded `/` inside a single Windows path component. Caller owns the
    /// returned memory.
    pub fn clonePath(self: Identity, alloc: std.mem.Allocator, code_root: []const u8) ![]u8 {
        const rel = try self.relPath(alloc);
        defer alloc.free(rel);
        return fsutil.joinSlashy(alloc, code_root, rel);
    }

    pub fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, a.host, b.host) and
            std.mem.eql(u8, a.owner, b.owner) and
            std.mem.eql(u8, a.repo, b.repo);
    }
};

/// Identity for a repo with no remote yet; relPath is "local/<name>". Unlike
/// fromUrl, fields borrow `name`/static strings rather than owning memory.
pub fn local(name: []const u8) Identity {
    return .{ .host = "local", .owner = "", .repo = name };
}

const Parsed = struct {
    host: []const u8,
    path: []const u8,
};

fn stripScheme(url: []const u8) ?[]const u8 {
    const schemes = [_][]const u8{ "ssh://", "https://", "http://", "git://" };
    for (schemes) |s| {
        if (std.ascii.startsWithIgnoreCase(url, s)) return url[s.len..];
    }
    return null;
}

/// Drops "[user@]" and a trailing ":port" from a URL authority.
fn authorityHost(authority: []const u8) []const u8 {
    const after_user = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
    const host_end = std.mem.indexOfScalar(u8, after_user, ':') orelse after_user.len;
    return after_user[0..host_end];
}

fn parseUrl(url: []const u8) error{UnrecognizedUrl}!Parsed {
    if (stripScheme(url)) |rest| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UnrecognizedUrl;
        return .{ .host = authorityHost(rest[0..slash]), .path = rest[slash + 1 ..] };
    }
    if (std.mem.indexOf(u8, url, "://") != null) return error.UnrecognizedUrl;

    // scp-like "[user@]host:path" - only when the colon precedes any slash,
    // so an unrecognized "scheme://..." isn't misread as one.
    const colon = std.mem.indexOfScalar(u8, url, ':');
    const first_slash = std.mem.indexOfScalar(u8, url, '/');
    if (colon != null and (first_slash == null or colon.? < first_slash.?)) {
        const c = colon.?;
        const authority = url[0..c];
        const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
        return .{ .host = host, .path = url[c + 1 ..] };
    }

    return parseShorthand(url);
}

/// Shorthand for a user-typed remote: "owner/repo" defaults to host
/// github.com, while "host/owner/repo" (three or more segments) names the host
/// explicitly. Fewer than two segments is not a repo reference.
fn parseShorthand(url: []const u8) error{UnrecognizedUrl}!Parsed {
    const trimmed = trimTrailingSlashes(url);
    const first_slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return error.UnrecognizedUrl;
    const rest = trimmed[first_slash + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '/') != null) {
        // host/owner/repo: the first segment is the host.
        return .{ .host = trimmed[0..first_slash], .path = rest };
    }
    // owner/repo: default to github.com.
    return .{ .host = "github.com", .path = trimmed };
}

fn trimTrailingSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn stripDotGit(s: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, ".git")) s[0 .. s.len - 4] else s;
}

/// Normalizes a git remote URL (scp-like, ssh://, https://, http://, git://)
/// into an Identity. Rejects fewer than two path segments, empty segments,
/// a `.`/`..` segment, a segment carrying a backslash, and a host of "local"
/// (reserved for `local()`). `host`, `owner`, and `repo` on the result are
/// each allocator-owned; free them individually.
pub fn fromUrl(alloc: std.mem.Allocator, url: []const u8) error{ UnrecognizedUrl, OutOfMemory }!Identity {
    const parsed = try parseUrl(url);

    const host = try alloc.alloc(u8, parsed.host.len);
    errdefer alloc.free(host);
    _ = std.ascii.lowerString(host, parsed.host);
    if (std.mem.eql(u8, host, "local")) return error.UnrecognizedUrl;
    // A `.`/`..` host or one carrying a backslash would land in the same
    // clone-path segment as owner/repo segments below; guard it identically.
    if (std.mem.eql(u8, host, ".") or std.mem.eql(u8, host, "..")) return error.UnrecognizedUrl;
    if (std.mem.indexOfScalar(u8, host, '\\') != null) return error.UnrecognizedUrl;

    var path = trimTrailingSlashes(parsed.path);
    path = trimTrailingSlashes(stripDotGit(path));

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(alloc);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.UnrecognizedUrl;
        // `.`/`..` are not normalized by std.fs.path.join, and a smuggled
        // backslash becomes a path separator on Windows - either would let
        // the derived clone path escape code_root (code_root/x/../y).
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.UnrecognizedUrl;
        if (std.mem.indexOfScalar(u8, seg, '\\') != null) return error.UnrecognizedUrl;
        try segments.append(alloc, seg);
    }
    if (segments.items.len < 2) return error.UnrecognizedUrl;

    const repo = try alloc.dupe(u8, segments.items[segments.items.len - 1]);
    errdefer alloc.free(repo);
    const owner = try std.mem.join(alloc, "/", segments.items[0 .. segments.items.len - 1]);

    return .{ .host = host, .owner = owner, .repo = repo };
}

/// Turns user input into a cloneable remote URL: a full URL (scheme or
/// scp-like) is returned unchanged, while a "owner/repo" or "host/owner/repo"
/// shorthand becomes a canonical "https://host/owner/repo" so a plain
/// `git clone` of it - and re-clone from the stored marker later - works.
/// Errors `UnrecognizedUrl` on input that is neither a URL nor a shorthand.
pub fn expand(alloc: std.mem.Allocator, input: []const u8) error{ UnrecognizedUrl, OutOfMemory }![]u8 {
    if (stripScheme(input) != null) return alloc.dupe(u8, input);
    const colon = std.mem.indexOfScalar(u8, input, ':');
    const slash = std.mem.indexOfScalar(u8, input, '/');
    if (colon != null and (slash == null or colon.? < slash.?)) return alloc.dupe(u8, input);

    const id = try fromUrl(alloc, input);
    defer alloc.free(id.host);
    defer alloc.free(id.owner);
    defer alloc.free(id.repo);
    return std.fmt.allocPrint(alloc, "https://{s}/{s}/{s}", .{ id.host, id.owner, id.repo });
}

test "expand: shorthand becomes a canonical https url, a full url passes through" {
    const alloc = testing.allocator;
    {
        const u = try expand(alloc, "acme/widget");
        defer alloc.free(u);
        try testing.expectEqualStrings("https://github.com/acme/widget", u);
    }
    {
        const u = try expand(alloc, "example.com/acme/widget");
        defer alloc.free(u);
        try testing.expectEqualStrings("https://example.com/acme/widget", u);
    }
    {
        const u = try expand(alloc, "git@github.com:acme/widget.git");
        defer alloc.free(u);
        try testing.expectEqualStrings("git@github.com:acme/widget.git", u);
    }
    {
        const u = try expand(alloc, "https://github.com/acme/widget");
        defer alloc.free(u);
        try testing.expectEqualStrings("https://github.com/acme/widget", u);
    }
}

fn expectIdentity(want: Identity, url: []const u8) !void {
    const got = try fromUrl(testing.allocator, url);
    defer testing.allocator.free(got.host);
    defer testing.allocator.free(got.owner);
    defer testing.allocator.free(got.repo);
    try testing.expectEqualStrings(want.host, got.host);
    try testing.expectEqualStrings(want.owner, got.owner);
    try testing.expectEqualStrings(want.repo, got.repo);
}

test "fromUrl: accepted forms all normalize to the same identity" {
    const want = Identity{ .host = "github.com", .owner = "sakakibara", .repo = "holt" };
    const urls = [_][]const u8{
        "git@github.com:sakakibara/holt.git",
        "ssh://git@github.com/sakakibara/holt.git",
        "ssh://git@github.com:22/sakakibara/holt.git",
        "https://github.com/sakakibara/holt",
        "https://github.com/sakakibara/holt.git",
        "https://github.com/sakakibara/holt/",
        "https://github.com/sakakibara/holt.git/",
        "http://github.com/sakakibara/holt",
        "git://github.com/sakakibara/holt",
        "sakakibara/holt",
        "github.com/sakakibara/holt",
    };
    for (urls) |url| try expectIdentity(want, url);
}

test "fromUrl: host/owner/repo shorthand names a non-github host" {
    try expectIdentity(.{ .host = "example.com", .owner = "acme", .repo = "widget" }, "example.com/acme/widget");
}

test "fromUrl: gitlab subgroups join all but the last segment into owner" {
    try expectIdentity(.{ .host = "gitlab.com", .owner = "a/b", .repo = "c" }, "https://gitlab.com/a/b/c");
}

test "fromUrl: host is lowercased, leading www. kept, owner/repo case preserved" {
    try expectIdentity(
        .{ .host = "github.com", .owner = "Sakakibara", .repo = "Holt" },
        "https://GitHub.COM/Sakakibara/Holt",
    );
    try expectIdentity(
        .{ .host = "www.github.com", .owner = "sakakibara", .repo = "holt" },
        "https://www.github.com/sakakibara/holt",
    );
}

test "fromUrl: scheme matching is case-insensitive" {
    try expectIdentity(
        .{ .host = "github.com", .owner = "O", .repo = "R" },
        "HTTPS://GitHub.com/O/R",
    );
    try expectIdentity(
        .{ .host = "host", .owner = "o", .repo = "r" },
        "SSH://git@Host/o/r",
    );
}

test "fromUrl: rejects unrecognized or underspecified forms" {
    const urls = [_][]const u8{
        "",
        "holt",
        "github.com",
        "https://github.com/only",
        "https://github.com//sakakibara/holt", // empty path segment
        "https://local/sakakibara/holt", // "local" host collision
        "ftp://github.com/sakakibara/holt", // unrecognized scheme
    };
    for (urls) |url| {
        try testing.expectError(error.UnrecognizedUrl, fromUrl(testing.allocator, url));
    }
}

test "fromUrl: rejects traversal and backslash segments, accepts dotted names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{
        "https://github.com/../foo",
        "https://github.com/acme/../evil",
        "https://github.com/acme/..\\..\\evil",
    }) |bad| {
        try testing.expectError(error.UnrecognizedUrl, fromUrl(a, bad));
    }
    // dotted names and subgroups are fine (whole-segment check, not substring).
    _ = try fromUrl(a, "https://github.com/acme/my.repo");
    _ = try fromUrl(a, "https://gitlab.com/group/subgroup/repo");
}

test "fromUrl: different accepted forms of the same repo compare eql" {
    const a = try fromUrl(testing.allocator, "git@github.com:sakakibara/holt.git");
    defer testing.allocator.free(a.host);
    defer testing.allocator.free(a.owner);
    defer testing.allocator.free(a.repo);
    const b = try fromUrl(testing.allocator, "https://github.com/sakakibara/holt");
    defer testing.allocator.free(b.host);
    defer testing.allocator.free(b.owner);
    defer testing.allocator.free(b.repo);
    try testing.expect(Identity.eql(a, b));
}

test "relPath and clonePath join host/owner/repo, including subgroup owners" {
    const id = try fromUrl(testing.allocator, "https://gitlab.com/a/b/c");
    defer testing.allocator.free(id.host);
    defer testing.allocator.free(id.owner);
    defer testing.allocator.free(id.repo);

    const rel = try id.relPath(testing.allocator);
    defer testing.allocator.free(rel);
    try testing.expectEqualStrings("gitlab.com/a/b/c", rel);

    const clone = try id.clonePath(testing.allocator, "/code");
    defer testing.allocator.free(clone);
    const want_clone = try std.fs.path.join(testing.allocator, &.{ "/code", "gitlab.com", "a", "b", "c" });
    defer testing.allocator.free(want_clone);
    try testing.expectEqualStrings(want_clone, clone);
}

test "local: isLocal, relPath, and clonePath" {
    const id = local("scratch");
    try testing.expect(id.isLocal());

    const rel = try id.relPath(testing.allocator);
    defer testing.allocator.free(rel);
    try testing.expectEqualStrings("local/scratch", rel);

    const clone = try id.clonePath(testing.allocator, "/code");
    defer testing.allocator.free(clone);
    const want_clone = try std.fs.path.join(testing.allocator, &.{ "/code", "local", "scratch" });
    defer testing.allocator.free(want_clone);
    try testing.expectEqualStrings(want_clone, clone);
}

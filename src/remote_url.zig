//! How git reads a remote URL, as far as the delete gate needs: which
//! transport it takes, the host it reaches, the parts that may hold a
//! credential, and whether the text can be read two ways.

const std = @import("std");
const builtin = @import("builtin");

/// The transport git takes for a URL: a local path (`file://` included),
/// its own ssh, git and http transports, or anything else (a remote
/// helper, `<t>::<address>` or `<scheme>://` of another scheme).
pub const Transport = enum { local, ssh, git, http, https, unsupported };

/// A URL as `parse` reads it.
pub const Url = struct {
    transport: Transport = .local,
    /// The text before `://` or `::`, when there is one.
    scheme: ?[]const u8 = null,
    /// host(u): for `<scheme>://`, the authority after its last `@`,
    /// without port and brackets; for scp-like, the text before the first
    /// `:` (a bracketed host up to `]`), after its last `@`. Null when
    /// there is none to read.
    host: ?[]const u8 = null,
    /// The userinfo before host(u), without its `@`.
    user: ?[]const u8 = null,
    port: ?[]const u8 = null,
    /// The text can be read two ways, or git reads it otherwise than it
    /// looks: `%` in a scheme authority, a host starting with `-`, a `[`
    /// in the authority that does not open host(u), or a userinfo split
    /// that disagrees with host(u).
    ambiguous: bool = false,
    /// The userinfo split: from `info_start` to just past its last `@`
    /// (`info_end`, `info_start` when there is none).
    info_start: usize = 0,
    info_end: usize = 0,
    /// Where the query and fragment start: the first `?` or `#`, else the
    /// URL's length.
    tail: usize,

    /// ssh, git, http or https.
    pub fn countingTransport(self: Url) bool {
        return switch (self.transport) {
            .ssh, .git, .http, .https => true,
            .local, .unsupported => false,
        };
    }
};

/// `url` read as git reads it (B8 of the delete-gate paper).
pub fn parse(url: []const u8) Url {
    var out: Url = .{ .tail = url.len };
    if (prefixEnd(url, "::")) |end| {
        out.transport = .unsupported;
        out.scheme = url[0 .. end - 2];
        return out;
    }
    const authority_start = prefixEnd(url, "://");
    var authority_end: usize = undefined;
    if (authority_start) |start| {
        const scheme = url[0 .. start - 3];
        out.scheme = scheme;
        out.transport = if (std.mem.eql(u8, scheme, "ssh") or std.mem.eql(u8, scheme, "git+ssh") or std.mem.eql(u8, scheme, "ssh+git")) .ssh else if (std.mem.eql(u8, scheme, "git")) .git else if (std.mem.eql(u8, scheme, "http")) .http else if (std.mem.eql(u8, scheme, "https")) .https else if (std.mem.eql(u8, scheme, "file")) .local else .unsupported;
        if (out.transport == .unsupported) return out;
        out.info_start = start;
        authority_end = start + (std.mem.indexOfAny(u8, url[start..], if (out.transport == .http or out.transport == .https) "/?#" else "/") orelse url.len - start);
    } else {
        if (localPath(url) != null) return out;
        out.transport = .ssh;
        authority_end = scpColon(url) orelse {
            out.ambiguous = true;
            return out;
        };
    }
    out.info_end = out.info_start;
    out.tail = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    if (std.mem.lastIndexOfScalar(u8, url[out.info_start..out.tail], '@')) |at| out.info_end = out.info_start + at + 1;
    if (std.mem.lastIndexOfScalar(u8, url, '@')) |at| {
        if (at >= authority_end or at >= out.tail) out.ambiguous = true;
    }
    const authority = url[out.info_start..authority_end];
    if (authority_start != null and std.mem.indexOfScalar(u8, authority, '%') != null) out.ambiguous = true;
    const host_start = out.info_start + if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| at + 1 else @as(usize, 0);
    if (host_start > out.info_start) out.user = url[out.info_start .. host_start - 1];
    if (std.mem.indexOfScalar(u8, authority, '[')) |b| if (out.info_start + b != host_start) {
        out.ambiguous = true;
    };
    const host_port = url[host_start..authority_end];
    if (std.mem.startsWith(u8, host_port, "[")) {
        if (std.mem.indexOfScalar(u8, host_port, ']')) |end| {
            out.host = host_port[1..end];
            const rest = host_port[end + 1 ..];
            if (rest.len > 0) {
                if (authority_start != null and rest[0] == ':') {
                    out.port = rest[1..];
                } else out.ambiguous = true;
            }
        } else out.ambiguous = true;
    } else if (authority_start != null) {
        if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
            out.host = host_port[0..colon];
            out.port = host_port[colon + 1 ..];
            if (std.mem.indexOfScalar(u8, host_port[colon + 1 ..], ':') != null) out.ambiguous = true;
        } else out.host = host_port;
    } else out.host = host_port;
    if (out.host) |host| {
        if (host.len > 0 and host[0] == '-') out.ambiguous = true;
    } else out.ambiguous = true;
    return out;
}

/// The path `url` names when git reads it as a local path: the rest of a
/// `file://` URL, or text that is neither `<scheme>://` nor `<t>::` and has
/// no `:` before its first `/` (on Windows, `\` too, and a drive letter's
/// `:` is part of the path); null for any other URL.
pub fn localPath(url: []const u8) ?[]const u8 {
    if (prefixEnd(url, "::") != null) return null;
    if (std.mem.startsWith(u8, url, "file://")) return url[7..];
    if (prefixEnd(url, "://") != null) return null;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return url;
    const slash = std.mem.indexOfAny(u8, url, if (builtin.os.tag == .windows) "/\\" else "/") orelse url.len;
    if (colon > slash) return url;
    if (builtin.os.tag == .windows and colon == 1 and std.ascii.isAlphabetic(url[0])) return url;
    return null;
}

fn scpColon(url: []const u8) ?usize {
    var bracket = false;
    for (url, 0..) |c, i| {
        if (c == '[') bracket = true;
        if (c == ']') bracket = false;
        if (c == ':' and !bracket) return i;
        if (c == '/') return null;
    }
    return null;
}

fn prefixEnd(url: []const u8, delimiter: []const u8) ?usize {
    if (url.len == 0 or !std.ascii.isAlphanumeric(url[0])) return null;
    for (url[1..], 1..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-') continue;
        return if (std.mem.startsWith(u8, url[i..], delimiter)) i + delimiter.len else null;
    }
    return null;
}

/// The shown URL of `raw`: without its userinfo split and everything from
/// the first `?` or `#`; `<scheme>://...`, or `...` scp-like, when it is
/// ambiguous; a local path as it is; only the transport's name for any
/// other URL. Not yet made printable.
pub fn shown(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    const url = parse(raw);
    if (url.transport == .unsupported) return a.dupe(u8, url.scheme orelse "unsupported");
    if (url.transport == .local and url.scheme == null) return a.dupe(u8, raw);
    if (url.ambiguous) {
        if (url.scheme) |scheme| return std.mem.concat(a, u8, &.{ scheme, "://..." });
        return a.dupe(u8, "...");
    }
    return std.mem.concat(a, u8, &.{ raw[0..url.info_start], raw[url.info_end..url.tail] });
}

/// Whether the host `raw_host`, read as git reads a URL's host, is this
/// machine, `machine_hostname` being this machine's name: empty or holding
/// `%` (a zone, which reaches loopback on some systems); a loopback,
/// `0.0.0.0` or `::` address in any spelling `inet_aton` and `inet_pton`
/// read (v4-mapped included); `localhost` or a name ending in
/// `.localhost`; or the machine's name, its first label, or that label
/// with `.local`. Case and a trailing dot are ignored.
pub fn hostIsLocal(raw_host: []const u8, machine_hostname: []const u8) bool {
    var host = trimDot(raw_host);
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '%') != null) return true;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or (host.len > ".localhost".len and std.ascii.endsWithIgnoreCase(host, ".localhost"))) return true;
    const machine = trimDot(machine_hostname);
    if (machine.len > 0) {
        const first = machine[0 .. std.mem.indexOfScalar(u8, machine, '.') orelse machine.len];
        if (std.ascii.eqlIgnoreCase(host, machine) or std.ascii.eqlIgnoreCase(host, first)) return true;
        if (host.len == first.len + ".local".len and std.ascii.eqlIgnoreCase(host[0..first.len], first) and std.ascii.eqlIgnoreCase(host[first.len..], ".local")) return true;
    }
    if (ipv4(host)) |ip| return ip == 0 or ip >> 24 == 127;
    const words = ipv6(host) orelse return false;
    if (std.mem.allEqual(u16, words[0..7], 0) and words[7] <= 1) return true;
    if (std.mem.allEqual(u16, words[0..5], 0) and words[5] == 65535) {
        return words[6] >> 8 == 127 or (words[6] == 0 and words[7] == 0);
    }
    return false;
}

fn trimDot(host: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, host, ".")) host[0 .. host.len - 1] else host;
}

fn ipv4(host: []const u8) ?u32 {
    var parts: [4]u32 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (part.len == 0 or count == parts.len) return null;
        const hex = part.len >= 2 and part[0] == '0' and (part[1] == 'x' or part[1] == 'X');
        const base: u32 = if (hex) 16 else if (part.len > 1 and part[0] == '0') 8 else 10;
        const digits = if (hex) part[2..] else part;
        if (digits.len == 0) return null;
        var value: u32 = 0;
        for (digits) |c| {
            const digit = std.fmt.charToDigit(c, @intCast(base)) catch return null;
            value = std.math.mul(u32, value, base) catch return null;
            value = std.math.add(u32, value, digit) catch return null;
        }
        parts[count] = value;
        count += 1;
    }
    var value: u32 = 0;
    for (parts[0 .. count - 1]) |part| {
        if (part > 255) return null;
        value = (value << 8) | part;
    }
    const remaining: u6 = @intCast(8 * (5 - count));
    if (@as(u64, parts[count - 1]) >= @as(u64, 1) << remaining) return null;
    return @intCast((@as(u64, value) << remaining) | parts[count - 1]);
}

fn ipv6(host: []const u8) ?[8]u16 {
    if (host.len < 2 or host.len > 45) return null;
    var words: [8]u16 = @splat(0);
    var count: usize = 0;
    var compressed: ?usize = null;
    var pos: usize = 0;
    if (host[0] == ':') {
        if (host[1] != ':') return null;
        compressed = 0;
        pos = 2;
    }
    while (pos < host.len) {
        const end = std.mem.indexOfScalarPos(u8, host, pos, ':') orelse host.len;
        const part = host[pos..end];
        if (part.len == 0 or count == words.len) return null;
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            if (end != host.len or count > 6) return null;
            var it = std.mem.splitScalar(u8, part, '.');
            var bytes: [4]u8 = undefined;
            for (&bytes) |*byte| {
                const digits = it.next() orelse return null;
                if (digits.len == 0 or digits.len > 3 or (digits.len > 1 and digits[0] == '0')) return null;
                var value: u16 = 0;
                for (digits) |c| {
                    if (!std.ascii.isDigit(c)) return null;
                    value = value * 10 + (c - '0');
                }
                if (value > 255) return null;
                byte.* = @intCast(value);
            }
            if (it.next() != null) return null;
            words[count] = (@as(u16, bytes[0]) << 8) | bytes[1];
            words[count + 1] = (@as(u16, bytes[2]) << 8) | bytes[3];
            count += 2;
        } else {
            if (part.len > 4) return null;
            var value: u16 = 0;
            for (part) |c| value = (value << 4) | (std.fmt.charToDigit(c, 16) catch return null);
            words[count] = value;
            count += 1;
        }
        if (end == host.len) break;
        pos = end + 1;
        if (pos == host.len) return null;
        if (host[pos] == ':') {
            if (compressed != null) return null;
            compressed = count;
            pos += 1;
        }
    }
    if (compressed) |start| {
        if (count == words.len) return null;
        std.mem.copyBackwards(u16, words[words.len - (count - start) ..], words[start..count]);
        @memset(words[start..][0 .. words.len - count], 0);
    } else if (count != words.len) return null;
    return words;
}

test "localPath: helpers never become local paths" {
    for ([_][]const u8{ "fd::7", "ext::ssh host:p", "hg::/tmp/repo", "gcrypt::file:///tmp/repo", "9helper::address" }) |url| {
        try std.testing.expect(localPath(url) == null);
    }
}

test "parse: Git transport and authority syntax" {
    const cases = [_]struct { raw: []const u8, transport: Transport, host: ?[]const u8 = null, user: ?[]const u8 = null, port: ?[]const u8 = null, ambiguous: bool = false }{
        .{ .raw = "relative/repo:part", .transport = .local },
        .{ .raw = "/tmp/repo", .transport = .local },
        .{ .raw = "repo.bundle", .transport = .local },
        .{ .raw = "file:///tmp/repo", .transport = .local, .host = "" },
        .{ .raw = "ssh://alice@host:2222/repo", .transport = .ssh, .host = "host", .user = "alice", .port = "2222" },
        .{ .raw = "ssh://user%40name@host/repo", .transport = .ssh, .host = "host", .user = "user%40name", .ambiguous = true },
        .{ .raw = "git://%31%32%37.0.0.1/repo", .transport = .git, .host = "%31%32%37.0.0.1", .ambiguous = true },
        .{ .raw = "ssh://alice:pw@host/repo", .transport = .ssh, .host = "host", .user = "alice:pw" },
        .{ .raw = "git+ssh://host/repo", .transport = .ssh, .host = "host" },
        .{ .raw = "ssh+git://host/repo", .transport = .ssh, .host = "host" },
        .{ .raw = "alice@host:repo", .transport = .ssh, .host = "host", .user = "alice" },
        .{ .raw = "[::1]:repo", .transport = .ssh, .host = "::1" },
        .{ .raw = "alice@[::ffff:127.0.0.1]:repo", .transport = .ssh, .host = "::ffff:127.0.0.1", .user = "alice" },
        .{ .raw = "ssh://alice@[::1]:2222/repo", .transport = .ssh, .host = "::1", .user = "alice", .port = "2222" },
        .{ .raw = "https://alice:pw@host:443/repo?secret#more", .transport = .https, .host = "host", .user = "alice:pw", .port = "443" },
        .{ .raw = "http://host?secret", .transport = .http, .host = "host" },
        .{ .raw = "git://host?secret", .transport = .git, .host = "host?secret" },
        .{ .raw = "HTTP://host/repo", .transport = .unsupported },
        .{ .raw = "hg::https://host/repo", .transport = .unsupported },
        .{ .raw = "ext::ssh host:p", .transport = .unsupported },
        .{ .raw = "fd::7", .transport = .unsupported },
        .{ .raw = "9helper::address", .transport = .unsupported },
        .{ .raw = "9scheme://host/path", .transport = .unsupported },
        .{ .raw = "u:pw@h:p", .transport = .ssh, .host = "u", .ambiguous = true },
        .{ .raw = "http://alice:AB/CD@h/x", .transport = .http, .host = "alice", .port = "AB", .ambiguous = true },
        .{ .raw = "git://127.0.0.1:p/a@elsewhere.invalid/x.git", .transport = .git, .host = "127.0.0.1", .port = "p", .ambiguous = true },
        .{ .raw = "http://127.0.0.1/a@elsewhere.invalid/x", .transport = .http, .host = "127.0.0.1", .ambiguous = true },
        .{ .raw = "https://host?secret@elsewhere/x", .transport = .https, .host = "host", .ambiguous = true },
        .{ .raw = "ssh://-option/repo", .transport = .ssh, .host = "-option", .ambiguous = true },
        .{ .raw = "ssh:///repo", .transport = .ssh, .host = "" },
        .{ .raw = "git://:9418/repo", .transport = .git, .host = "", .port = "9418" },
        .{ .raw = "git://[]:9418/repo", .transport = .git, .host = "", .port = "9418" },
        .{ .raw = "[::1%1]:repo", .transport = .ssh, .host = "::1%1" },
        .{ .raw = "[fe80::1%lo0]:repo", .transport = .ssh, .host = "fe80::1%lo0" },
        .{ .raw = "git://[::1%25lo0]:9418/repo", .transport = .git, .host = "::1%25lo0", .port = "9418", .ambiguous = true },
        .{ .raw = "repo.bundle", .transport = .local },
    };
    for (cases) |case| {
        const got = parse(case.raw);
        try std.testing.expectEqual(case.transport, got.transport);
        try std.testing.expectEqual(case.ambiguous, got.ambiguous);
        try std.testing.expectEqualDeep(case.host, got.host);
        try std.testing.expectEqualDeep(case.user, got.user);
        try std.testing.expectEqualDeep(case.port, got.port);
    }
}

test "shown: hides credentials including malformed and helper addresses" {
    const cases = [_][2][]const u8{
        .{ "http://alice:AB/CD@h/x", "http://..." },
        .{ "http://alice:AB/CD+EF@127.0.0.1:18402/x.git", "http://..." },
        .{ "u:pw@h:p", "..." },
        .{ "https://alice:secret@host/x?token#fragment", "https://host/x" },
        .{ "git://alice:secret@host/x?token", "git://host/x" },
        .{ "alice@host:repo?token#fragment", "host:repo" },
        .{ "host:repo#token", "host:repo" },
        .{ "host:repo?token@tail", "..." },
        .{ "ssh://host?secret", "ssh://host" },
        .{ "ext::ssh alice:secret@host", "ext" },
        .{ "hg::https://alice:secret@host?token", "hg" },
        .{ "custom://alice:secret@host?token", "custom" },
        .{ "9helper::alice:secret@host", "9helper" },
        .{ "git://%31%32%37.0.0.1/repo", "git://..." },
        .{ "ssh://alice%3Asecret%40host/repo", "ssh://..." },
        .{ "ssh://host/repo%20name", "ssh://host/repo%20name" },
        .{ "relative/path?literal", "relative/path?literal" },
        .{ "file:///tmp/repo", "file:///tmp/repo" },
        .{ "file://alice:secret@host/path?token", "file://host/path" },
    };
    for (cases) |case| {
        const got = try shown(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "hostIsLocal: numeric spellings and machine names" {
    const local = [_][]const u8{
        "127.1",           "127.0.1",       "2130706433", "0x7f000001",      "0x7f.1",           "0177.0.0.1",
        "127.255.255.255", "127.0.0.1",     "0",          "0.0.0.0",         "localhost",        "localhost.",
        "LOCALHOST",       "sub.localhost", "::1",        "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1", "::ffff:7f00:1",
        "::ffff:0:0",      "::",            "[::1]",      "machine",         "MACHINE.local",    "machine.example",
    };
    for (local) |host| try std.testing.expect(hostIsLocal(host, "machine.example"));
    for ([_][]const u8{ "::1%lo0", "::ffff:127.0.0.1%zone", "[::1%lo0]", "0:0:0:0:0:ffff:127.0.0.1", "", "[]", "fe80::1%lo0", "::1%1", "%" }) |host| try std.testing.expect(hostIsLocal(host, "machine.example"));
    const remote = [_][]const u8{
        "128.0.0.1",         "126.255.255.255",   "::2",                "::ffff:128.0.0.1", "10.0.0.1",    "192.168.0.1",
        "localhost.example", "notlocalhost",      "other.local",        "127.0.0.1.evil",   "127.0.0.1..", "4294967296",
        "0x100000000",       "127.16777216",      "127.0.65536",        "127.0.0.256",      "127.0.0.1.2", "+2130706433",
        "-2130706433",       " 127.0.0.1",        "127.0.0.1 ",         "0x",               "09",          "127..1",
        "::ffff:127.00.0.1", "::ffff:0x7f.0.0.1", ":::1",               "::1:",             "0::0::1",     "0:0:0:0:0:0:0:0::",
        "0:0:0:0:0:0:0:0:1", "::00000",           "::ffff:127.0.0.1:1",
    };
    for (remote) |host| try std.testing.expect(!hostIsLocal(host, "machine.example"));
}

test "localPath: file URLs and platform drive syntax" {
    try std.testing.expectEqualStrings("/tmp/repo", localPath("file:///tmp/repo").?);
    try std.testing.expectEqualStrings("./host:repo", localPath("./host:repo").?);
    try std.testing.expect(localPath("https://host/repo") == null);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\repo", localPath("C:\\repo").?);
    } else try std.testing.expect(localPath("C:\\repo") == null);
}

test "parse: bounded adversarial inputs preserve slice bounds" {
    const started = std.Io.Clock.awake.now(std.testing.io);
    var buffer: [4096]u8 = undefined;
    const alphabet = "a0:/@?#[]+.-\\";
    var random = std.Random.DefaultPrng.init(8134);
    for (0..1000) |_| {
        const len = random.random().uintLessThan(usize, buffer.len + 1);
        for (buffer[0..len]) |*c| c.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        const raw = buffer[0..len];
        const url = parse(raw);
        try std.testing.expect(url.info_start <= url.info_end);
        try std.testing.expect(url.info_end <= url.tail);
        try std.testing.expect(url.tail <= raw.len);
        const text = try shown(std.testing.allocator, raw);
        std.testing.allocator.free(text);
        _ = hostIsLocal(raw, "machine.example");
    }
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds < 5 * std.time.ns_per_s);
}

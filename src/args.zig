//! Comptime type-driven command definitions - the ergonomic front end of the
//! CLI framework. A command declares one schema struct whose every field is a
//! self-describing wrapper (`Flag`, `Opt`, `Pos`, `Rest`) carrying that arg's
//! metadata IN ITS TYPE: help, short letter, completion, and kind. From that
//! one declaration the framework derives:
//!   - `Args(Spec)`: a plain struct (`bool`, `?[]const u8`, ...) the command's
//!     `run` receives and reads directly (`a.json`, `a.org`), fully typed;
//!   - the parser that fills it;
//!   - the flag set, the usage line, and the completion metadata.
//!
//! Because the metadata is welded to the field - not a side table joined by a
//! stringly-matched name - it cannot be misnamed or desynced, and a bad
//! completion category is a compile error. Those are exactly the silent
//! failure modes cobra (and any separate-metadata design) leaves open.

const std = @import("std");
const cli = @import("cli.zig");

pub const Kind = enum { flag, option, positional, variadic };

/// Per-field metadata, carried in the wrapper type. Every field defaults, so a
/// wrapper spells out only what it needs (`Flag(.{ .help = "..." })`).
pub const Meta = struct {
    /// Short flag letter (`-j`); null means long-only.
    short: ?u8 = null,
    help: []const u8 = "",
    /// How the value (option) or argument (positional) completes.
    complete: cli.Complete = .none,
    value_name: []const u8 = "value",
};

const Info = struct { kind: Kind, Value: type, meta: Meta };

/// A boolean switch (`--json`). Parsed value: `bool`.
pub fn Flag(comptime m: Meta) type {
    return struct {
        pub const arg_info = Info{ .kind = .flag, .Value = bool, .meta = m };
    };
}

/// An optional value option (`--org <v>`). Parsed value: `?T` (null when
/// absent).
pub fn Opt(comptime T: type, comptime m: Meta) type {
    return struct {
        pub const arg_info = Info{ .kind = .option, .Value = ?T, .meta = m };
    };
}

/// A positional argument. `Pos([]const u8, ...)` is required; `Pos(?[]const u8,
/// ...)` is optional. Positionals are consumed in schema-declaration order.
pub fn Pos(comptime T: type, comptime m: Meta) type {
    return struct {
        pub const arg_info = Info{ .kind = .positional, .Value = T, .meta = m };
    };
}

/// A final positional that soaks up every token after a literal `--` (a
/// passthrough command's own argv). Parsed value: `[]const []const u8`.
pub fn Rest(comptime m: Meta) type {
    return struct {
        pub const arg_info = Info{ .kind = .variadic, .Value = []const []const u8, .meta = m };
    };
}

fn infoOf(comptime SpecField: type) Info {
    return SpecField.arg_info;
}

/// The non-derivable command attributes. A closed struct (not an `anytype`
/// bag) so a misspelled attribute - `.grop`, `.detials` - is a compile error,
/// exactly like a misspelled field in `Meta`.
pub const About = struct {
    name: []const u8,
    about: []const u8,
    group: cli.Group = .system,
    /// Overrides the auto-generated synopsis when set.
    usage: ?[]const u8 = null,
    details: []const u8 = "",
    needs_workspace: bool = true,
    /// Mutually-exclusive groups: within each inner list of field names, at
    /// most one may be provided, else a usage error names the conflicting two.
    /// Field names are comptime-checked against the schema, so a typo is a
    /// build error - the constraint can never silently reference a field that
    /// does not exist.
    exclusive: []const []const []const u8 = &.{},
};

/// The plain struct a command's `run` receives: each schema field mapped to
/// its parsed value type (`Flag` -> bool, `Opt(T)` -> ?T, ...), reified with
/// `@Struct`. `run` reads `a.json`, `a.org` directly - no `.value`, no
/// string-keyed lookup.
pub fn Args(comptime Spec: type) type {
    const spec_fields = @typeInfo(Spec).@"struct".fields;
    comptime var names: [spec_fields.len][:0]const u8 = undefined;
    comptime var types: [spec_fields.len]type = undefined;
    inline for (spec_fields, 0..) |sf, i| {
        names[i] = sf.name;
        types[i] = infoOf(sf.type).Value;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = name[0..name.len].*;
        for (&buf) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const final = buf;
        return &final;
    }
}

/// Builds the runtime `cli.Command` for a schema-typed command: derives its
/// flags, positional slots, and usage from `Spec`, and wraps `run_fn` in a
/// trampoline that parses argv into an `Args(Spec)` value first. Call at
/// comptime (in the command table).
pub fn command(
    comptime Spec: type,
    comptime about: About,
    comptime run_fn: fn (ctx: *cli.Ctx, args: Args(Spec)) anyerror!u8,
) cli.Command {
    comptime validate(Spec, about);
    const Trampoline = struct {
        fn run(ctx: *cli.Ctx) anyerror!u8 {
            const parsed = try parse(Spec, ctx);
            try checkExclusive(Spec, about, ctx, parsed);
            return run_fn(ctx, parsed);
        }
    };

    return .{
        .name = about.name,
        .summary = about.about,
        .usage = about.usage orelse autoUsage(Spec, about.name),
        .group = about.group,
        .details = about.details,
        .flags = comptime deriveFlags(Spec),
        .args = comptime deriveArgs(Spec),
        .needs_workspace = about.needs_workspace,
        .run = &Trampoline.run,
    };
}

/// Comptime schema sanity: no two flags may share a long name or a short
/// letter (a copy-paste slip is a build error, not a runtime shadow), and
/// every field named in an `exclusive` group must actually exist in the
/// schema (a mistyped constraint is a build error, never a silent no-op).
fn validate(comptime Spec: type, comptime about: About) void {
    const flags = deriveFlags(Spec);
    for (flags, 0..) |a, i| {
        for (flags[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.long, b.long))
                @compileError("duplicate flag --" ++ a.long);
            if (a.short != null and b.short != null and a.short.? == b.short.?)
                @compileError("duplicate short flag -" ++ [_]u8{a.short.?});
        }
    }
    for (about.exclusive) |group| {
        for (group) |name| {
            if (!@hasField(Spec, name))
                @compileError("exclusive constraint names \"" ++ name ++ "\", which is not a field of the schema");
        }
    }
}

/// A field is "provided" when the user gave it: a bool flag that is true, or
/// an optional option/positional that is non-null. Required fields count as
/// always provided.
fn isProvided(comptime Spec: type, parsed: Args(Spec), comptime name: []const u8) bool {
    const v = @field(parsed, name);
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => v,
        .optional => v != null,
        else => true,
    };
}

/// Enforces `about.exclusive` after parsing: at most one field per group may
/// be provided, else a usage error naming the two conflicting flags.
fn checkExclusive(comptime Spec: type, comptime about: About, ctx: *cli.Ctx, parsed: Args(Spec)) !void {
    inline for (about.exclusive) |group| {
        var first: ?[]const u8 = null;
        inline for (group) |name| {
            if (isProvided(Spec, parsed, name)) {
                const spelled = comptime kebab(name);
                if (first) |a| {
                    ctx.args.message = std.fmt.allocPrint(ctx.alloc, "--{s} and --{s} are mutually exclusive", .{ a, spelled }) catch "mutually exclusive options given";
                    return error.UsageError;
                }
                first = spelled;
            }
        }
    }
}

fn deriveFlags(comptime Spec: type) []const cli.Flag {
    comptime {
        var flags: []const cli.Flag = &.{};
        for (@typeInfo(Spec).@"struct".fields) |sf| {
            const in = infoOf(sf.type);
            if (in.kind != .flag and in.kind != .option) continue;
            flags = flags ++ [_]cli.Flag{.{
                .long = kebab(sf.name),
                .short = in.meta.short,
                .help = in.meta.help,
                .takes_value = in.kind == .option,
                .value_name = in.meta.value_name,
                .value = in.meta.complete,
            }};
        }
        return flags;
    }
}

fn deriveArgs(comptime Spec: type) []const cli.Arg {
    comptime {
        var args: []const cli.Arg = &.{};
        for (@typeInfo(Spec).@"struct".fields) |sf| {
            const in = infoOf(sf.type);
            if (in.kind != .positional and in.kind != .variadic) continue;
            args = args ++ [_]cli.Arg{.{
                .name = sf.name,
                .complete = in.meta.complete,
                .optional = @typeInfo(in.Value) == .optional or in.kind == .variadic,
                .variadic = in.kind == .variadic,
            }};
        }
        return args;
    }
}

fn autoUsage(comptime Spec: type, comptime name: []const u8) []const u8 {
    comptime {
        var u: []const u8 = "holt " ++ name;
        var has_flags = false;
        for (@typeInfo(Spec).@"struct".fields) |sf| {
            const in = infoOf(sf.type);
            switch (in.kind) {
                .flag, .option => has_flags = true,
                .positional => u = u ++ if (@typeInfo(in.Value) == .optional) " [" ++ sf.name ++ "]" else " <" ++ sf.name ++ ">",
                .variadic => u = u ++ " -- <" ++ sf.name ++ "...>",
            }
        }
        if (has_flags) u = u ++ " [flags]";
        return u;
    }
}

/// Fills an `Args(Spec)` from `ctx.args`, driven at comptime by each schema
/// field's wrapper kind. Positionals are pulled in declaration order.
fn parse(comptime Spec: type, ctx: *cli.Ctx) !Args(Spec) {
    var result: Args(Spec) = undefined;

    // A variadic `-- passthrough` field is consumed first, no matter where it
    // sits in the schema, so a token meant for the child command (a `--org`
    // after `--`) can never be claimed by one of this command's own options.
    inline for (@typeInfo(Spec).@"struct".fields) |sf| {
        if (comptime infoOf(sf.type).kind == .variadic)
            @field(result, sf.name) = (try ctx.args.restAfterDoubleDash()) orelse &.{};
    }

    inline for (@typeInfo(Spec).@"struct".fields) |sf| {
        const in = comptime infoOf(sf.type);
        if (comptime in.kind == .variadic) continue;
        const long = comptime kebab(sf.name);
        switch (comptime in.kind) {
            .flag => @field(result, sf.name) = ctx.args.flag(long, in.meta.short),
            .option => @field(result, sf.name) = try optionValue(in.Value, ctx, long, in.meta.short),
            .positional => @field(result, sf.name) = try positional(in.Value, sf.name, ctx),
            .variadic => unreachable,
        }
    }
    try ctx.args.finish();
    return result;
}

/// An option's value of type `V` (`?[]const u8` or `?<int>`). Absent yields
/// null; a non-numeric integer is a usage error naming the flag.
fn optionValue(comptime V: type, ctx: *cli.Ctx, long: []const u8, short: ?u8) !V {
    const child = @typeInfo(V).optional.child;
    const raw = (try rawValue(ctx, long, short)) orelse return null;
    if (child == []const u8) return raw;
    if (@typeInfo(child) == .int) {
        return std.fmt.parseInt(child, raw, 10) catch {
            ctx.args.message = std.fmt.allocPrint(ctx.alloc, "--{s} requires an integer, got \"{s}\"", .{ long, raw }) catch "invalid integer";
            return error.UsageError;
        };
    }
    @compileError("unsupported option value type: " ++ @typeName(V));
}

fn rawValue(ctx: *cli.Ctx, long: []const u8, short: ?u8) !?[]const u8 {
    if (try ctx.args.option(long)) |v| return v;
    if (short) |s| return ctx.args.shortOption(s);
    return null;
}

fn positional(comptime V: type, comptime name: []const u8, ctx: *cli.Ctx) !V {
    return switch (V) {
        []const u8 => try ctx.args.requiredPositional(name),
        ?[]const u8 => ctx.args.positional(),
        else => @compileError("unsupported positional type for " ++ name ++ ": " ++ @typeName(V)),
    };
}

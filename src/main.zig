const std = @import("std");
const cli = @import("cli.zig");
const version_cmd = @import("commands/version.zig");
const init_cmd = @import("commands/init.zig");
const setup_cmd = @import("commands/setup.zig");
const path_cmd = @import("commands/path.zig");
const list_cmd = @import("commands/list.zig");
const new_cmd = @import("commands/new.zig");
const add_cmd = @import("commands/add.zig");
const get_cmd = @import("commands/get.zig");
const rm_cmd = @import("commands/rm.zig");
const alias_cmd = @import("commands/alias.zig");
const sync_cmd = @import("commands/sync.zig");
const restore_cmd = @import("commands/restore.zig");
const doctor_cmd = @import("commands/doctor.zig");
const promote_cmd = @import("commands/promote.zig");
const archive_cmd = @import("commands/archive.zig");
const delete_cmd = @import("commands/delete.zig");
const rename_cmd = @import("commands/rename.zig");
const org_cmd = @import("commands/org.zig");
const backup_cmd = @import("commands/backup.zig");
const info_cmd = @import("commands/info.zig");
const status_cmd = @import("commands/status.zig");
const backends_cmd = @import("commands/backends.zig");
const backend_cmd = @import("commands/backend.zig");
const recent_cmd = @import("commands/recent.zig");
const adopt_cmd = @import("commands/adopt.zig");
const keep_cmd = @import("commands/keep.zig");
const edit_cmd = @import("commands/edit.zig");
const config_cmd = @import("commands/config.zig");
const run_cmd = @import("commands/run.zig");
const upgrade_cmd = @import("commands/upgrade.zig");
const worktree_cmd = @import("commands/worktree.zig");

pub const command_table = [_]cli.Command{
    path_cmd.command,
    list_cmd.command,
    init_cmd.command,
    setup_cmd.command,
    new_cmd.command,
    add_cmd.command,
    get_cmd.command,
    rm_cmd.command,
    alias_cmd.command,
    adopt_cmd.command,
    keep_cmd.command,
    info_cmd.command,
    status_cmd.command,
    backends_cmd.command,
    recent_cmd.command,
    sync_cmd.command,
    restore_cmd.command,
    doctor_cmd.command,
    promote_cmd.command,
    rename_cmd.command,
    org_cmd.command,
    archive_cmd.command,
    backup_cmd.command,
    edit_cmd.command,
    worktree_cmd.command,
    backend_cmd.command,
    config_cmd.command,
    run_cmd.command,
    version_cmd.command,
    upgrade_cmd.command,
    delete_cmd.command,
};

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.debug.print("holt: failed to read command line arguments\n", .{});
        return 1;
    };
    return cli.dispatch(init.gpa, argv[1..], &command_table);
}

test {
    _ = @import("json");
    _ = @import("toml");
    _ = @import("fsutil.zig");
    _ = @import("identity.zig");
    _ = @import("config.zig");
    _ = @import("diag.zig");
    _ = @import("marker.zig");
    _ = @import("proc.zig");
    _ = @import("git.zig");
    _ = @import("recover.zig");
    _ = @import("project.zig");
    _ = @import("workspace.zig");
    _ = @import("hub.zig");
    _ = @import("doctor.zig");
    _ = @import("testutil.zig");
    _ = @import("cli.zig");
    _ = @import("ui.zig");
    _ = @import("shell.zig");
    _ = @import("commands/common.zig");
    _ = @import("commands/version.zig");
    _ = @import("commands/init.zig");
    _ = @import("commands/setup.zig");
    _ = @import("commands/path.zig");
    _ = @import("commands/list.zig");
    _ = @import("commands/new.zig");
    _ = @import("commands/add.zig");
    _ = @import("commands/get.zig");
    _ = @import("commands/rm.zig");
    _ = @import("commands/alias.zig");
    _ = @import("commands/sync.zig");
    _ = @import("commands/restore.zig");
    _ = @import("commands/doctor.zig");
    _ = @import("commands/promote.zig");
    _ = @import("commands/archive.zig");
    _ = @import("commands/delete.zig");
    _ = @import("commands/rename.zig");
    _ = @import("commands/org.zig");
    _ = @import("commands/backup.zig");
    _ = @import("commands/info.zig");
    _ = @import("commands/status.zig");
    _ = @import("commands/backends.zig");
    _ = @import("commands/backend.zig");
    _ = @import("commands/recent.zig");
    _ = @import("commands/adopt.zig");
    _ = @import("commands/keep.zig");
    _ = @import("commands/edit.zig");
    _ = @import("commands/config.zig");
    _ = @import("commands/run.zig");
    _ = @import("commands/upgrade.zig");
    _ = @import("commands/worktree.zig");
    _ = @import("integration_test.zig");
}

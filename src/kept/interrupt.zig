//! Test seam: named points inside the multi-step writes of the kept store.
//! A test sets `at`, and the write stops there with `error.Interrupted`,
//! leaving what a crash at that point would leave; or sets `hook`, which
//! runs at every point as another process acting at that moment would.
//! Outside tests nothing ever stops or runs.

const builtin = @import("builtin");

pub const Point = enum {
    keep_pending,
    keep_key,
    keep_block,
    keep_aside,
    keep_fact,
    keep_place,
    /// Keep into an existing kept directory: one missing file is placed.
    keep_merged,
    keep_link,
    keep_clear,
    /// `replaceWithLink`: the content has moved to its temporary.
    link_moved,
    /// `replaceWithLink`: the link is in place, the temporary not removed.
    link_created,
    /// `stage`: the copy is in staging, not yet verified.
    stage_copied,
    /// `placeNew`: the kept parents exist, the copy not yet moved in.
    place_parents,
    /// `setAside`: the data is copied, the manifest not yet written.
    aside_copied,
    /// `setAside`: the manifest is written, not yet verified.
    aside_manifest,
    /// `moveAside`: the manifest is written, the content not yet moved.
    move_manifest,
    /// `replaceKept`: the old copy is set aside, the new one not yet in.
    replace_aside,
    /// `replaceKept`: the old copy was found unchanged since it was set
    /// aside; the new one is not yet in.
    replace_checked,
    /// `replaceKept` without an exchange rename: the old copy is in
    /// staging, the new one not yet in.
    replace_moved_out,
    /// `replaceKept`: the new copy is in, the old one not yet removed.
    replace_swapped,
    /// Released rule: the copy is beside the link, not yet in its place.
    convert_copied,
    /// Released rule: the copy and the link have traded places, the link
    /// not yet removed; or, without an exchange rename, the link is gone
    /// and the copy not yet moved in.
    convert_swapped,
    /// `retargetLink`: the new link is beside the old one.
    retarget_created,
    /// `--take-*`: the `pending` record is written, nothing else yet.
    take_pending,
    /// `--take-local` and `--take-kept`: the local content is set aside.
    take_aside,
    /// `--take-local` and `--take-aside`: the new kept copy and its fact
    /// are in place, the working tree not yet linked.
    take_facts,
    /// `--take-local` and `--take-kept`: the link is made, `pending` not
    /// yet cleared.
    take_link,
    /// `--prune-aside`: an entry a purge mark names is recorded pruned
    /// (`store.writePruned`); nothing of the entry is removed yet.
    prune_marked,
    /// `--prune-aside`: an entry's data is removed, its manifest not yet.
    prune_data,
    /// `--from`: some paths of the old key are copied, not yet all.
    from_copied,
    /// `createStore`: the new store is complete beside `kept/`, not yet
    /// renamed into place.
    store_seeded,
    /// The matcher's scratch repository is complete beside its place, not
    /// yet renamed into it.
    matcher_made,
    /// `rekey.moveKey`: the new key's record exists.
    rekey_record,
    /// `rekey.moveKey`: the new key names the old one and holds its skip
    /// lines; no path has moved yet.
    rekey_from,
    /// `rekey.moveKey`: a path's released marker and facts have moved, its
    /// content not yet.
    rekey_facts,
    /// `rekey.moveKey`: a path's content has moved.
    rekey_path,
    /// `rekey.moveKey`: a copy that cannot move (the old one of a path the
    /// new key holds different content at, or a file no fact names in the
    /// new key) is set aside and verified, and nothing else of the path has
    /// changed yet.
    rekey_aside,
    /// `rekey.moveKey`: the old key's record is gone, its earlier
    /// identities and skip lists not yet.
    rekey_reserved,
};

pub var at: ?Point = null;

pub var hook: ?*const fn (Point) void = null;

pub fn check(p: Point) error{Interrupted}!void {
    if (!builtin.is_test) return;
    if (hook) |h| h(p);
    if (at) |s| if (s == p) return error.Interrupted;
}

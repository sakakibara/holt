# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Kept files.** `holt keep <path>` inside a clone or linked worktree moves
  a file git does not carry (`.clasp.json`, `.claude/settings.local.json`, a
  local config) into `<synced_root>/kept/<host>/<owner>/<repo>/` and links it
  from the clone, so it follows the repo to every machine. A directory is kept
  whole. holt hides each kept path from git in a block of the clone's
  `info/exclude`, and copies anything it replaces or removes to an aside entry
  under `kept/.holt-aside/` first. A path a negated `.gitignore` line
  un-ignores is refused, naming the line, since git would see its link. Kept
  files need git 2.32 or newer.
- `holt keep --review [<path>] [--all]` asks about each ignored file that is
  not kept, but not about an ignored directory holding only directories that
  hold nothing, down to 512 levels below it. For a file in a clone: keep, keep
  everywhere, skip, skip everywhere, or quit, or only skip or quit when its
  name holds a control character. With `--all`, first, for a pattern files in
  several repos share: keep everywhere, skip everywhere, review each, or quit.
  The first prompt, when it is one of these, also offers never ask again,
  which turns kept files off. For content holt's block hides that holt holds
  nowhere else: take local, take kept, or quit. For a file inside a submodule:
  skip, skip everywhere, or quit. For an entry at a hub root: keep, skip
  everywhere, or quit. A name holding a line break is left as it is, or at a
  hub root offered keep or quit. The first write creates `kept/`, seeding
  `kept/.holt-skip` (regenerable content, never offered) and `kept/.holt-auto`
  (kept without asking, seeded with `.clasp.json`) as files the user edits and
  holt never rewrites.
- `holt keep --take-local`, `--take-kept`, and `--take-aside` settle a kept
  path whose copies differ; `--prune-aside [--older-than <days>] [<entry>...]`
  removes aside entries nothing still needs whose stamp and arrival here are
  both older than 30 days and that are here whole, or the entries named (one a
  purge names, or whose manifest says a purge set it aside, only with `--yes`,
  which the hint to remove it anyway carries); `--from <old key>` copies the
  kept files a renamed repo left behind (a clone's root commits, which tie it
  to an old key, are read with replace refs left out); `--retire-machine
  [<machine-id>]` records a machine that will write no more: the records it
  had then, whose copies it may never upload, stop blocking `keep`,
  `--take-local`, and `unkeep`, while what it keeps later blocks again, and
  `--unretire-machine [<machine-id>]` removes the retirement. Until such a
  copy arrives or its machine is retired, the path is reported as kept on that
  machine and not here yet, naming the ways out; once it is retired, an aside
  entry holding that copy is offered with `--take-aside` before `holt unkeep`.
  A retirement is dated, as every date holt prints, as a UTC date, `YYYY-MM-DD
  UTC`; on a machine with no kept-file records, `--retire-machine` says there
  is nothing to retire.
- `holt unkeep <path>` turns a kept path's link back into a regular copy on
  every machine; `--purge <path> --yes` removes a released path's kept copy
  into aside, from which a machine that still links the path restores a copy
  at its next `sync`, leaving the link, unsettled, until that entry arrives
  whole, and removing the link only once the entry is pruned, which
  `kept/.holt-pruned/<entry>` records; `--repo <key>`
  releases every kept path of a repo.
- `holt sync`, `holt restore`, `repo get`, `repo adopt`, `repo promote`,
  `holt worktree`, and `doctor --fix` link kept files, and `sync`, bare
  `restore`, `--review`, and the deleters keep what the auto patterns name.
  `sync` and `restore` exit 1 while a kept file is not linked, and bare
  `restore` names each repo with kept files but no clone here. `adopt` and
  `promote` move a repo's kept files to its new identity.
- `holt doctor` checks `kept files linked`, `kept store valid`, and `tracked
  kept path`, and its symlink scan covers `kept/`. `holt status` shows kept
  paths not linked, paths an auto pattern names that git does not ignore, a
  count of files not kept, and apart from it counts of those the auto
  patterns will keep and of the purged paths restored from aside at the next
  `sync` (`not_linked`, `not_restored`, `not_kept`, `will_keep`, `nested`, and
  `unlisted` in `--json`, beside a project's `local_only` hub entries and the
  `unjudged` clones); `holt info` lists each repo's kept
  paths (`kept` in `--json`). A path an auto pattern names that a negated
  `.gitignore` line un-ignores is shown with that line, not with a keep.
- `sync --dry-run` names what the auto patterns would keep. Without `kept/`,
  `status`, `sync`, and `restore` offer to set kept files up only while a
  clone holds a file not kept, and while the synced folder holds projects
  they say another machine's `kept/` may still be downloading instead. After
  a backend switch that left `kept/` behind, `status`, `sync`, `restore`, and
  `doctor` say `kept/ is at <old>: copy it to <new>`, and `keep`, `unkeep`,
  `doctor --retire`, and the deleters refuse with that line.
- `holt doctor --retire` reports, changing nothing, what exists only on this
  machine before it is wiped: files not kept, nested repositories, unsettled
  kept files, uncommitted changes, the git state no remote holds and the
  operations in progress that the deleters refuse on, in every git directory
  it weighs, weighed and hinted as they do it (every working tree's
  HEAD included, each URL that did not answer with its way out, the note of
  other such URLs beside it, each host a skip kept from being asked named once
  with its clones, and git state it cannot read named with making it readable
  or `holt repo remove <key> --clone --force`), each remote whose push URLs
  are all on this machine, once, with the command replacing them, files in the
  code tree outside every clone, and loose hub entries, each once with the
  command that settles it. It lists every machine with kept files and the UTC
  date of its newest record, or `unknown`, and on a machine with no kept-file
  records says there is nothing to retire.
- `holt worktree -r --force` removes a dirty worktree, passing `--force` to
  `git worktree remove`.

### Changed

- `repo remove --clone`, `worktree -r`, and `project archive --prune` also
  refuse while the tree holds files not kept, nested repositories, unsettled
  kept files, or git state no remote holds in the clone or its submodules: any
  ref (branches, tags, notes, remote-tracking and `refs/prefetch` refs, custom
  refs), per-worktree ref, or HEAD naming a commit or other object no remote
  holds, each line naming the command that settles it. A branch whose commit a
  remote holds never refuses, whatever its upstream: `archive --prune` weighs
  each clone as the other deleters do, with no check of its own before. What a
  remote holds is what its ssh, `git://`, `http://`, and `https://` URLs on
  another machine list now (`git ls-remote`): first the push URLs of each
  ref's target, then, while something is not held, the other push URLs and the
  fetch URLs, and none when nothing weighed is at risk, as when the refs that
  survive `worktree -r` hold it all; a commit is held only when git confirms
  it is a commit here and a listed object here contains it, replace refs and
  grafts aside, never because one of the clone's own refs does. Local paths,
  `file://`, bundles, remote helpers, and URLs whose host is this machine
  (loopback, `localhost`, an empty host, a host holding `%`, this machine's
  names) or that git and curl can read two ways, a bracket in the authority
  that does not open the host included, never count. Each ref is hinted to its
  target (`branch.<b>.pushRemote`, `remote.pushDefault`, the upstream's
  remote, `origin`, then the first remote whose push URLs all count) with `git
  -C <P> push --recurse-submodules=no -- <target> <src>:<dst>`: a branch keeps
  its name when it is new there or a fast-forward, never the target's default
  branch; tags and every other case go under `holt-kept/`. `worktree -r` keeps
  a HEAD or per-worktree ref at risk with a local `holt-kept/` branch or ref
  instead. A push URL that does not answer holds back the refs of its target,
  named on one line with why as holt names it, never git's own error, and the
  way out: reconnect, verify the host key of a host ssh could not verify,
  remove that URL when the target's other push URLs answered, or replace it
  with a `pushurl`, each removal made in the file that holds the value, or
  `--force`; one remote's URLs on one host and port that did not answer for
  the same kind of reason share a line, which names every host it covers. A
  clone with no push target gets one line naming its refs at risk, why each
  remote counts as no copy, and one command that makes one count, or `git
  remote add`. Each weighing asks each URL once for each repository; the
  deleters weigh again with fresh answers after their prompt only when it
  waited on a person at a terminal. `repo remove --clone` and `worktree -r` on
  a terminal announce each URL's first query as `asking <remote> at <url>...`;
  otherwise a query that has run 5 seconds prints `waiting for <host>...`.
  Each query runs in a session of its own with no terminal prompt, no
  prompting credential helper, no redirect followed, a batch-mode ssh unless
  the user names one, and at most 30 seconds, and holt kills the queries it
  runs when SIGINT, SIGTERM, or SIGHUP ends it; after a host-level failure no
  other URL on that host is asked for the rest of the command, and `archive
  --prune` and `doctor --retire` name the clones such a host held back once,
  after the last clone, as a host that did not answer or whose host key was
  not verified. The rev-list input of a weighing goes through a pipe, so a
  weighing writes no file, and the git reading it runs in a session of its own
  that holt kills when SIGINT, SIGTERM, or SIGHUP ends it. A URL is printed
  without its userinfo, query, and fragment, and a command removing one
  matches it without naming a password or token, or opens the file in an
  editor for a value holding a control character. Just before deleting, the
  deleters read every ref and HEAD again
  and keep the clone if any changed; `archive --prune` then names `holt repo
  remove <key> --clone` to delete it. On a terminal they first offer the
  review. `--force` deletes anyway after setting aside what it can, and never
  when setting aside fails, `kept/` cannot be read while the clone has
  kept-file links, or the tree holds another filesystem's mount point. A
  refusal after something was already set aside, or holt's links recorded and
  removed, says the clone or worktree was kept and names each with where its
  aside entry holds it, never `nothing was deleted`.
  `archive --prune` reports each clone it keeps as `not pruned <repo>:
  <reason>`, each reason on a line of its own when there are several, naming
  `holt repo remove <key> --clone` to delete it once settled, and `holt repo
  remove <key> --clone --force` where a reason names deleting anyway; a remote
  that could not be asked is settled by reconnecting, or verifying the host
  key, then that `repo remove`, never by running the archive again, and a
  clone git cannot read is named as such. `repo remove --clone` and `worktree
  -r` print a closing line naming `--force` only when a line above does not
  name it already. Git state that could not be read names only `--force`. A
  merge, rebase, `am`, cherry-pick, revert, or bisect in progress in a git
  directory the delete removes refuses it, naming the commands that finish or
  abort it, since it holds what no ref does (a paused `rebase --autostash`
  keeps the change only in its autostash); `--force` names it as deleted, with
  its autostash. `worktree -r` weighs a worktree whose directory is gone
  through its record, under the clone's lock: its HEAD and per-worktree refs,
  any operation in progress (an `am`'s unapplied patches included), staged
  changes only the record's index holds, and each submodule git directory
  under the record's `modules/` with its operations in progress. It refuses to
  remove the record with the lines `repo remove --clone` gives for them, or
  when any of them changes before the removal; `--force` names each as
  deleted. Reflogs are weighed nowhere, so commits only a removed record's own
  reflogs name are deleted with it. One whose directory is gone and whose
  record holds an operation in progress or staged changes is named first with
  `mkdir -p <worktree> && printf 'gitdir: %s\n' <record> > <worktree>/.git &&
  git -C <worktree> checkout-index -a`, which brings it back to finish, abort,
  or stash them there. A worktree in a state holt does not change is refused,
  even with `--force`, before anything is weighed, set aside, or written, and
  is never weighed: a path more than one record names, as a copied record
  leaves, where `git worktree remove` may reach any of them; a directory whose
  `.git` is gone, cannot be read, does not read as a link, names a git
  directory that is not there, or leads to another git directory than its
  record, as another repository's working tree at its path does, a symlink at
  the path followed and a relative `.git` read against the real path of its
  directory; a path holding something that is not a directory, or a symlink
  to nothing; and a path under something that is not a directory, where no
  directory can be made. `worktree -r` looks for these states again once the
  worktree is weighed, before anything is set aside. `worktree -r`, `repo
  remove --clone`, `doctor --retire`, `status`, `sync`, and `doctor` name each
  as `<worktree>: <what git and holt see>; holt does not change it: resolve it
  with git (git -C <clone> worktree list), then run again`, and name no
  command writing a `.git` or a record's `gitdir`, removing a record, or
  stashing for it. A record `git worktree list` leaves out, one whose `gitdir`
  cannot be read or one `git worktree add` left half made, is named as
  `<record>: <what git and holt see>; holt does not change it: resolve it with
  git (the record is <record>), then run again`: `repo remove --clone`,
  `project archive --prune`, and `doctor --retire` for either, refusing its
  clone, `status`, `sync`, and `doctor` for one whose `gitdir` cannot be read,
  and `sync` for a half-made one. No holt command runs or names `git
  worktree repair` or `git worktree prune`, which act on every record of the
  clone; moving a clone (`repo adopt`, `repo promote`) writes the `.git` of
  each worktree that leads to the record where it was before the move, and the
  record's `gitdir` of each worktree it no longer leads to, a relative `.git`
  read against where the worktree was before the move and a relative `gitdir`
  against where the record was, each against the real path of its directory,
  one at a time, checked with `git rev-parse --absolute-git-dir`, relinking
  each where it is, and naming the dir that was not moved, when the clone's
  `@worktrees` dir cannot be moved, and a working tree holt cannot read whose
  directory is gone is named with commands reaching that one worktree or its
  record (bringing it back, or `git -C <clone> worktree remove <worktree>`),
  while one moved with plain `mv` is named with what git and holt see there
  and `git -C <clone> worktree list`, and no command, since the one that
  settles it writes the record; `status`, `sync`, and `doctor` name `git
  worktree remove` for
  one whose directory is gone only when a weighing of its record as the
  deleters weigh it finds nothing at risk, else `holt worktree
  <project>/<repo> <branch> -r` for one `holt worktree` made, and for any
  other the lines the deleters give. On Windows, hints are printed for
  PowerShell 7: each writing a file with `New-Item` and `Set-Content
  -NoNewline`, and each removing a directory with `Remove-Item -Recurse -Force
  -LiteralPath` in place of `rm -rf`. An operation in progress in a submodule
  git directory whose working tree is gone is named with the commands bringing
  that tree back from its git directory first, and one in a submodule git
  directory that names no working tree with `--force` alone, never with `git
  --work-tree` at the git directory; one in a submodule git directory whose
  `core.worktree` names something that is not a directory, a symlink to
  nothing, a path under something that is not a directory, or a path that
  cannot be read refuses the delete, even with `--force`, and fails `doctor
  --retire`, with what is seen there and `git config --file <module>/config
  core.worktree`, and no command bringing it back. `doctor --retire` fails on
  staged changes only the record of a worktree that is gone holds, with the
  lines the deleters give, and names a worktree that is gone once, as a
  working tree git cannot list, not again as an unsettled kept file. A path no
  worktree record of the clone names is refused, even with `--force`, as not a
  working tree of it, before anything is named or set aside. These gates
  replace the recoverability check `repo remove --clone` and `archive --prune`
  ran first, and `repo remove -p <project> --clone` unlinks the member only
  once the delete succeeds, so a refused or failed delete leaves the member
  linked. They refuse, even with `--force`, while a submodule has a linked
  working tree, naming it with `git -C <worktree> worktree remove <worktree>`,
  or, for one whose directory is gone, `git --git-dir <module> worktree remove
  <worktree>`, or, for one holt does not change, with what is seen there and
  `git --git-dir
  <module> worktree list`, and `repo remove --clone` while the clone has one,
  weighing each first as `worktree -r` weighs it: one holding a commit only
  its HEAD or per-worktree refs hold, or an operation in progress, is named
  with the command keeping or settling it, one holding nested repositories
  with `holt repo adopt <path>` for each, and one holding files not kept with
  each of them and `holt keep --review <worktree>`, never a removal, and a
  line naming how to delete anyway names that worktree's removal with
  `--force`; one holt does not change is named unweighed, once for its path,
  as above; only one holding nothing is named with `holt worktree
  <project>/<repo> <branch> -r` for one `holt worktree` made, when `-p` names
  its project, else `git -C <clone> worktree remove <worktree>`, which for one
  whose directory is gone removes that one record, a locked one unlocked first
  and a dirty one committed or discarded first.

### Fixed

- A command holt runs and reads the output of ends at once, killed, when
  reading one of its streams fails, as when holt cannot hold that much
  output, instead of holt waiting until whatever still holds the other
  stream ends.
- `holt ... >> file` appends instead of writing over the start of the file,
  and `holt ... > file 2>&1` keeps the lines of both streams: standard output
  and error are written at the file's own offset.
- `status`, `info`, `doctor`, `doctor --retire`, and `sync --dry-run` leave a
  clone's `.git` as it was: the git commands holt runs take no optional locks
  (`GIT_OPTIONAL_LOCKS=0`), so `git status` never rewrites the index to
  refresh it. Those that only read fetch no missing object from a promisor
  remote (`GIT_NO_LAZY_FETCH=1`, git 2.44 and newer), read each object as
  stored, not as a replace ref stands in for it (`GIT_NO_REPLACE_OBJECTS=1`),
  and never wait on a terminal prompt (`GIT_TERMINAL_PROMPT=0`).
- The recoverability check counts untracked files and submodule changes
  whatever `status.showUntrackedFiles` and a submodule's `ignore` say, and
  counts a failing `git status` as dirty.
- Hint paths are quoted for PowerShell on Windows, each single quote in
  them doubled, the typographic ones U+2018 to U+201B, which PowerShell also
  reads as quotes, included, and a path holding a backslash reads the same in fish and POSIX shells, the backslash kept inside
  the quotes where both shells read it as is.

## [0.9.2] - 2026-08-02

### Fixed

- `--help` on a command with subcommands (`repo`, `project`, `org`,
  `config`) lists them in a `Commands:` table with their one-line
  summaries, like the top-level help. Before, a group's help showed only
  its usage line and summary, saying nothing about what each verb does.
  Leaf commands' help output is unchanged.

## [0.9.1] - 2026-08-02

### Fixed

- `holt worktree` and `holt path <project>/<repo>@<branch>` no longer join
  the branch name into the `<clone>@worktrees/` path unchecked: a branch
  whose segments would escape the directory (`..`, a backslash, an empty
  or `~`-leading segment) is refused as a usage error instead of resolving
  -- and, for `path`, printing -- a location outside the managed tree.
- `holt sync`'s `run: holt repo promote <name>` hint now shell-quotes a
  repo name containing spaces or shell metacharacters, so pasting the
  hinted command runs it verbatim. Plain names print unchanged.
- `holt doctor` reports a member whose alias value is unusable (not a
  string, or a segment the path rules refuse) under "aliases valid";
  before, such an alias silently did nothing and no check named it.

## [0.9.0] - 2026-08-01

### Changed

- **Breaking.** The verbs that create, remove, or rename a thing are grouped
  under the noun they act on: `holt project new|remove|rename|archive|unarchive`
  and `holt repo new|get|adopt|remove|promote|alias`. `new`, `add`, `get`,
  `create`, `rm`, `adopt`, `promote`, `alias`, `rename`, `archive`, and
  `delete` are gone at the top level, with no aliases. Query, navigation, and
  maintenance commands -- `path`, `list`, `status`, `info`, `recent`, `doctor`,
  `sync`, `backup`, `edit`, `run`, `keep`, `worktree`, `config`, `setup`,
  `backend`, `backends`, `version`, `upgrade`, `init` -- are unchanged.
- **Breaking.** `holt repo get` covers what `get` and `add` both did: one verb
  for cloning a remote repo, with `-p <project>` deciding membership. All three
  intake verbs now take the project the same way.
- **Breaking.** `restore` no longer unarchives. It dispatched on `--all`
  between cloning every missing repo and moving one directory inside the synced
  tree. Unarchiving is `holt project unarchive`. `holt restore <project>` was
  accepted before and meant something else -- it unarchived that project --
  where it now scopes the re-clone to that project's repos; the whole-workspace
  re-clone is the bare `holt restore`, which `--all` used to select.
- **Breaking.** Creating a project and its first repo in one command is gone:
  `holt new <org>/<name> [url]` took an optional url and cloned it as the first
  member. `holt project new` creates the project alone, and `holt repo get
  <url> -p <project>` adds the repo, so one command no longer both creates a
  project and touches the code tree.
- An ambiguous or unrecognized project query no longer empties the repo slot in
  completions: it offers the union of every member repo name in the workspace
  rather than nothing, which is also what `holt repo remove <repo> -p
  <project>` needs, since its project comes after the repo.

### Added

- `holt repo remove <repo> --clone` deletes a checkout, refusing while any
  project still references it and refusing on dirty, stashed, or unpushed state
  unless `--force`. Nothing removed a clone before except `archive --prune`.
  It also refuses while the clone has a linked worktree, and that is the one
  gate `--force` does not override: a worktree's objects and its unpushed
  commits live in the main clone's `.git`, which the recoverability check
  cannot see into.
- `holt repo remove --clone` names the checkout and asks before deleting it.
  `-y`/`--yes` skips that prompt; `--force` does not, since `--force` is what
  waived the recoverability check.
- `holt project new` names the next step when it creates a project with no
  repos, since such a project has no `code/` directory yet.

### Fixed

- `holt sync` no longer aborts the whole workspace over one marker entry whose
  url does not resolve. It skips that member -- which gets no hub link, since
  holt cannot know where its clone would live -- names it under its project,
  reconciles every other project, and exits nonzero. A marker synced from
  another machine used to end the run at `internal error: UnrecognizedUrl`,
  naming neither the project nor the member.
- A marker `aliases` value is held to the hub link-name rule where it is read,
  not only where `holt repo alias` writes it, and the rule now also refuses a
  backslash (a path separator on Windows) and a leading `~`. A hand-edited or
  synced marker aliasing a repo to `../../../../elsewhere` used to build that
  link path verbatim, planting a symlink outside `hub_root` -- and replacing
  one already there -- while `holt sync` reported success. Such an alias is now
  ignored: the repo links under its own name, `holt sync` names the alias under
  its project, and the run exits nonzero.
- A marker `repos` url beginning with `-` is refused, and every subprocess that
  takes a marker value, a project name, or a typed argument as a positional now
  separates it with `--`. `holt restore` used to hand such a url straight to
  `git clone` as its first word, where git read it as an option instead of a
  repository -- `--upload-pack=<cmd>` names a command git runs. `holt backup`
  passed a project's directory name to `tar` the same way, where a leading `-`
  became an option. The separator covers `git clone`, `git worktree add`, and
  `git remote add` as well, so a branch or url starting with `-` is a bad ref
  or a bad url rather than a flag.
- The worktree commands leaked a per-call copy of the path they hand to git.
  The copy is made only when the path carries a backslash, so it leaked on
  Windows every time and on POSIX never; it is now freed on every platform.

## [0.8.1] - 2026-07-31

### Changed

- `holt setup --help` lists the `--backend`/`--synced-root` exclusion under a
  `Constraints:` section, and the error naming it now carries the reason. The
  rule was declared once for the parser and written out a second time in the
  command's prose, so the two could drift and only one of them reached the
  person who tripped it; cli-zig 0.3.0 lets the declaration carry its own
  reason, and the prose is gone.
- Windows: a `HOME` in POSIX form (`/c/Users/me`, as Git Bash and MSYS2 export
  it) is no longer taken as the home directory -- it resolves against whatever
  drive happens to be current, so it names no stable location. `USERPROFILE`
  is used instead. Inherited from env-zig 0.1.2; holt moved from 0.1.1 to
  0.2.1 in this release, along with toml 0.4.0 -> 0.6.0 and json 0.2.0 ->
  0.3.0, all additive.

## [0.8.0] - 2026-07-31

### Added

- `holt path --root <code|hub|synced>` prints one configured root as a single
  absolute line, the same contract as every other `holt path` form. The `hir`
  shell function now reads `code_root` from it. It previously recovered the
  value by grepping `holt config`, which made a report written for a person
  load-bearing for navigation: relabelling a line, or showing its path against
  `~`, would have broken `cd` in every shell, since a quoted `~` never expands.

### Changed

- Paths inside messages now contract `$HOME` to `~` everywhere. Most printed
  absolute before while a handful were contracted -- `holt create` showed the
  same clone path both ways depending on whether it succeeded. Output a caller
  parses is unchanged and stays absolute: the bare cd-friendly path line, `list
  --paths`, and `config`'s `key = value` lines, whose values a script joins
  onto a relative key inside quotes, where a `~` would never expand.
- A load diagnostic now names only what is wrong, leaving the path to the
  caller that already holds it. Marker and config failures used to bake the
  path into the message and have the caller print it alongside, so `holt
  list`, `holt doctor`, and `holt config` each reported the same file twice on
  one line.
- `holt doctor` reports every path in its findings against `~` as well,
  including the backend line.

## [0.7.0] - 2026-07-24

### Security

- `holt upgrade` now verifies the downloaded archive against the release's
  published checksums before unpacking or installing anything. A missing
  checksums file, a missing entry for the asset, or a mismatch each refuse the
  install -- previously the archive replaced the running binary unverified. The
  published checksum file is now named `SHA256SUMS`; `upgrade` and both install
  scripts read that name first and fall back to `checksums.txt`, so earlier
  releases still verify.

### Changed

- **Breaking, Windows only.** The config now lives under
  `%LOCALAPPDATA%\holt\config.toml`, not `~/.config/holt/config.toml` -- that
  is where a program's per-user config belongs on that platform, and a
  `~/.local`-shaped path is a POSIX habit carried somewhere it means nothing. `$XDG_CONFIG_HOME` is
  still honoured first, on every platform, so setting it restores the old
  location exactly.

  There is no migration: holt has no released Windows users to migrate. Anyone
  who does have a config there moves the file, or points `$XDG_CONFIG_HOME` at
  its parent. POSIX is unaffected -- the path is unchanged there.

  A relative `$XDG_CONFIG_HOME` is also now ignored (the XDG spec calls it
  invalid), rather than resolving against whatever directory holt was run from.

- holt reads the environment through a value it is handed rather than the
  process's own, so what a command sees can be supplied. Tests no longer edit
  the environment of the process running them, except where a git child must
  inherit one. `~` now expands via `USERPROFILE` where a Windows shell names no
  `HOME`, having previously failed outright.

## [0.6.0] - 2026-07-12

### Changed

- The command-line layer - argument parsing, command dispatch, shell
  completion, and help rendering - is now provided by the `cli` dependency
  instead of an in-tree implementation. User-facing behavior (help text,
  completion, error messages, and exit codes) is unchanged.

### Added

- `holt help <command> <subcommand>` renders the nested subcommand's help;
  previously the third token was ignored.

## [0.5.2] - 2026-07-09

### Fixed

- `holt list --repos` (and therefore `hir`) emit forward-slash code-tree keys
  (`<host>/<owner>/<repo>`, `local/<name>`) on every platform. v0.5.1 emitted
  native-separator keys on Windows (backslashes), which broke the display and
  the tests; the key is now a portable `/`-joined logical key everywhere, and
  Windows still resolves it via `cd`/`Set-Location`.

## [0.5.1] - 2026-07-09

### Fixed

- **`holt list --repos` and `hir` show clean relative code-tree keys**
  (`<host>/<owner>/<repo>`, `local/<name>`) instead of full absolute paths, so
  the `hir` picker reads like `hi`'s project list rather than repeating the
  `code_root` prefix on every line. `hir` resolves the key back to the clone
  via `code_root`; the key is computed safely even when `code_root` carries a
  trailing slash.

## [0.5.0] - 2026-07-09

### Added

- **`hir`** - an interactive fuzzy jump to a code repo's clone, the
  counterpart to `hi` (which jumps to a project hub). It pipes the code tree
  through `fzf` and `cd`s into the picked clone, reaching every repo including
  standalone `get`-clones and `local/` repos that `hi` cannot. Emitted by
  `holt init` for fish, zsh, bash, and PowerShell. The nav family is now `h`
  (jump by name), `hi` (fuzzy project -> hub), `hir` (fuzzy repo -> clone).
- **`holt list --repos`** lists every clone in the code tree
  (`<host>/<owner>/<repo>` and `local/<name>`), one absolute path per line (a
  JSON array with `--json`). It backs `hir` and is independently scriptable;
  worktrees and clone-staging temp dirs are excluded.

## [0.4.0] - 2026-07-09

### Added

- **`holt create`** makes a git repo from scratch. `holt create <name>` runs
  `git init` at `<code_root>/local/<name>` (a local repo, no remote); a
  `owner/repo` / `host/owner/repo` / url spec instead creates it at its
  identity path with `origin` set (nothing pushed); `-p <project>` attaches it
  as a project member (marker + hub) rather than standalone. This fills the gap
  `new`/`add`/`get` left - they only clone an existing remote and reject a
  from-scratch local repo. The created path is printed, so `cd $(holt create
  foo)` works.

### Changed

- **Shell completion is smarter, complete, and consistent across all four
  shells.** Candidates now match the same case-insensitive subsequence
  (smartcase) rule the resolver uses, so any selector that resolves on Enter
  also completes on TAB, ranked exact > prefix > subsequence. Candidates carry
  descriptions where the shell supports them (fish, zsh, PowerShell): a
  project's org, a member repo's clone state (`cloned`/`missing`/`local`), a
  backend's synced root. A flag's value completes in context (`run --repo`
  completes off the project), a glued `--flag=value` completes its value, and
  `adopt` completes a path or a project by shape. Every command's positionals
  and flags now complete or are explicitly free-form, guarded by a test:
  `setup --backend` offers the builtin backends (fixing empty-on-fresh-install),
  `worktree` completes existing branches, `org rename` completes orgs
  (including archive-only ones), and `add`/`get`/`new` path args complete
  files. PowerShell gains the `h` completer, bash quotes candidates containing
  spaces, and an already-typed flag is not re-offered. No `git` runs on the TAB
  path.
- **`status`, `recent`, and `doctor` are substantially faster on large
  workspaces** by cutting per-repo `git` subprocesses: `status` collapses its
  four git calls per repo into one `git status --porcelain=v2`, and `recent`
  drops a redundant repository check - roughly a 3x and 2x speedup respectively
  across hundreds of projects, with byte-identical output.
- Corrected the `holt doctor --full` help to describe its real effect (it
  widens the symlink scan to the whole synced root), not a per-repo git check.

### Fixed

- **Repo identity parsing rejects path-traversal segments** - a `.`, `..`, or
  backslash in a url/shorthand's host or any path segment - so a crafted spec
  can no longer place a clone outside the code tree (notably on Windows, where
  the path separator differs). Applies to `create`, `add`, `get`, and every
  command that derives a clone path from an identity.
- The Windows PowerShell installer preserves expandable (`%VAR%`) entries when
  adding its directory to the user `PATH`, and renames an existing `holt.exe`
  aside so a reinstall over a running copy succeeds.
- `holt upgrade` stages its download under the platform temp directory
  (`%TEMP%` on Windows) rather than `/tmp`.

## [0.3.0] - 2026-07-08

### Added

- **Windows support.** holt now runs on Windows (x86_64 and aarch64)
  alongside macOS and Linux. The three-tree workspace model works there via
  directory junctions - which need no special privilege - for the hub's
  directory links. A synced content *file* surfaced at a hub root uses a
  file symlink where the OS permits it (Developer Mode or an elevated
  shell), and where it does not, `sync` and `doctor` report it as needing
  Developer Mode rather than dropping it silently.
- **Windows release assets and self-update.** Each release now ships
  `holt-windows-{aarch64,x86_64}.zip`, and `holt upgrade` installs them on
  Windows - extracting the archive and replacing the running `holt.exe`
  despite the lock Windows holds on a running executable.
- **PowerShell installer.** `irm
  https://raw.githubusercontent.com/sakakibara/holt/main/scripts/install.ps1
  | iex` installs the latest release to `%LOCALAPPDATA%\holt\bin` and adds
  it to the user `PATH`, mirroring the existing `curl | sh` installer.

### Changed

- **`holt get` and the clone-backed commands stream git's progress** to the
  terminal instead of capturing it, so a large clone shows live progress and
  can prompt for credentials rather than appearing to hang.
- `holt upgrade` extracts its release archive in process, dropping the
  external `tar` dependency (macOS/Linux behavior is unchanged).

## [0.2.0] - 2026-07-07

### Added

- **The hub mirrors all synced content.** A project's hub now symlinks every
  top-level entry in its content dir, not just a fixed `docs`/`assets`/`links`,
  so anything you keep in synced content shows up at the project root on every
  machine.
- **`holt keep <path>`** promotes a loose file or directory at a project's hub
  root into synced content (moving it there and leaving a symlink behind), so a
  file you create at the project root can be cloud-synced. The move is
  cross-filesystem safe.
- **`holt status` surfaces loose local files** at a hub root in an on-demand
  `local-only` section (and a `local_only` array under `--json`), so an unsynced
  file at the project root is reported rather than silently lost.
- **Standalone `holt adopt <path>`.** Given a single path, `adopt` ingests an
  existing local clone with no project attached, moving it to its identity path
  in the code tree; `holt adopt <project> <path>` is unchanged. `holt get` now
  redirects a local-checkout path argument to `holt adopt`.

### Changed

- A project's hub `code/` directory is created only when the project has at
  least one repo, so a docs-only project gets a clean hub.
- Clone relocation (`adopt`, `promote`, `archive`, `org rename`, `restore`) now
  works across filesystems - for example a checkout on an external or
  cloud-mounted volume - via a copy-then-delete fallback, instead of failing
  when a plain rename cannot cross the boundary.

### Fixed

- **`holt sync` no longer risks deleting real data when pruning orphaned hubs.**
  It refuses to prune through a symlinked `hub_root`, and never deletes a hub
  directory that contains real files (such as loose local files), including on
  filesystems that do not report directory-entry types.

## [0.1.0] - 2026-07-07

Initial release.

### Added

- **Three-tree workspace layout.** Shared git clones under a `code`
  root (`~/Code/<host>/<owner>/<repo>`, one clone per remote, shared across
  projects), cloud-synced project `docs`/`assets`/`links` plus a `.holt.json`
  marker under a `content` root (pure files, the source of truth), and a
  local, fully-derived `hub` root that symlinks the two together per project
  and is regenerated idempotently by `sync`.
- **Named-preset backend config** at `~/.config/holt/config.toml`. `backend`
  selects a `[backends.<name>]` preset resolving to `synced_root`, or
  `synced_root` is set directly; any cloud works via a preset or a direct
  path. No auto-detection and no presumption of any backend - first run
  requires an explicit `holt setup`.
- **Config commands:** `setup` (seed presets and pick a backend, interactive
  or by flag), `backends` (list presets), `backend` (show or switch the active
  preset with a comment-preserving surgical edit), and `config` / `config
  edit`.
- **Project lifecycle:** `new`, `add`, `rm`, `alias`, `adopt`, `promote`,
  `rename`, `org rename` (bulk-rename an org), `archive` / `restore`,
  `delete`, and `backup`.
- **Maintenance:** `sync` (reconcile every hub with its marker and prune
  orphaned hubs) and `doctor` (`--fix`/`--full`) checking structural
  invariants - stray symlinks, root containment, marker parsing, evicted
  markers, clone presence and completeness, hub drift and orphans, cross-tree
  shadows, orphaned content, stale aliases, cloud conflict copies, and stale
  clone temporaries (`--fix` reclaims them).
- **Inspection and navigation:** `path`, `list`, `info`, `status`, `recent`,
  `edit`, `get` (standalone clone into the code tree), and `run` (execute a
  command in
  each member repo, across a project / an `--org` / `--all`, deduped by real
  clone path).
- **`worktree`** wraps `git worktree` so two branches of a repo can be checked
  out at once without a second clone: worktrees live in a sibling
  `<clone>@worktrees/` dir and surface in the hub as one derived
  `code/<repo>@worktrees` link (git owns the branch tree inside it, so slashy
  branch names just nest), navigable via `h <project>/<repo>@<branch>`.
  `archive --prune` keeps any clone that has worktrees.
- **Dynamic shell completion** for fish, zsh, bash, and PowerShell via `holt
  init`, completing subcommands, flags, and live values (projects, orgs, a
  project's member repos, archived projects, backends), alongside the `h`/`hi`
  navigation functions.
- **Tiered smartcase project resolver:** a selector matches a project's
  `org/name` or bare `name` by exact, then prefix, then substring, then
  span-ranked fuzzy subsequence, case-insensitive unless it contains an
  uppercase letter.
- **`owner/repo` and `host/owner/repo` URL shorthand** in `get` and `add`
  (expanded to a real clone URL, defaulting the host to github.com).
- **`archive --prune`** reclaims disk after archiving by deleting only member
  clones that are clean, in sync with their remote, and no longer used by any
  active project, behind a confirmation.
- **Parallelism** via `-j`/`--jobs` for `run`, `status`, `recent`, `doctor`,
  and `restore --all` (which rebuilds a whole workspace from its synced
  markers, cloning every missing repo concurrently and deduped by clone path so
  a repo shared across projects is fetched once), and machine-readable `--json`
  output for `list`, `status`, `info`, and `recent`.
- **`upgrade`** self-updates from the latest (or a named) GitHub release, and
  `version` prints the build identifier.
- Comptime type-driven CLI framework: each command declares a schema struct
  from which the parser, help, and completion metadata are derived, so they
  cannot drift and a declaration mistake is a compile error.
- Safety throughout: atomic marker, config, and backup writes; atomic clones
  (each lands in a temp dir and is renamed into place, so a crashed or
  concurrent clone never leaves a half-populated path); per-project advisory
  locking across every marker edit and content move so concurrent runs never
  lose an edit or race a rename; a clone-path lock so `archive --prune` cannot
  delete a clone a concurrent command is referencing; clones are never deleted
  except by that explicit, safety-gated prune; and destructive moves are gated
  on a recoverability check.

[0.9.2]: https://github.com/sakakibara/holt/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/sakakibara/holt/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/sakakibara/holt/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/sakakibara/holt/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/sakakibara/holt/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/sakakibara/holt/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/sakakibara/holt/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/sakakibara/holt/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/sakakibara/holt/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/sakakibara/holt/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sakakibara/holt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sakakibara/holt/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sakakibara/holt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sakakibara/holt/releases/tag/v0.1.0

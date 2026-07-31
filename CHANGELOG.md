# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

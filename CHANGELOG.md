# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/sakakibara/holt/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/sakakibara/holt/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sakakibara/holt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sakakibara/holt/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sakakibara/holt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sakakibara/holt/releases/tag/v0.1.0

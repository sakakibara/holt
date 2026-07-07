# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/sakakibara/holt/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sakakibara/holt/releases/tag/v0.1.0

# Backup Home Requirements

## Purpose and platform

`backup-home` is a Bash CLI for safe, inspectable backups of explicitly selected
absolute paths on Ubuntu 24.04. It uses `rsync 3.2.7` and timestamped filesystem
snapshots as its only backup engine.

The tool must remain understandable, dependency-light, dry-run friendly, and safe
for local external disks or mounted filesystems. Archive-only engines, built-in
compression, GPG wrappers, cloud backends, database logic inside the backup core,
and repository/database logic inside the core are outside this version.
Application-aware database backups and repository mirrors may be supplied by
explicit external collectors, including trusted collectors shipped beside the core.

## Configuration

All active configuration lives under `config/`:

- `config/profiles/home.conf` defines `include=ABSOLUTE_PATH_OR_GLOB` entries, zero
  or more repeated `exclude_file=PATH` references, `sensitive=yes|no`, and
  `unencrypted_destination=warn|require|allow`. A profile without an exclude file
  copies every matched path. Profiles that omit the new keys retain the compatible
  defaults `sensitive=no` and `unencrypted_destination=allow`.
- exclude files contain one absolute or global pattern per line without a leading
  `!`; relative exclude-file references resolve from the profile directory.
- `config/manual/home.manual` contains `Title` or `Title | Description` checklist
  entries.
- `config/collectors/enabled.conf` contains
  `PRIORITY|MODE|NAME|COMMAND[|TIMEOUT_SECONDS]` collector entries. Priorities are
  unique non-negative integers and lower values run first. The timeout is a positive
  integer and defaults to 1800 seconds. The legacy three-column form is rejected
  with migration guidance.
- `config/docker-recovery/local.conf` contains the local home-relative service paths,
  container and volume names, Compose identifiers, and helper images used by the
  optional Docker collector. It is ignored by Git; only an
  inactive sample is tracked.
- `config/{credentials,codex-mcp,browser,github,gitlab,knowledge,server}-recovery/local.conf` contains
  reviewed machine/account/application selections for the corresponding collector.
  These files are ignored; tracked `.sample` files contain no personal
  account, host, token, or absolute machine path.
- `config/retention/default.conf` contains `keep_last=POSITIVE_INTEGER`.

Comments start with `#`; blank lines are ignored. Control characters, unknown keys,
duplicate collector names, non-absolute includes, and dangerous root includes are
invalid. The CLI may override each default config path. Legacy top-level rules and
manual files are not runtime fallbacks.

## Commands and options

Required commands are `plan`, `manual`, `run`, `list`, `verify`, `restore`,
`restore-plan`, `recover`, `prune`, `drill`, and `help`.

Global options are `--dest`, `--config-file`, `--manual-file`, `--collectors-file`,
`--retention-file`, `--dry-run`, `--verbose`, `--yes`,
`--ignore-errors`, and `--log-file`. Command options include `--snapshot`, `--path`,
`--restore-to`, `--keep-last`, `--deep`, `--target-user`, `--target-home`,
`--staging-dir`, repeatable `--map-path SOURCE=TARGET`, repeatable
`--component ID`, repeatable `--approve-destructive ID`, `--resume SESSION_ID`,
`--all`, `--skip-deep-verify`, and `--allow-legacy`.

`--ignore-errors` may allow an operation to finish collecting diagnostics, but it
must never turn a required collector, serious rsync error, verify, restore, drill,
lock, or prune failure into a successful exit code. Rsync exit code 24 is a warning
because live source files may vanish during traversal.

## Snapshot transaction and layout

- Real runs create `snapshots/.incomplete-TIMESTAMP-PID` and publish the final
  `snapshots/TIMESTAMP` only after rsync, artifact collection, manifest creation,
  and basic self-verification succeed.
- Failed or interrupted runs remove temporary staging and incomplete snapshot data.
  Their log and failure report remain under `logs/`.
- Final snapshots preserve absolute path layout and may reuse unchanged files with
  `rsync --link-dest` against the latest finalized snapshot.
- Every final snapshot contains `.backup-home/manifest.tsv`, `report.txt`,
  `checksums.sha256`, and a stable `artifacts/collectors` location.
- New snapshots use manifest schema v3. The manifest records schema version, timing,
  host and OS, source user/UID/GID/home, safe config digest, roots, excludes,
  previous snapshot, collector results, rsync status, warnings, payload metrics,
  checksum count, script revision/digest, sensitive-profile state, best-effort
  destination-encryption detection, configured unencrypted-destination policy, and
  each collector's priority, protocol version, and restore capability. It must not
  contain tokens, environment dumps, or raw authentication diagnostics. Schemas v1
  and v2 remain readable.

## Collectors and manual staging

- Collectors are explicitly enabled as
  `priority|required|name|/absolute/executable[|timeout-seconds]` or
  `priority|optional|name|/absolute/executable[|timeout-seconds]`; arbitrary
  directory auto-discovery, snapshot code execution, built-in application
  collectors, and `eval` are forbidden.
- Every collector executable provides read-only `metadata`, mandatory `backup`, and
  optional `restore describe|preflight|apply|verify|guide` operations. Exit code 20
  means manual work remains and 64 means restore is unsupported.
- The core passes a versioned, non-secret `BACKUP_HOME_*` context containing
  collector identity/order/mode/timeout, project/profile/destination/run/host/source
  identity, staging paths, and dry-run/verbosity. Restore adds snapshot,
  artifact/session/staging, source/target identity, selected component, approval,
  yes, and dry-run state. The full contract is documented in
  `docs/collector-contract.md`.
- A required collector failure or timeout aborts the backup. An optional collector
  failure or timeout is recorded as a warning and produces a
  successful-with-warnings snapshot. Partial output from a failed collector is
  deleted and replaced by a private `failure.tsv` marker before later collectors
  continue.
- The external Ubuntu system inventory collector exports dconf including Deja Dup,
  manual APT packages, dpkg selections, Snap and Flatpak lists when available,
  crontab, selected Nautilus data, and OS/tool versions. Package application stays
  guided; dconf application requires exact component approval, a private pre-restore
  copy, reset of the exact selected subtree before load, and post-apply equality
  verification. Crontab also requires exact approval, a private copy, and equality
  verification. Inventory command failures create explicit collector warnings and
  never leave partial output files that can be mistaken for valid inventory. A real
  no-crontab response is recorded separately from execution failures. Nautilus
  directory symlinks are resolved within the source home and stored as regular
  logical home-relative directories.
- The knowledge collector selects only configured image/document extensions from
  the rsync-excluded `my-files/learning-daily` tree, preserves home-relative paths,
  and supports safety-copying restore. Restore revalidates artifact path metadata
  and rejects traversal or symlink escapes outside artifact, target, and session
  roots.
- The manual backup collector owns the interactive checklist and staging workflow.
  A normalized empty checklist succeeds unattended with valid empty artifacts;
  non-empty checklists require a terminal. Restore is intentionally unsupported.
- A GitLab collector is shipped disabled. It prefers `glab`, has a reviewed
  paginated `curl`/`jq` API fallback, explicitly supports either owned projects or
  accessible membership projects, verifies the authenticated username against the
  configured account before enumeration, mirrors repositories and metadata, and
  limits automatic recovery to a safe local copy with manual remote rebuild guidance.
- Repository recovery uses only an explicit external collector or an included local
  artifact path. GitHub/GitLab clone and API logic do not belong in the backup core.
- Every shipped recovery collector writes `index.tsv`, `checksums.sha256`, and
  `RESTORE.md`, uses a private staging directory, never prints secret contents, and
  fails rather than silently omitting a required configured source.
- The credentials collector creates component-separated metadata-preserving archives
  for explicitly configured SSH/GPG, keyring, and Codex credential paths. GitHub
  account credentials belong exclusively to the GitHub collector.
- The Codex/MCP collector uses the Python standard-library SQLite online backup API
  and `PRAGMA quick_check`. A SQLite-like file discovered below a candidate root is
  assigned the root's unambiguous configured category, backed up automatically, and
  recorded as a warning until explicitly classified. An unreadable or ambiguously
  categorized discovered candidate is skipped with a warning; an explicitly
  configured database remains required and fails the collector when unavailable or
  inconsistent. Raw WAL/SHM/database files may be excluded only when covered by this
  collector.
- The browser collector is targeted: bookmark backups, open-session files, sanitized
  extension inventory, and allowlisted extension state are permitted. Raw profiles,
  history, cookies, saved passwords, and unselected extension state are forbidden.
- The GitHub collector mirrors explicitly configured accounts' owned repositories,
  wikis, gists, LFS objects when required tooling is available, and reviewable API
  metadata. It periodically obtains an official user-migration archive with Git data
  excluded, retains two by default, and may fall back only to a cache no older than
  the configured limit. It exports secret names but cannot export Actions or webhook
  secret values.
- The server collector uses a reviewed SSH alias, a metadata-preserving configuration
  archive, online SQLite backups, bounded journals, safe inventory, and an external
  trusted Joplin logical-backup helper. It excludes historical deployment backups
  and physical PostgreSQL storage. A remote failure may use only a cache no older
  than the configured limit.
- The shipped `collectors/docker-recovery` wrapper is an explicit external collector.
  It requires reviewed local configuration and must not embed a username, mount
  point, or machine-specific service layout in tracked code.
  It must prefer logical PostgreSQL dumps and verified native SQL Server backups for
  running databases, use physical archives only while the corresponding database is
  stopped, preserve TaskSorter data-protection keys, archive unreadable AdGuard
  bind-mounted configuration and runtime data, and checksum every artifact.
  Raw live database storage may be excluded from rsync only when this collector is
  required by the active configuration. A running stateful service without an
  application-aware collector must fail instead of producing a
  misleading successful snapshot.
- Real manual staging remains interactive through a required manual collector. In
  optional mode, the collector records the deferred checklist and a warning without
  prompting or blocking the snapshot. All staging is removed on success, error,
  cancellation, or signal.

## Locking, retention, verification, and restore

- `run` and real `prune` use an exclusive destination lock. `list`, `verify`,
  `restore`, `restore-plan`, `recover`, `drill`, and read-only previews use a shared
  lock. `plan`, `manual`, and `help` do not lock.
- Lock conflicts are failures and identify the lock path and available owner
  metadata. Stale lock files do not block because ownership is enforced by `flock`.
- Pruning is an explicit command, previews by default, requires `--yes` for deletion,
  requires `keep_last >= 1`, considers only valid timestamp directories, protects
  the newest retained snapshots, revalidates candidates under the exclusive lock,
  and logs every deletion. Backup runs never prune automatically.
- Basic verification validates the manifest, captured roots, required collector
  artifacts, file count, and status. Legacy snapshots without manifests remain
  listable/restorable and use the current profile for basic verification.
- Each new snapshot records checksums for generated artifacts and at most 16 sampled
  regular payload files no larger than 16 MiB. `verify --deep` checks that recorded
  set; full checksum scans remain out of scope.
- Restore defaults to dry-run and requires `--yes` for real writes. Snapshot names
  and selected paths are validated against traversal. Partial restore preserves the
  original absolute path layout beneath the chosen alternate destination.
- `drill` requires an explicit absolute path, restores it to a temporary directory,
  compares source and restored content with checksum-aware rsync, returns non-zero
  on mismatch, and always cleans its temporary data.

## Guided recovery

- `restore` remains the low-level file restore command. `restore-plan` is a read-only
  preflight report, and `recover` is the component-aware guided workflow.
- `restore-plan` validates the selected snapshot, manifest status, captured roots,
  collector artifacts, file count, recorded checksum set, source and target identity,
  target free space, path mappings, collectors, component risks, and legacy failure
  evidence. Deep verification is the default; skipping it must be explicit.
- Recovery components may be filesystem roots, trusted local collector components,
  or collector-artifact fallbacks. The core routes opaque component IDs back to the
  active trusted collector executable. Unknown or unsupported collector artifacts
  remain available in staging with manual guidance.
- Recovery sessions live below
  `${XDG_STATE_HOME:-$HOME/.local/state}/backup-home/recovery/SESSION_ID`, with
  directories mode `0700` and state, plan, and guidance files mode `0600`. State is
  append-only and records staged, verified, skipped, failed, and manual-pending
  outcomes. `recover --resume SESSION_ID` must continue unfinished work without
  silently repeating verified components.
- Every filesystem component is restored into staging and checksum-compared before
  merge. Merge never uses delete semantics. Existing targets are compared first;
  conflicts stay manual-pending unless that exact destructive component is approved.
  Approved replacement creates a safety copy below the recovery session before any
  target mutation and verifies the final content afterward.
- Manifest v2 source identity defines the default source-to-target home mapping.
  `--target-user`, `--target-home`, and repeatable `--map-path SOURCE=TARGET` support
  a different account or filesystem layout. Legacy identity may be inferred only
  with warnings and explicit `--allow-legacy`.
- Interactive recovery asks for component consent and exact destructive approval.
  Non-interactive recovery requires `--component` or `--all`. `--all --yes` applies
  safe and privileged components but skips destructive work; destructive work needs
  the matching `--approve-destructive ID`.
- `sudo` may be used only when explicitly needed to set target ownership or by a
  trusted application collector. Package installation and SQL Server database
  replacement remain guided manual steps. Dconf and crontab imports require exact
  component approval and are never silent.
- The shipped Docker collector automates TaskSorter, Joplin Server, and AdGuard recovery
  where verified artifacts and local prerequisites are available. It prepares SQL
  Server artifacts and a T-SQL template but intentionally leaves the final database
  selection and replacement to the operator.
- The trusted local collectors for credentials, Codex/MCP databases, targeted
  browser data, GitHub recovery, and server recovery expose their recovery
  components from the same executable. They create safety copies before approved
  replacement.
  Browser installation, GitHub remote creation/push, server network/firewall changes,
  secret rotation, and Joplin remote database replacement remain guided steps.
- Legacy snapshots remain available to low-level restore. Guided recovery warns that
  identity and checksums are incomplete, requires `--allow-legacy`, and blocks a
  snapshot with a matching failed-run report.

## Safety and acceptance

The backup destination must not be `/`, the current account's home directory, or
inside a configured source.
For a sensitive profile, encryption detection walks the destination block-device
ancestry looking for `crypto_LUKS`. `require` blocks `not-detected` and `unknown`,
`warn` records a warning and produces `success-with-warnings`, and `allow` proceeds.
Detection is advisory and cannot prove physical or provider-level encryption.
Missing configured sources warn and continue, but invalid configuration and required
operation failures are non-zero. Real runs confirm destination and estimated size,
write dated logs, and never expose secrets in summaries.

Acceptance requires syntax and ShellCheck validation plus isolated integration tests
for help/plan/dry-run, two linked snapshots, manifests, collectors, failure cleanup,
locking, pruning, basic/deep verification, legacy handling, safe partial restore,
restore drill, traversal rejection, manifest v3 identity and v1/v2 compatibility, read-only recovery plans,
staging and conflict handling, resumable sessions, destructive approval boundaries,
unified collector restore, collector fallbacks, and meaningful exit codes.
Acceptance also requires isolated tests for sensitive-destination policy, live-WAL
SQLite backup, explicit database classification, targeted browser boundaries, and
GitHub/server freshness fallback.

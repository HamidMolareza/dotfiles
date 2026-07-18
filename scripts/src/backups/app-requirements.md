# Backup Home Requirements

## Purpose and platform

`backup-home` is a Bash CLI for safe, inspectable backups of explicitly selected
absolute paths on Ubuntu 24.04. It uses `rsync 3.2.7` and timestamped filesystem
snapshots as its only backup engine.

The tool must remain understandable, dependency-light, dry-run friendly, and safe
for local external disks or mounted filesystems. Archive-only engines, built-in
compression, GPG wrappers, cloud backends, database logic inside the backup core,
and automatic repository mirroring are outside this version. Application-aware
database backups may be supplied by explicit external collectors.

## Configuration

All active configuration lives under `config/`:

- `config/profiles/home.conf` defines `include=ABSOLUTE_PATH_OR_GLOB` entries and
  zero or more repeated `exclude_file=PATH` references. A profile without an
  exclude file copies every matched path.
- exclude files contain one absolute or global pattern per line without a leading
  `!`; relative exclude-file references resolve from the profile directory.
- `config/manual/home.manual` contains `Title` or `Title | Description` checklist
  entries.
- `config/collectors/enabled.conf` contains `MODE|NAME|COMMAND` collector entries.
- `config/docker-recovery/local.conf` contains the local home-relative service paths,
  container and volume names, Compose identifiers, and helper images used by the
  optional Docker collector and restore handler. It is ignored by Git; only an
  inactive sample is tracked.
- `config/restore/handlers.local.conf` optionally contains
  `COLLECTOR|ABSOLUTE_EXECUTABLE` restore-handler entries. A missing default local
  file is valid. Only trusted local executables may be configured; code stored in a
  snapshot must never be executed.
- `config/retention/default.conf` contains `keep_last=POSITIVE_INTEGER`.

Comments start with `#`; blank lines are ignored. Control characters, unknown keys,
duplicate collector names, non-absolute includes, and dangerous root includes are
invalid. The CLI may override each default config path. Legacy top-level rules and
manual files are not runtime fallbacks.

## Commands and options

Required commands are `plan`, `manual`, `run`, `list`, `verify`, `restore`,
`restore-plan`, `recover`, `prune`, `drill`, and `help`.

Global options are `--dest`, `--config-file`, `--manual-file`, `--collectors-file`,
`--handlers-file`, `--retention-file`, `--dry-run`, `--verbose`, `--yes`,
`--ignore-errors`, and `--log-file`. Command options include `--snapshot`, `--path`,
`--restore-to`, `--keep-last`, `--deep`, `--target-user`, `--target-home`,
`--staging-dir`, repeatable `--map-path SOURCE=TARGET`, repeatable
`--component ID`, repeatable `--approve-destructive ID`, `--resume SESSION_ID`,
`--all`, `--skip-deep-verify`, and `--allow-legacy`.

`--ignore-errors` may allow an operation to finish collecting diagnostics, but it
must never turn a required collector, rsync, verify, restore, drill, lock, or prune
failure into a successful exit code.

## Snapshot transaction and layout

- Real runs create `snapshots/.incomplete-TIMESTAMP-PID` and publish the final
  `snapshots/TIMESTAMP` only after rsync, artifact collection, manifest creation,
  and basic self-verification succeed.
- Failed or interrupted runs remove temporary staging and incomplete snapshot data.
  Their log and failure report remain under `logs/`.
- Final snapshots preserve absolute path layout and may reuse unchanged files with
  `rsync --link-dest` against the latest finalized snapshot.
- Every final snapshot contains `.backup-home/manifest.tsv`, `report.txt`,
  `checksums.sha256`, and stable `artifacts/manual` and `artifacts/collectors`
  locations.
- New snapshots use manifest schema v2. The manifest records schema version, timing,
  host and OS, source user/UID/GID/home, safe config digest, roots, excludes,
  previous snapshot, collector results, rsync status, warnings, payload metrics,
  checksum count, and script revision/digest. It must not contain tokens, environment
  dumps, or raw authentication diagnostics. Schema v1 remains readable.

## Collectors and manual staging

- Collectors are explicitly enabled as `required|name|builtin:system-inventory` or
  `optional|name|/absolute/executable`; arbitrary directory auto-discovery and
  `eval` are forbidden.
- Each collector receives a private staging directory through
  `BACKUP_HOME_STAGE_DIR`. Dry runs list collectors but never execute them.
- A required collector failure aborts the backup. An optional collector failure is
  recorded as a warning and may produce a successful-with-warnings snapshot.
- The opt-in system inventory collector exports dconf, manual APT packages, dpkg
  selections, Snap and Flatpak lists when available, crontab, selected Nautilus
  data, OS/tool versions, and conservative restore guidance. It never uses sudo or
  automatically restores settings.
- Repository recovery uses only an explicit external collector or an included local
  artifact path. GitHub/GitLab clone and API logic do not belong in the backup core.
- The shipped `collectors/docker-recovery` wrapper is an explicit external collector.
  It requires reviewed local configuration and must not embed a username, mount
  point, or machine-specific service layout in tracked code.
  It must prefer logical PostgreSQL dumps and verified native SQL Server backups for
  running databases, use physical archives only while the corresponding database is
  stopped, preserve TaskSorter data-protection keys, archive unreadable AdGuard
  bind-mounted configuration and runtime data, and checksum every artifact.
  Raw live database storage may be excluded from rsync only when this collector is
  required by the active configuration. A running stateful service without an
  application-aware handler must fail the collector instead of producing a
  misleading successful snapshot.
- Real manual staging remains interactive and is stored under the stable manual
  artifact path. All staging is removed on success, error, cancellation, or signal.

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
  target free space, path mappings, handlers, component risks, and legacy failure
  evidence. Deep verification is the default; skipping it must be explicit.
- Recovery components may be filesystem roots, system inventory, trusted local
  handler components, or collector-artifact fallbacks. A handler supports
  `describe`, `preflight`, `apply`, `verify`, and `guide`; its protocol and environment
  are documented and versioned with the tool. Unknown collector artifacts remain
  available in staging with manual guidance.
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
  trusted application handler. Package installation, dconf import, crontab import,
  and SQL Server database replacement remain reviewable manual steps rather than
  silent automation.
- The shipped Docker handler automates TaskSorter, Joplin Server, and AdGuard recovery
  where verified artifacts and local prerequisites are available. It prepares SQL
  Server artifacts and a T-SQL template but intentionally leaves the final database
  selection and replacement to the operator.
- Legacy snapshots remain available to low-level restore. Guided recovery warns that
  identity and checksums are incomplete, requires `--allow-legacy`, and blocks a
  snapshot with a matching failed-run report.

## Safety and acceptance

The backup destination must not be `/`, the current account's home directory, or
inside a configured source.
Missing configured sources warn and continue, but invalid configuration and required
operation failures are non-zero. Real runs confirm destination and estimated size,
write dated logs, and never expose secrets in summaries.

Acceptance requires syntax and ShellCheck validation plus isolated integration tests
for help/plan/dry-run, two linked snapshots, manifests, collectors, failure cleanup,
locking, pruning, basic/deep verification, legacy handling, safe partial restore,
restore drill, traversal rejection, manifest v2 identity, read-only recovery plans,
staging and conflict handling, resumable sessions, destructive approval boundaries,
trusted restore handlers, collector fallbacks, and meaningful exit codes.

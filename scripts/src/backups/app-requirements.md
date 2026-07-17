# Backup Home Requirements

## Purpose and platform

`backup-home` is a Bash CLI for safe, inspectable backups of explicitly selected
absolute paths on Ubuntu 24.04. It uses `rsync 3.2.7` and timestamped filesystem
snapshots as its only backup engine.

The tool must remain understandable, dependency-light, dry-run friendly, and safe
for local external disks or mounted filesystems. Archive-only engines, built-in
compression, GPG wrappers, cloud backends, database dumps, and automatic repository
mirroring are outside this version.

## Configuration

All active configuration lives under `config/`:

- `config/profiles/home.conf` defines `include=ABSOLUTE_PATH_OR_GLOB` entries and
  repeated `exclude_file=PATH` references.
- exclude files contain one absolute or global pattern per line without a leading
  `!`; relative exclude-file references resolve from the profile directory.
- `config/manual/home.manual` contains `Title` or `Title | Description` checklist
  entries.
- `config/collectors/enabled.conf` contains `MODE|NAME|COMMAND` collector entries.
- `config/retention/default.conf` contains `keep_last=POSITIVE_INTEGER`.

Comments start with `#`; blank lines are ignored. Control characters, unknown keys,
duplicate collector names, non-absolute includes, and dangerous root includes are
invalid. The CLI may override each default config path. Legacy top-level rules and
manual files are not runtime fallbacks.

## Commands and options

Required commands are `plan`, `manual`, `run`, `list`, `verify`, `restore`, `prune`,
`drill`, and `help`.

Global options are `--dest`, `--config-file`, `--manual-file`, `--collectors-file`,
`--retention-file`, `--dry-run`, `--verbose`, `--yes`, `--ignore-errors`, and
`--log-file`. Command options include `--snapshot`, `--path`, `--restore-to`,
`--keep-last`, and `--deep`.

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
- The manifest records schema version, timing, host and OS, safe config digest,
  roots, excludes, previous snapshot, collector results, rsync status, warnings,
  payload metrics, checksum count, and script revision/digest. It must not contain
  tokens, environment dumps, or raw authentication diagnostics.

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
- Real manual staging remains interactive and is stored under the stable manual
  artifact path. All staging is removed on success, error, cancellation, or signal.

## Locking, retention, verification, and restore

- `run` and real `prune` use an exclusive destination lock. `list`, `verify`,
  `restore`, `drill`, and read-only previews use a shared lock. `plan`, `manual`,
  and `help` do not lock.
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

## Safety and acceptance

The backup destination must not be `/`, `/home/home`, or inside a configured source.
Missing configured sources warn and continue, but invalid configuration and required
operation failures are non-zero. Real runs confirm destination and estimated size,
write dated logs, and never expose secrets in summaries.

Acceptance requires syntax and ShellCheck validation plus isolated integration tests
for help/plan/dry-run, two linked snapshots, manifests, collectors, failure cleanup,
locking, pruning, basic/deep verification, legacy handling, safe partial restore,
restore drill, traversal rejection, and meaningful exit codes.

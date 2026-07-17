# Backup Home

`backup-home` is a Bash CLI for inspectable, snapshot-style home backups built on
`rsync`. It preserves absolute source layout inside timestamped directories, reuses
unchanged files with hard links, and keeps restore possible with ordinary filesystem
tools.

The behavior source of truth is `app-requirements.md`. The manifest wire format is
documented in `docs/manifest-v1.md`.

## Design boundaries

- `rsync` snapshots are the only backup engine.
- A run is published only after copy, metadata generation, and self-verification
  succeed.
- Dry runs do not execute collectors, open manual staging, publish snapshots, or
  delete data.
- Repository exports are handled by explicit external wrappers, not clone/API logic
  inside this tool.
- Compression, GPG, cloud backends, database dumps, and automatic restore scripts
  are intentionally outside the tool.

## Requirements

The target is Ubuntu 24.04 with Bash and standard utilities. The main required tools
are `rsync`, `flock`, `find`, `du`, `df`, `sha256sum`, `shuf`, `readlink`, and common
GNU core utilities. Optional inventory tools include `dconf`, `apt-mark`, `dpkg`,
`snap`, `flatpak`, `crontab`, and `hostnamectl`.

## Project layout

```text
.
├── backup-home
├── app-requirements.md
├── config
│   ├── profiles
│   │   ├── home.conf          # ignored local config
│   │   └── home.conf.sample
│   ├── excludes
│   │   ├── common.exclude
│   │   ├── local.exclude      # ignored local config
│   │   └── local.exclude.sample
│   ├── manual
│   │   ├── home.manual        # ignored local config
│   │   └── home.manual.sample
│   ├── collectors
│   │   ├── enabled.conf       # ignored local config
│   │   └── enabled.conf.sample
│   └── retention
│       └── default.conf
├── docs
│   └── manifest-v1.md
└── tests
    └── integration.sh
```

The old top-level `backup-home.rules` and `backup-home.manual` paths are no longer
runtime fallbacks. Existing local values were migrated into `config/`; ignored legacy
copies may be kept under `config/migration/` only for rollback.

For a fresh checkout, create the ignored local files from the tracked samples:

```bash
cp config/profiles/home.conf.sample config/profiles/home.conf
cp config/excludes/local.exclude.sample config/excludes/local.exclude
cp config/manual/home.manual.sample config/manual/home.manual
cp config/collectors/enabled.conf.sample config/collectors/enabled.conf
```

Review every include, exclude, manual task, and collector before the first run.

## Configuration

### Profile

The default profile is `config/profiles/home.conf`:

```text
include=/home/home/Downloads
include=/home/home/my-files
exclude_file=../excludes/common.exclude
exclude_file=../excludes/local.exclude
```

An include must be an absolute path or glob. `/` is rejected. `exclude_file` may be
absolute or relative to the profile file. Pass a different profile with
`--config-file PATH`.

### Excludes

Exclude files contain one pattern per line without the old `!` prefix:

```text
# Absolute path
/home/home/Desktop/temp

# Name matched below any included root
node_modules
bin
obj

# Glob
*.tmp
```

Shared development/build exclusions belong in `config/excludes/common.exclude`.
Machine-specific paths belong in the ignored `config/excludes/local.exclude`.

### Manual checklist

The default `config/manual/home.manual` format is unchanged:

```text
Mobile Contacts
Passwords | Export the recovery material that is not already in a selected path
```

The `manual` command walks the list. A real run with checklist items creates an
interactive staging tree and stores its contents under the stable snapshot path
`.backup-home/artifacts/manual/`. The staging directory is removed on every exit
path, including errors and signals.

### Collectors

Collectors are opt-in and listed in `config/collectors/enabled.conf`:

```text
required|system-inventory|builtin:system-inventory
optional|repository-export|/absolute/path/to/repository-export-wrapper
```

The fields are mode, unique safe name, and command. External entries must be an
absolute executable with no shell evaluation. Use a wrapper when arguments or more
configuration are needed.

Each collector receives:

- `BACKUP_HOME_STAGE_DIR`: its private artifact directory
- `BACKUP_HOME_SNAPSHOT_NAME`: the planned timestamp
- `BACKUP_HOME_DEST`: the canonical destination

Proxy variables already present in the environment are inherited. Tokens,
environment dumps, and raw collector output are not written into the manifest.
External collectors should put only deliberate recovery artifacts in their stage
directory and must not print secrets.

A required collector failure aborts the run. An optional failure is recorded and can
produce a `success-with-warnings` snapshot. Dry-run lists collectors but never calls
them.

The built-in `system-inventory` collector captures available dconf settings, manual
APT packages, dpkg selections, Snap and Flatpak application lists, current-user
crontab, selected Nautilus data, OS metadata, tool versions, and a conservative
`RESTORE.md`. It never runs with `sudo` and never applies settings or installs
packages.

### Retention

`config/retention/default.conf` currently contains:

```text
keep_last=10
```

This does not schedule or trigger pruning. It is read only when `prune` is invoked.

## Commands

```text
backup-home [global-options] <command> [command-options]
```

- `plan`: show profile, excludes, resolved roots, size estimate, collectors, manual
  tasks, and retention policy.
- `manual`: walk through the manual checklist.
- `run`: create or dry-run a snapshot.
- `list`: list finalized snapshots with `success`, `success-with-warnings`, or
  `legacy` status.
- `verify`: perform basic verification; `--deep` also validates recorded checksums.
- `restore`: dry-run or apply a full/partial restore.
- `prune`: preview or apply keep-last retention.
- `drill`: restore one selected path to a temporary directory and compare it.
- `help`: show CLI usage.

Common options:

- `--dest PATH`
- `--config-file PATH`
- `--manual-file PATH`
- `--collectors-file PATH`
- `--retention-file PATH`
- `--dry-run`
- `--verbose`
- `--yes`
- `--ignore-errors`
- `--log-file PATH`

`--ignore-errors` means “finish useful diagnostics where possible.” It never converts
a required collector, rsync, verify, restore, drill, lock, or prune failure into exit
code zero.

## Plan and backup

Inspect the active configuration:

```bash
./backup-home --dest /media/home/backup-drive plan
```

Preview rsync without collectors or staging:

```bash
./backup-home --dest /media/home/backup-drive run --dry-run
```

Create a real snapshot after the confirmation prompt:

```bash
./backup-home --dest /media/home/backup-drive run
```

For intentional unattended execution without manual checklist items:

```bash
./backup-home --dest /media/home/backup-drive run --yes
```

A real run uses this transaction:

1. Validate config, sources, destination, estimated size, collectors, and lock.
2. Create temporary manual/collector staging.
3. Copy selected sources into `snapshots/.incomplete-TIMESTAMP-PID`.
4. Copy generated artifacts and create report/checksums/manifest.
5. Perform basic self-verification.
6. Atomically rename the incomplete directory to `snapshots/TIMESTAMP`.

If a required step fails, the incomplete snapshot and staging are removed. The dated
log plus `*.failure.tsv` and `*.failure.txt` remain under `<dest>/logs/`.

## Destination layout and locking

```text
<dest>/
├── .backup-home/
│   ├── run.lock
│   └── lock-owner.tsv
├── logs/
└── snapshots/
    └── YYYY-MM-DD_HH-mm-ss/
        ├── home/home/...
        └── .backup-home/
            ├── manifest.tsv
            ├── report.txt
            ├── checksums.sha256
            └── artifacts/
```

Real `run` and `prune --yes` operations use an exclusive `flock`. `list`, `verify`,
`restore`, `drill`, and previews use a shared lock. A lock conflict returns exit code
75 and prints available owner metadata. A stale file alone cannot hold a lock.

## Verify

Verify the latest finalized snapshot:

```bash
./backup-home --dest /media/home/backup-drive verify
```

Verify one snapshot and its recorded checksum sample:

```bash
./backup-home --dest /media/home/backup-drive \
  verify 2026-07-17_12-00-00 --deep
```

Basic verification uses captured roots from the snapshot manifest, not today's
profile. It also validates status, required collector artifact directories, and file
count. Deep verification checks all generated artifacts plus up to 16 recorded
payload files no larger than 16 MiB.

Snapshots created before manifests are shown as `legacy`. They remain listable and
restorable, and basic verification falls back to the current profile with a warning.
Deep verification is unavailable for them.

## Prune

Preview snapshots older than the newest configured count:

```bash
./backup-home --dest /media/home/backup-drive prune
```

Preview a one-off policy:

```bash
./backup-home --dest /media/home/backup-drive prune --keep-last 5
```

Apply exactly the displayed candidates:

```bash
./backup-home --dest /media/home/backup-drive prune --keep-last 5 --yes
```

Prune considers only timestamp-named directories, requires at least one retained
snapshot, revalidates candidates under the exclusive lock, and logs each deletion.
Hard-linked snapshots remain independently inspectable; actual reclaimed space can
be smaller than their apparent size.

## Restore and restore drill

Restore defaults to dry-run. Partial restore now preserves the original absolute
layout below the alternate destination.

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-07-17_12-00-00 \
  --path /home/home/.dotfiles \
  --restore-to /tmp/restore-dotfiles
```

The corresponding real restore writes to:

```text
/tmp/restore-dotfiles/home/home/.dotfiles
```

Apply after reviewing the dry-run:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-07-17_12-00-00 \
  --path /home/home/.dotfiles \
  --restore-to /tmp/restore-dotfiles \
  --yes
```

Snapshot names and selected paths reject traversal. `/` and destinations inside the
backup destination are rejected. A full restore excludes internal `.backup-home`
metadata from the restored payload.

Exercise one path without keeping restored files:

```bash
./backup-home --dest /media/home/backup-drive \
  drill 2026-07-17_12-00-00 \
  --path /home/home/.dotfiles
```

The drill copies the selected path to `mktemp -d`, compares it with checksum-aware
rsync, reports differences as failure, and cleans the temporary tree on every exit.

## Joplin and server artifacts

If the active profile includes `/home/home/backups/joplin`, restore it into staging:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-07-17_12-00-00 \
  --path /home/home/backups/joplin \
  --restore-to /tmp/restore-joplin \
  --yes
```

The files are then under:

```text
/tmp/restore-joplin/home/home/backups/joplin
```

Verify service-specific `.sha256` files and follow the Joplin PostgreSQL restore
procedure separately. `backup-home` restores files; it does not stop services or run
`pg_restore`.

The same distinction applies to `/home/home/backups/server`: it contains local
artifacts pulled from servers, not the live servers. Restore them to staging, inspect
their manifests/checksums/readmes, and use each service's documented recovery flow.

## Validation

Run the complete isolated suite:

```bash
bash -n backup-home tests/integration.sh
shellcheck -x backup-home tests/integration.sh
tests/integration.sh
```

The suite uses only temporary sources and destinations. It covers dry-run, two linked
snapshots, manifests, required/optional collectors, system inventory, rsync failure,
signal cleanup, lock conflicts, retention, basic/deep verification, checksum
tampering, legacy snapshots, safe partial restore, traversal rejection, and drill.

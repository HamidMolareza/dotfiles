# Backup Home

`backup-home` is a Bash CLI for inspectable, snapshot-style home backups built on
`rsync`. It preserves absolute source layout inside timestamped directories, reuses
unchanged files with hard links, and keeps restore possible with ordinary filesystem
tools.

The behavior source of truth is `app-requirements.md`. New snapshots use the
`docs/manifest-v3.md` wire format; schemas v1 and v2 remain readable.

## Design boundaries

- `rsync` snapshots are the only backup engine.
- A run is published only after copy, metadata generation, and self-verification
  succeed.
- Dry runs do not execute collectors, open manual staging, publish snapshots, or
  delete data.
- Repository exports are handled by explicit external wrappers, not clone/API logic
  inside this tool.
- Compression, GPG, cloud backends, and database logic inside the core are outside
  the tool. Explicit collectors may create application-aware database recovery
  artifacts, and only trusted local collectors may apply them.

## Requirements

The target is Ubuntu 24.04 with Bash and standard utilities. The main required tools
are `rsync`, `flock`, `find`, `du`, `df`, `sha256sum`, `shuf`, `readlink`, and common
GNU core utilities. Optional inventory tools include `dconf`, `apt-mark`, `dpkg`,
`snap`, `flatpak`, `crontab`, and `hostnamectl`.
Application collectors add explicit requirements: Python 3 for consistent SQLite
backup and sanitized JSON export, Git/GitHub CLI for GitHub recovery, `glab` or
`curl` plus `jq` for GitLab recovery, SSH for server recovery, and Docker for Docker
service recovery. The core still works without those collectors when they are
disabled.

## Project layout

```text
.
├── backup-home
├── collectors                 # backup plus optional restore implementations
├── lib                        # configuration and Python standard-library helpers
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
│   ├── docker-recovery
│   │   ├── local.conf         # ignored local config
│   │   └── local.conf.sample
│   ├── *-recovery             # ignored local.conf plus tracked inactive sample
│   ├── README.md
│   └── retention
│       └── default.conf
├── docs
│   ├── docker-recovery.md
│   ├── manifest-v1.md
│   ├── manifest-v2.md
│   ├── manifest-v3.md
│   ├── new-machine-recovery.md
│   ├── recovery-collectors.md
│   └── collector-contract.md
└── tests
    ├── integration.sh
    └── recovery-collectors.sh
```

The old top-level `backup-home.rules` and `backup-home.manual` paths are no longer
runtime fallbacks. Active configuration lives only in the documented `config/`
subdirectories.

For a fresh checkout, create the ignored local files from the tracked samples:

```bash
cp config/profiles/home.conf.sample config/profiles/home.conf
cp config/excludes/local.exclude.sample config/excludes/local.exclude
cp config/manual/home.manual.sample config/manual/home.manual
cp config/collectors/enabled.conf.sample config/collectors/enabled.conf
```

When enabling Docker recovery, also copy and review its local layout:

```bash
cp config/docker-recovery/local.conf.sample config/docker-recovery/local.conf
```

Other recovery collectors follow the same ignored-local pattern:

```bash
for name in credentials codex-mcp browser github gitlab knowledge server; do
  cp "config/$name-recovery/local.conf.sample" "config/$name-recovery/local.conf"
done
```

Review every include, exclude, manual task, and collector before the first
run. See `config/README.md` for the tracked-versus-local policy.

## Configuration

### Profile

The default profile is `config/profiles/home.conf`:

```text
include=/home/alice/Downloads
include=/home/alice/Projects
sensitive=yes
unencrypted_destination=warn
exclude_file=../excludes/common.exclude
exclude_file=../excludes/local.exclude
```

An include must be an absolute path or glob. `/` is rejected. `exclude_file` may be
absolute or relative to the profile file. Exclude files are optional; omitting every
`exclude_file` entry copies all matched paths. Pass a different profile with
`--config-file PATH`.

`sensitive` defaults to `no`. For `sensitive=yes`, the destination policy is:

- `warn`: continue when LUKS encryption is not detected, record the condition, and
  publish `success-with-warnings`
- `require`: block both `not-detected` and `unknown`
- `allow`: continue without a policy warning

Detection is best-effort through the mounted block-device ancestry. It is visible in
`plan`, the report, the manifest, and `restore-plan`; it is not proof of encryption.

### Excludes

Exclude files contain one pattern per line without the old `!` prefix:

```text
# Absolute path
/home/alice/Desktop/temp

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

The `manual` command walks the list. A required `manual-backup` collector owns
interactive staging and stores its reviewed files with the other collector
artifacts. When configured as optional, it records the deferred checklist and a
warning without prompting or blocking the snapshot. The staging directory is removed
on every exit path.

### Collectors

Collectors are opt-in and listed in `config/collectors/enabled.conf`:

```text
100|required|system-inventory|/absolute/path/to/collectors/system-inventory|300
700|optional|repository-export|/absolute/path/to/repository-export
```

The fields are unique numeric priority, mode, unique safe name, and absolute
executable, followed by an optional positive timeout in seconds. The timeout
defaults to 1800 seconds. Lower priorities run first. Duplicate names or priorities
and the old three-column format are rejected.

Each executable implements read-only `metadata`, mandatory `backup`, and optionally
`restore describe|preflight|apply|verify|guide`. See
[collector-contract.md](docs/collector-contract.md) for the versioned shared
context, component records, exit codes, and safety rules.

Proxy variables already present in the environment are inherited. Tokens,
environment dumps, and raw collector output are not written into the manifest.
External collectors should put only deliberate recovery artifacts in their stage
directory and must not print secrets.

A required collector failure aborts the run. An optional failure or timeout is
recorded and produces a `success-with-warnings` snapshot. Its partial staging output
is replaced with a safe `failure.tsv`, and later collectors still run. Dry-run lists
collectors but never calls them.

The external `system-inventory` collector captures available dconf and Deja Dup
settings, manual APT packages, dpkg selections, Snap and Flatpak application lists,
current-user crontab, selected Nautilus data, OS metadata, tool versions, and a
conservative `RESTORE.md`. Package and Nautilus recovery is staged privately with
review guidance and never installs or merges anything automatically. An explicitly
approved dconf or Deja Dup restore first saves the current subtree, resets that exact
subtree, loads the artifact, and verifies an exact match. Crontab follows the same
safety-copy and exact-verification model. Failed inventory commands create warnings
and no partial artifact; a genuine missing crontab is recorded separately. Nautilus
directory symlinks are resolved into regular home-relative artifact directories.
The collector never runs with `sudo`.

The optional tracked `collectors/docker-recovery` wrapper creates a logical
TaskSorter PostgreSQL dump while the
container is running, preserves its Data Protection keys, creates SQL Server native
backups with checksums and `RESTORE VERIFYONLY`, and handles Joplin PostgreSQL as a
logical online dump or a physical archive only while stopped. Excluded AdGuard
configuration and runtime data are archived separately. See
`docs/docker-recovery.md` for the exact coverage and restore boundaries.

Machine-specific service paths, container and volume names, Compose identifiers, and
image tags live only in ignored `config/docker-recovery/local.conf`. The collector
fails clearly when that file is missing or invalid. Set
`BACKUP_HOME_DOCKER_RECOVERY_CONFIG` only when an alternate reviewed absolute config
path is needed.

The Docker collector requires the Docker daemon and its referenced images to already
be available. Its artifacts contain database content and credentials or keys, so the
destination should be encrypted; a temporary `warn` policy records the accepted risk
until storage is migrated. Large collector outputs are staged below `TMPDIR`
before being copied into the snapshot; point `TMPDIR` at a filesystem with enough
temporary space when the default `/tmp` is too small.

Tracked collectors also cover explicit credential groups, Codex/MCP SQLite state,
targeted browser recovery, GitHub mirrors and metadata, and remote server state.
Their account names, paths, hosts, extension allowlists, and freshness policies live
only in ignored local configuration. Each creates an index, checksums, and restore
guidance. See [recovery-collectors.md](docs/recovery-collectors.md) for coverage,
failure policy, sensitive-data boundaries, and known non-automatable steps.
Codex/MCP candidate roots also discover new SQLite-like files. A newly discovered
valid database is backed up automatically and recorded as a warning until it is
classified explicitly; an unreadable discovered candidate is skipped with a warning.
Explicitly configured database failures remain fatal.

The shipped GitLab collector is disabled by default. Its reviewed local config
selects `scope|owned` or `scope|membership`; membership covers authenticated
accessible projects. `glab` is preferred, while the `curl`/`jq` fallback follows
every API page without putting the token in a URL or process argument.

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
- `restore-plan`: inspect snapshot and target recovery readiness without changing
  the target.
- `recover`: run a staged, component-aware, resumable recovery session.
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
a required collector, serious rsync failure, verify, restore, drill, lock, or prune
failure into exit code zero. Rsync exit code 24 is always treated as a warning because
it means source files vanished while the live filesystem was being copied.

## Plan and backup

Inspect the active configuration:

```bash
./backup-home --dest /mnt/backup-drive/backups plan
```

Preview rsync without collectors or staging:

```bash
./backup-home --dest /mnt/backup-drive/backups run --dry-run
```

Create a real snapshot after the confirmation prompt:

```bash
./backup-home --dest /mnt/backup-drive/backups run
```

For intentional unattended execution without manual checklist items:

```bash
./backup-home --dest /mnt/backup-drive/backups run --yes
```

A real run uses this transaction:

1. Validate config, sources, destination, estimated size, collectors, and lock.
2. Run collectors in priority order in private staging directories.
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
`restore`, `restore-plan`, `recover`, `drill`, and previews use a shared lock. A lock
conflict returns exit code 75 and prints available owner metadata. A stale file alone
cannot hold a lock.

## Verify

Verify the latest finalized snapshot:

```bash
./backup-home --dest /mnt/backup-drive/backups verify
```

Verify one snapshot and its recorded checksum sample:

```bash
./backup-home --dest /mnt/backup-drive/backups \
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
./backup-home --dest /mnt/backup-drive/backups prune
```

Preview a one-off policy:

```bash
./backup-home --dest /mnt/backup-drive/backups prune --keep-last 5
```

Apply exactly the displayed candidates:

```bash
./backup-home --dest /mnt/backup-drive/backups prune --keep-last 5 --yes
```

Prune considers only timestamp-named directories, requires at least one retained
snapshot, revalidates candidates under the exclusive lock, and logs each deletion.
Hard-linked snapshots remain independently inspectable; actual reclaimed space can
be smaller than their apparent size.

## Restore and restore drill

Restore defaults to dry-run. Partial restore now preserves the original absolute
layout below the alternate destination.

```bash
./backup-home --dest /mnt/backup-drive/backups \
  restore 2026-07-17_12-00-00 \
  --path /home/alice/.dotfiles \
  --restore-to /tmp/restore-dotfiles
```

The corresponding real restore writes to:

```text
/tmp/restore-dotfiles/home/alice/.dotfiles
```

Apply after reviewing the dry-run:

```bash
./backup-home --dest /mnt/backup-drive/backups \
  restore 2026-07-17_12-00-00 \
  --path /home/alice/.dotfiles \
  --restore-to /tmp/restore-dotfiles \
  --yes
```

Snapshot names and selected paths reject traversal. `/` and destinations inside the
backup destination are rejected. A full restore excludes internal `.backup-home`
metadata from the restored payload.

Exercise one path without keeping restored files:

```bash
./backup-home --dest /mnt/backup-drive/backups \
  drill 2026-07-17_12-00-00 \
  --path /home/alice/.dotfiles
```

The drill copies the selected path to `mktemp -d`, compares it with checksum-aware
rsync, reports differences as failure, and cleans the temporary tree on every exit.

## Guided recovery on a new machine

Start with a read-only plan. Deep verification is enabled by default:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  restore-plan 2026-07-17_12-00-00 \
  --target-user home
```

The report checks the manifest and snapshot checksums, source and target identities,
free space, path mappings, collector artifacts, trusted collectors, component risks,
and application prerequisites. It returns non-zero when recovery is blocked. Use
`--skip-deep-verify` only when the cost is understood; use `--allow-legacy` only for
an intentionally selected pre-manifest or incomplete-metadata snapshot.

Run the interactive workflow after the plan is clean:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover 2026-07-17_12-00-00 \
  --target-user home
```

Recovery presents each filesystem, inventory, and application component separately.
Selected files are copied into staging and checksum-compared before merge. Existing
targets are compared without deletion; conflicts remain `manual-pending` unless the
exact destructive component is approved. Before an approved replacement, the
current target is copied into the session's `pre-restore/` safety area.

For unattended recovery, `--all --yes` applies safe and privileged components but
skips anything whose effective risk is destructive:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover 2026-07-17_12-00-00 \
  --all --yes
```

Approve a reviewed destructive component by its exact ID:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover 2026-07-17_12-00-00 \
  --component docker.tasksorter \
  --approve-destructive docker.tasksorter \
  --yes
```

If the new account or layout differs, use `--target-user`, `--target-home`, and one
or more `--map-path SOURCE=TARGET` arguments. The manifest v2 source identity is the
default mapping source. Recovery sessions are private and resumable under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/backup-home/recovery/SESSION_ID/
```

Continue an interrupted or manual-pending session with:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover --resume SESSION_ID
```

Each session keeps `plan.txt`, append-only `state.tsv`, component logs, reviewable
commands, `manual-steps.md`, staged data, and any safety copies. Keep the staging and
session directories until every selected component is verified. The complete
bare-machine sequence is in `docs/new-machine-recovery.md`.

## Joplin and server artifacts

If the active profile includes `/home/alice/backups/joplin`, restore it into staging:

```bash
./backup-home --dest /mnt/backup-drive/backups \
  restore 2026-07-17_12-00-00 \
  --path /home/alice/backups/joplin \
  --restore-to /tmp/restore-joplin \
  --yes
```

The files are then under:

```text
/tmp/restore-joplin/home/alice/backups/joplin
```

Verify service-specific `.sha256` files before using them. The low-level `restore`
command restores files only. In guided `recover`, the trusted Docker collector can
restore Joplin Server PostgreSQL and start Compose on a fresh target, or after exact
approval when existing state would be replaced.

The same distinction applies to `/home/alice/backups/server`: it contains local
artifacts pulled from servers, not the live servers. Guided recovery can restore two
explicitly configured SQLite services after exact approval, but network, firewall,
WireGuard, provider, secret, and Joplin changes remain reviewable operator steps.

The GitHub collector stages only explicitly configured accounts from its working
cache; that cache is not included by the main rsync profile. It can restore the
selected local mirrors and credentials, but remote repository creation and
`git push --mirror` are always guided and never performed in bulk automatically.

## Validation

Run the complete isolated suite:

```bash
bash -n backup-home tests/*.sh collectors/* lib/collector-common lib/collector-restore/*
python3 -m py_compile lib/*.py
shellcheck -S warning -x backup-home tests/*.sh collectors/* lib/collector-common lib/collector-restore/*
tests/integration.sh
tests/recovery-collectors.sh
```

The suite uses only temporary sources and destinations. It covers dry-run, two linked
snapshots, manifests, required/optional collectors, system inventory, rsync failure,
signal cleanup, lock conflicts, retention, basic/deep verification, checksum
tampering, legacy snapshots, safe partial restore, traversal rejection, drill,
manifest v3 identity plus v1/v2 compatibility, read-only recovery planning, staged
merge conflicts, resumable sessions, unified collector restore, destructive
approval, and collector fallbacks.
The recovery collector suite also covers sensitive-destination policy, live-WAL
SQLite backup, automatic candidate discovery, targeted browser boundaries,
knowledge path traversal and symlink containment, system restore safety/verification,
required and deferred optional manual staging, paginated GitLab clients, and fresh-cache versus
stale-cache behavior for GitHub and server collection.

# Backup Home

`backup-home` is a Bash backup tool built around `rsync`.

It creates timestamped snapshots, uses one rules file for include and exclude logic,
keeps restore simple by preserving the original absolute path layout inside each
snapshot, and can stage manual-only files in a temporary folder during real backup
runs.

The current behavior source of truth is `app-requirements.md`.

## Files

```text
.
├── backup-home
├── backup-home.rules
├── backup-home.manual
├── README.md
└── app-requirements.md
```

## Rules File

By default the app reads:

```text
./backup-home.rules
```

You can override it with `--config-file PATH`.

Format:

```text
# comment
/home/home/my-files
/home/home/Downloads/*.txt
!/home/home/Desktop/temp
!node_modules
!bin
```

Rules behave like this:

- a normal line includes an absolute path or glob pattern
- a line starting with `!` excludes a path or pattern
- absolute excludes match specific absolute paths
- non-absolute excludes such as `!node_modules` or `!bin` match those names anywhere under included roots
- inline comments are allowed after whitespace
- blank lines are ignored

## Manual Checklist File

By default the app reads:

```text
./backup-home.manual
```

If you want a different checklist file, pass `--manual-file PATH`.

Format:

```text
# comment
# Title | Description
Mobile Contacts
OTP | Copy google Auth backups
```

Each line can be either `Title` or `Title | Description`. The description is
optional. The `manual` command shows one task at a time and waits for confirmation
before moving to the next item unless you use `--yes`.

During a real `run`, the script also creates a temporary staging folder for manual
tasks, opens it with `xdg-open` when available, and waits for you to place files
there before the backup continues. Folder names are based on task titles. If a task
has a description, the related folder gets a `task.txt` file with the title and
description. The staged files are included in the snapshot, and the temporary folder
is removed when the script exits, including successful completion, cancellation, and
interrupts such as `Ctrl+C`.

## Commands

```text
backup-home [global-options] <command> [command-options]
```

Commands:

- `plan` - show the active rules, resolved backup roots, and manual checklist
- `plan` also shows an estimated size breakdown for each resolved backup root after exclusions are applied
- `manual` - print the manual checklist
- `run` - create a new snapshot
- `list` - list snapshots in the destination
- `verify` - confirm a snapshot exists and check expected paths
- `restore` - restore a full snapshot or one path
- `help` - show usage

## Global Options

- `--dest PATH` - backup destination root
- `--config-file PATH` - use a different rules file
- `--manual-file PATH` - use a different manual checklist file
- `--dry-run` - preview without writing changes
- `--verbose` - show detailed `rsync` output
- `--yes` - skip confirmation where supported
- `--ignore-errors` - continue when rsync or verification hits recoverable errors
- `--log-file PATH` - write the backup log to an explicit path

## How Backup Works

- `backup-home` reads include and exclude rules from `backup-home.rules`
- it resolves matching absolute paths
- it estimates the size of each resolved backup root after exclusions and shows the largest ones first
- for real backups with manual checklist items, it creates a temporary staging folder under `/tmp`
- it includes that staging folder in the snapshot for that backup run
- it creates a snapshot under `<dest>/snapshots/YYYY-MM-DD_HH-mm-ss`
- it writes logs under `<dest>/logs/`
- if an older snapshot exists, it uses `rsync --link-dest` to save space

In practice:

- the first snapshot is a full copy of the selected data
- later snapshots still look complete, but unchanged files are reused with hard links
- changed and new files are copied into the newer snapshot

## Default Rules In This Project

Current default includes:

- `/home/home/Downloads`
- `/home/home/Desktop`
- `/home/home/my-files`
- `/home/home/Private`
- `/home/home/.dotfiles`
- `/home/home/.gapcode`
- `/home/home/.secure-exports`
- `/home/home/.copilot`
- `/home/home/.config/WirePanelClient`
- `/home/home/backups/joplin`
- `/home/home/backups/server`
- `/media/home/09190305819/Medical`

Current default excludes:

- `/home/home/Desktop/temp`
- `/home/home/.dotfiles/docker-services/adguard/data/adguard/workdir/data`
- `/home/home/my-files/learning-daily`
- global dev/build folders: `node_modules`, `bin`, `obj`, `dist`, `build`,
  `.next`, `.nuxt`, `.cache`, and `coverage`

## Examples

Show the plan:

```bash
./backup-home --dest /media/home/backup-drive plan
```

Dry-run a backup:

```bash
./backup-home --dest /media/home/backup-drive run --dry-run
```

Dry-run and continue even if some paths fail:

```bash
./backup-home --dest /media/home/backup-drive --ignore-errors run --dry-run
```

Run a real backup:

```bash
./backup-home --dest /media/home/backup-drive run
```

List snapshots:

```bash
./backup-home --dest /media/home/backup-drive list
```

Verify the latest snapshot:

```bash
./backup-home --dest /media/home/backup-drive verify
```

Restore one path from a snapshot:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-04-07_12-00-00 \
  --path /home/home/.dotfiles \
  --restore-to /tmp/restore-dotfiles
```

Apply the restore for real:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-04-07_12-00-00 \
  --path /home/home/.dotfiles \
  --restore-to /tmp/restore-dotfiles \
  --yes
```

## Restore Joplin Backups

The default rules include `/home/home/backups/joplin`, which should contain
Joplin PostgreSQL dumps, `.sha256` files, and optional `.gpg` copies created by
the VPS migration helper.

Restore the backup folder from a snapshot into a staging directory first:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-04-07_12-00-00 \
  --path /home/home/backups/joplin \
  --restore-to /tmp/restore-joplin
```

Apply the folder restore only after reviewing the dry-run:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-04-07_12-00-00 \
  --path /home/home/backups/joplin \
  --restore-to /tmp/restore-joplin \
  --yes
```

Verify the dump before using it:

```bash
cd /tmp/restore-joplin/home/home/backups/joplin
sha256sum -c joplin-YYYYMMDDTHHMMSSZ.dump.sha256
```

To restore Joplin on the VPS, stop the app, restore the selected dump into the
PostgreSQL container, then start and verify the app:

```bash
ssh arvan 'sudo docker stop arvan-joplin-app'
cat /tmp/restore-joplin/home/home/backups/joplin/joplin-YYYYMMDDTHHMMSSZ.dump \
  | ssh arvan 'sudo docker exec -i arvan-joplin-db sh -lc '"'"'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges --exit-on-error'"'"''
ssh arvan 'sudo docker start arvan-joplin-app'
/home/home/my-files/temp/arvan-vps/scripts/joplin-vps status arvan
```

Use the local rollback database only when intentionally rolling back to the old
local Joplin stack. Do not run the local and VPS Joplin apps against
independently changing databases.

## Restore Server Artifact Backups

The default rules include `/home/home/backups/server`. This folder is for local
artifacts pulled from servers, not the live server itself.

Restore it into a staging directory first:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-04-07_12-00-00 \
  --path /home/home/backups/server \
  --restore-to /tmp/restore-server
```

Apply after reviewing the dry-run:

```bash
./backup-home --dest /media/home/backup-drive \
  restore 2026-04-07_12-00-00 \
  --path /home/home/backups/server \
  --restore-to /tmp/restore-server \
  --yes
```

After restore, inspect any checksum, manifest, or service-specific README files
inside `/tmp/restore-server/home/home/backups/server`. Restore artifacts back to
a live server only through that service's own documented procedure; do not
blindly overwrite live server paths.

Walk the manual checklist interactively:

```bash
./backup-home manual
```

Use a custom manual checklist file:

```bash
./backup-home --manual-file /path/to/my.manual manual
```

## Safety Notes

- `--dest` is required for commands that operate on snapshots
- the tool refuses `/` as a destination
- the tool refuses destinations inside configured source roots
- `run` supports dry-run mode
- missing configured paths are reported as warnings and skipped
- `restore` defaults to dry-run unless `--yes` is provided
- the tool estimates free space before a real backup
- `plan` and `run` show an estimated size breakdown for each backup root
- real `run` creates a manual staging folder for checklist items and removes it when the script exits
- real backups write logs under `<dest>/logs/`
- `manual` pauses after each task unless `--yes` is provided
- `--ignore-errors` lets backup and verify continue with warnings instead of stopping on some errors

## Customization

Edit `backup-home.rules` to change what gets backed up.

Use normal lines to include and `!` lines to exclude. If you want to use a totally
separate rule set, create another file and pass it with `--config-file`.

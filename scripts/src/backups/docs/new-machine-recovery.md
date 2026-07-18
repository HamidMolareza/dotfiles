# New Machine Recovery

This runbook rebuilds a machine from a `backup-home` snapshot while keeping each
irreversible decision visible. The examples use a placeholder encrypted-disk
location; replace it with the local mount point:

```text
/mnt/encrypted-backup/backups
```

## 1. Prepare a trusted recovery environment

Install Ubuntu, create an administrator account, and install the base tools used by
the recovery CLI:

```bash
sudo apt update
sudo apt install bash rsync coreutils findutils util-linux gawk
```

Obtain a clean, trusted checkout of this backup tool independently of the snapshot.
Review local restore handlers before running them. Never execute scripts copied out
of a backup snapshot.

Recreate ignored local configuration from the tracked samples. When recovering
Docker services, review `config/docker-recovery/local.conf.sample`, copy it to
`local.conf`, and set paths and Docker names for the new machine before running
`restore-plan`.

Create the intended target user before recovery. Reusing the original username,
UID, GID, and home path is simplest, but it is not mandatory. Manifest v2 records the
source identity, and `--target-user`, `--target-home`, and `--map-path` can map it to a
different layout.

## 2. Mount and protect the backup disk

Connect and unlock the external disk, then confirm that the destination is mounted:

```bash
findmnt /mnt/encrypted-backup
ls -ld /mnt/encrypted-backup/backups
```

Use an encrypted filesystem or encrypted container for this backup set. `Private`,
`.env` files, database dumps, Data Protection keys, and service configuration are
sensitive. Do not keep the only copy directly on an unencrypted NTFS/exFAT volume.
Keep the disk read-only until a recovery action genuinely needs normal access when
that is practical.

## 3. Select and verify a snapshot

From the trusted tool checkout:

```bash
./backup-home --dest /mnt/encrypted-backup/backups list
./backup-home --dest /mnt/encrypted-backup/backups \
  verify SNAPSHOT --deep
```

Do not proceed if verification reports checksum, required-collector, file-count, or
status failures. A `success-with-warnings` snapshot needs explicit review of every
warning.

## 4. Inspect the new-machine recovery plan

Run the read-only preflight before changing the target:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  restore-plan SNAPSHOT \
  --target-user home
```

Review source and target identity, home mapping, free space, filesystem components,
collector artifacts, service prerequisites, effective risks, warnings, and blockers.
For a different home layout, add an explicit mapping, for example:

```bash
--target-user newuser \
--target-home /srv/users/newuser \
--map-path /home/alice/Private=/srv/users/newuser/Private
```

Deep recorded-checksum verification is the default. Avoid
`--skip-deep-verify` unless a known performance or media problem justifies weaker
assurance. A legacy snapshot lacks recorded source identity and artifact checksums;
use `--allow-legacy` only after manual inspection. A matching failed-run report is a
blocker, not a warning to bypass.

## 5. Run staged recovery

Interactive recovery is the safest default:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover SNAPSHOT \
  --target-user home
```

Choose each component separately. The tool stages and checksum-compares filesystem
data before merge, never uses delete semantics, and does not silently overwrite a
different target. A conflict becomes `manual-pending`. If replacement is intentional,
approve that exact component only after reviewing the plan and current target.

Safe unattended recovery is available with:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover SNAPSHOT --all --yes
```

This does not approve destructive components. For a reviewed replacement, combine
`--component ID`, `--approve-destructive ID`, and `--yes`. The tool creates a safety
copy under the recovery session before changing an existing target.

Recovery sessions live under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/backup-home/recovery/SESSION_ID/
```

Inspect `plan.txt`, `state.tsv`, `manual-steps.md`, `logs/`, `commands/`, staging, and
`pre-restore/`. Continue unfinished work without repeating verified components:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover --resume SESSION_ID
```

Do not remove the session, staging, or safety copies until the rebuilt machine is
fully verified.

## 6. Rebuild system-level configuration

The `system.inventory` component stages the inventory and generates a list of manual
APT packages missing from the new machine. Review the generated commands instead of
blindly installing everything. Hardware, Ubuntu release, repositories, package names,
and desktop choices may differ.

Apply dconf, crontab, Snap, Flatpak, and package selections selectively. The recovery
tool intentionally does not import them automatically. Reboot or log out after
desktop/session changes where required.

## 7. Recover application services

Install Docker Engine and the Compose plugin, start the daemon, and make the required
images available before rerunning `restore-plan`. The handler does not pull images
automatically.

### TaskSorter

Select `docker.tasksorter`. The core first restores the TaskSorter source and Compose
definition. The trusted Docker handler then restores PostgreSQL from the logical dump
or stopped-volume archive, restores Data Protection keys before the backend starts,
starts PostgreSQL/backend/frontend, waits for health, and verifies PostgreSQL and the
application services. Existing TaskSorter containers or volumes make the component
destructive and require exact approval; a safety archive is created first.

### Joplin Server

Select `docker.joplin-server`. The handler restores the Compose source, restores the
PostgreSQL logical dump or compatible stopped-data archive, starts Compose, and
checks database health. Existing database files require exact destructive approval
and a safety archive.

JEX exports under the restored Joplin desktop backup path remain useful as a separate
application-level fallback. Do not import both recovery paths blindly into the same
profile.

### AdGuard Home

Select `docker.adguard`. The handler stops the service, restores the separately
archived configuration and runtime data, restarts Compose, and verifies the service.
Existing state requires exact approval and is archived first. Test DNS resolution,
filters, upstreams, and the administration UI afterward.

### SQL Server

Select `docker.mssql`. Recovery stages verified `.bak` artifacts and writes a T-SQL
template using `RESTORE FILELISTONLY`. The final `RESTORE DATABASE`, logical file
mapping, target database name, and replacement decision stay manual because they are
environment-specific and potentially destructive. Review the generated template,
restore to a deliberate name, run application migrations only when appropriate, and
perform application-level checks before retiring the old database.

Unknown collector artifacts are staged with their `RESTORE.md` guidance and remain
`manual-pending`.

## 8. Verify and close the recovery

After components report verified:

1. Confirm ownership and permissions, especially `Private`, SSH/GPG opt-in material,
   Docker bind mounts, and executable scripts.
2. Open TaskSorter and other critical projects; run their normal tests or smoke
   checks and confirm Git remotes and uncommitted work.
3. Verify database counts and representative records, not only container health.
4. Test Joplin sync, AdGuard DNS, scheduled tasks, desktop settings, and required
   applications.
5. Review every `manual-pending`, `warning`, and `failed` state in the session.
6. Keep the external backup unchanged until the new machine has survived normal use
   and at least one fresh verified backup.

If an approved merge or handler produced a bad result, stop affected services and use
the session's `pre-restore/` safety copy or handler safety archive. Recovery does not
automatically roll back because service-specific rollback can itself destroy newer
data.

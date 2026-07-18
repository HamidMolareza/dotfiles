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
sudo apt install bash rsync coreutils findutils util-linux gawk python3 git openssh-client
```

Obtain a clean, trusted checkout of this backup tool independently of the snapshot.
Review local restore handlers before running them. Never execute scripts copied out
of a backup snapshot.

Recreate ignored local configuration from the tracked samples. Review the Docker,
credentials, Codex/MCP, browser, GitHub, and server recovery samples and copy only
the collectors you intend to use. Set paths, account names, extension IDs, SSH
aliases, and service names for the new machine before running `restore-plan`.

The old machine's ignored local files are data, not trusted code. If needed, restore
the previous `config/` tree to a temporary directory, compare it with the clean
checkout, and copy reviewed values manually. Never run a collector or handler copied
from the snapshot.

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

Use an encrypted filesystem or encrypted container for this backup set when
available. `Private`,
`.env` files, database dumps, Data Protection keys, and service configuration are
sensitive. Do not keep the only copy directly on an unencrypted NTFS/exFAT volume.
Keep the disk read-only until a recovery action genuinely needs normal access when
that is practical.

Older snapshots may have been intentionally created on an unencrypted destination
under a `warn` policy. `restore-plan` reports the recorded state; treat the warning
as a storage-risk disclosure, not as snapshot corruption. Keep physical custody of
the disk and prioritize moving future snapshots to LUKS-encrypted storage.

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

Review source and target identity, recorded destination-encryption state, home
mapping, free space, filesystem components, collector artifacts, service
prerequisites, effective risks, warnings, and blockers.
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

Recommended order is foundational files, credentials, Codex/MCP databases, browser
prerequisites and state, Docker applications, GitHub mirrors/credentials, and remote
server recovery. Rerun `restore-plan` whenever installing a missing prerequisite or
initializing a new browser profile changes readiness.

## 6. Rebuild system-level configuration

The `system.inventory` component stages the inventory and generates a list of manual
APT packages missing from the new machine. Review the generated commands instead of
blindly installing everything. Hardware, Ubuntu release, repositories, package names,
and desktop choices may differ.

Apply dconf, crontab, Snap, Flatpak, and package selections selectively. The recovery
tool intentionally does not import them automatically. Reboot or log out after
desktop/session changes where required.

## 7. Recover credentials, Codex, and browsers

### Credentials

Recover credential components independently. All configured components are
recommended for a complete recovery; skip GNOME keyring or GitHub CLI state only when
a fresh login from the password manager is deliberately preferable. Existing state
changes the component risk to destructive. Exact approval causes the handler to
create a private safety archive before extraction.

Restore GnuPG or the GNOME keyring from a separate TTY or administrator session after
the target desktop user is logged out. The handler blocks while `gpg-agent`, the
keyring daemon, Codex, or related MCP processes are using the selected component.

After SSH/GPG recovery, test one known SSH host and list GnuPG keys without sharing
the output. After keyring recovery, log out and back in and confirm that the login
keyring unlocks. Rotate any credential that may have been exposed while the backup
disk was unencrypted.

### Codex and MCP

Close Codex and every MCP process before selecting `codex.databases` or
`mcp.databases`. The handler restores only explicitly classified database files,
removes stale WAL/SHM sidecars, corrects ownership, and runs `PRAGMA quick_check`.
Normal filesystem recovery supplies Codex sessions, config, skills, memories,
authentication files, and MCP logs.

Start one MCP at a time afterward. Use a read-only health or listing call before any
write operation. If a service reports a database error, stop it and recover the
per-file safety copy from the recovery session rather than repeatedly restarting it.

### Browsers

Install Firefox/Chromium, start each once to create a profile, and close every
browser. Review `browser.extensions` first and install only trusted extensions from
official stores. Start Firefox once after installation and close it again so stable
extension IDs receive new profile UUIDs.

Resume recovery for `browser.bookmarks`, `browser.sessions`, `browser.onetab`, and
`browser.extensions`. Missing profiles or extensions become `manual-pending`; the
session contains the targeted artifacts and instructions. The backup intentionally
does not contain history, cookies, saved browser passwords, or a complete raw
profile. Open recovered sessions offline first if unexpected navigation would be a
security or privacy risk.

## 8. Recover application services

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

## 9. Recover GitHub and remote servers

### GitHub

Restore `github.local-mirrors` as normal filesystem data and optionally approve
`github.credentials`. Validate each account with ambient token variables removed.
Run `git fsck --full` on important bare mirrors and compare repository metadata,
issues, releases, and rules before rebuilding anything remote.

Select `github.remote-rebuild` to generate review instructions. The handler never
creates a repository and never runs `git push --mirror`; perform those operations one
repository at a time after checking account ownership, visibility, archive state,
default branch, and name collisions. Re-enter Actions and webhook secret values from
the password manager because GitHub exports names only.

### Remote server

Restore the local server cache before server components. Use the guided foundation,
secret, WireGuard, proxy-router, Joplin, and log components to inspect the saved
configuration and inventory. Deploy service code from a trusted repository checkout,
not from a snapshot archive.

Gateway Monitor and GitHub proxy SQLite recovery can be automated after exact
destructive approval. The handler keeps a timestamped remote safety copy, stops only
the configured systemd unit or Docker container, installs a clean database, restarts
it, and checks integrity and runtime state. Keep the original SSH session open during
any network work. Apply
provider firewall/security-group, DNS, nftables, routes, and WireGuard changes only
after comparing the new environment, and prove a second SSH path works before
closing the first.

Restore Joplin from the newest checksum-verified logical PostgreSQL dump through the
trusted helper or documented Compose process. Never substitute physical PostgreSQL
files from a running server.

## 10. Verify and close the recovery

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

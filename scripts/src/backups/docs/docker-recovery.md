# Docker Recovery Collector

`collectors/docker-recovery` keeps application consistency outside the rsync backup
core. A local profile may copy `/home/alice/.dotfiles/docker-services`,
but raw storage that cannot be copied safely while live is excluded and represented
by collector artifacts under:

```text
.backup-home/artifacts/collectors/docker-recovery/
```

## Coverage

| Service | Running state | Recovery artifact |
| --- | --- | --- |
| TaskSorter PostgreSQL | Running | `pg_dumpall` logical cluster dump |
| TaskSorter PostgreSQL | Stopped | Physical named-volume archive |
| TaskSorter backend | Either | Data Protection key-volume archive |
| SQL Server | Running | One native `.bak` per online database, including system databases except `tempdb` |
| SQL Server | Stopped | Physical bind-mounted data archive |
| Joplin PostgreSQL | Running | `pg_dumpall` logical cluster dump |
| Joplin PostgreSQL | Stopped | Physical PostgreSQL 15 data archive |
| AdGuard configuration | Either | Read-only archive of the bind-mounted `confdir` |
| AdGuard runtime data | Either | Read-only archive; a running capture is recorded as a warning |

Every SQL Server native backup uses `COPY_ONLY` and `CHECKSUM`, then passes
`RESTORE VERIFYONLY` before it is published. Every collector file is also recorded in
`checksums.sha256`.

## Local configuration

No machine path, username, container name, volume name, or image tag is selected by
tracked configuration. Copy the inactive sample and review it locally:

```bash
cp config/docker-recovery/local.conf.sample config/docker-recovery/local.conf
```

The ignored file defines home-relative TaskSorter and service paths, Docker object
names, Compose identifiers, helper images, and the list of unsupported running
stateful containers that must block a backup. It contains no passwords or connection
strings. Both the collector and trusted restore handler reject missing, unknown,
duplicate, malformed, absolute, or traversal-bearing path settings.

For example, a local home profile may separately include:

- `/home/alice/Projects/TaskSorter` for source and Compose definitions
- `/home/alice/backups/joplin` for existing server dump artifacts
- `/home/alice/snap/joplin-desktop/common/JoplinBackup` for JEX exports
- the static Docker service definitions, local environment file, patches, and readable
  non-database data below `/home/alice/.dotfiles/docker-services`; unreadable AdGuard
  configuration is represented by the collector's `config.tar`

## Restore boundaries

Prefer logical PostgreSQL dumps and SQL Server `.bak` files. They are more portable
and are created without stopping running services. The generated `RESTORE.md` files
inside each snapshot give artifact-specific guidance.

Physical PostgreSQL or SQL Server archives are fallback artifacts created only when
the corresponding database is stopped. Restore them only while every consumer is
stopped and only with the same database major version. Restoring databases remains an
explicit operator action at collection time; the collector never replaces active
data. Guided recovery may apply supported artifacts later through the separate,
trusted local restore handler and its approval rules.

TaskSorter's Data Protection keys must be restored before the backend starts if
existing encrypted cookies or protected payloads need to remain readable.

Stop AdGuard before extracting `config.tar` into its bind-mounted `confdir` or
`work-data.tar` into `workdir/data`, then validate DNS and the administration UI
after restart.

## Guided restore handler

Run a read-only target and artifact preflight first:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  restore-plan SNAPSHOT
```

When Docker recovery artifacts are present, the trusted
`restore-handlers/docker-recovery` exposes these component IDs:

| Component | Automated behavior | Replacement boundary |
| --- | --- | --- |
| `docker.tasksorter` | Restore source, PostgreSQL, Data Protection keys, and Compose services; verify database and service health | Existing volumes or containers require exact destructive approval and safety archives |
| `docker.joplin-server` | Restore source and PostgreSQL, start Compose, verify database health | Existing PostgreSQL files require exact destructive approval and a safety archive |
| `docker.adguard` | Restore source, configuration, and runtime state; start and verify Compose | Existing bind-mounted state requires exact destructive approval and safety archives |
| `docker.mssql` | Stage `.bak` files and generate a reviewable T-SQL template | Always manual-pending; database names, file mappings, and final replacement are never guessed |

Run selected recovery interactively, or name a component explicitly:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover SNAPSHOT \
  --component docker.tasksorter
```

If preflight detects existing TaskSorter state, approve only after reviewing the
target and planned safety copy:

```bash
./backup-home --dest /mnt/encrypted-backup/backups \
  recover SNAPSHOT \
  --component docker.tasksorter \
  --approve-destructive docker.tasksorter \
  --yes
```

The handler rechecks destructive approval independently. Application safety archives
are stored under the private recovery session. Core filesystem merge safety copies
are stored below its `pre-restore/` directory. Keep both until application-level
verification succeeds.

SQL Server recovery intentionally stops after writing
`commands/sql-server-restore-template.sql`. Copy deliberate `.bak` files into a
compatible container, run `RESTORE FILELISTONLY`, replace placeholders with reviewed
logical file mappings, and execute `RESTORE DATABASE` manually. Do not restore system
databases blindly.

## Operational requirements

- Keep the backup destination encrypted because database dumps, `.env` files, and
  Data Protection keys are sensitive.
- Keep the Docker daemon available for a real backup. Dry-run intentionally does not
  execute collectors.
- Keep every image selected in the local Docker recovery config available. The
  running SQL Server container must contain `sqlcmd`. The collector never pulls
  images automatically.
- Ensure `TMPDIR` has enough free space for all generated artifacts. The current
  database set needs several gigabytes of temporary space.
- Treat collector warnings as recovery work, not harmless noise. A snapshot with a
  collector warning is finalized as `success-with-warnings`.
- List locally running stateful containers without an application-aware handler in
  `unsupported_containers`. If one is running, the required collector fails instead
  of copying live raw storage and claiming success.
- Restore handlers are local trusted code. Never copy or execute a handler from a
  snapshot; see `restore-handler-contract.md` for the protocol and trust boundary.

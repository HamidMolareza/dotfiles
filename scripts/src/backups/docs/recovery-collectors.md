# Recovery Collectors

The recovery collectors keep application-specific consistency logic outside the
`backup-home` core. They are explicit executables in `config/collectors/enabled.conf`;
none is discovered or executed implicitly. Their matching trusted handlers are
automatically registered from the local checkout and never from snapshot data.

Every collector writes a private artifact directory containing:

- `index.tsv`: paths and status without secret contents
- `checksums.sha256`: every generated regular file
- `RESTORE.md`: recovery boundaries and operator guidance
- optional `warnings.txt`: non-fatal limitations that make the snapshot
  `success-with-warnings`

Local selections live in ignored `config/*-recovery/local.conf` files. Copy the
tracked sample, review every line, and never put tokens or passwords in these files.

## Destination sensitivity

Mark profiles containing credentials, private files, database dumps, or browser
state with:

```text
sensitive=yes
unencrypted_destination=warn
```

`warn` is useful while migrating an existing unencrypted backup disk: the run
continues, but the manifest and report preserve the warning. Use `require` only after
the destination is reliably mounted through a visible LUKS layer. `allow` suppresses
the policy decision but does not make the data safe.

## Credentials

`credentials-recovery` accepts `COMPONENT|HOME_RELATIVE_PATH` entries. Each component
becomes a separate metadata-preserving tar archive so SSH/GPG material, the GNOME
keyring, GitHub CLI state, and Codex authentication can be approved independently.
The handler validates archive paths, creates a private pre-restore archive for
existing state, extracts without trusting snapshot ownership, and then corrects
target ownership when needed. It never prints archive contents.

## Codex and MCP

`codex-mcp-recovery` classifies every database as `sqlite` or `static`, with a
`codex` or `mcp` category. SQLite files are copied through the online backup API and
checked with `PRAGMA quick_check`; a static classification is reserved for a
database-like legacy file that SQLite cannot open. Candidate roots are scanned, and
an unclassified `.db`, `.sqlite`, or `.sqlite3` file fails the collector to prevent
silent data loss.

Normal profile includes retain sessions, memories, logs, skills, configuration, and
MCP logs. Raw classified databases and their WAL/SHM files are excluded from rsync.
During recovery, close Codex and MCP processes. The handler safety-copies the current
database and sidecars, installs the clean artifact with private mode, removes stale
sidecars, and repeats the integrity check.

## Browsers

`browser-recovery` deliberately does not copy a complete profile. It exports:

- Firefox bookmark backups and session-recovery files
- Chromium `Bookmarks` and `Sessions`
- sanitized extension inventory derived from Firefox `extensions.json` and Chromium
  `Preferences`
- storage for explicitly allowlisted Firefox extensions

It excludes history, cookies, saved browser passwords, caches, and unselected
extension state. Firefox extension data is keyed by stable extension ID in local
configuration. The collector resolves that ID to the source profile UUID; the
handler resolves it again on the new machine, so OneTab and other allowlisted state
can move between different profile UUIDs.

All browsers must be closed for restore. Install each extension from its official
store and start Firefox once before resuming recovery. Missing target profiles or
extensions become `manual-pending` with staged artifacts and precise guidance.

## GitHub

`github-recovery` obtains each reviewed account token through `gh auth token --user`
and ignores ambient `GITHUB_TOKEN`/`GH_TOKEN`. It validates `/user.login` before use
and never places a token in a URL, Git config, log, or manifest. Because credentials
were explicitly selected for recovery, a private token artifact is available to the
destructive `github.credentials` component. The official user-migration endpoint
must also be readable; configure a compatible classic PAT for each account before the
first backup. A fine-grained or incompatible OAuth token may clone repositories but
still receive HTTP 403 from the migration API.

The persistent cache contains bare mirrors of owned repositories, wikis, gists, and
Git LFS objects, plus API exports for repository settings, issues, pull requests,
labels, milestones, releases, rulesets, environments, collaborators, Pages, webhook
metadata, deploy keys, Actions variables, and secret names. Optional API endpoints
may be unavailable because of plan, feature, or scope and are marked explicitly.

An official user-migration archive is refreshed at the configured interval with
repository locking disabled and Git data excluded; its value is issues, releases,
attachments, and other migration metadata already complemented by local Git mirrors.
Two archives are retained by default. A failed live refresh may use the cache only
within `max-age-hours`; stale cache fails a required collector.

Recovery restores local mirrors and credentials but never creates a GitHub
repository or pushes a mirror automatically. Actions and webhook secret values
cannot be exported by GitHub and stay on the manual checklist.

## Server

`server-recovery` uses one reviewed SSH alias. It creates an atomic, retained local
bundle with:

- a numeric-owner, ACL/xattr-preserving tar of explicitly listed configuration and
  secret paths
- online, integrity-checked SQLite backups
- bounded journal excerpts and safe system/service/container/network inventory
- a checksum for every bundle file

It does not copy historical deployment-backup trees, unbounded logs, or physical
PostgreSQL storage. A configured trusted Joplin helper performs the logical
PostgreSQL dump and local checksum verification separately. A failed remote refresh
may use a cache only within `max-age-hours`, which should normally be 24.

The handler can replace the Gateway Monitor and GitHub proxy SQLite databases only
after exact destructive approval. It uploads one clean database, keeps a timestamped
remote copy of the database and sidecars, stops one explicitly configured systemd
unit or Docker container, installs the artifact atomically, starts it, and verifies
both SQLite integrity and runtime state. Foundation, secrets, WireGuard, firewall,
routing, proxy-router,
provider DNS/security groups, and Joplin remain guided because blind automation can
remove remote access or overwrite newer server state.

# Restore Handler Contract

Restore handlers extend guided recovery without putting application-specific logic
inside the backup core. They are trusted local executables. A handler copied into a
snapshot is data and must never be executed.

## Registration and trust

Optional local registrations use one entry per line in
`config/restore/handlers.local.conf`:

```text
collector-name|/absolute/path/to/trusted/executable
```

The collector name identifies the matching snapshot artifact directory. The command
must be absolute and executable; shell fragments, arguments, relative paths, and
duplicate names are rejected. A missing default local file is valid. The tracked
tracked handlers below `restore-handlers/` for Docker, credentials, Codex/MCP,
browser, GitHub, and server recovery are registered automatically when executable
and not overridden by a matching local entry.

Review a handler with the same care as a root-capable restore script. It may inspect
snapshot data, change services, and use `sudo` only when its documented component
requires it. It must not print secrets, environment dumps, connection strings, or
database contents.

## Invocation

The core invokes:

```text
HANDLER ACTION [COMPONENT_ID]
```

Supported actions are:

- `describe`: declare available components; no target changes.
- `preflight`: inspect one component and report readiness and effective risk; no
  target changes.
- `apply`: perform the approved component recovery.
- `verify`: verify the recovered component.
- `guide`: print concise Markdown for operator-owned or failed follow-up work.

Handlers must accept repeated read-only calls. `describe`, `preflight`, and `guide`
must not mutate the target.

## Describe records

`describe` writes tab-separated records to stdout. A component must be declared
before its path or dependencies:

```text
component<TAB>ID<TAB>LABEL<TAB>CAPABILITY<TAB>RISK<TAB>RECOMMENDATION
path<TAB>ID<TAB>ABSOLUTE_SOURCE_PATH
dependency<TAB>ID<TAB>OTHER_COMPONENT_ID
```

Values are:

- `CAPABILITY`: `automatic`, `guided`, or `files-only`.
- `RISK`: `safe`, `privileged`, `destructive`, or `manual`.
- `RECOMMENDATION`: `recommended` or `optional`.
- `ID`: a stable value matching `[A-Za-z0-9][A-Za-z0-9._-]*`.

A `path` asks the core to stage, verify, map, and safely merge that snapshot source
before `apply`. A dependency must reach verified state before the dependent component
is run.

## Preflight records

`preflight` writes two-field, tab-separated records:

```text
ok<TAB>MESSAGE
warning<TAB>MESSAGE
blocker<TAB>MESSAGE
risk<TAB>safe|privileged|destructive|manual
```

The dynamic `risk` record may strengthen or otherwise replace the declared risk after
examining the new machine. For example, an initially privileged database restore can
become destructive when an existing data volume is detected.

## Environment

Every action receives:

```text
BACKUP_HOME_RESTORE_ACTION
BACKUP_HOME_SNAPSHOT_DIR
BACKUP_HOME_ARTIFACT_DIR
BACKUP_HOME_RESTORE_STAGING_DIR
BACKUP_HOME_RESTORE_SESSION_DIR
BACKUP_HOME_SOURCE_HOME
BACKUP_HOME_TARGET_USER
BACKUP_HOME_TARGET_UID
BACKUP_HOME_TARGET_GID
BACKUP_HOME_TARGET_HOME
BACKUP_HOME_RESTORE_DRY_RUN
BACKUP_HOME_RESTORE_ASSUME_YES
BACKUP_HOME_DESTRUCTIVE_APPROVED
```

`BACKUP_HOME_ARTIFACT_DIR` points to
`.backup-home/artifacts/collectors/COLLECTOR_NAME` inside the snapshot.
`BACKUP_HOME_DESTRUCTIVE_APPROVED` is `1` only when the operator approved that exact
component. A handler must independently refuse destructive work when it is not `1`.
Application handlers may define a separate ignored local configuration. The shipped
Docker handler uses `config/docker-recovery/local.conf`, optionally overridden by
`BACKUP_HOME_DOCKER_RECOVERY_CONFIG`; snapshot configuration is never sourced.

## Exit status and output

- Exit `0`: action succeeded.
- Exit `20`: work is intentionally `manual-pending`; `guide` must explain the next
  steps.
- Any other non-zero status: action failed.

`apply` and `verify` output is written to the private recovery-session log. Keep it
brief and sanitized. `guide` output is displayed and appended to
`manual-steps.md`. Never depend on executing code or commands supplied by snapshot
contents.

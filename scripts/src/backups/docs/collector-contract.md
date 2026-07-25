# Collector contract

Collectors are trusted local executables. A snapshot stores data, never executable
collector code. The registry format is:

```text
PRIORITY|MODE|NAME|ABSOLUTE_COMMAND[|TIMEOUT_SECONDS]
```

`PRIORITY` is a unique non-negative integer; lower values run first. `MODE` is
`required` or `optional`. `TIMEOUT_SECONDS` is an optional positive integer and
defaults to 1800. Names and priorities must be unique. The former three-column
format is rejected so an accidental migration cannot silently change execution
order.

## Commands

Every collector implements:

```text
collector metadata
collector backup
collector restore ACTION [COMPONENT]
```

`metadata` is read-only and prints tab-separated records:

```text
protocol	1
backup	required
restore	supported
```

Use `restore unsupported` when restore is not implemented. `backup` is mandatory.
The optional restore actions are `describe`, `preflight`, `apply`, `verify`, and
`guide`. `describe`, `preflight`, and `guide` must be read-only. Component IDs are
opaque to the core. Exit code `0` means success, `20` means manual work remains,
`64` means unsupported, and every other non-zero code means failure.

## Shared context

The core passes non-secret values. A collector may ignore values it does not need:

- `BACKUP_HOME_PROTOCOL_VERSION`, `BACKUP_HOME_ACTION`
- `BACKUP_HOME_COLLECTOR_NAME`, `BACKUP_HOME_COLLECTOR_PRIORITY`,
  `BACKUP_HOME_COLLECTOR_MODE`, `BACKUP_HOME_COLLECTOR_TIMEOUT_SECONDS`,
  `BACKUP_HOME_COLLECTOR_CONFIG`
- `BACKUP_HOME_PROJECT_DIR`, `BACKUP_HOME_PROFILE_FILE`,
  `BACKUP_HOME_MANUAL_FILE`
- `BACKUP_HOME_DEST`, `BACKUP_HOME_DESTINATION_ENCRYPTION`
- `BACKUP_HOME_RUN_ID`, `BACKUP_HOME_SNAPSHOT_NAME`,
  `BACKUP_HOME_RUN_STARTED_AT`, `BACKUP_HOME_COLLECTOR_STARTED_AT`
- `BACKUP_HOME_SOURCE_USER`, `BACKUP_HOME_SOURCE_UID`,
  `BACKUP_HOME_SOURCE_GID`, `BACKUP_HOME_SOURCE_HOME`
- `BACKUP_HOME_HOSTNAME`, `BACKUP_HOME_OS_ID`,
  `BACKUP_HOME_OS_VERSION_ID`
- `BACKUP_HOME_STAGE_DIR`, `BACKUP_HOME_ARTIFACT_DIR`,
  `BACKUP_HOME_DRY_RUN`, `BACKUP_HOME_VERBOSE`

Restore also receives:

- `BACKUP_HOME_SNAPSHOT_DIR`, `BACKUP_HOME_RESTORE_ACTION`,
  `BACKUP_HOME_RESTORE_COMPONENT`
- `BACKUP_HOME_RESTORE_SESSION_DIR`, `BACKUP_HOME_RESTORE_STAGING_DIR`
- `BACKUP_HOME_TARGET_USER`, `BACKUP_HOME_TARGET_UID`,
  `BACKUP_HOME_TARGET_GID`, `BACKUP_HOME_TARGET_HOME`
- `BACKUP_HOME_RESTORE_DRY_RUN`, `BACKUP_HOME_RESTORE_ASSUME_YES`,
  `BACKUP_HOME_DESTRUCTIVE_APPROVED`

Tokens and secret contents are never part of shared context.
Every documented variable is set explicitly for each invocation. Values that do not
apply to metadata or backup are empty (or `0` for flags), and unrelated ambient
`BACKUP_HOME_*` variables are removed. The matching shipped collector's specific
`*_CONFIG` override is preserved deliberately.

## Backup output

Write only below `BACKUP_HOME_STAGE_DIR`. Shipped collectors use
`lib/collector-common` to create `index.tsv`, `checksums.sha256`, optional
`warnings.txt`, and `RESTORE.md`. A required configured source must fail instead of
being silently omitted.

The core runs metadata with a 30-second timeout and backup/restore with the
collector's configured timeout. It sends `TERM` first and `KILL` after a 10-second
grace period. Exit code 124 means timeout. When a backup invocation fails, the core
deletes that collector's partial stage and writes a private `failure.tsv` containing
only its name, status, exit code, timeout state, and configured timeout. Optional
collector failures continue; required collector failures stop the run.

## Restore records and safety

`describe` emits one or more records:

```text
component	ID	LABEL	CAPABILITY	RISK	RECOMMENDATION
path	ID	ABSOLUTE_SOURCE_PATH
dependency	ID	OTHER_COMPONENT_ID
```

Capabilities are `automatic`, `guided`, or `files-only`; risks are `safe`,
`privileged`, `destructive`, or `manual`; recommendations are `recommended` or
`optional`. `preflight` emits `ok`, `warning`, `blocker`, or `risk` records.

The core owns component selection, approvals, session/resume state, and routing.
The collector owns application-specific staging, safety copies, merge/apply, and
verification. Existing state must not be replaced unless
`BACKUP_HOME_DESTRUCTIVE_APPROVED=1` for that exact component.

## Minimal template

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/lib/collector-common"

case "${1:-backup}" in
  metadata) collector_metadata unsupported ;;
  backup)
    collector_init
    # Write reviewed artifacts below "$COLLECTOR_STAGE_DIR".
    collector_finalize
    ;;
  restore) exit 64 ;;
  *) collector_fail "Unsupported collector action" ;;
esac
```

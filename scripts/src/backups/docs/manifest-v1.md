# Backup Home Manifest Schema v1

Every finalized snapshot created by `backup-home` contains:

```text
.backup-home/manifest.tsv
.backup-home/report.txt
.backup-home/checksums.sha256
.backup-home/artifacts/
```

`report.txt` is the human summary. `manifest.tsv` is the stable machine-readable
record used by `verify` and `list`.

## Encoding

The manifest is UTF-8 text with tab-separated fields and one record per line. The
first field is the record type. Backslash, tab, newline, and carriage-return
characters in scalar values are represented as `\\`, `\t`, `\n`, and `\r`.

Configuration paths and collector names reject control characters before a run, so
their manifest values are unambiguous without shell evaluation. Consumers must not
source the manifest as shell code.

## Scalar records

Scalar records have two fields: type and value.

```text
schema_version       1
snapshot             YYYY-MM-DD_HH-mm-ss
status               success | success-with-warnings
started_at           ISO-8601 timestamp
ended_at             ISO-8601 timestamp
hostname             snapshot producer hostname
os_id                /etc/os-release ID
os_version_id        /etc/os-release VERSION_ID
profile_name         profile basename only
config_digest        SHA-256 over profile/exclude/collector config inputs
previous_snapshot    timestamp or none
rsync_exit_code      integer
backup_home_revision git:SHORT_HASH or unversioned
script_sha256        SHA-256 of the executed script
payload_bytes        logical regular-file bytes outside .backup-home
file_count           total regular files in the finalized snapshot
checksum_count       records in checksums.sha256
```

The digest identifies config without embedding full config contents. Resolved roots
and applied excludes are recorded separately because they are needed to interpret and
verify the snapshot.

## Repeated records

Resolved roots and excludes use two fields:

```text
root       /absolute/resolved/path
exclude    pattern
warning    human-readable warning
```

Collector records use seven fields:

```text
collector  NAME  MODE  STATUS  EXIT_CODE  STARTED_AT  ENDED_AT
```

`MODE` is `required` or `optional`. `STATUS` is `success`, `warning`, or `failed`.
A finalized snapshot cannot contain a failed required collector.

## Checksums

`checksums.sha256` uses normal GNU `sha256sum` check-file syntax with paths relative
to the snapshot root. It contains:

- `.backup-home/report.txt`
- every regular file under `.backup-home/artifacts/`
- up to 16 sampled payload files smaller than 16 MiB

`verify --deep` runs `sha256sum -c --strict --quiet` from the snapshot root. The
manifest itself is not part of the checksum set because it records the checksum count
and is written last.

## Failure reports

Failed runs do not publish snapshot manifests. After temporary and incomplete data
are removed, the destination log directory retains:

```text
backup-home-TIMESTAMP.log
backup-home-TIMESTAMP.failure.tsv
backup-home-TIMESTAMP.failure.txt
```

The failure TSV contains schema version, planned snapshot, status, start/end times,
exit code, and a sanitized reason. It is a run diagnostic, not a valid snapshot
manifest.

## Compatibility

Directories with timestamp names but without `.backup-home/manifest.tsv` are treated
as legacy snapshots. They remain available for list, restore, link-dest reuse, prune,
and current-profile basic verification. They cannot pass schema or deep checksum
verification.

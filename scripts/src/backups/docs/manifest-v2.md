# Backup Home Manifest Schema v2

Every finalized snapshot created by the current `backup-home` contains:

```text
.backup-home/manifest.tsv
.backup-home/report.txt
.backup-home/checksums.sha256
.backup-home/artifacts/
```

`report.txt` is the human summary. `manifest.tsv` is the stable machine-readable
record used by verification, listing, recovery planning, and source-to-target path
mapping.

## Encoding

The manifest is UTF-8 text with tab-separated fields and one record per line. The
first field is the record type. Backslash, tab, newline, and carriage-return
characters in scalar values are represented as `\\`, `\t`, `\n`, and `\r`.

Configuration paths and collector names reject control characters before a run.
Consumers must parse records and must never source the manifest as shell code.

## Scalar records

Scalar records have two fields: type and value.

```text
schema_version       2
snapshot             YYYY-MM-DD_HH-mm-ss
status               success | success-with-warnings
started_at           ISO-8601 timestamp
ended_at             ISO-8601 timestamp
hostname             snapshot producer hostname
os_id                /etc/os-release ID
os_version_id        /etc/os-release VERSION_ID
source_user          source account name
source_uid           numeric source user ID
source_gid           numeric source primary group ID
source_home          canonical source home path
profile_name         profile basename only
sensitive_profile    yes | no
destination_encryption_state detected | not-detected | unknown | not-applicable
unencrypted_destination_policy warn | require | allow
config_digest        SHA-256 over profile/exclude/collector config inputs
previous_snapshot    timestamp or none
rsync_exit_code      integer
backup_home_revision git:SHORT_HASH or unversioned
script_sha256        SHA-256 of the executed script
payload_bytes        logical regular-file bytes outside .backup-home
file_count           total regular files in the finalized snapshot
checksum_count       records in checksums.sha256
```

The four source identity fields are the schema v2 addition. `restore-plan` reports
them, and `recover` uses `source_home` as the default mapping prefix. A different
target account or layout may be selected explicitly without rewriting the snapshot.

The three sensitivity fields are backward-compatible schema v2 extensions. For a
sensitive profile, the producer walks the mounted destination's block-device
ancestry and reports whether a `crypto_LUKS` layer is visible. `unknown` means the
tools or mount topology did not permit a reliable answer. `not-applicable` means the
profile was not marked sensitive. This is a local best-effort observation, not a
cryptographic attestation.

The configuration digest identifies inputs without embedding their contents. The
manifest must not contain tokens, environment dumps, connection strings, or raw
authentication diagnostics.

## Repeated records

Resolved roots, applied excludes, and warnings use two fields:

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

`verify --deep`, `restore-plan`, and guided `recover` validate the recorded set by
default where applicable. The manifest itself is not part of the checksum set because
it records the checksum count and is written last.

## Compatibility

Schema v1 manifests remain listable, verifiable, and restorable. Guided recovery
infers their source identity and warns that the identity was not recorded. Timestamp
directories without a manifest are `legacy`: low-level restore remains available,
while guided recovery requires `--allow-legacy`, cannot provide recorded checksum
assurance, and refuses a snapshot with a matching failed-run report.

See `manifest-v1.md` for the previous wire format.

# Manifest schema v3

Schema v3 keeps the v2 identity, safety, root, warning, checksum, and payload fields.
Its collector record adds ordering and protocol information:

```text
collector	NAME	MODE	STATUS	EXIT_CODE	STARTED_AT	ENDED_AT	PRIORITY	PROTOCOL	RESTORE
```

`PRIORITY` is the configured non-negative integer, `PROTOCOL` is currently `1`,
and `RESTORE` is `supported` or `unsupported`. Readers continue to accept schema
v1 and v2 records, whose collector lines end after `ENDED_AT`.

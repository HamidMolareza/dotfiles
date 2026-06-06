# SSH Helpers

This folder contains small SSH-related commands that are exported through
`scripts/exports`.

## SCP Transfers

Use `scp-download` and `scp-upload` when you want the normal `scp` behavior but
do not want to remember the source and destination order.

Download from a server into the current directory:

```bash
scp-download arvan /remote/file
```

Download into a specific local directory:

```bash
scp-download --to ./downloads arvan "/remote/file name.txt"
```

Upload a local file or directory into the remote home directory:

```bash
scp-upload arvan ./local-file
scp-upload arvan ./local-folder
```

Upload into a specific remote directory:

```bash
scp-upload --to /srv/backups/ arvan ./backup.tar.gz
```

Preview the command without connecting:

```bash
scp-download --dry-run arvan /remote/file
scp-upload --dry-run arvan ./local-file
```

Run without the confirmation prompt:

```bash
scp-upload --yes arvan ./local-file
```

Common SSH options are supported:

```bash
scp-upload \
  --port 2222 \
  --identity ~/.ssh/id_ed25519 \
  --jump-host bastion \
  --to /srv/backups/ \
  user@example.com \
  ./backup.tar.gz
```

Notes:

- The first argument is the SSH alias or `[user@]hostname`.
- Downloads default to the current local directory.
- Uploads default to the remote home directory.
- Multiple sources are supported.
- Directory transfers are recursive automatically.
- Paths with spaces should be quoted.
- The commands print the generated `scp` command before executing it.
- Non-interactive execution requires `--yes`; `--dry-run` never connects.

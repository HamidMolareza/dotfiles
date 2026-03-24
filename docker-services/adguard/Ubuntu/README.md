# Ubuntu DNS Helper Scripts

This folder contains helper scripts to make Ubuntu use the local AdGuard Home instance as its DNS resolver.

## Files

- `install-local-dns.sh`: points Ubuntu DNS to local AdGuard Home
- `uninstall-local-dns.sh`: restores the previous DNS-related state

## What the install script changes

The install script:

- creates a `systemd-resolved` drop-in at `/etc/systemd/resolved.conf.d/99-adguard-local.conf`
- creates a `NetworkManager` drop-in at `/etc/NetworkManager/conf.d/99-adguard-local-dns.conf`
- writes `/etc/resolv.conf` to use the chosen AdGuard DNS address
- stores backups in `/var/lib/adguard-ubuntu-dns`
- restarts `systemd-resolved` and `NetworkManager` when present

By default, it uses:

```bash
127.0.0.1
```

You can override that with `ADGUARD_DNS`.

## Requirements

- Ubuntu with `systemd-resolved`
- AdGuard Home already running and listening on DNS, usually `127.0.0.1:53`
- `sudo` access

## Install

```bash
sudo ./install-local-dns.sh
```

Or with a custom DNS target:

```bash
sudo ADGUARD_DNS=127.0.0.1 ./install-local-dns.sh
```

## Uninstall

```bash
sudo ./uninstall-local-dns.sh
```

## Verify

After install, test resolution with:

```bash
resolvectl query example.com
```

You can also inspect the active listener:

```bash
ss -lntu '( sport = :53 )'
```

## Safety

- The install script is designed to be reversible.
- Existing DNS-related files are backed up only once, so rerunning the install script does not overwrite the original backup.
- The uninstall script restores prior files when backups exist, otherwise it removes the drop-ins and falls back to the standard `systemd-resolved` stub symlink behavior.

## Troubleshooting

- If DNS stops working, make sure AdGuard Home is actually running: `docker compose ps`
- If port `53` is busy, another local DNS service may still be bound to it.
- If resolution still looks stale, rerun:

```bash
sudo systemctl restart systemd-resolved NetworkManager
```

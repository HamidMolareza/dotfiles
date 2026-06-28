# AdGuard Home

This directory runs `AdGuard Home` with Docker Compose and stores its persistent data locally.

## Files

- `docker-compose.yml`: main container definition
- `find-admin-url.sh`: prints the detected AdGuard admin URL
- `reset-admin-password.sh`: resets the AdGuard admin password by editing `AdGuardHome.yaml`
- `data/adguard/workdir`: runtime/work data
- `data/adguard/confdir`: AdGuard Home configuration
- `Ubuntu/`: helper scripts and notes for configuring Ubuntu to use this instance as its DNS resolver

## Start

```bash
./enable-adguard.sh
```

This starts the `adguardhome` service and creates its container if needed.
After the container is running, the script configures Ubuntu to use AdGuard at
`127.0.0.1` as its local DNS resolver. It may prompt for `sudo`.

To use another local AdGuard address:

```bash
ADGUARD_DNS=127.0.0.1 ./enable-adguard.sh
```

## Stop

```bash
./disable-adguard.sh
```

This stops AdGuard Home without removing its container or persistent data.
Before stopping the container, the script restores the Ubuntu DNS settings saved
by `Ubuntu/install-local-dns.sh`. If DNS restoration fails, AdGuard remains running.

## Restart

```bash
docker compose restart
```

## Logs

```bash
docker compose logs -f adguardhome
```

## First-time setup

1. Start the container with `docker compose up -d`.
2. Open the AdGuard Home web UI.
3. Complete the initial setup wizard.
4. Confirm AdGuard Home is listening on the DNS port you expect, usually host port `53`.

Because this setup uses `network_mode: host`, AdGuard Home binds directly to the host network stack. That is usually the simplest setup for DNS and DHCP.

## Data and persistence

The container keeps its state in:

- `./data/adguard/workdir`
- `./data/adguard/confdir`

Back up those directories if you want to preserve your filters, upstreams, rewrites, and UI settings.

## Ubuntu host DNS

If this machine is Ubuntu and you want the OS itself to use this AdGuard Home instance as its resolver, see:

- `Ubuntu/README.md`

## Admin helpers

Find the current admin URL:

```bash
./find-admin-url.sh
```

Reset the admin password:

```bash
./reset-admin-password.sh
```

If the AdGuard config file is root-owned, the script may prompt for `sudo`.

## Notes

- The Compose file includes log rotation, `no-new-privileges`, `tmpfs` for `/tmp`, and higher `nofile` limits.
- If you ever switch away from `network_mode: host`, publish only the ports you actually need.

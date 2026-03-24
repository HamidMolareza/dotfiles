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
docker compose up -d
```

## Stop

```bash
docker compose down
```

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

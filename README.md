# Raspberry Pi Fleet Bootstrap & Audit

## System architecture and rationale

Each Raspberry Pi boots from an internal SD card that hosts the primary OS and services. A USB stick holds periodic full clones made with `rpi-clone` for manual rollback. Devices reside behind a firewall and communicate over a ZeroTier VPN. Every 3‑5 years the fleet is rebuilt on a fresh OS image to avoid end‑of‑life and security exposure.

## Upgrade and fallback philosophy

Phase 1 is a physical swap: burn Raspberry Pi OS Bookworm to a new SD card, boot, then run the bootstrap script below. The USB clone remains a manual fallback. Phase 2 will add remote boot and automated rollback once local testing is complete.

## Scripts

### bootstrap.sh
Configures a fresh system:
- Enables and starts SSH
- Installs ZeroTier and joins a network if `ZT_NETWORK_ID` is set
- Installs WayVNC for remote desktop (RealVNC Server is no longer bundled but can be installed manually)
- Installs common tools: cron, curl, wget, vim, git, htop, etc.
- Runs `apt update` and `apt full-upgrade -y`
- Sets up unattended upgrades with automatic reboot when required
- Adds a monthly reboot via cron on the 5th at 03:00
- Ensures `systemd-timesyncd` keeps the clock in sync
- Logs actions to stdout and `/var/log/bootstrap.log`

Run with root privileges:
```sh
sudo ./bootstrap.sh
```
Optional variables:
- `ZT_NETWORK_ID` – ZeroTier network to join
- `VNC_PASSWORD` – password for WayVNC (random if unset)

### audit.sh
Captures system state and user data:
- Lists installed APT packages
- Lists enabled and running systemd services
- Dumps crontabs for users with UID ≥ 1000
- Inventories users, home directories, shells, dotfiles, and paths under `~/.ssh/` and `~/.config/`
- Writes JSON report to `/tmp/system_audit_*.json`
- Creates per‑user tarballs of dotfiles and `~/.ssh/` under `/tmp/gesser_user_backups`

Run with root privileges:
```sh
sudo ./audit.sh
```

## Output structure
- `/var/log/bootstrap.log` – log from `bootstrap.sh`
- `/tmp/system_audit_<timestamp>.json` – audit report
- `/tmp/gesser_user_backups/USERNAME_backup.tgz` – per‑user archives

## Known caveats
- ZeroTier install uses an external script and requires Internet access
- WayVNC password is printed during setup; change it if needed
- If a user lacks `.ssh/` or `.config/`, the audit will note empty lists
- RealVNC Server can still be installed separately but currently requires an X11 session

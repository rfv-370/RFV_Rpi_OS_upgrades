# Raspberry Pi Fleet Bootstrap & Audit

## Quick Summary

- `bootstrap.sh`: prepares a fresh Pi (SSH, ZeroTier, WayVNC, upgrades).
- `audit.sh`: captures system state and user data into JSON and backups.
- `re-install.sh`: rebuilds a system from an audit file.

> This summary is for future reference (e.g., 5 years later) to recall the workflow quickly.

### Usage cheat sheet

```sh
wget https://raw.githubusercontent.com/rfv-370/RFV_Rpi_OS_upgrades/main/bootstrap.sh && sudo bash bootstrap.sh
wget https://raw.githubusercontent.com/rfv-370/RFV_Rpi_OS_upgrades/main/audit.sh && sudo bash audit.sh
wget https://raw.githubusercontent.com/rfv-370/RFV_Rpi_OS_upgrades/main/re-install.sh && sudo bash re-install.sh <system_audit.json>
```

## System architecture and rationale

Each Raspberry Pi boots from an internal SD card that hosts the primary OS and services. A USB stick holds periodic full clones made with `rpi-clone` for manual rollback. Devices reside behind a firewall and communicate over a ZeroTier VPN. Every 3‑5 years the fleet is rebuilt on a fresh OS image to avoid end‑of‑life and security exposure.

## Upgrade and fallback philosophy

Phase 1 is a physical swap: burn Raspberry Pi OS Bookworm to a new SD card, boot, then run the bootstrap script below. The USB clone remains a manual fallback. Phase 2 will add remote boot and automated rollback once local testing is complete.

## Scripts

### bootstrap.sh
Configures a fresh system:
- Enables and starts SSH
- Installs ZeroTier (join networks manually after running)
- Installs WayVNC for remote desktop (RealVNC Server is no longer bundled but can be installed manually)
- Installs common tools: cron, curl, wget, vim, git, htop, etc.
- Runs `apt update` and `apt full-upgrade -y`
- Sets up unattended upgrades with automatic reboot when required
- Adds a monthly reboot via cron on the 5th at 03:00
- Ensures `systemd-timesyncd` keeps the clock in sync
- Logs actions to stdout and `./bootstrap.log`
- Requires editing `VNC_PASSWORD` at the top of the script before execution

Run with root privileges:
```sh
sudo ./bootstrap.sh
```

### audit.sh
Captures system state and user data:
- Lists installed APT packages
- Lists enabled and running systemd services
- Dumps crontabs for users with UID ≥ 1000
- Inventories users, home directories, shells, dotfiles, and paths under `~/.ssh/` and `~/.config/`
- Writes JSON report to `./system_audit_<timestamp>.json`
- Creates per‑user tarballs of dotfiles and `~/.ssh/` under `./gesser_user_backups`
- Logs actions to stdout and `./audit.log`

Run with root privileges:
```sh
sudo ./audit.sh
```

### re-install.sh
Restores a system using an audit produced by `audit.sh`:
- Installs APT packages listed in the audit
- Re-creates users, home directories, dotfiles, and crontabs
- Restores custom systemd units, enabled/running services, firewall rules, SSH host keys, and optional `/etc` backup
- Logs actions to `./re-install_<timestamp>.log`

Run with root privileges:
```sh
sudo ./re-install.sh <system_audit.json>
```

## Output structure
- `./bootstrap.log` – log from `bootstrap.sh`
- `./audit.log` – log from `audit.sh`
- `./system_audit_<timestamp>.json` – audit report
- `./gesser_user_backups/USERNAME_backup.tgz` – per‑user archives
- `./re-install_<timestamp>.log` – log from `re-install.sh`

## Known caveats
- ZeroTier install uses an external script and requires Internet access; joining a network must be approved manually
- WayVNC password must be set in `bootstrap.sh` before running
- If a user lacks `.ssh/` or `.config/`, the audit will note empty lists
- RealVNC Server can still be installed separately but currently requires an X11 session
- Future improvement: `re-install.sh` could automate ZeroTier network joins with a pause for manual approval

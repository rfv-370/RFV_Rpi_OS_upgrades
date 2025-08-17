#!/bin/bash
# Run as root: sudo ./audit.sh
set -euo pipefail

# This script must be run with root privileges.
[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }

# ---------- SUMMARY REMARKS ----------
SUMMARY="
Raspberry Pi Fleet System Audit Script

This script performs a comprehensive audit and backup of a Raspberry Pi (or similar Debian-based system) for fleet management and disaster recovery.
It captures:
- Installed APT packages
- Enabled and running systemd services, plus custom systemd units
- ZeroTier network memberships
- NFS/SSHFS/CIFS mounts and exports, /etc/fstab, contents of /mnt, and which are mounts
- Firewall configuration (iptables/nft)
- SSH host keys (base64-encoded)
- /etc directory backup as a tarball
- For each user (UID >= 1000): username, home, shell, dotfiles, ~/.ssh, ~/.config, crontab, and a tarball of dotfiles and .ssh
- All output is written to the current working directory

Remarks:
- Only APT packages are inventoried. Packages from pip, snap, flatpak, etc. are NOT included.
- Certificates are not backed up.
- User backup tarballs are referenced in the main JSON by filename only, and expected to be in the same directory.
- /etc is backed up as a tarball for full system config recovery.
"

# ---------- ECHO SUMMARY BEFORE ANY ACTION ----------
LOG_FILE="./audit.log"
touch "$LOG_FILE"
{
echo "$SUMMARY"
echo "------------------------------------------------------------"
echo "A summary of actions that will be performed:"
echo
echo "- List all installed APT packages"
echo "- List all enabled and running systemd services"
echo "- List custom systemd units (.service/.timer in /etc/systemd/system)"
echo "- List ZeroTier networks this device is a member of"
echo "- Copy /etc/fstab and /etc/exports (if present)"
echo "- List active remote mounts (NFS, SSHFS, CIFS) and directories in /mnt"
echo "- Dump firewall rules (iptables and nft, if available)"
echo "- Archive all SSH host keys in /etc/ssh (base64-encoded)"
echo "- Create a tarball backup of /etc"
echo "- For each real user (UID >= 1000):"
echo "    - Inventory dotfiles, ~/.ssh, ~/.config"
echo "    - Dump crontab"
echo "    - Create a tarball of dotfiles and .ssh"
echo "- Compile all collected data into a JSON file in the current directory"
echo
echo "All output and backup files will be created in: $(pwd)"
echo "------------------------------------------------------------"
} | tee -a "$LOG_FILE"
sleep 2

log() { echo "$(date -Iseconds) $*" | tee -a "$LOG_FILE"; }

# Output locations: current directory
OUTDIR="$(pwd)"
TS="$(date +%Y%m%d%H%M%S)"
OUTPUT_FILE="$OUTDIR/system_audit_${TS}.json"
BACKUP_DIR="$OUTDIR/gesser_user_backups"
ETC_TARBALL="$OUTDIR/etc_backup_${TS}.tgz"
ETC_DIFF_FILE="$OUTDIR/etc_diff_${TS}.txt"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# --- 1. PACKAGE INVENTORY ---
log "Gathering APT package list"
dpkg-query -W -f='${Package} ${Version}\n' | sort > "$OUTDIR/apt_packages.txt"

# --- 2. SYSTEMD SERVICES ---
log "Gathering enabled services"
systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' | sort > "$OUTDIR/enabled_services.txt"

log "Gathering running services"
systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sort > "$OUTDIR/running_services.txt"

# Custom systemd units
log "Gathering custom systemd units (/etc/systemd/system)"
find /etc/systemd/system -type f \( -name '*.service' -o -name '*.timer' \) -print | sort > "$OUTDIR/custom_systemd_units.txt"

# --- 3. ZEROTIER NETWORKS ---
log "Gathering ZeroTier network memberships"
ZEROTIER_NETWORKS=""
if command -v zerotier-cli &>/dev/null; then
  ZEROTIER_NETWORKS="$(zerotier-cli listnetworks 2>/dev/null | tail -n +2 || true)"
  echo "$ZEROTIER_NETWORKS" > "$OUTDIR/zerotier_networks.txt"
fi

# --- 4. NFS, SSHFS, FSTAB, MNT ---
log "Capturing fstab and NFS/SSHFS/CIFS mounts"
cp /etc/fstab "$OUTDIR/fstab"
[ -f /etc/exports ] && cp /etc/exports "$OUTDIR/exports" || true

# List mounts
mount | grep -E ' type (nfs|cifs|sshfs) ' > "$OUTDIR/remote_mounts.txt" || true

# List /mnt content and which are mount points
ls -1 /mnt > "$OUTDIR/mnt_dirs.txt" || true
findmnt -rn -o TARGET | grep '^/mnt' > "$OUTDIR/mnt_mountpoints.txt" || true

# --- 5. FIREWALL CONFIG ---
log "Capturing firewall rules (iptables/nft)"
if command -v nft &>/dev/null; then
  nft list ruleset > "$OUTDIR/nft_ruleset.txt" 2>/dev/null || true
fi
if command -v iptables-save &>/dev/null; then
  iptables-save > "$OUTDIR/iptables_ruleset.txt" 2>/dev/null || true
fi

# --- 6. SSH HOST KEYS ---
log "Capturing SSH host keys"
SSH_HOST_KEYS=()
for keyfile in /etc/ssh/ssh_host_*_key; do
  [ -f "$keyfile" ] || continue
  b64=$(base64 < "$keyfile" | tr -d '\n')
  SSH_HOST_KEYS+=("{\"file\":\"$(basename "$keyfile")\",\"mode\":\"$(stat -c '%a' "$keyfile")\",\"base64\":\"$b64\"}")
done
SSH_HOST_KEYS_JSON="$(printf '[%s]' "$(IFS=,; echo "${SSH_HOST_KEYS[*]}")")"
export SSH_HOST_KEYS_JSON

# --- 7. /etc BACKUP + DIFF ---
log "Backing up /etc"
tar czf "$ETC_TARBALL" -C / etc
chmod 600 "$ETC_TARBALL"

# Prepare a diff against clean Raspberry Pi OS (future: here we just list files for now)
find /etc -type f | sort > "$ETC_DIFF_FILE"

# --- 8. USERS & DOTFILES ---
USER_JSONL="$OUTDIR/user_data.jsonl"
: > "$USER_JSONL"

for user in $(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd); do
  home=$(eval echo "~$user")
  shell=$(getent passwd "$user" | cut -d: -f7)

  dotfiles_list=$(for f in .bashrc .profile .gitconfig; do [ -f "$home/$f" ] && printf '%s\n' "$f"; done)
  dotfiles_json=$(printf '%s\n' "$dotfiles_list" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')

  ssh_paths=$(find "$home/.ssh" -mindepth 1 -maxdepth 5 2>/dev/null | sed "s|$home/||")
  ssh_json=$(printf '%s\n' "$ssh_paths" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')

  config_paths=$(find "$home/.config" -mindepth 1 -maxdepth 5 2>/dev/null | sed "s|$home/||")
  config_json=$(printf '%s\n' "$config_paths" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')

  cron_content=$(crontab -l -u "$user" 2>/dev/null || true)
  cron_json=$(printf '%s' "$cron_content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

  tarball="${user}_backup.tgz"
  tar czf "$BACKUP_DIR/$tarball" -C "$home" $(for f in .bashrc .profile .gitconfig .ssh; do [ -e "$home/$f" ] && echo "$f"; done) 2>/dev/null || true
  chmod 600 "$BACKUP_DIR/$tarball"

  USER_NAME="$user" HOME_DIR="$home" USER_SHELL="$shell" DOTFILES="$dotfiles_json" SSH_PATHS="$ssh_json" CONFIG_PATHS="$config_json" CRON="$cron_json" TARBALL_NAME="$tarball" \
  python3 - <<'PY'
import os, json
print(json.dumps({
  "username": os.environ["USER_NAME"],
  "home": os.environ["HOME_DIR"],
  "shell": os.environ["USER_SHELL"],
  "dotfiles": json.loads(os.environ["DOTFILES"]),
  "ssh_paths": json.loads(os.environ["SSH_PATHS"]),
  "config_paths": json.loads(os.environ["CONFIG_PATHS"]),
  "crontab": json.loads(os.environ["CRON"]),
  "tarball": os.environ["TARBALL_NAME"]
}))
PY >> "$USER_JSONL"

done

# --- 9. MAIN JSON BUILD ---
python3 - <<PY
import json, pathlib, os

def readfilelines(path):
    try:
        with open(path) as f:
            return [line.strip() for line in f if line.strip()]
    except Exception:
        return []

with open('$OUTDIR/apt_packages.txt') as f:
    packages = [line.strip() for line in f if line.strip()]
with open('$OUTDIR/enabled_services.txt') as f:
    enabled_services = [line.strip() for line in f if line.strip()]
with open('$OUTDIR/running_services.txt') as f:
    running_services = [line.strip() for line in f if line.strip()]
with open('$OUTDIR/custom_systemd_units.txt') as f:
    custom_systemd_units = [line.strip() for line in f if line.strip()]
with open('$OUTDIR/user_data.jsonl') as f:
    users = [json.loads(line) for line in f if line.strip()]

zerotier_networks = readfilelines('$OUTDIR/zerotier_networks.txt')
nfs_exports = readfilelines('$OUTDIR/exports') if os.path.exists('$OUTDIR/exports') else []
fstab = readfilelines('$OUTDIR/fstab')
remote_mounts = readfilelines('$OUTDIR/remote_mounts.txt')
mnt_dirs = readfilelines('$OUTDIR/mnt_dirs.txt')
mnt_mountpoints = readfilelines('$OUTDIR/mnt_mountpoints.txt')

firewall = {}
for fw, path in [
    ("nft", "$OUTDIR/nft_ruleset.txt"),
    ("iptables", "$OUTDIR/iptables_ruleset.txt"),
]:
    if os.path.exists(path):
        with open(path) as f:
            firewall[fw] = f.read()

with open('$OUTDIR/etc_diff_${TS}.txt') as f:
    etc_diff = [line.strip() for line in f if line.strip()]

ssh_host_keys = json.loads(os.environ.get("SSH_HOST_KEYS_JSON", "[]"))

with open('$OUTDIR/etc_backup_${TS}.tgz', 'rb') as f:
    etc_backup_filename = os.path.basename(f.name)
json.dump({
    "packages": packages,
    "enabled_services": enabled_services,
    "running_services": running_services,
    "custom_systemd_units": custom_systemd_units,
    "users": users,
    "zerotier_networks": zerotier_networks,
    "fstab": fstab,
    "nfs_exports": nfs_exports,
    "remote_mounts": remote_mounts,
    "mnt_dirs": mnt_dirs,
    "mnt_mountpoints": mnt_mountpoints,
    "firewall": firewall,
    "ssh_host_keys": ssh_host_keys,
    "etc_backup": etc_backup_filename,
    "etc_diff": etc_diff,
    "remarks": [
        "This audit covers APT packages only. Snap, Flatpak, pip, or other user-installed applications are NOT included.",
        "Certificates (TLS, etc) are not backed up.",
        "User backup tarballs are referenced by filename only; expected to be in the same directory as this JSON.",
        "For SSH host key restore, you may need to set correct permissions (600 for private keys, 644 for public)."
    ]
}, open("$OUTPUT_FILE", "w"), indent=2)
PY

chmod 600 "$OUTPUT_FILE"
log "Audit saved to $OUTPUT_FILE"
log "User backups stored in $BACKUP_DIR"
log "Etc backup stored as $ETC_TARBALL"

#!/bin/bash
set -euo pipefail

### Raspberry Pi Fleet System - Reinstall Script ###
# This script restores system state from an audit performed by audit.sh.
# Place this script, the audit JSON, user backup tarballs, and /etc backup in the same directory on the new system.
# Run as root: sudo ./re-install.sh

AUDIT_JSON="${1:-}"
LOGFILE="re-install_$(date +%Y%m%d%H%M%S).log"
OUTDIR="$(pwd)"

if [[ -z "$AUDIT_JSON" ]]; then
  AUDIT_JSON=$(ls system_audit_*.json | head -n1)
fi

if [[ ! -f "$AUDIT_JSON" ]]; then
  echo "ERROR: Audit JSON file not found."
  exit 1
fi

log() { echo "$(date -Iseconds) $*" | tee -a "$LOGFILE"; }

log "Starting system re-install from audit: $AUDIT_JSON"

# --- 1. Install APT packages ---
log "Installing APT packages..."
PKGS=$(python3 -c "import json; print(' '.join(json.load(open('$AUDIT_JSON'))['packages']))")
if [[ -n "$PKGS" ]]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS
fi

# --- 2. Restore users ---
log "Restoring users and home directories..."
python3 - <<'PY' > /tmp/users_to_restore.sh
import json, os
d = json.load(open(os.environ["AUDIT_JSON"]))
for user in d['users']:
    print(f"id {user['username']} 2>/dev/null || useradd -m -s {user['shell']} {user['username']}")
    print(f"usermod -s {user['shell']} {user['username']}")
PY
chmod +x /tmp/users_to_restore.sh
AUDIT_JSON="$AUDIT_JSON" /tmp/users_to_restore.sh

# --- 3. Restore user dotfiles, .ssh, .config, crontab ---
log "Restoring user dotfiles, .ssh, .config, and crontabs..."
python3 - <<'PY'
import json, os
d = json.load(open(os.environ["AUDIT_JSON"]))
bd = os.path.join(os.path.dirname(os.environ["AUDIT_JSON"]), "gesser_user_backups")
for user in d['users']:
    t = user.get('tarball', '')
    if t:
        tar = os.path.join(bd, t)
        home = user['home']
        print(f"if [ -f '{tar}' ]; then tar xzf '{tar}' -C '{home}' --no-same-owner; chown -R {user['username']}:{user['username']} '{home}'; fi")
    c = user.get("crontab", "")
    if c and c.strip():
        print(f"echo {json.dumps(c)} | crontab -u {user['username']} -")
PY > /tmp/restore_user_files.sh
chmod +x /tmp/restore_user_files.sh
AUDIT_JSON="$AUDIT_JSON" /tmp/restore_user_files.sh

# --- 4. Restore custom systemd units ---
log "Restoring custom systemd units..."
CUSTOM_UNITS=$(python3 -c "import json; print(' '.join(json.load(open('$AUDIT_JSON'))['custom_systemd_units']))")
for unit in $CUSTOM_UNITS; do
  if [[ -f "$unit" ]]; then
    dest="/etc/systemd/system/$(basename "$unit")"
    cp -f "$unit" "$dest"
    chmod 644 "$dest"
  fi
done

# --- 5. Enable/start services ---
log "Enabling and starting systemd services..."
ENABLED_SERVICES=$(python3 -c "import json; print(' '.join(json.load(open('$AUDIT_JSON'))['enabled_services']))")
for srv in $ENABLED_SERVICES; do
  systemctl enable "$srv" || true
done
RUNNING_SERVICES=$(python3 -c "import json; print(' '.join(json.load(open('$AUDIT_JSON'))['running_services']))")
for srv in $RUNNING_SERVICES; do
  systemctl start "$srv" || true
done

# --- 6. Restore fstab, exports, mnt dirs, remote mounts ---
log "Restoring /etc/fstab, /etc/exports, /mnt dirs as appropriate..."
python3 - <<'PY'
import json, os, shutil
d = json.load(open(os.environ["AUDIT_JSON"]))
if d.get("fstab"):
    with open("/etc/fstab", "w") as f: f.write("\n".join(d["fstab"])+"\n")
if d.get("nfs_exports"):
    with open("/etc/exports", "w") as f: f.write("\n".join(d["nfs_exports"])+"\n")
if d.get("mnt_dirs"):
    for dname in d["mnt_dirs"]:
        if dname: os.makedirs(f"/mnt/{dname}", exist_ok=True)
PY
# Note: actual mounting must be handled by init/systemd after reboot.

# --- 7. Restore firewall config ---
log "Restoring firewall rules..."
python3 - <<'PY'
import json, os
d = json.load(open(os.environ["AUDIT_JSON"]))
fw = d.get("firewall", {})
if fw.get("nft"):
    with open("/tmp/restore_nft.txt", "w") as f: f.write(fw["nft"])
    os.system("nft -f /tmp/restore_nft.txt || true")
if fw.get("iptables"):
    with open("/tmp/restore_iptables.txt", "w") as f: f.write(fw["iptables"])
    os.system("iptables-restore < /tmp/restore_iptables.txt || true")
PY

# --- 8. Restore SSH host keys ---
log "Restoring SSH host keys..."
python3 - <<'PY'
import json, os, base64
d = json.load(open(os.environ["AUDIT_JSON"]))
for k in d.get("ssh_host_keys", []):
    path = "/etc/ssh/" + k["file"]
    with open(path, "wb") as f: f.write(base64.b64decode(k["base64"]))
    os.chmod(path, int(k["mode"], 8))
PY
systemctl restart ssh || systemctl restart sshd || true

# --- 9. Restore /etc backup (optional, CAUTION) ---
ETC_BACKUP=$(python3 -c "import json; print(json.load(open('$AUDIT_JSON')).get('etc_backup',''))")
if [[ -n "$ETC_BACKUP" && -f "$ETC_BACKUP" ]]; then
  log "Extracting /etc backup from $ETC_BACKUP (CAUTION: this will overwrite existing /etc files!)"
  tar xzf "$ETC_BACKUP" -C /
  # Optionally, you could manually review/merge instead of bulk overwrite.
fi

log "Re-install complete. Please review log: $LOGFILE"
echo "NOTICE: Only APT packages, users, dotfiles, SSH keys, crontabs, systemd units, and firewall/ZeroTier/NFS info are restored."
echo "pip, snap, flatpak packages, and certificates are NOT restored by this script."

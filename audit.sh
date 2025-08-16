#!/bin/bash
set -euo pipefail

log() { echo "$(date -Iseconds) $*"; }

OUTPUT_FILE="/tmp/system_audit_$(date +%Y%m%d%H%M%S).json"
BACKUP_DIR="/tmp/gesser_user_backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

log "Gathering package list"
dpkg-query -W -f='${Package} ${Version}\n' | sort > /tmp/apt_packages.txt

log "Gathering enabled services"
systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' | sort > /tmp/enabled_services.txt

log "Gathering running services"
systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sort > /tmp/running_services.txt

USER_JSONL=/tmp/user_data.jsonl
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

  tarball="$BACKUP_DIR/${user}_backup.tgz"
  tar czf "$tarball" -C "$home" $(for f in .bashrc .profile .gitconfig .ssh; do [ -e "$home/$f" ] && echo "$f"; done) 2>/dev/null || true
  chmod 600 "$tarball"

  USER_NAME="$user" HOME_DIR="$home" USER_SHELL="$shell" DOTFILES="$dotfiles_json" SSH_PATHS="$ssh_json" CONFIG_PATHS="$config_json" CRON="$cron_json" \
  python3 - <<'PY'
import os, json
print(json.dumps({
  "username": os.environ["USER_NAME"],
  "home": os.environ["HOME_DIR"],
  "shell": os.environ["USER_SHELL"],
  "dotfiles": json.loads(os.environ["DOTFILES"]),
  "ssh_paths": json.loads(os.environ["SSH_PATHS"]),
  "config_paths": json.loads(os.environ["CONFIG_PATHS"]),
  "crontab": json.loads(os.environ["CRON"])
}))
PY >> "$USER_JSONL"

done

python3 - <<'PY'
import json, pathlib
with open('/tmp/apt_packages.txt') as f:
    packages=[line.strip() for line in f if line.strip()]
with open('/tmp/enabled_services.txt') as f:
    enabled=[line.strip() for line in f if line.strip()]
with open('/tmp/running_services.txt') as f:
    running=[line.strip() for line in f if line.strip()]
with open('/tmp/user_data.jsonl') as f:
    users=[json.loads(line) for line in f if line.strip()]
with open("$OUTPUT_FILE","w") as f:
    json.dump({
        "packages": packages,
        "enabled_services": enabled,
        "running_services": running,
        "users": users
    }, f, indent=2)
PY

chmod 600 "$OUTPUT_FILE"
log "Audit saved to $OUTPUT_FILE"
log "User backups stored in $BACKUP_DIR"

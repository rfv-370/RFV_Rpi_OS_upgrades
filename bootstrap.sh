#!/bin/bash
set -euo pipefail

# ====== Parameters ======
LOG_FILE="./bootstrap.log"
# Set your desired WayVNC password before running.
VNC_PASSWORD="CHANGE_ME"

if [ "$VNC_PASSWORD" = "CHANGE_ME" ]; then
  echo "Please edit bootstrap.sh and set VNC_PASSWORD before running."
  exit 1
fi

# ====== Logging Setup ======
touch "$LOG_FILE"
log() {
  echo "$(date -Iseconds) $*" | tee -a "$LOG_FILE"
}

# ====== Error Handling ======
trap 'log "Error on line $LINENO"; echo "Error on line $LINENO"' ERR

# ====== Script Start ======
log "Bootstrap started"

[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

log "Updating package lists"
apt-get update -y || log "apt-get update failed"

log "Performing full upgrade"
apt-get full-upgrade -y || log "full-upgrade failed"

log "Installing base packages"
apt-get install -y sudo openssh-server cron curl wget vim git htop unattended-upgrades wayvnc || log "apt-get install failed"

log "Enabling and starting SSH"
systemctl enable ssh || log "systemctl enable ssh failed"
systemctl start ssh || log "systemctl start ssh failed"

log "Installing ZeroTier"
if ! command -v zerotier-cli >/dev/null 2>&1; then
  curl -fsSL https://install.zerotier.com | bash || log "ZeroTier install failed"
fi
systemctl enable zerotier-one || log "systemctl enable zerotier-one failed"
systemctl start zerotier-one || log "systemctl start zerotier-one failed"
log "NOTE: ZeroTier network join must be performed manually after bootstrap!"

# Write wayvnc config to /etc/wayvnc/config (system service uses this by default)
log "Configuring wayvnc system service with password (see /etc/wayvnc/config)"
cat >/etc/wayvnc/config <<CONF
address=0.0.0.0
rfb_port=5900
password=$VNC_PASSWORD
CONF
chmod 600 /etc/wayvnc/config

systemctl enable wayvnc.service || log "systemctl enable wayvnc failed"
systemctl start wayvnc.service || log "systemctl start wayvnc failed"

log "Configuring unattended upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
if ! grep -q 'Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
cat >>/etc/apt/apt.conf.d/50unattended-upgrades <<'CONF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
CONF
fi

log "Adding monthly reboot cron job (5th at 3am)"
( crontab -l 2>/dev/null; echo "0 3 5 * * /sbin/shutdown -r now" ) | crontab -

log "Enabling systemd-timesyncd"
timedatectl set-ntp true || log "timedatectl set-ntp failed"

log "Bootstrap completed"
log "REMINDER: ZeroTier join, locale, timezone, hostname, firewall, and network setup are manual steps as per deployment requirements."

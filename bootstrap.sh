#!/bin/bash
set -euo pipefail

# ====== Parameters ======
LOG_FILE="./bootstrap.log"
VNC_PASSWORD="xxxYYYzzz-456*\$!"

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

DEFAULT_USER=$(awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd)
if [ -n "$DEFAULT_USER" ]; then
  log "Configuring wayvnc for user $DEFAULT_USER with password $VNC_PASSWORD"
  sudo -u "$DEFAULT_USER" mkdir -p "/home/$DEFAULT_USER/.config/wayvnc"
  sudo -u "$DEFAULT_USER" tee "/home/$DEFAULT_USER/.config/wayvnc/config" >/dev/null <<CONF
address=0.0.0.0
rfb_port=5900
password=$VNC_PASSWORD
CONF
  chmod 600 "/home/$DEFAULT_USER/.config/wayvnc/config"
  systemctl enable "wayvnc@$DEFAULT_USER.service" || log "systemctl enable wayvnc@$DEFAULT_USER failed"
  systemctl start "wayvnc@$DEFAULT_USER.service" || log "systemctl start wayvnc@$DEFAULT_USER failed"
fi

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

log "REMINDER: Locale, timezone, hostname, firewall, and network setup are manual steps as per deployment requirements."

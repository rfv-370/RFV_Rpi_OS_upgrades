#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/bootstrap.log"
log() {
  echo "$(date -Iseconds) $*" | tee -a "$LOG_FILE"
}

[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }

log "Updating package lists"
apt-get update -y

log "Performing full upgrade"
apt-get full-upgrade -y

log "Installing base packages"
apt-get install -y openssh-server cron curl wget vim git htop unattended-upgrades wayvnc

log "Enabling and starting SSH"
systemctl enable ssh
systemctl start ssh

log "Installing ZeroTier"
if ! command -v zerotier-cli >/dev/null 2>&1; then
  curl -fsSL https://install.zerotier.com | bash
fi
systemctl enable zerotier-one
systemctl start zerotier-one
if [ -n "${ZT_NETWORK_ID:-}" ]; then
  zerotier-cli join "$ZT_NETWORK_ID" || true
fi

DEFAULT_USER=$(awk -F: '$3>=1000 && $1!="nobody" {print $1; exit}' /etc/passwd)
if [ -n "$DEFAULT_USER" ]; then
  VNC_PASS=${VNC_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12)}
  log "Configuring wayvnc for user $DEFAULT_USER with password $VNC_PASS"
  sudo -u "$DEFAULT_USER" mkdir -p "/home/$DEFAULT_USER/.config/wayvnc"
  sudo -u "$DEFAULT_USER" tee "/home/$DEFAULT_USER/.config/wayvnc/config" >/dev/null <<CONF
address=0.0.0.0
rfb_port=5900
password=$VNC_PASS
CONF
  chmod 600 "/home/$DEFAULT_USER/.config/wayvnc/config"
  systemctl enable "wayvnc@$DEFAULT_USER.service"
  systemctl start "wayvnc@$DEFAULT_USER.service"
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

log "Adding monthly reboot cron job"
( crontab -l 2>/dev/null; echo "0 3 5 * * /sbin/shutdown -r now" ) | crontab -

log "Enabling systemd-timesyncd"
timedatectl set-ntp true

log "Bootstrap completed"

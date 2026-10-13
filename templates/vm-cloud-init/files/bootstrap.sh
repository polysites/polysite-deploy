#!/bin/bash
# First-boot provisioning for a Polysite server on Ubuntu 22.04 / 24.04. Run once by cloud-init (output: /var/log/polysite-bootstrap.log).
# Reads /etc/polysite-bootstrap.env (the two domains). Safe to run again: every step checks first.
set -euo pipefail
exec > >(tee -a /var/log/polysite-bootstrap.log) 2>&1
echo "== polysite bootstrap $(date -u +%FT%TZ)"
# shellcheck disable=SC1091
. /etc/polysite-bootstrap.env
: "${SITE_DOMAIN:?}" "${ADMIN_DOMAIN:?}"
case "$SITE_DOMAIN$ADMIN_DOMAIN" in *example.org*|*example.net*) echo "Edit /etc/polysite-bootstrap.env (the domains are still examples), then run: sh /opt/polysite/bootstrap.sh"; exit 1 ;; esac

# --- swap: the CMS needs about 1 GB at start-up, so a small VM gets a swap file
if [ "$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)" -lt 3500 ] && ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Docker Engine from Docker's own apt repository (the key's fingerprint is checked, not trusted blindly)
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
  fp=$(gpg --show-keys --with-colons /tmp/docker.asc | awk -F: '/^fpr:/ {print $10; exit}')
  [ "$fp" = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ] || { echo "Docker's signing key has an unexpected fingerprint ($fp): stopping"; exit 1; }
  gpg --dearmor < /tmp/docker.asc > /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
systemctl enable --now docker
# Keep Docker's own logs from filling the disk.
[ -f /etc/docker/daemon.json ] || { echo '{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"5"}}' > /etc/docker/daemon.json; systemctl restart docker; }

# --- firewall: only SSH, http and https
ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
ufw --force enable

# --- unattended security upgrades; the server does not reboot by itself
systemctl enable --now unattended-upgrades

# --- the stack
cd /opt/polysite
if [ ! -f .env ]; then
  ./init.sh "$SITE_DOMAIN" "$ADMIN_DOMAIN" | tee /root/polysite-setup.txt
  chmod 600 /root/polysite-setup.txt
fi
systemctl daemon-reload
systemctl enable --now polysite.service
echo "== done. Point DNS for $SITE_DOMAIN and $ADMIN_DOMAIN at this server; then open https://$ADMIN_DOMAIN/admin and use the setup token in /root/polysite-setup.txt"

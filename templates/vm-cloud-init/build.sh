#!/bin/sh
# Writes cloud-init.yaml: the cloud-config with the files of ../compose-caddy and files/ embedded, so the file is self-contained and
# can be pasted into a cloud provider's "user data" box. Run it after changing any of them:  sh build.sh   (check.sh verifies it is current).
set -eu
cd "$(dirname "$0")"
embed() { # <path on the server> <source file> <mode> [owner]
  printf '  - path: %s\n    permissions: "%s"\n    owner: root:root\n    content: |\n' "$1" "$3"
  sed 's/^\(.\)/      \1/; s/^$/      /' "$2"
}
{
  cat <<'HEAD'
#cloud-config
# Polysite on a fresh Ubuntu 22.04 / 24.04 VM: Docker, a firewall, automatic security updates, swap if the machine is small, and the stack of
# templates/compose-caddy (Caddy with automatic HTTPS, the CMS, the site, PostgreSQL, nightly backups), started by systemd.
#
# 1. Replace the two domain names in /etc/polysite-bootstrap.env below.  2. Paste this file as the VM's "user data" when you create it
# (AWS EC2: Advanced details > User data; GCP: Metadata > user-data; DigitalOcean, Hetzner: User data).  3. Point DNS at the VM.
# 4. After the first boot (3 to 6 minutes) read /root/polysite-setup.txt for the setup token and open https://<admin domain>/admin.
# Progress: tail -f /var/log/polysite-bootstrap.log.  Needs: 2 vCPU and 4 GB RAM recommended (2 GB works with the swap file), 20 GB disk,
# inbound 22, 80 and 443.  The images are pinned in /opt/polysite/docker-compose.yml.
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - ufw
  - unattended-upgrades
write_files:
HEAD
  embed /etc/polysite-bootstrap.env files/bootstrap.env 0644
  embed /opt/polysite/bootstrap.sh files/bootstrap.sh 0755
  embed /etc/systemd/system/polysite.service files/polysite.service 0644
  embed /opt/polysite/docker-compose.yml ../compose-caddy/docker-compose.yml 0644
  embed /opt/polysite/Caddyfile ../compose-caddy/Caddyfile 0644
  embed /opt/polysite/.env.example ../compose-caddy/.env.example 0644
  embed /opt/polysite/init.sh ../compose-caddy/init.sh 0755
  cat <<'TAIL'
runcmd:
  - [bash, /opt/polysite/bootstrap.sh]
final_message: "Polysite bootstrap finished after $UPTIME seconds. See /root/polysite-setup.txt and /var/log/polysite-bootstrap.log"
TAIL
} > cloud-init.yaml
echo "wrote cloud-init.yaml"

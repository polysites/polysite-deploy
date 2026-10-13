#!/bin/sh
# Installs Polysite on a bare Ubuntu 22.04 / 24.04 server (run as root): Node.js 24, PostgreSQL, nginx, the source at the tag in ../VERSION,
# the build, the systemd units and a firewall. Read it first; every step is plain apt, git, npm and systemctl.
#   sudo ./scripts/install.sh www.example.org admin.example.org
# Not run end to end on a real server (see the README for what was tested). Re-running is safe.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ $# -eq 2 ] || { echo "usage: $0 <site domain> <admin domain>"; exit 2; }
SITE=$1; ADMIN=$2
HERE=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(cat "$HERE/VERSION")
export DEBIAN_FRONTEND=noninteractive
rand() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48; }

apt-get update -y
apt-get install -y ca-certificates curl gnupg git ufw unattended-upgrades postgresql nginx build-essential python3
# Node.js 24 LTS from NodeSource (check the script's source first: https://github.com/nodesource/distributions).
if ! { command -v node >/dev/null 2>&1 && node -v | grep -q '^v24'; }; then curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt-get install -y nodejs; fi

id polysite >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/polysite --shell /usr/sbin/nologin polysite
install -d -o polysite -g polysite /opt/polysite

# --- database
PG=$(rand)
if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='polysite'\"" | grep -q 1; then
  su postgres -c "psql -c \"CREATE ROLE polysite LOGIN CREATEDB PASSWORD '$PG'\""
  su postgres -c "createdb -O polysite polysite"
  DBURL="postgres://polysite:$PG@127.0.0.1:5432/polysite"
fi

# --- configuration
install -d -m 750 -o root -g polysite /etc/polysite
if [ ! -f /etc/polysite/polysite.env ]; then
  TOKEN=$(rand); RS=$(rand)
  sed -e "s|^CMS_DOMAIN=.*|CMS_DOMAIN=$ADMIN|" -e "s|^SITE_DOMAIN=.*|SITE_DOMAIN=$SITE|" -e "s|^NUXT_PUBLIC_CMS_SERVER_URL=.*|NUXT_PUBLIC_CMS_SERVER_URL=https://$ADMIN|" \
      -e "s|^PAYLOAD_SECRET=.*|PAYLOAD_SECRET=$(rand)|" -e "s|^REVALIDATE_SECRET=.*|REVALIDATE_SECRET=$RS|" -e "s|^NUXT_REVALIDATE_SECRET=.*|NUXT_REVALIDATE_SECRET=$RS|" \
      -e "s|^POLYSITE_SETUP_TOKEN=.*|POLYSITE_SETUP_TOKEN=$TOKEN|" -e "s|^DATABASE_URL=.*|DATABASE_URL=${DBURL:?the database role already existed: put its URL in /etc/polysite/polysite.env yourself}|" \
      "$HERE/polysite.env.example" > /etc/polysite/polysite.env
  chown root:polysite /etc/polysite/polysite.env; chmod 640 /etc/polysite/polysite.env
  echo "Setup token for the first-run page: $TOKEN" | tee /root/polysite-setup.txt; chmod 600 /root/polysite-setup.txt
fi

# --- source and build (as the service user)
[ -d /opt/polysite/src/.git ] || su polysite -s /bin/sh -c "git clone --depth 1 --branch v$VERSION https://github.com/polysites/polysite.git /opt/polysite/src"
su polysite -s /bin/sh -c "cd /opt/polysite/src && sh $HERE/scripts/build.sh /opt/polysite/src"

# --- services
install -m 644 "$HERE"/systemd/polysite-cms.service "$HERE"/systemd/polysite-web.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now polysite-cms.service polysite-web.service

# --- nginx (see proxy/ for Apache and Caddy), then certificates with certbot
sed -e "s/site\.example\.org/$SITE/g; s/admin\.example\.org/$ADMIN/g" -e "s/server cms:3001;/server 127.0.0.1:3001;/; s/server web:3000;/server 127.0.0.1:3000;/" \
  "$HERE/proxy/nginx/polysite.conf" > /etc/nginx/conf.d/polysite.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw --force enable
echo "Next: point DNS for $SITE and $ADMIN here, then get certificates: see README.md (certbot), and switch to proxy/nginx/polysite-tls.conf."

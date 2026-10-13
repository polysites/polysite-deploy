#!/bin/sh
# Writes .env from .env.example with fresh random secrets, for the domains you give.
#   ./init.sh www.example.org admin.example.org
# Prints the setup token you will need on the first-run page. Refuses to overwrite an existing .env.
set -eu
[ $# -eq 2 ] || { echo "usage: ./init.sh <site domain> <admin domain>"; exit 2; }
[ ! -e .env ] || { echo ".env already exists; remove it first if you really want new secrets (PAYLOAD_SECRET must not change on a running install)"; exit 1; }
rand() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48; }
PG=$(rand); PS=$(rand); RS=$(rand); TOKEN=$(rand)
sed -e "s|^SITE_DOMAIN=.*|SITE_DOMAIN=$1|" -e "s|^CMS_DOMAIN=.*|CMS_DOMAIN=$2|" \
    -e "s|^PAYLOAD_SECRET=.*|PAYLOAD_SECRET=$PS|" -e "s|^REVALIDATE_SECRET=.*|REVALIDATE_SECRET=$RS|" -e "s|^NUXT_REVALIDATE_SECRET=.*|NUXT_REVALIDATE_SECRET=$RS|" \
    -e "s|^POLYSITE_SETUP_TOKEN=.*|POLYSITE_SETUP_TOKEN=$TOKEN|" -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG|" \
    -e "s|^DATABASE_URL=.*|DATABASE_URL=postgres://polysite:$PG@db:5432/polysite|" .env.example > .env
chmod 600 .env
echo "Wrote .env. Setup token for the first-run page: $TOKEN"
echo "Next: point DNS for $1 and $2 at this server, then:  docker compose up -d   and open https://$2/admin"
# The proxy configuration names the domains itself (it cannot read .env): put yours in.
find proxy -type f \( -name '*.conf' -o -name '*.yml' \) -exec sed -i "s/site\.example\.org/$1/g; s/admin\.example\.org/$2/g" {} +
echo "Domains written into proxy/. Edit the e-mail in proxy/traefik.yml before starting." >/dev/null

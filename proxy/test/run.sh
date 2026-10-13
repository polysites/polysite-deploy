#!/bin/sh
# Tests a reverse-proxy configuration from proxy for real: starts a throwaway Polysite stack in its own Docker project (the
# repository's own docker-compose.yml with the proxy's compose file layered on top, exactly how a person would use it), puts the proxy
# in front, and drives it. Nothing is published on the host; the checks run in a Node container on the stack's network.
#
#   proxy/test/run.sh <mode>
#   modes: nginx | nginx-tls | apache | apache-tls | traefik | traefik-tls | traefik-labels | all
#
#   plain modes: the whole first-run smoke test (tests/smoke/smoke.mjs: setup, sign in, publish, form, redirect) goes through the proxy,
#                then proxy/test/checks.mjs (headers, uploads, size limits, forged X-Forwarded-For, unknown hosts).
#   tls modes:   the https server blocks with a self-signed certificate: redirect, HSTS, X-Forwarded-Proto, TLS versions, HTTP/2.
#
# Images: set CMS_IMAGE and WEB_IMAGE to images you already have (the published ones, or built from this tree), or leave them unset
# and the script builds both from a clean copy of this working tree (a few minutes). Needs Docker with Compose 2.24 or newer only.
# Not tested here, because it needs the real internet: obtaining a Let's Encrypt certificate (the TLS files name certbot's paths).
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORE=${POLYSITE_CORE:-$ROOT/../polysite}   # a checkout of the core: its compose file, Caddyfile, smoke test and source
[ -f "$CORE/docker-compose.yml" ] || { echo "Set POLYSITE_CORE to a checkout of the polysite repository (looked in $CORE)"; exit 1; }
MODES=${1:?usage: run.sh nginx|nginx-tls|apache|apache-tls|traefik|traefik-tls|traefik-labels|all}
if [ "$MODES" = all ]; then
  rc=0
  for m in nginx nginx-tls apache apache-tls traefik traefik-tls traefik-labels; do
    echo; echo "################ $m"
    sh "$0" "$m" || rc=1
  done
  exit $rc
fi
MODE=$MODES
case "$MODE" in
  nginx|nginx-tls)           PROXY=nginx;   OVERRIDE=proxy/nginx/docker-compose.nginx.yml ;;
  apache|apache-tls)         PROXY=apache;  OVERRIDE=proxy/apache/docker-compose.apache.yml ;;
  traefik|traefik-tls)       PROXY=traefik; OVERRIDE=proxy/traefik/docker-compose.traefik-file.yml ;;
  traefik-labels)            PROXY=traefik; OVERRIDE=proxy/traefik/docker-compose.traefik.yml ;;
  *) echo "unknown mode $MODE"; exit 1 ;;
esac
TLS=0; case "$MODE" in *-tls) TLS=1 ;; esac

PROJECT="polysite-proxytest-$MODE"
WORK=$(mktemp -d)
compose() { (cd "$WORK" && docker compose -p "$PROJECT" -f docker-compose.yml -f tests/smoke/docker-compose.smoke.yml -f .github/scripts/docker-compose.images.yml -f "$OVERRIDE" -f test.override.yml "$@"); }
cleanup() {
  [ -z "${KEEP:-}" ] || { echo "KEEP is set: leaving project $PROJECT running in $WORK"; return 0; }
  compose down -v >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || docker run --rm -v "$WORK:/w" alpine rm -rf /w >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Only the files a person has on the server: the compose file, the env example, the proxy files (and the test helpers).
mkdir -p "$WORK/tests" "$WORK/.github"
cp "$CORE/docker-compose.yml" "$CORE/Caddyfile" "$CORE/.env.example" "$WORK/"
cp -R "$CORE/tests/smoke" "$WORK/tests/"
cp -R "$CORE/.github/scripts" "$WORK/.github/"
cp -R "$ROOT/proxy" "$WORK/"

# The edit a person makes: their own domains in place of the placeholders.
find "$WORK/proxy" -type f \( -name '*.conf' -o -name '*.yml' \) ! -path '*/test/*' -exec sed -i 's/site\.example\.org/localhost/g; s/admin\.example\.org/admin.localhost/g' {} +

# --- images
if [ -z "${CMS_IMAGE:-}" ] || [ -z "${WEB_IMAGE:-}" ]; then
  echo "Building the images from this tree (set CMS_IMAGE and WEB_IMAGE to skip)..."
  SRC=$(mktemp -d)
  (cd "$CORE" && git ls-files -z --cached --others --exclude-standard | tar --null --ignore-failed-read -T - -cf -) | tar -x -C "$SRC"
  mkdir -p "$SRC/themes" "$SRC/plugins"
  (cd "$SRC" && docker build -q -f apps/cms/Dockerfile --target run -t polysite-proxytest-cms . && docker build -q -f apps/web/Dockerfile --target run -t polysite-proxytest-web .)
  rm -rf "$SRC" 2>/dev/null || true
  CMS_IMAGE=polysite-proxytest-cms; WEB_IMAGE=polysite-proxytest-web
fi
export CMS_IMAGE WEB_IMAGE BACKUP_IMAGE="${BACKUP_IMAGE:-unused/backup:none}"

# --- environment
rand() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48; }
PGPASS=$(rand); PSECRET=$(rand); RSECRET=$(rand)
cp "$WORK/.env.example" "$WORK/.env"
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$PGPASS/; s#^DATABASE_URL=.*#DATABASE_URL=postgres://polysite:$PGPASS@db:5432/polysite#; s/^PAYLOAD_SECRET=.*/PAYLOAD_SECRET=$PSECRET/; s/^NUXT_REVALIDATE_SECRET=.*/NUXT_REVALIDATE_SECRET=$RSECRET/; s/^REVALIDATE_SECRET=.*/REVALIDATE_SECRET=$RSECRET/" "$WORK/.env"
sed -i 's/^SITE_DOMAIN=.*/SITE_DOMAIN=localhost/; s/^CMS_DOMAIN=.*/CMS_DOMAIN=admin.localhost/' "$WORK/.env"
# The sign-in limit the forged-X-Forwarded-For check relies on.
echo "POLYSITE_LOGIN_RATE_LIMIT=4" >> "$WORK/.env"
if [ "$TLS" = 1 ]; then
  sed -i 's/^SITE_SCHEME=.*/SITE_SCHEME=https/; s/^CMS_SCHEME=.*/CMS_SCHEME=https/' "$WORK/.env"
  echo "POLYSITE_SETUP_TOKEN=$(rand)" >> "$WORK/.env"
fi
echo "ACME_EMAIL=test@example.org" >> "$WORK/.env"

# --- certificates for the tls modes (self-signed; the real ones come from Let's Encrypt)
mkdir -p "$WORK/certs"
if [ "$TLS" = 1 ]; then
  WIN_CERTS=$(cd "$WORK/certs" && (pwd -W 2>/dev/null || pwd))
  MSYS_NO_PATHCONV=1 docker run --rm -v "$WIN_CERTS:/c" alpine/openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout /c/privkey.pem -out /c/fullchain.pem -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,DNS:admin.localhost" >/dev/null 2>&1
  [ -s "$WORK/certs/fullchain.pem" ] || { echo "could not create the test certificate"; exit 1; }
fi

# --- the test's own additions to the proxy's compose file: nothing published on the host, and the test-only static configs
case "$MODE" in
  nginx)
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  nginx:
    ports: !reset []
EOF
    ;;
  nginx-tls)
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  nginx:
    ports: !reset []
    volumes:
      - ./proxy/nginx/polysite-tls.conf:/etc/nginx/conf.d/polysite.conf:ro
      - ./certs/fullchain.pem:/etc/letsencrypt/live/localhost/fullchain.pem:ro
      - ./certs/privkey.pem:/etc/letsencrypt/live/localhost/privkey.pem:ro
      - ./certs/fullchain.pem:/etc/letsencrypt/live/admin.localhost/fullchain.pem:ro
      - ./certs/privkey.pem:/etc/letsencrypt/live/admin.localhost/privkey.pem:ro
EOF
    ;;
  apache)
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  apache:
    ports: !reset []
EOF
    ;;
  apache-tls)
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  apache:
    ports: !reset []
    command: ["httpd-foreground", "-DTLS"]
    volumes:
      - ./certs/fullchain.pem:/etc/letsencrypt/live/localhost/fullchain.pem:ro
      - ./certs/privkey.pem:/etc/letsencrypt/live/localhost/privkey.pem:ro
      - ./certs/fullchain.pem:/etc/letsencrypt/live/admin.localhost/fullchain.pem:ro
      - ./certs/privkey.pem:/etc/letsencrypt/live/admin.localhost/privkey.pem:ro
EOF
    ;;
  traefik)
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  traefik:
    ports: !reset []
    volumes:
      - ./proxy/test/traefik-http.yml:/etc/traefik/traefik.yml:ro
EOF
    ;;
  traefik-tls)
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  traefik:
    ports: !reset []
    volumes:
      - ./proxy/test/traefik-tls.yml:/etc/traefik/traefik.yml:ro
EOF
    ;;
  traefik-labels)
    # The shipped command line, except that the https entry point is plain http and has no certificate resolver.
    cat > "$WORK/test.override.yml" <<'EOF'
services:
  traefik:
    ports: !reset []
    command: !override
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.websecure.address=:80
      - --entrypoints.websecure.transport.respondingtimeouts.readtimeout=300s
      - --log.level=INFO
EOF
    ;;
esac

echo "== $MODE: starting the stack from the images"
compose config -q || { echo "the compose files do not merge"; exit 1; }
compose up -d --no-build cms web "$PROXY"

wait_healthy() {
  n=0
  until [ "$(docker inspect --format '{{.State.Health.Status}}' "$(compose ps -q "$1")")" = "healthy" ]; do
    n=$((n + 1)); [ "$n" -le 60 ] || { echo "$1 never became healthy"; compose logs --tail 60 "$1" || true; exit 1; }
    sleep 5
  done
}
wait_healthy cms
wait_healthy web
sleep 3
[ -n "$(compose ps -q "$PROXY")" ] && [ "$(docker inspect --format '{{.State.Running}}' "$(compose ps -q "$PROXY")")" = "true" ] \
  || { echo "$PROXY is not running"; compose logs --tail 40 "$PROXY" || true; exit 1; }

TEST_DIR=$(cd "$WORK/proxy/test" && (pwd -W 2>/dev/null || pwd))
SMOKE_DIR=$(cd "$WORK/tests/smoke" && (pwd -W 2>/dev/null || pwd))
NET="${PROJECT}_default"
node_run() { MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" "$@"; }

rc=0
if [ "$TLS" = 0 ]; then
  echo "== $MODE: the first-run smoke test, through the proxy"
  node_run -v "$SMOKE_DIR:/smoke:ro" -e BASE="http://$PROXY:80" -e SITE_HOST=localhost -e CMS_HOST=admin.localhost node:24 node /smoke/smoke.mjs || rc=1
  if [ "$rc" = 0 ]; then
    echo "== $MODE: proxy checks"
    node_run -v "$TEST_DIR:/t:ro" -e PROXY_HOST="$PROXY" -e MODE=plain -e EXPECT_ACME_WEBROOT="$([ "$PROXY" = traefik ] && echo 0 || echo 1)" node:24 node /t/checks.mjs || rc=1
  fi
else
  echo "== $MODE: https checks"
  node_run -v "$TEST_DIR:/t:ro" -e PROXY_HOST="$PROXY" -e MODE=tls node:24 node /t/checks.mjs || rc=1
fi
if [ "$rc" != 0 ]; then
  echo "FAILED ($MODE). Recent logs:"
  compose logs --tail 40 "$PROXY" cms web || true
  exit 1
fi
echo "== $MODE: passed"

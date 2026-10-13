#!/bin/sh
# Tests the bare-metal layout in containers, without systemd: shellcheck, then BUILDS both apps from a source tree with scripts/build.sh on Node.js 24,
# and starts them with the commands of the two unit files against a throwaway PostgreSQL behind the nginx configuration from proxy/nginx, and runs the core's
# first-run smoke test through it (it needs the core's tests/smoke folder: pass the core checkout as the first argument).
#   sh test.sh /path/to/polysite-core-checkout        (takes several minutes: it runs npm ci and both builds)
set -eu
CORE=${1:?usage: test.sh <core checkout>}
HERE=$(cd "$(dirname "$0")" && pwd)
HW=$(cd "$HERE" && (pwd -W 2>/dev/null || pwd))
export MSYS_NO_PATHCONV=1
NET=polysite-baremetal-net; P=polysite-baremetal
SRC=$(mktemp -d)
cleanup() { docker rm -f $P-pg $P-cms $P-web $P-nginx >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; docker run --rm -v "${SRCW:-/nonexistent}:/s" alpine rm -rf /s/src >/dev/null 2>&1 || true; rmdir "$SRC" 2>/dev/null || true; }
trap cleanup EXIT

echo "== shellcheck"
docker run --rm -v "$HW:/mnt" -w /mnt koalaman/shellcheck:stable scripts/install.sh scripts/build.sh && echo "  ok" || { echo "  shellcheck FAILED"; exit 1; }

echo "== the source tree (tracked files of the core checkout; no plugins, no themes)"
mkdir -p "$SRC/src"; SRCW=$(cd "$SRC" && (pwd -W 2>/dev/null || pwd))
(cd "$CORE" && git ls-files -z --cached --others --exclude-standard | tar --null --ignore-failed-read -T - -cf -) | tar -x -C "$SRC/src"
mkdir -p "$SRC/src/themes" "$SRC/src/plugins"

echo "== build with scripts/build.sh on node:24"
docker run --rm -v "$SRCW/src:/opt/polysite/src" -v "$HW/scripts:/scripts:ro" node:24 sh /scripts/build.sh /opt/polysite/src

echo "== PostgreSQL, the two services, nginx"
docker network create $NET >/dev/null
docker run -d --name $P-pg --network $NET -e POSTGRES_USER=polysite -e POSTGRES_PASSWORD=bare-metal-test-password -e POSTGRES_DB=polysite postgres:16-alpine >/dev/null
until docker exec $P-pg pg_isready -q -U polysite; do sleep 2; done
cat > "$SRC/polysite.env" <<EOF
CMS_DOMAIN=admin.localhost
CMS_SCHEME=http
SITE_DOMAIN=localhost
SITE_SCHEME=http
PAYLOAD_SECRET=bare-metal-test-secret-0123456789abcdef0123456789
REVALIDATE_SECRET=bare-metal-test-revalidate-0123456789abcdef01
NUXT_REVALIDATE_SECRET=bare-metal-test-revalidate-0123456789abcdef01
DATABASE_URL=postgres://polysite:bare-metal-test-password@$P-pg:5432/polysite
NUXT_PUBLIC_API_BASE=/api
NUXT_API_BASE_INTERNAL=http://$P-cms:3001/api
NUXT_REVALIDATE_URL=http://$P-web:3000/api/revalidate
NUXT_PUBLIC_CMS_SERVER_URL=http://admin.localhost
EOF
# The units' ExecStartPre and ExecStart, word for word, with the loopback addresses replaced by 0.0.0.0 so the containers can reach each other.
docker run -d --name $P-cms --network $NET -v "$SRCW/src:/opt/polysite/src" -v "$SRCW/polysite.env:/etc/polysite/polysite.env:ro" -w /opt/polysite/src/apps/cms -e NODE_ENV=production node:24 \
  sh -c 'set -a; . /etc/polysite/polysite.env; npx payload migrate && exec node node_modules/next/dist/bin/next start --port 3001 --hostname 0.0.0.0' >/dev/null
docker run -d --name $P-web --network $NET -v "$SRCW/src:/opt/polysite/src" -v "$SRCW/polysite.env:/etc/polysite/polysite.env:ro" -w /opt/polysite/src/apps/web -e NODE_ENV=production -e HOST=0.0.0.0 -e PORT=3000 node:24 \
  sh -c 'set -a; . /etc/polysite/polysite.env; exec node .output/server/index.mjs' >/dev/null
sed -e "s/site\.example\.org/localhost/g; s/admin\.example\.org/admin.localhost/g" -e "s/server 127.0.0.1:3001;/server $P-cms:3001;/; s/server 127.0.0.1:3000;/server $P-web:3000;/" "$HERE/proxy/nginx/polysite.conf" > "$SRC/polysite-nginx.conf"
docker run -d --name $P-nginx --network $NET -v "$SRCW/polysite-nginx.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
n=0; until docker run --rm --network $NET node:24 node -e 'fetch("http://'$P'-cms:3001/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'; do n=$((n+1)); [ $n -lt 60 ] || { docker logs --tail 40 $P-cms; exit 1; }; sleep 5; done
echo "  both services answer /api/health"
docker run --rm --network $NET node:24 node -e 'fetch("http://'$P'-web:3000/api/health").then(r=>r.json()).then(j=>{console.log("web:",JSON.stringify(j));process.exit(j.status==="ok"?0:1)})'

echo "== the core's first-run smoke test through nginx"
SMOKE=$(cd "$CORE/tests/smoke" && (pwd -W 2>/dev/null || pwd))
docker run --rm --network $NET -v "$SMOKE:/smoke:ro" -e BASE="http://$P-nginx:80" -e SITE_HOST=localhost -e CMS_HOST=admin.localhost node:24 node /smoke/smoke.mjs
echo "Bare-metal checks passed."

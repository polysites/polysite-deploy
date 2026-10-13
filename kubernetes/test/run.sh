#!/bin/sh
# Tests the Helm chart for real on a throwaway single-node k3s cluster that runs as a Docker container (no kubectl or Helm on the host):
# installs it from LOCAL images, waits for the migration Job and the pods, drives the whole first-run smoke test through the Ingress and the
# edge proxy, runs the proxy checks, proves a pre-upgrade migration, upgrades to a second image version, rolls back, checks the backup
# CronJob and the multi-replica refusals, shows what is NOT safe with two replicas (permission cache, page cache), and removes everything.
#
#   CMS_IMAGE=repo/polysite-cms:1.0.0 WEB_IMAGE=repo/polysite-web:1.0.0 BACKUP_IMAGE=repo/polysite-backup:1.0.0 \
#   CMS_IMAGE2=repo/polysite-cms:1.0.1 WEB_IMAGE2=repo/polysite-web:1.0.1 sh kubernetes/test/run.sh
#
# The images are given as <registry>/<name>:<tag> (the names must end in polysite-cms, polysite-web, polysite-backup). The second pair is
# any other build (for the upgrade step); when unset the upgrade re-uses the first pair under a new tag, which still exercises the Job and the rollout.
set -eu
: "${CMS_IMAGE:?set CMS_IMAGE}" "${WEB_IMAGE:?set WEB_IMAGE}" "${BACKUP_IMAGE:?set BACKUP_IMAGE}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CORE=${POLYSITE_CORE:-$ROOT/../polysite}   # a checkout of the core: the smoke test is read from it
[ -f "$CORE/docker-compose.yml" ] || { echo "Set POLYSITE_CORE to a checkout of the polysite repository (looked in $CORE)"; exit 1; }
CHART_DIR=$(cd "$ROOT/kubernetes/helm" && (pwd -W 2>/dev/null || pwd))
TEST_DIR=$(cd "$ROOT/proxy/test" && (pwd -W 2>/dev/null || pwd))
SMOKE_DIR=$(cd "$CORE/tests/smoke" && (pwd -W 2>/dev/null || pwd))
NET=polysite-k8stest-net
K3S=polysite-k8stest-k3s
NS=polysite
REL=ps
WORK=$(mktemp -d)
WORKW=$(cd "$WORK" && (pwd -W 2>/dev/null || pwd))
export MSYS_NO_PATHCONV=1

cleanup() {
  [ -z "${KEEP:-}" ] || { echo "KEEP is set: leaving $K3S running"; return 0; }
  docker rm -f "$K3S" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
kc() { docker exec "$K3S" kubectl -n "$NS" "$@"; }
helm() { docker run --rm --network "container:$K3S" -v "$WORKW:/w:ro" -v "$CHART_DIR:/charts:ro" -e KUBECONFIG=/w/kubeconfig -w /charts alpine/helm:3.17.3 "$@"; }
step() { printf '\n== %s\n' "$*"; }
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAILED=1; }
FAILED=0

# Node's fetch will not send a Host header of our choosing, so the checks use this small http wrapper.
cat > "$WORK/hfetch.mjs" <<'JS'
import http from "node:http";
export function hfetch(url, { method = "GET", headers = {}, body } = {}) {
  const u = new URL(url);
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: u.hostname, port: u.port || 80, path: u.pathname + u.search, method, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => { const text = Buffer.concat(chunks).toString(); resolve({ status: res.statusCode, text: async () => text, json: async () => JSON.parse(text) }); });
    });
    req.on("error", reject);
    req.end(body);
  });
}
JS
cat > "$WORK/health.mjs" <<'JS'
import { hfetch } from "/w/hfetch.mjs";
const r = await hfetch(`${process.env.BASE}/api/health`, { headers: { host: "admin.localhost" } });
const j = await r.json();
console.log(JSON.stringify(j));
process.exit(j.status === "ok" ? 0 : 1);
JS

step "start k3s"
docker rm -f "$K3S" >/dev/null 2>&1 || true
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker run -d --name "$K3S" --network "$NET" --privileged --tmpfs /run --tmpfs /var/run -e K3S_KUBECONFIG_MODE=644 \
  rancher/k3s:v1.31.5-k3s1 server --disable metrics-server >/dev/null
n=0; until docker exec "$K3S" kubectl get nodes 2>/dev/null | grep -q ' Ready'; do n=$((n+1)); [ $n -lt 60 ] || { echo "k3s did not start"; exit 1; }; sleep 3; done
docker exec "$K3S" cat /etc/rancher/k3s/k3s.yaml > "$WORK/kubeconfig"
ok "k3s is ready"

step "load the images into the cluster (nothing is pulled from a registry)"
tags() { img=$1; name=${img##*/}; base=${name%%:*}; tag=${name##*:}; echo "$base $tag"; }
for img in "$CMS_IMAGE" "$WEB_IMAGE" "$BACKUP_IMAGE" ${CMS_IMAGE2:-} ${WEB_IMAGE2:-} nginxinc/nginx-unprivileged:1.27-alpine postgres:16-alpine; do
  docker save --platform linux/amd64 "$img" | docker exec -i "$K3S" ctr -n k8s.io images import - >/dev/null || echo "  (could not import $img: the cluster will pull it)"
done
ok "imported"
REG=${CMS_IMAGE%/polysite-cms:*}
TAG1=${CMS_IMAGE##*:}
if [ -n "${CMS_IMAGE2:-}" ]; then TAG2=${CMS_IMAGE2##*:}; else
  TAG2=${TAG1}-up
  for n in cms web; do eval "src=\$$(echo ${n} | tr a-z A-Z)_IMAGE"; docker tag "$src" "$REG/polysite-$n:$TAG2"; docker save --platform linux/amd64 "$REG/polysite-$n:$TAG2" | docker exec -i "$K3S" ctr -n k8s.io images import - >/dev/null; done
fi

step "namespace and Secret (the production way: a Secret made beforehand)"
kc2() { docker exec "$K3S" kubectl "$@"; }
kc2 create namespace "$NS" >/dev/null
rand() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48; }
PGPASS=$(rand)
kc create secret generic polysite-secrets \
  --from-literal=PAYLOAD_SECRET="$(rand)" --from-literal=REVALIDATE_SECRET="$(rand)" --from-literal=POSTGRES_PASSWORD="$PGPASS" \
  --from-literal=DATABASE_URL="postgres://polysite:$PGPASS@$REL-polysite-postgres:5432/polysite" >/dev/null
ok "secret created"

VALUES="--set image.registry=$REG --set image.tag=$TAG1 --set image.pullPolicy=IfNotPresent --set domains.sites={localhost} --set domains.admin=admin.localhost --set domains.scheme=http \
  --set secrets.existingSecret=polysite-secrets --set postgresql.enabled=true --set ingress.className=traefik --set ingress.controllerPreset=none --set ingress.tls.enabled=false \
  --set image.edge=nginxinc/nginx-unprivileged:1.27-alpine --set config.POLYSITE_LOGIN_RATE_LIMIT=4"

step "helm install --wait (demo database, migration Job as a post-install hook)"
# shellcheck disable=SC2086
helm install "$REL" polysite -n "$NS" $VALUES --wait --timeout 12m || { bad "install failed"; kc get pods; kc describe pods | tail -40; exit 1; }
ok "installed"
kc get pods
kc get job 2>/dev/null | grep -q migrate && bad "the migration Job should have been removed after it succeeded" || ok "migration Job done and removed"

step "the pods run hardened"
for c in cms web; do
  uid=$(kc exec "deploy/$REL-polysite-$c" -- id -u); [ "$uid" != 0 ] && ok "$c runs as uid $uid" || bad "$c runs as root"
  ro=$(kc get "deploy/$REL-polysite-$c" -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}')
  [ "$ro" = true ] && ok "$c has a read-only root file system and is healthy with it" || bad "$c root file system is writable"
done

step "smoke test through the Ingress (k3s's Traefik) and the edge proxy"
PORTFWD="$K3S"
if docker run --rm --network "$NET" -v "$SMOKE_DIR:/smoke:ro" -e BASE="http://$PORTFWD:80" -e SITE_HOST=localhost -e CMS_HOST=admin.localhost node:24 node /smoke/smoke.mjs; then ok "smoke test passed"; else bad "smoke test failed"; kc logs deploy/$REL-polysite-cms --tail 40; fi
step "proxy checks (headers, uploads, size limits, forged X-Forwarded-For) through the same path"
if docker run --rm --network "$NET" -v "$TEST_DIR:/t:ro" -e PROXY_HOST="$PORTFWD" -e MODE=plain node:24 node /t/checks.mjs; then ok "proxy checks passed"; else bad "proxy checks failed"; fi

step "upgrade to the second version (the Job runs first), then check the version the apps report"
# shellcheck disable=SC2086
helm upgrade "$REL" polysite -n "$NS" $(echo "$VALUES" | sed "s/image.tag=$TAG1/image.tag=$TAG2/") --wait --timeout 12m && ok "upgraded" || bad "upgrade failed"
kc get pods
helm history "$REL" -n "$NS"
step "helm rollback"
helm rollback "$REL" 1 -n "$NS" --wait --timeout 10m && ok "rolled back" || bad "rollback failed"
img=$(kc get "deploy/$REL-polysite-cms" -o jsonpath='{.spec.template.spec.containers[0].image}'); [ "${img##*:}" = "$TAG1" ] && ok "cms image is back to $img" || bad "cms image is $img"
docker run --rm --network "$NET" -v "$WORKW:/w:ro" -e BASE="http://$PORTFWD" node:24 node /w/health.mjs && ok "healthy after rollback" || bad "unhealthy after rollback"

step "a destructive migration is refused by the guard (the Job fails, nothing is switched)"
echo "  (covered by kubernetes/test/lint.sh and deploy: the guard script is the one deploy.sh runs)"

step "the backup CronJob"
# Not --wait: with a WaitForFirstConsumer storage class (k3s local-path) the backup volume stays Pending until the first backup pod uses it, and --wait would never finish.
# shellcheck disable=SC2086
helm upgrade "$REL" polysite -n "$NS" $VALUES --set backups.enabled=true --set backups.persistence.enabled=true --timeout 3m >/dev/null && ok "backups enabled" || bad "enabling backups failed"
kc create job --from="cronjob/$REL-polysite-backup" manual-backup >/dev/null
n=0; until [ "$(kc get job manual-backup -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ]; do n=$((n+1)); [ $n -lt 40 ] || break; sleep 3; done
kc logs job/manual-backup --tail 6 || true
[ "$(kc get job manual-backup -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] && ok "backup job succeeded" || bad "backup job failed"

step "NetworkPolicy example applies and the site still works"
# shellcheck disable=SC2086
helm upgrade "$REL" polysite -n "$NS" $VALUES --set networkPolicy.enabled=true --set 'networkPolicy.ingressFrom[0].namespaceSelector.matchLabels.kubernetes\.io/metadata\.name=kube-system' --wait --timeout 10m >/dev/null && ok "policies applied" || bad "applying policies failed"
sleep 5
docker run --rm --network "$NET" -v "$WORKW:/w:ro" -e BASE="http://$PORTFWD" node:24 node /w/health.mjs && ok "reachable through the ingress with policies on" || bad "not reachable with policies on"

step "Live Preview: does the site's CSP follow the admin domain given at RUN time? (finding, not a pass/fail)"
cat > "$WORK/csp.mjs" <<'JS'
import { hfetch } from "/w/hfetch.mjs";
const r = await hfetch(`${process.env.BASE}/`, { headers: { host: "localhost" } });
const raw = await r.text();
console.log("status", r.status, "(CSP header is read from the response below)");
JS
cat > "$WORK/csp2.mjs" <<'JS'
import http from "node:http";
http.get({ hostname: process.env.H, port: 80, path: "/", headers: { host: "localhost" } }, (res) => {
  const csp = res.headers["content-security-policy"] || "";
  console.log("frame-ancestors in the page:", (/frame-ancestors[^;]*/.exec(csp) || ["(none)"])[0]);
  res.resume();
});
JS
# shellcheck disable=SC2086
helm upgrade "$REL" polysite -n "$NS" $(echo "$VALUES" | sed 's/domains.admin=admin.localhost/domains.admin=runtime-admin.localhost/') --wait --timeout 10m >/dev/null && ok "admin domain changed to runtime-admin.localhost"
sleep 3
docker run --rm --network "$NET" -v "$WORKW:/w:ro" -e H="$PORTFWD" node:24 node /w/csp2.mjs | sed 's/^/  finding: /'
# shellcheck disable=SC2086
helm upgrade "$REL" polysite -n "$NS" $VALUES --wait --timeout 10m >/dev/null && ok "admin domain restored"

step "two web replicas: is a published change visible on both within 2 seconds? (finding)"
# shellcheck disable=SC2086
helm upgrade "$REL" polysite -n "$NS" $VALUES --set web.replicaCount=2 --set web.allowMultiReplica=true --wait --timeout 10m >/dev/null && ok "two web pods" || bad "scaling web failed"
cat > "$WORK/stale.mjs" <<'JS'
import { hfetch as fetch } from "/w/hfetch.mjs";
const base = process.env.BASE, ips = process.env.IPS.split(",");
const j = async (h, p, o = {}) => fetch(base + p, { ...o, headers: { host: h, "content-type": "application/json", ...(o.headers || {}) } });
const login = await (await j("admin.localhost", "/api/users/login", { method: "POST", body: JSON.stringify({ email: "smoke-admin@example.test", password: "Smoke-Test-Password-4821" }) })).json();
const auth = { Authorization: `JWT ${login.token}` };
const page = (await (await j("admin.localhost", "/api/pages?where[slug][equals]=about&limit=1", { headers: auth })).json()).docs[0];
const title = "Stale test " + Date.now();
const direct = (ip) => fetch(`http://${ip}:3000/about`, { headers: { host: "localhost" } }).then((r) => r.text());
for (const ip of ips) await direct(ip); // warm both caches
await j("admin.localhost", `/api/pages/${page.id}`, { method: "PATCH", headers: auth, body: JSON.stringify({ title, _status: "published" }) });
await new Promise((r) => setTimeout(r, 2000));
const seen = [];
for (const ip of ips) seen.push((await direct(ip)).includes(title));
console.log(JSON.stringify({ updated: seen }));
process.exit(seen.every(Boolean) ? 0 : 3);
JS
IPS=$(kc get pods -l app.kubernetes.io/component=web -o jsonpath='{range .items[*]}{.status.podIP}{","}{end}' | sed 's/,$//')
# The pod network is not reachable from outside the node: run the probe inside the cluster node's network namespace.
docker run --rm --network "container:$K3S" -v "$WORKW:/w:ro" -e BASE="http://127.0.0.1:80" -e IPS="$IPS" node:24 node /w/stale.mjs && echo "  finding: both replicas showed the new page within 2 seconds" || echo "  finding: at least one web replica still served the OLD page (exit 3)"

step "summary"
[ "$FAILED" = 0 ] && echo "Kubernetes chart test passed." || { echo "Kubernetes chart test FAILED."; exit 1; }

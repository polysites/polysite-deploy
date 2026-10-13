#!/bin/sh
# Tests the deployment templates (everything runs in containers; no cluster or cloud account).
#
#   sh templates/test.sh static           no images needed: every compose file is valid, the copies of the proxy configuration are the tested ones,
#                                         the Kubernetes values render against the chart, the cloud-init file is current
#   sh templates/test.sh run <caddy|nginx|apache>
#                                         starts the template's stack on this machine from LOCAL images (CMS_IMAGE, WEB_IMAGE, BACKUP_IMAGE as
#                                         <registry>/polysite-cms:<tag> ...; the registry is substituted for ghcr.io/polysites and the tag for v0.1.0),
#                                         over plain http, and runs the first-run smoke test through the template's proxy. Cleans up after itself.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE=${POLYSITE_CORE:-$ROOT/../polysite}   # a checkout of the core: only the "run" mode needs it (the smoke test)
export MSYS_NO_PATHCONV=1
w() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }
fail=0

static() {
  echo "== compose files are valid with the example environment, and every image is pinned"
  for p in caddy nginx apache traefik; do
    d=$ROOT/templates/compose-$p; tmp=$(mktemp -d); cp -R "$d"/. "$tmp/"; cp "$tmp/.env.example" "$tmp/.env"
    if (cd "$tmp" && docker compose config -q 2>/tmp/cc.err); then
      if grep -E 'image:.*:latest' "$d/docker-compose.yml" >/dev/null; then echo "  FAIL compose-$p uses :latest"; fail=1; else echo "  ok   compose-$p"; fi
    else echo "  FAIL compose-$p: $(cat /tmp/cc.err)"; fail=1; fi
    rm -rf "$tmp"
  done

  echo "== the proxy files in the templates are the tested ones from proxy"
  chk() { if diff -q "$1" "$2" >/dev/null; then echo "  ok   $2"; else echo "  FAIL $2 differs from $1"; fail=1; fi; }
  for f in polysite.conf polysite-tls.conf; do chk "$ROOT/proxy/nginx/$f" "$ROOT/templates/compose-nginx/proxy/$f"; done
  for f in httpd.conf polysite.conf polysite-tls.conf; do chk "$ROOT/proxy/apache/$f" "$ROOT/templates/compose-apache/proxy/$f"; done
  chk "$ROOT/proxy/traefik/traefik.yml" "$ROOT/templates/compose-traefik/proxy/traefik.yml"
  chk "$ROOT/proxy/traefik/dynamic/polysite.yml" "$ROOT/templates/compose-traefik/proxy/dynamic/polysite.yml"

  echo "== the Kubernetes values render against the chart in this repository"
  C=$(w "$ROOT/kubernetes/helm"); V=$(w "$ROOT/templates/kubernetes-helm")
  out=$(docker run --rm -v "$C:/charts:ro" -v "$V:/v:ro" -w /charts alpine/helm:3.17.3 template polysite polysite -f /v/values.yaml) || { echo "  FAIL helm template"; fail=1; out=""; }
  [ -z "$out" ] || { printf '%s\n' "$out" | docker run --rm -i ghcr.io/yannh/kubeconform:latest-alpine -strict -summary -kubernetes-version 1.31.0 - && echo "  ok   kubernetes-helm/values.yaml" || fail=1; }
  docker run --rm -v "$V:/v:ro" ghcr.io/yannh/kubeconform:latest-alpine -strict -ignore-missing-schemas -summary -kubernetes-version 1.31.0 /v/argocd /v/flux /v/kustomize /v/secret.example.yaml && echo "  ok   Argo CD, Flux, kustomize and Secret examples parse (the Argo CD and Flux custom resources have no schema here, so only the Kubernetes kinds are schema-checked)" || fail=1

  echo "== cloud-init"
  sh "$ROOT/templates/vm-cloud-init/test.sh" 2>&1 | grep -E "ok  |FAIL|passed|FAILED" || fail=1
  [ "$fail" = 0 ] || { echo "Template checks FAILED."; exit 1; }
  echo "Template checks passed."
}

run() {
  p=$1
  case "$p" in caddy) svc=caddy ;; nginx) svc=nginx ;; apache) svc=apache ;; *) echo "run: caddy | nginx | apache"; exit 2 ;; esac
  : "${CMS_IMAGE:?set CMS_IMAGE}" "${WEB_IMAGE:?set WEB_IMAGE}" "${BACKUP_IMAGE:?set BACKUP_IMAGE}"
  REG=${CMS_IMAGE%/polysite-cms:*}; TAG=${CMS_IMAGE##*:}
  PROJECT=polysite-tpl-$p; tmp=$(mktemp -d)
  cleanup() { (cd "$tmp" && docker compose -p "$PROJECT" down -v >/dev/null 2>&1) || true; rm -rf "$tmp" 2>/dev/null || true; }
  trap cleanup EXIT
  cp -R "$ROOT/templates/compose-$p"/. "$tmp/"
  (cd "$tmp" && ./init.sh localhost admin.localhost >/dev/null)
  sed -i "s#^SITE_SCHEME=.*#SITE_SCHEME=http#; s#^CMS_SCHEME=.*#CMS_SCHEME=http#; s#^POLYSITE_SETUP_TOKEN=.*#POLYSITE_SETUP_TOKEN=#" "$tmp/.env"
  echo "POLYSITE_REGISTRY=$REG" >> "$tmp/.env"
  sed -i "s#:v0\.1\.0#:$TAG#" "$tmp/docker-compose.yml"
  # Nothing is published on the host: the test runs on the project's network.
  printf 'services:\n  %s:\n    ports: !reset []\n' "$svc" > "$tmp/test.override.yml"
  [ "$p" != caddy ] || true
  c() { (cd "$tmp" && docker compose -p "$PROJECT" -f docker-compose.yml -f test.override.yml "$@"); }
  echo "== $p template: starting from the images"
  c up -d cms web "$svc"
  n=0; until [ "$(docker inspect --format '{{.State.Health.Status}}' "$(c ps -q cms)")" = healthy ] && [ "$(docker inspect --format '{{.State.Health.Status}}' "$(c ps -q web)")" = healthy ]; do
    n=$((n+1)); [ $n -lt 60 ] || { c logs --tail 40 cms; exit 1; }; sleep 5; done
  sleep 3
  S=$(w "$CORE/tests/smoke")
  docker run --rm --network "${PROJECT}_default" -v "$S:/smoke:ro" -e BASE="http://$svc:80" -e SITE_HOST=localhost -e CMS_HOST=admin.localhost node:24 node /smoke/smoke.mjs
  echo "== $p template: passed"
}

case "${1:-}" in
  static) static ;;
  run) run "${2:-}" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac

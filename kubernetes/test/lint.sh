#!/bin/sh
# Static checks for the Helm chart, in containers (no Helm or kubectl on the host): `helm lint`, then `helm template` for each
# values file in helm/polysite/ci piped through kubeconform against the Kubernetes schemas, plus checks that the chart refuses what it must.
# No cluster is needed, so this runs in CI.   sh kubernetes/test/lint.sh
set -eu
# Resolve the folder once: a second relative `cd` after the first one failed (`pwd -W` exists only in Git Bash) cannot work.
HERE_UNIX=$(cd "$(dirname "$0")/.." && pwd)
HERE=$(cd "$HERE_UNIX" && (pwd -W 2>/dev/null || pwd))
HELM_IMAGE=${HELM_IMAGE:-alpine/helm:3.17.3}
KUBECONFORM_IMAGE=${KUBECONFORM_IMAGE:-ghcr.io/yannh/kubeconform:latest-alpine}
KVER=${KUBE_VERSION:-1.31.0}
helm() { MSYS_NO_PATHCONV=1 docker run --rm -v "$HERE/helm:/charts:ro" -w /charts "$HELM_IMAGE" "$@"; }
fail=0

echo "== helm lint"
for f in minimal full no-edge; do helm lint polysite -f "polysite/ci/$f-values.yaml" --strict || fail=1; done

echo "== helm template | kubeconform (Kubernetes $KVER)"
for f in minimal full no-edge; do
  out=$(helm template rel polysite -f "polysite/ci/$f-values.yaml") || { echo "template failed for $f"; fail=1; continue; }
  printf '%s\n' "$out" | MSYS_NO_PATHCONV=1 docker run --rm -i "$KUBECONFORM_IMAGE" -strict -summary -kubernetes-version "$KVER" - || fail=1
done

echo "== the chart refuses what would break an install"
expect_fail() { # <message fragment> <helm args...>
  frag=$1; shift
  if out=$(helm template rel polysite -f polysite/ci/minimal-values.yaml "$@" 2>&1); then echo "FAIL: accepted: $*"; fail=1
  else printf '%s' "$out" | grep -q "$frag" && echo "  ok   refused: $*" || { echo "FAIL: refused for another reason: $*"; printf '%s\n' "$out" | tail -3; fail=1; }; fi
}
expect_fail "cms.replicaCount > 1 is refused" --set cms.replicaCount=2
expect_fail "web.replicaCount > 1 is refused" --set web.replicaCount=2
expect_fail "needs cms.allowMultiReplica" --set cms.autoscaling.enabled=true
expect_fail "domains.admin is required" --set domains.admin=
expect_fail "needs a setup token" --set secrets.existingSecret= --set secrets.payloadSecret=x --set secrets.revalidateSecret=y --set secrets.databaseUrl=postgres://a
expect_fail "needs somewhere to put the archives" --set backups.enabled=true
exit $fail

#!/bin/sh
# helm install or upgrade with the pinned chart version from chart.yaml and your values.yaml.   ./scripts/install.sh
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^chartVersion: *//p' chart.yaml)
exec helm upgrade --install polysite oci://ghcr.io/polysites/charts/polysite --version "$VERSION" \
  --namespace "${NAMESPACE:-polysite}" --create-namespace -f values.yaml --wait --timeout 15m

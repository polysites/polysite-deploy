#!/bin/sh
# Builds both apps from a source tree, the way the Dockerfiles do (no secrets or database needed to build).
#   scripts/build.sh [source dir]        default /opt/polysite/src
# Needs Node.js 24 LTS and npm. Run it as the service user (or root, then chown the tree to polysite): it writes node_modules, .next and .output.
set -eu
SRC=${1:-/opt/polysite/src}
echo "== CMS"
cd "$SRC/apps/cms"
npm ci
# Each plugin is its own package with its own dependencies (core-only installs have none).
for d in "$SRC"/plugins/*/; do
  if [ -f "$d/package-lock.json" ]; then npm ci --prefix "$d"; elif [ -f "$d/package.json" ]; then npm install --prefix "$d"; fi
done
npx payload generate:importmap
npx payload generate:types
npm run build
mkdir -p media
echo "== web"
cd "$SRC/apps/web"
npm ci
npm run build
echo "built"

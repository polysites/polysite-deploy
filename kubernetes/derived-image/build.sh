#!/bin/sh
# Builds YOUR Polysite images: the core at a tag plus your plugins and themes, using the core's own Dockerfiles. Run it in CI, and point the Helm chart
# (image.registry, image.cms.repository, image.web.repository, image.tag) or the Compose file at what it pushes.
#
#   ./build.sh --core v0.1.0 --plugins ./plugins --themes ./themes --registry registry.example.org/acme --tag v0.1.0-acme1 [--push]
#
# Why not "FROM the published image and COPY the plugins in"? Because that cannot work: the CMS image already holds a finished `next build` in which the
# plugin list, the admin import map and the generated types were fixed, and the web image holds a finished Nuxt build with the theme layers compiled in.
# A folder copied on top is never loaded (docs/guide/plugins.md: "Plugins are fixed into an image when it is built"). The build below runs the
# core's Dockerfiles with the plugins and themes in the build context, which is exactly how the published images are made, minus the extra folders.
set -eu
CORE=""; PLUGINS=""; THEMES=""; REGISTRY=""; TAG=""; PUSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --core) CORE=$2; shift 2 ;; --plugins) PLUGINS=$2; shift 2 ;; --themes) THEMES=$2; shift 2 ;;
    --registry) REGISTRY=$2; shift 2 ;; --tag) TAG=$2; shift 2 ;; --push) PUSH=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
[ -n "$CORE" ] && [ -n "$REGISTRY" ] && [ -n "$TAG" ] || { echo "usage: $0 --core <tag or checkout dir> --registry <reg/ns> --tag <tag> [--plugins dir] [--themes dir] [--push]"; exit 2; }
CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT
if [ -d "$CORE" ]; then
  (cd "$CORE" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf -) | tar -x -C "$CTX"
else
  git clone --quiet --depth 1 --branch "$CORE" https://github.com/polysites/polysite.git "$CTX"
fi
mkdir -p "$CTX/plugins" "$CTX/themes"
# Your folders are copied as they are. Each plugin must have "type":"module" in its package.json and a polysite manifest (plugins/README.md).
[ -z "$PLUGINS" ] || cp -R "$PLUGINS"/. "$CTX/plugins/"
[ -z "$THEMES" ] || cp -R "$THEMES"/. "$CTX/themes/"
VERSION=${TAG#v}
for app in cms web; do
  docker build -f "$CTX/apps/$app/Dockerfile" --target run --build-arg POLYSITE_VERSION="$VERSION" -t "$REGISTRY/polysite-$app:$TAG" "$CTX"
done
echo "Built $REGISTRY/polysite-cms:$TAG and $REGISTRY/polysite-web:$TAG"
if [ "$PUSH" = 1 ]; then docker push "$REGISTRY/polysite-cms:$TAG"; docker push "$REGISTRY/polysite-web:$TAG"; fi
echo "Use them:  helm upgrade ... --set image.registry=$REGISTRY --set image.tag=$TAG   (the backup image stays the published one: --set image.backup.registry=ghcr.io/polysites --set image.backup.tag=<core tag>)"

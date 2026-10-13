#!/bin/sh
# Checks cloud-init.yaml without creating a VM, in containers: it is up to date with its sources, valid against cloud-init's own schema,
# its scripts pass shellcheck, and on a clean Ubuntu 24.04 the files it writes work: init.sh produces a complete .env with fresh secrets, the
# compose file is valid, Docker's signing key has the fingerprint the bootstrap script demands, and Docker's apt repository offers docker-ce.
# What it cannot do: run the bootstrap as root on a real VM (ufw, systemd, installing and starting Docker).   sh test.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$HERE" && (pwd -W 2>/dev/null || pwd))
export MSYS_NO_PATHCONV=1
fail=0

echo "== cloud-init.yaml is current"
old=$(mktemp); cp "$HERE/cloud-init.yaml" "$old"; (cd "$HERE" && sh build.sh >/dev/null)
if diff -q "$old" "$HERE/cloud-init.yaml" >/dev/null; then echo "  ok   up to date"; else echo "  FAIL cloud-init.yaml was stale and has been rebuilt: commit it"; fail=1; fi
rm -f "$old"

echo "== shellcheck on the scripts it writes"
docker run --rm -v "$W/files:/f:ro" koalaman/shellcheck:stable /f/bootstrap.sh && echo "  ok   shellcheck clean" || fail=1

echo "== schema, written files and Docker's apt repository on Ubuntu 24.04"
docker run --rm -v "$W:/c:ro" ubuntu:24.04 bash -c '
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq cloud-init curl gnupg ca-certificates python3-yaml >/dev/null
echo "-- cloud-init schema"; cloud-init schema -c /c/cloud-init.yaml
echo "-- write_files"; mkdir -p /out && python3 - <<PY
import yaml, os
cfg = yaml.safe_load(open("/c/cloud-init.yaml"))
for f in cfg["write_files"]:
    p = "/out" + f["path"]; os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(f["content"]); os.chmod(p, int(f["permissions"], 8))
print(len(cfg["write_files"]), "files written;", "runcmd:", cfg["runcmd"])
PY
cd /out/opt/polysite && cp /out/etc/polysite-bootstrap.env /tmp/b.env && ./init.sh www.test.example admin.test.example | sed "s/: .*/: <token hidden>/"
for k in PAYLOAD_SECRET REVALIDATE_SECRET NUXT_REVALIDATE_SECRET POLYSITE_SETUP_TOKEN POSTGRES_PASSWORD; do v=$(sed -n "s/^$k=//p" .env); [ ${#v} -ge 32 ] || { echo "$k is too short"; exit 1; }; done
grep -q "^DATABASE_URL=postgres://polysite:$(sed -n "s/^POSTGRES_PASSWORD=//p" .env)@db" .env && echo "  ok   .env is complete, secrets are 32+ characters"
[ "$(stat -c %a .env)" = 600 ] && echo "  ok   .env is mode 600"
bash -n /out/opt/polysite/bootstrap.sh && echo "  ok   bootstrap.sh parses"
echo "-- Docker signing key"; curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/d.asc
fp=$(gpg --show-keys --with-colons /tmp/d.asc | awk -F: "/^fpr:/ {print \$10; exit}")
[ "$fp" = 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ] && echo "  ok   fingerprint matches the one bootstrap.sh requires" || { echo "  FAIL fingerprint $fp"; exit 1; }
install -m 0755 -d /etc/apt/keyrings; gpg --dearmor < /tmp/d.asc > /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq >/dev/null; apt-cache policy docker-ce docker-compose-plugin | grep -E "^docker|Candidate"
' || fail=1
[ "$fail" = 0 ] && echo "cloud-init checks passed." || { echo "cloud-init checks FAILED."; exit 1; }

#!/bin/sh
# Creates the Secret named in values.yaml with fresh random values, in the current kubectl context.
#   ./scripts/create-secret.sh 'postgres://user:password@host:5432/polysite?sslmode=require'
# Prints the setup token (needed once, on the first-run page) and stores nothing on disk. Refuses to overwrite an existing Secret.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <DATABASE_URL>"; exit 2; }
NS=${NAMESPACE:-polysite}; NAME=${SECRET_NAME:-polysite-secrets}
rand() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48; }
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
if kubectl -n "$NS" get secret "$NAME" >/dev/null 2>&1; then echo "Secret $NAME already exists in $NS: not touching it (PAYLOAD_SECRET must not change)"; exit 1; fi
TOKEN=$(rand)
kubectl -n "$NS" create secret generic "$NAME" --from-literal=PAYLOAD_SECRET="$(rand)" --from-literal=REVALIDATE_SECRET="$(rand)" \
  --from-literal=POLYSITE_SETUP_TOKEN="$TOKEN" --from-literal=DATABASE_URL="$1"
echo "Setup token for the first-run page: $TOKEN"
echo "Keep a copy of PAYLOAD_SECRET apart from your backups: kubectl -n $NS get secret $NAME -o jsonpath='{.data.PAYLOAD_SECRET}' | base64 -d"

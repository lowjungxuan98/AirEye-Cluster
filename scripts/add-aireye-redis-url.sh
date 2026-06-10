#!/bin/sh
set -eu

NAMESPACE="${NAMESPACE:-infra}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_BOOTSTRAP_SECRET="${VAULT_BOOTSTRAP_SECRET:-vault-bootstrap-secret}"
VAULT_SHARED_PATH="${VAULT_SHARED_PATH:-secret/aireye-cluster/redis}"
VAULT_APP_PATH="${VAULT_APP_PATH:-secret/aireye-cluster/app}"
REDIS_HOST="${REDIS_HOST:-redis.infra.svc.cluster.local}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-0}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to decode and URL-encode secret values" >&2
  exit 1
fi

ROOT_TOKEN_B64="$(
  kubectl -n "$NAMESPACE" get secret "$VAULT_BOOTSTRAP_SECRET" \
    -o jsonpath='{.data.VAULT_ROOT_TOKEN}'
)"

ROOT_TOKEN="$(
  ROOT_TOKEN_B64="$ROOT_TOKEN_B64" python3 - <<'PY'
import base64
import os

print(base64.b64decode(os.environ["ROOT_TOKEN_B64"]).decode(), end="")
PY
)"

REDIS_PASSWORD="$(
  printf '%s\n' "$ROOT_TOKEN" |
    kubectl -n "$NAMESPACE" exec -i "$VAULT_POD" -- sh -ec '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN
      vault kv get -field=REDIS_PASSWORD "$1"
    ' sh "$VAULT_SHARED_PATH"
)"

REDIS_URL="$(
  REDIS_PASSWORD="$REDIS_PASSWORD" \
  REDIS_HOST="$REDIS_HOST" \
  REDIS_PORT="$REDIS_PORT" \
  REDIS_DB="$REDIS_DB" \
  python3 - <<'PY'
import os
import urllib.parse

password = urllib.parse.quote(os.environ["REDIS_PASSWORD"], safe="")
host = os.environ["REDIS_HOST"]
port = os.environ["REDIS_PORT"]
db = os.environ["REDIS_DB"]

print(f"redis://:{password}@{host}:{port}/{db}", end="")
PY
)"

printf '%s\n%s\n' "$ROOT_TOKEN" "$REDIS_URL" |
  kubectl -n "$NAMESPACE" exec -i "$VAULT_POD" -- sh -ec '
    IFS= read -r VAULT_TOKEN
    IFS= read -r REDIS_URL
    export VAULT_TOKEN
    vault kv get "$1" >/dev/null
    vault kv patch "$1" REDIS_URL="$REDIS_URL" >/dev/null
  ' sh "$VAULT_APP_PATH"

echo "Patched REDIS_URL into $VAULT_APP_PATH. VSO will sync it to aireye-app-secret."

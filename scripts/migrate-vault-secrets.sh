#!/bin/sh
# Phase 0: Copy flat Vault paths to per-app subpaths under aireye-cluster/*.
# Idempotent — safe to re-run. Leaves old paths untouched.
# Run BEFORE committing Phase A.
set -eu

NAMESPACE="${NAMESPACE:-infra}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_BOOTSTRAP_SECRET="${VAULT_BOOTSTRAP_SECRET:-vault-bootstrap-secret}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ROOT_TOKEN="$(
  B64="$(kubectl -n "$NAMESPACE" get secret "$VAULT_BOOTSTRAP_SECRET" \
    -o jsonpath='{.data.VAULT_ROOT_TOKEN}')"
  B64="$B64" python3 -c "import base64,os; print(base64.b64decode(os.environ['B64']).decode(),end='')"
)"

ve() {
  printf '%s\n' "$ROOT_TOKEN" |
    kubectl -n "$NAMESPACE" exec -i "$VAULT_POD" -- sh -ec "
      IFS= read -r VAULT_TOKEN; export VAULT_TOKEN
      \$@
    " sh "$@"
}

vault_kv_get_json() {
  # Returns the JSON .data object from a kv-v2 path, or exits non-zero.
  printf '%s\n' "$ROOT_TOKEN" |
    kubectl -n "$NAMESPACE" exec -i "$VAULT_POD" -- sh -ec "
      IFS= read -r VAULT_TOKEN; export VAULT_TOKEN
      vault kv get -format=json \"\$1\" 2>/dev/null
    " sh "$1"
}

vault_kv_put_from_json() {
  # Args: path json_object
  # Writes all key=value pairs from the JSON object to the Vault path.
  PATH_ARG="$1"
  JSON_ARG="$2"
  printf '%s\n%s\n' "$ROOT_TOKEN" "$JSON_ARG" |
    kubectl -n "$NAMESPACE" exec -i "$VAULT_POD" -- python3 -ec "
import sys, json, subprocess, os
root_token = sys.stdin.readline().rstrip('\n')
data = json.loads(sys.stdin.read())
kv_args = ['vault', 'kv', 'put', sys.argv[1]]
for k, v in data.items():
    kv_args.append(f'{k}={v}')
env = {**os.environ, 'VAULT_TOKEN': root_token}
subprocess.check_call(kv_args, env=env, stdout=subprocess.DEVNULL)
" "$PATH_ARG"
}

read_path_data() {
  # Returns the .data.data dict from vault kv get -format=json, or empty {}.
  PRAW="$(vault_kv_get_json "$1" 2>/dev/null)" || { echo "{}"; return; }
  printf '%s' "$PRAW" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('data',{}).get('data',{})))"
}

migrate_subpath() {
  SRC_JSON="$1"
  DEST_PATH="$2"
  shift 2
  # Remaining args: dest_key=src_key pairs (or dest_key=@literal for literal values)
  python3 -ec "
import json, sys
src = json.loads(sys.argv[1])
pairs = sys.argv[2:]
out = {}
missing = []
for pair in pairs:
    dest_k, src_k = pair.split('=', 1)
    if src_k.startswith('@'):
        out[dest_k] = src_k[1:]
    elif src_k in src:
        out[dest_k] = src[src_k]
    else:
        missing.append(src_k)
if missing:
    for m in missing:
        print(f'WARN: key {m!r} not found in source', file=sys.stderr)
print(json.dumps(out))
" "$SRC_JSON" "$@"
}

echo "=== Phase 0: Vault secret migration ==="
echo "Cluster namespace: $NAMESPACE  Pod: $VAULT_POD"
echo

# ---------------------------------------------------------------------------
# 1. Read source paths
# ---------------------------------------------------------------------------

echo "Reading secret/aireye-cluster ..."
SRC_CLUSTER="$(read_path_data secret/aireye-cluster)"

echo "Reading secret/aireye-app-secret ..."
SRC_APP="$(read_path_data secret/aireye-app-secret)"

echo "Reading secret/langfuse-secret ..."
SRC_LANGFUSE="$(read_path_data secret/langfuse-secret)"

echo "Reading secret/argocd-image-updater-git-creds ..."
SRC_ARGO="$(read_path_data secret/argocd-image-updater-git-creds)"

# ---------------------------------------------------------------------------
# 2. Warn on unmapped keys in secret/aireye-cluster
# ---------------------------------------------------------------------------

MAPPED_CLUSTER_KEYS="VAULT_PG_CONNECTION_URL POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REDIS_HOST REDIS_PORT REDIS_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_BOOTSTRAP_USERNAME KEYCLOAK_BOOTSTRAP_PASSWORD KEYCLOAK_BOOTSTRAP_EMAIL KEYCLOAK_USER_USERNAME KEYCLOAK_USER_PASSWORD KEYCLOAK_USER_EMAIL KC_DB KC_DB_URL KC_DB_USERNAME OIDC_CLIENT_ID OIDC_CLIENT_SECRET LITELLM_MASTER_KEY LITELLM_SALT_KEY DATABASE_URL OPENAI_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY NVIDIA_NIM_API_KEY LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY"

UNMAPPED="$(python3 -ec "
import json, sys
src = json.loads(sys.argv[1])
mapped = set(sys.argv[2].split())
unmapped = [k for k in src if k not in mapped]
for k in unmapped:
    print(k)
" "$SRC_CLUSTER" "$MAPPED_CLUSTER_KEYS")"

if [ -n "$UNMAPPED" ]; then
  echo "ERROR: The following keys in secret/aireye-cluster are not mapped to any subpath:" >&2
  printf '%s\n' "$UNMAPPED" | sed 's/^/  /' >&2
  echo "Triage these keys before proceeding with Phase A." >&2
  exit 1
fi

echo "All keys in secret/aireye-cluster are mapped. Proceeding."
echo

# ---------------------------------------------------------------------------
# 3. Write subpaths
# ---------------------------------------------------------------------------

echo "--- aireye-cluster/vault ---"
OUT="$(migrate_subpath "$SRC_CLUSTER" secret/aireye-cluster/vault \
  VAULT_PG_CONNECTION_URL=VAULT_PG_CONNECTION_URL)"
vault_kv_put_from_json secret/aireye-cluster/vault "$OUT"
echo "  OK"

echo "--- aireye-cluster/pg ---"
OUT="$(migrate_subpath "$SRC_CLUSTER" secret/aireye-cluster/pg \
  PG_USER=POSTGRES_USER \
  PG_PASSWORD=POSTGRES_PASSWORD \
  PG_DB=POSTGRES_DB)"
vault_kv_put_from_json secret/aireye-cluster/pg "$OUT"
echo "  OK"

echo "--- aireye-cluster/redis ---"
# REDIS_HOST and REDIS_PORT may not be in the flat path (could be hardcoded elsewhere).
# Use defaults if missing.
OUT="$(python3 -ec "
import json, sys
src = json.loads(sys.argv[1])
out = {
    'REDIS_HOST': src.get('REDIS_HOST', 'redis.infra.svc.cluster.local'),
    'REDIS_PORT': src.get('REDIS_PORT', '6379'),
    'REDIS_PASSWORD': src['REDIS_PASSWORD'],
}
print(json.dumps(out))
" "$SRC_CLUSTER")"
vault_kv_put_from_json secret/aireye-cluster/redis "$OUT"
echo "  OK"

echo "--- aireye-cluster/minio ---"
OUT="$(migrate_subpath "$SRC_CLUSTER" secret/aireye-cluster/minio \
  MINIO_ROOT_USER=MINIO_ROOT_USER \
  MINIO_ROOT_PASSWORD=MINIO_ROOT_PASSWORD)"
vault_kv_put_from_json secret/aireye-cluster/minio "$OUT"
echo "  OK"

echo "--- aireye-cluster/kc ---"
OUT="$(python3 -ec "
import json, sys
src = json.loads(sys.argv[1])
out = {
    'KC_BOOTSTRAP_ADMIN_USERNAME': src['KEYCLOAK_ADMIN'],
    'KC_BOOTSTRAP_ADMIN_PASSWORD': src['KEYCLOAK_ADMIN_PASSWORD'],
    'KC_DB': src['KC_DB'],
    'KC_DB_URL': src['KC_DB_URL'],
    'KC_DB_USERNAME': src['KC_DB_USERNAME'],
    'KC_USER_USERNAME': src['KEYCLOAK_USER_USERNAME'],
    'KC_USER_PASSWORD': src['KEYCLOAK_USER_PASSWORD'],
    'KC_USER_EMAIL': src['KEYCLOAK_USER_EMAIL'],
}
# Copy-if-present: KC_GITOPS_* (may not exist; job shell-defaults them)
for dest, orig in [
    ('KC_GITOPS_USERNAME', 'KEYCLOAK_BOOTSTRAP_USERNAME'),
    ('KC_GITOPS_PASSWORD', 'KEYCLOAK_BOOTSTRAP_PASSWORD'),
    ('KC_GITOPS_EMAIL',    'KEYCLOAK_BOOTSTRAP_EMAIL'),
]:
    if orig in src:
        out[dest] = src[orig]
    else:
        print(f'NOTE: {orig} not found; {dest} will use shell default', file=__import__(\"sys\").stderr)
print(json.dumps(out))
" "$SRC_CLUSTER")"
vault_kv_put_from_json secret/aireye-cluster/kc "$OUT"
echo "  OK"

echo "--- aireye-cluster/oidc ---"
OUT="$(migrate_subpath "$SRC_CLUSTER" secret/aireye-cluster/oidc \
  OIDC_CLIENT_ID=OIDC_CLIENT_ID \
  OIDC_CLIENT_SECRET=OIDC_CLIENT_SECRET)"
vault_kv_put_from_json secret/aireye-cluster/oidc "$OUT"
echo "  OK"

echo "--- aireye-cluster/litellm ---"
OUT="$(migrate_subpath "$SRC_CLUSTER" secret/aireye-cluster/litellm \
  LITELLM_MASTER_KEY=LITELLM_MASTER_KEY \
  LITELLM_SALT_KEY=LITELLM_SALT_KEY \
  LITELLM_DATABASE_URL=DATABASE_URL \
  OPENAI_API_KEY=OPENAI_API_KEY \
  DEEPSEEK_API_KEY=DEEPSEEK_API_KEY \
  OPENROUTER_API_KEY=OPENROUTER_API_KEY \
  NVIDIA_NIM_API_KEY=NVIDIA_NIM_API_KEY \
  LANGFUSE_PUBLIC_KEY=LANGFUSE_PUBLIC_KEY \
  LANGFUSE_SECRET_KEY=LANGFUSE_SECRET_KEY)"
vault_kv_put_from_json secret/aireye-cluster/litellm "$OUT"
echo "  OK"

echo "--- aireye-cluster/app (from secret/aireye-app-secret) ---"
if [ "$(printf '%s' "$SRC_APP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")" -eq 0 ]; then
  echo "  WARN: secret/aireye-app-secret is empty or missing — skipping" >&2
else
  vault_kv_put_from_json secret/aireye-cluster/app "$SRC_APP"
  echo "  OK"
fi

echo "--- aireye-cluster/langfuse (from secret/langfuse-secret, keys renamed) ---"
if [ "$(printf '%s' "$SRC_LANGFUSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")" -eq 0 ]; then
  echo "  WARN: secret/langfuse-secret is empty or missing — skipping" >&2
else
  OUT="$(python3 -ec "
import json, sys
src = json.loads(sys.argv[1])
rename = {
    'NEXTAUTH_SECRET':                'LANGFUSE_NEXTAUTH_SECRET',
    'SALT':                           'LANGFUSE_SALT',
    'ENCRYPTION_KEY':                 'LANGFUSE_ENCRYPTION_KEY',
    'CLICKHOUSE_PASSWORD':            'LANGFUSE_CLICKHOUSE_PASSWORD',
    'S3_ACCESS_KEY_ID':               'LANGFUSE_S3_ACCESS_KEY_ID',
    'S3_SECRET_ACCESS_KEY':           'LANGFUSE_S3_SECRET_ACCESS_KEY',
    'LANGFUSE_INIT_PROJECT_PUBLIC_KEY':  'LANGFUSE_INIT_PROJECT_PUBLIC_KEY',
    'LANGFUSE_INIT_PROJECT_SECRET_KEY':  'LANGFUSE_INIT_PROJECT_SECRET_KEY',
}
out = {}
for src_k, dest_k in rename.items():
    if src_k in src:
        out[dest_k] = src[src_k]
    else:
        print(f'WARN: {src_k!r} not found in langfuse-secret', file=sys.stderr)
print(json.dumps(out))
" "$SRC_LANGFUSE")"
  vault_kv_put_from_json secret/aireye-cluster/langfuse "$OUT"
  echo "  OK"
fi

echo "--- aireye-cluster/argo (from secret/argocd-image-updater-git-creds) ---"
if [ "$(printf '%s' "$SRC_ARGO" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")" -eq 0 ]; then
  echo "  WARN: secret/argocd-image-updater-git-creds is empty or missing — skipping" >&2
else
  vault_kv_put_from_json secret/aireye-cluster/argo "$SRC_ARGO"
  echo "  OK"
fi

echo
echo "=== Subpath population complete ==="
echo

# ---------------------------------------------------------------------------
# 4. Pre-create k8s Secret vault-secret to break bootstrap deadlock in Phase B.
#    Values match what VSO will sync from aireye-cluster/vault.
# ---------------------------------------------------------------------------

echo "Pre-creating k8s Secret vault-secret in namespace $NAMESPACE ..."
VAULT_PG_URL="$(printf '%s' "$SRC_CLUSTER" | python3 -c "import json,sys; print(json.load(sys.stdin)['VAULT_PG_CONNECTION_URL'])")"
kubectl -n "$NAMESPACE" create secret generic vault-secret \
  --from-literal=VAULT_PG_CONNECTION_URL="$VAULT_PG_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  vault-secret created/updated."
echo

# ---------------------------------------------------------------------------
# 5. Print Phase C cleanup commands (NOT run automatically)
# ---------------------------------------------------------------------------

cat <<'CLEANUP'
=== Phase C cleanup (run ONLY after full verification) ===

# Delete the now-superseded flat Vault paths (subpaths survive):
kubectl -n infra exec vault-0 -- env VAULT_TOKEN="<root-token>" \
  vault kv metadata delete secret/aireye-cluster

kubectl -n infra exec vault-0 -- env VAULT_TOKEN="<root-token>" \
  vault kv metadata delete secret/aireye-app-secret

kubectl -n infra exec vault-0 -- env VAULT_TOKEN="<root-token>" \
  vault kv metadata delete secret/langfuse-secret

kubectl -n infra exec vault-0 -- env VAULT_TOKEN="<root-token>" \
  vault kv metadata delete secret/argocd-image-updater-git-creds

CLEANUP

echo "Phase 0 complete."

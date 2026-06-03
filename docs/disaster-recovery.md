# Disaster recovery

Runbook for rebuilding the cluster's data plane after total data loss.
Written from the 2026-05-18 incident: a `argocd app sync --replace
--force --async` against `aireye-cluster` deleted and recreated every PVC,
which on `local-path` storage means the underlying directory is removed
with the PV.

## What can cause total data loss

The local-path provisioner uses `reclaimPolicy: Delete`. Any operation
that deletes a PVC therefore wipes the on-disk data immediately. The
known triggers:

- `argocd app sync --replace --force` — `Replace=true` falls back to
  `kubectl replace` (delete-then-apply) for resources that fail
  server-side-apply, and `--force` makes it unstoppable. **Never run
  this against `aireye-cluster`.**
- `kubectl delete pvc <name>`
- An ArgoCD self-heal sync that decides a PVC is OutOfSync because of
  drift in an immutable field (e.g. `spec.volumeName` after binding).
  The `ignoreDifferences` + `RespectIgnoreDifferences=true` combo in
  `argocd/applications/aireye-cluster.yaml` is what neutralises this — keep
  it.

## Blast radius

Because Vault stores its backend in Postgres, one PVC cascade takes
everything else with it:

| PVC | Direct loss | Cascading loss |
|---|---|---|
| `postgres-data` | keycloak DB, vault DB, litellm DB | Vault KV secrets, auth method config, root token, unseal key |
| `redis-data` | session/cache state | — |
| `minio-data` | every bucket and object | aireye-app S3 contents |

There are no off-cluster backups. **If a PVC is gone, its data is
gone.** Treat any sync that touches PVCs or the data layer as
load-bearing.

## Prevention

1. **No `--replace --force` against this app, ever.**
2. Keep `RespectIgnoreDifferences=true` in the Application's
   `syncOptions` and the `ignoreDifferences` block for PVC
   `/spec/volumeName` and `/spec/storageClassName`. This removes the
   reason anyone would reach for `--replace`.
3. Pause `automated` sync on `aireye-cluster` before any deliberate
   data-layer surgery.
4. Stand up real backups (Velero, `pg_dump` CronJob to off-cluster
   storage, `mc mirror` to a separate MinIO/S3). This runbook assumes
   none exist; it's a rebuild path, not a restore path.

## Recovery procedure

Adjust pod names and addresses to your cluster. Run each section to
completion before moving on.

### 1. Pause auto-sync

```sh
kubectl -n argocd patch application aireye-cluster --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

ArgoCD will stop trying to push state while you reseed the cluster by
hand.

### 2. Recover credentials from surviving runtime state

Two recovery sources almost always survive a PVC wipe:

**a. Running pods.** A pod's env was set at start time and stays in
`/proc/1/environ` even after the Secret it was sourced from disappears:

```sh
kubectl -n infra exec deploy/litellm  -- env > /tmp/litellm.env
kubectl -n infra exec deploy/aireye-app -- env > /tmp/aireye-app.env
```

Useful values typically present:

| Variable | Source pod | Used for |
|---|---|---|
| `POSTGRES_PASSWORD` (in `DATABASE_URL`) | litellm | Postgres root, Keycloak DB, Vault backend |
| `LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY` | litellm | LiteLLM admin key, encryption |
| `GENERIC_CLIENT_ID` / `GENERIC_CLIENT_SECRET` | litellm | Keycloak OIDC client (also Vault, ArgoCD, MinIO) |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | aireye-app | MinIO root (S3 keys === root creds) |

**b. VSO-managed Secrets.** A k8s Secret managed by VSO survives even
when Vault is unreachable, and its `_raw` data field is the verbatim
Vault payload at last sync:

```sh
kubectl -n infra get secret aireye-app-secret \
  -o jsonpath='{.data._raw}' | base64 -d | jq '.data'
```

Generate fresh random values for anything not surfaced (typically
`REDIS_PASSWORD`, all Keycloak admin/user passwords).

### 3. Seed `server-secret` manually

`server-secret` is normally produced by VSO from Vault, but Vault needs
Postgres to start, and Postgres needs `server-secret`. Break the cycle
by creating the Secret by hand. Values should match what you will write
to Vault in step 5 — when VSO later overwrites the Secret with identical
bytes, no rollout restart fires.

```sh
kubectl -n infra create secret generic server-secret \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD=<recovered> \
  --from-literal=POSTGRES_DB=postgres \
  --from-literal=REDIS_PASSWORD=<generated> \
  --from-literal=MINIO_ROOT_USER=<recovered> \
  --from-literal=MINIO_ROOT_PASSWORD=<recovered> \
  --from-literal=OIDC_CLIENT_ID=<recovered> \
  --from-literal=OIDC_CLIENT_SECRET=<recovered> \
  --from-literal=KEYCLOAK_ADMIN=temp_admin \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=<generated> \
  --from-literal=KEYCLOAK_USER_USERNAME=<your-username> \
  --from-literal=KEYCLOAK_USER_PASSWORD=<generated> \
  --from-literal=KEYCLOAK_USER_EMAIL=<your-email> \
  --from-literal=KC_DB=postgres \
  --from-literal=KC_DB_URL=jdbc:postgresql://postgres:5432/keycloak \
  --from-literal=KC_DB_USERNAME=postgres \
  --from-literal=VAULT_PG_CONNECTION_URL="postgresql://postgres:<recovered>@postgres.infra.svc.cluster.local:5432/vault?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4. Bring up the data layer

```sh
kubectl -n infra delete pod postgres-0 redis-0 minio-0 --wait=false
# postgres-init ConfigMap runs on first boot and creates the keycloak,
# vault, and litellm databases.
```

Verify:

```sh
kubectl -n infra exec postgres-0 -- psql -U postgres -c '\l'
# expect: postgres, keycloak, vault, litellm
```

### 5. Initialize Vault on the fresh Postgres backend

```sh
kubectl -n infra delete pod vault-0   # forces clean reconnect

kubectl -n infra exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > /tmp/vault-init.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token'        /tmp/vault-init.json)

kubectl -n infra create secret generic vault-bootstrap-secret \
  --from-literal=VAULT_UNSEAL_KEY="$UNSEAL_KEY" \
  --from-literal=VAULT_ROOT_TOKEN="$ROOT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n infra exec vault-0 -- vault operator unseal "$UNSEAL_KEY"
```

Save the unseal key and root token in a password manager too. The
auto-unseal CronJob reads from `vault-bootstrap-secret`, but if both
copies are lost the keys cannot be recovered from inside Vault.

### 6. Populate Vault KV

```sh
export VT="$ROOT_TOKEN"
KE() { kubectl exec -n infra vault-0 -- env VAULT_TOKEN="$VT" "$@"; }

KE vault secrets enable -path=secret kv-v2

# Mirror every key from §3 plus the litellm templates VSO needs:
#   LITELLM_MASTER_KEY, LITELLM_SALT_KEY, DATABASE_URL,
#   REDIS_HOST=redis.infra.svc.cluster.local, REDIS_PORT=6379,
#   OPENAI_API_KEY, DEEPSEEK_API_KEY, OPENROUTER_API_KEY, NVIDIA_NIM_API_KEY
#   (empty string is fine for provider keys you don't have).
KE vault kv put secret/aireye-cluster POSTGRES_USER=postgres ...

# Mirror the surviving _raw payload from §2b:
KE vault kv put secret/aireye-app-secret <key>=<value> ...

# Restore the AirEye backend Redis URL after REDIS_PASSWORD exists:
./scripts/add-aireye-redis-url.sh
```

### 7. Configure Vault auth methods

The PostSync Job manifest contains the full sequence. Apply it directly:

```sh
kubectl apply -n infra -f vault/auth-config-job.yaml
```

This:

- enables `kubernetes/` auth (so VSO can authenticate)
- writes the `aireye-cluster-read` policy
- binds the `vso-aireye-cluster` role to the VSO ServiceAccount
- enables `oidc/` with Keycloak as provider

The OIDC step requires Vault to reach
`https://keycloak.lowjungxuan.dpdns.org/.../openid-configuration`. This
resolves to Cloudflare's edge, which presents a valid public cert — so
the call succeeds even when the origin's `keycloak-tls` Secret is
missing or self-signed.

### 8. Restart consumers

VSO overwrites the hand-seeded `server-secret` with the Vault-sourced
version. If values match, no restart fires. To be safe:

```sh
kubectl -n infra rollout restart \
  statefulset/postgres statefulset/redis statefulset/minio \
  deployment/keycloak deployment/litellm deployment/aireye-app
```

Wait for all rollouts to complete, then watch VSO converge:

```sh
kubectl -n infra get vaultstaticsecret
# expect all rows: SYNCED=True, HEALTHY=True, READY=True
```

### 9. Re-run idempotent hooks

```sh
kubectl apply -n infra -f keycloak/bootstrap-job.yaml
kubectl apply -n infra -f litellm/postgres-init-job.yaml
```

Verify in Keycloak: OIDC client `global`, the admin user, and the MinIO
`minio-policy` mapper exist.

### 10. Re-enable ArgoCD auto-sync

Only after every workload is Ready and every VaultStaticSecret is Synced:

```sh
kubectl -n argocd patch application aireye-cluster --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

## End-to-end verification

```sh
kubectl -n infra get vaultstaticsecret
kubectl -n infra get pods
kubectl -n infra exec vault-0    -- vault status
kubectl -n infra exec postgres-0 -- psql -U postgres -c '\l'
kubectl -n infra exec redis-0    -- sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
kubectl -n infra exec minio-0    -- curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:9000/minio/health/ready
kubectl -n argocd get application
```

For SSO: open Vault, ArgoCD, MinIO console, and LiteLLM UIs and confirm
the Keycloak login round-trip works on each.

## What does not recover

| What | Why | Mitigation |
|---|---|---|
| MinIO bucket contents | No off-cluster copy | App recreates empty buckets on first use; persistent objects must be re-uploaded |
| LiteLLM teams / users / keys | DB tables wiped | Recreate via `/team/new`, `/key/generate`, `/team/member_add` (master key only) |
| Per-host TLS Secrets (`aireye-app-tls`, `keycloak-tls`, `minio-tls`, `litellm-tls`) | Not managed by VSO, not in git | Re-create from Cloudflare Origin Cert per [cloudflare-proxy.md](cloudflare-proxy.md) |
| Vault root token / unseal key (the old ones) | New init produces new keys | Save the new ones from §5 |

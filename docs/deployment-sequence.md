# Deployment Sequence

End-to-end order for a fresh cluster.

## At A Glance

```text
manual:  ingress-nginx -> CF Origin Cert Secrets -> migrate-vault-secrets.sh -> root kustomize -> argocd -> argocd apps
gitops:  ArgoCD reconciles root path "." on every commit
```

## Manual Bootstrap

### 1. Cluster Prereqs

```sh
kubectl apply -k ingress-nginx
```

Then follow [cloudflare-proxy.md](cloudflare-proxy.md) to create the TLS
Secrets referenced by the ingresses.

### 2. Vault Values

Populate Vault KV-v2 under the per-app subpaths before syncing. Each
subpath maps to one app code:

| App Code | Vault Path | Keys |
|----------|-----------|------|
| VAULT | `secret/aireye-cluster/vault` | `VAULT_PG_CONNECTION_URL` |
| PG | `secret/aireye-cluster/pg` | `PG_USER`, `PG_PASSWORD`, `PG_DB` |
| REDIS | `secret/aireye-cluster/redis` | `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` |
| MINIO | `secret/aireye-cluster/minio` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` |
| KC | `secret/aireye-cluster/kc` | `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD`, `KC_GITOPS_*`, `KC_USER_*`, `KC_DB`, `KC_DB_URL`, `KC_DB_USERNAME` |
| OIDC | `secret/aireye-cluster/oidc` | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` |
| ARGO | `secret/aireye-cluster/argo` | `username`, `password` (git creds) |
| LITELLM | `secret/aireye-cluster/litellm` | `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_DATABASE_URL`, provider API keys |
| LANGFUSE | `secret/aireye-cluster/langfuse` | `LANGFUSE_NEXTAUTH_SECRET`, `LANGFUSE_SALT`, `LANGFUSE_ENCRYPTION_KEY`, `LANGFUSE_CLICKHOUSE_PASSWORD`, `LANGFUSE_S3_*`, `LANGFUSE_INIT_PROJECT_*` |
| APP | `secret/aireye-cluster/app` | AirEye backend keys including `REDIS_URL` |

The migration script populates all subpaths from the old flat path. On
a fresh cluster, populate the subpaths directly.

After `REDIS_PASSWORD` exists in `secret/aireye-cluster/redis`, derive
the Redis URL and patch the app path:

```sh
./scripts/add-aireye-redis-url.sh
```

See [argocd-image-updater.md](argocd-image-updater.md) for `secret/aireye-cluster/argo`.

### 3. Root Manifests

```sh
kubectl apply -k .
```

This installs the VSO custom resources, Postgres, Redis, Keycloak, MinIO,
`aireye-app`, and LiteLLM. The VSO controller is installed by the ArgoCD
Application in step 5.

### 4. ArgoCD

```sh
kubectl apply --server-side=true --force-conflicts -k argocd
kubectl apply -k argocd/applications
```

The first command installs ArgoCD itself. The second creates the self-managed
`aireye-cluster` Application and the `vault-secrets-operator` Application.

⚠️ After pushing Phase B to git: `argocd/` is NOT managed by any Application
— run `kubectl apply --server-side -k argocd` manually before deleting old
Vault paths to keep the ArgoCD VSS refreshing.

## ArgoCD Waves

| Wave | Resource | File | Why |
|------|----------|------|-----|
| `-1` | `Application/vault-secrets-operator` | `argocd/applications/vault-secrets-operator.yaml` | VSO before secret sync |
| `0` | `Application/argocd-image-updater` | `argocd/applications/argocd-image-updater.yaml` | Installs Image Updater beside ArgoCD Applications |
| `0` | `VaultStaticSecret/vault-secret` | `vault-secrets-operator/vault-secret.yaml` | Vault PGURL Secret |
| `0` | `VaultStaticSecret/pg-secret` | `vault-secrets-operator/pg-secret.yaml` | Postgres credentials |
| `0` | `VaultStaticSecret/redis-secret` | `vault-secrets-operator/redis-secret.yaml` | Redis credentials |
| `0` | `VaultStaticSecret/minio-secret` | `vault-secrets-operator/minio-secret.yaml` | MinIO credentials |
| `0` | `VaultStaticSecret/kc-secret` | `vault-secrets-operator/kc-secret.yaml` | Keycloak bootstrap |
| `0` | `VaultStaticSecret/oidc-secret` | `vault-secrets-operator/oidc-secret.yaml` | Shared OIDC client |
| `0` | `VaultStaticSecret/litellm-oidc-secret` | `vault-secrets-operator/litellm-oidc-secret.yaml` | LiteLLM GENERIC_* OIDC |
| `0` | `VaultStaticSecret/aireye-app-secret` | `vault-secrets-operator/aireye-app-secret.yaml` | App Secret |
| `0` | `VaultStaticSecret/litellm-secret` | `vault-secrets-operator/litellm-secret.yaml` | LiteLLM runtime Secret |
| `0` | Infrastructure and Services | component dirs | Default wave |
| `5` | `Job/litellm-postgres-init` | `litellm/postgres-init-job.yaml` | Creates the LiteLLM DB in existing Postgres |
| `10` | `Job/keycloak-bootstrap` | `keycloak/bootstrap-job.yaml` | Registers OIDC clients after Keycloak is up |
| `10` | `Deployment/aireye-app` | `aireye-app/deployment.yaml` | Starts after runtime Secrets are available |
| `10` | `Deployment/litellm` | `litellm/deployment.yaml` | Starts after DB init and `litellm-secret` |

## Verification

```sh
kubectl -n infra get vaultstaticsecret
kubectl -n infra get secret litellm-secret
kubectl -n infra rollout status deploy/litellm
curl -I https://litellm.lowjungxuan.dpdns.org/ui
curl -s https://litellm.lowjungxuan.dpdns.org/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

For SSO, open `https://litellm.lowjungxuan.dpdns.org/ui` and use the SSO login
button. Keycloak must allow redirect URI
`https://litellm.lowjungxuan.dpdns.org/sso/callback`.

## Re-runnable Jobs

Bootstrap Jobs (`keycloak-bootstrap`, `litellm-postgres-init`, and the
other `*-init` / `*-bootstrap` resources) run as ArgoCD Hooks with
`hook-delete-policy: BeforeHookCreation,HookSucceeded`. ArgoCD deletes and
recreates the Job before each sync instead of patching immutable
`Job.spec.template` fields (which would stay OutOfSync forever).

Do **not** add `Force=true,Replace=true` to these Jobs. That pattern
reintroduces OutOfSync churn and risks accidental PVC replacement on
unrelated resources when combined with `--force`.

LiteLLM intentionally does not use VSO rollout restarts. Its startup path runs
Prisma migrations, so repeated secret-refresh restarts can prevent the server
from reaching port `4000`.

## Tear-down Order

1. `kubectl delete -k argocd/applications`
2. `kubectl delete -k argocd`
3. `kubectl delete -k .`
4. Delete manually created runtime Secrets and namespaces if they are no
   longer needed.

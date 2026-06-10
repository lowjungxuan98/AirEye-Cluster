# Architecture

Single-cluster GitOps stack. Application workloads live in `infra`; ArgoCD
lives in `argocd`. Vault is the source of truth for runtime secrets, and VSO
syncs selected values into Kubernetes Secrets.

## Components

| Layer | Component | Role |
|-------|-----------|------|
| Network | ingress-nginx | Cluster ingress, hostNetwork |
| TLS | Cloudflare proxy | Edge TLS + Origin Certificate |
| Data | postgres | Keycloak and LiteLLM database |
| Cache | redis | ArgoCD state cache and LiteLLM cache |
| Identity | keycloak | OIDC IdP for ArgoCD and MinIO |
| Secrets | Vault + VSO | Sync per-app subpaths into per-app Kubernetes Secrets |
| Storage | minio | S3-compatible object store + console |
| GitOps | argocd | Reconciles this repo into the cluster |
| App | aireye-app | Backend service at `api.lowjungxuan.dpdns.org` |
| AI gateway | litellm | Central OpenAI-compatible gateway at `litellm.lowjungxuan.dpdns.org` |
| Observability | langfuse | LLM tracing and evaluation |

## Trust Topology

```text
Vault secret/ (KV-v2 mount)
  |
  +-- aireye-cluster/vault    →  vault-secret       (Vault pod VAULT_PG_CONNECTION_URL)
  +-- aireye-cluster/pg       →  pg-secret          (Postgres / Keycloak DB password)
  +-- aireye-cluster/redis    →  redis-secret        (Redis / ArgoCD / LiteLLM / Langfuse)
  +-- aireye-cluster/minio    →  minio-secret        (MinIO root creds + init jobs)
  +-- aireye-cluster/kc       →  kc-secret           (Keycloak bootstrap + DB config)
  +-- aireye-cluster/oidc     →  oidc-secret         (Shared OIDC client)
  |                           →  argocd-keycloak-oidc (ArgoCD OIDC clientSecret)
  |                           →  langfuse-keycloak-oidc
  |                           →  litellm-oidc-secret  (GENERIC_* vars)
  +-- aireye-cluster/litellm  →  litellm-secret      (LiteLLM keys + AI provider keys)
  +-- aireye-cluster/langfuse →  langfuse-secret     (Langfuse Helm chart keys)
  +-- aireye-cluster/argo     →  argocd-image-updater-git-creds
  +-- aireye-cluster/app      →  aireye-app-secret   (AirEye backend app keys)
  +-- aireye-genai-secret     →  aireye-genai-secret (AirEye GenAI app keys)
```

Each app code maps to exactly one Vault subpath and one Kubernetes Secret:

| App Code | Vault Path | K8s Secret |
|----------|-----------|------------|
| VAULT | `aireye-cluster/vault` | `vault-secret` |
| PG | `aireye-cluster/pg` | `pg-secret` |
| REDIS | `aireye-cluster/redis` | `redis-secret` |
| MINIO | `aireye-cluster/minio` | `minio-secret` |
| KC | `aireye-cluster/kc` | `kc-secret` |
| OIDC | `aireye-cluster/oidc` | `oidc-secret` (+ per-consumer transforms) |
| ARGO | `aireye-cluster/argo` | `argocd-image-updater-git-creds` |
| LITELLM | `aireye-cluster/litellm` | `litellm-secret` |
| LANGFUSE | `aireye-cluster/langfuse` | `langfuse-secret` |
| APP | `aireye-cluster/app` | `aireye-app-secret` |

## LiteLLM

LiteLLM is the centralized AI API gateway.

- UI: `https://litellm.lowjungxuan.dpdns.org/ui`
- API: `https://litellm.lowjungxuan.dpdns.org/v1/chat/completions`
- Config: `litellm/configmap.yaml`
- Secrets: `VaultStaticSecret/litellm-secret` + `redis-secret` + `litellm-oidc-secret`
- Database: existing Postgres, database `litellm`
- Cache: existing Redis

LiteLLM Admin UI SSO is not enabled by default because the open-source/enterprise
boundary can change. The base deployment works with `LITELLM_MASTER_KEY`.
Model aliases are defined in `litellm/configmap.yaml`; provider API keys stay in
Vault and are injected through `litellm-secret`.
The SSO wiring uses LiteLLM's generic OIDC provider variables and reuses the
existing Keycloak global client credentials (from `litellm-oidc-secret`).

## Bootstrap Order

1. Apply `ingress-nginx`.
2. Install Cloudflare Origin Cert TLS Secrets.
3. Run `scripts/migrate-vault-secrets.sh` to populate Vault subpaths and
   pre-create `vault-secret`.
4. Apply the root kustomization.
5. Apply `argocd`.
6. Apply `argocd/applications`.
7. ArgoCD reconciles the root path from then on.

## Sync Waves

| Wave | Resource | Why |
|------|----------|-----|
| -1 | `Application/vault-secrets-operator` | VSO CRDs and controller before secret sync |
| 0 | `VaultStaticSecret/*` | Runtime Secrets before consumers |
| 0 | Infrastructure and Services | Default wave |
| 5 | `Job/litellm-postgres-init` | Creates DB in existing Postgres |
| 10 | `Job/keycloak-bootstrap` | Needs Keycloak running before registering clients |
| 10 | `Deployment/aireye-app` | Starts after runtime Secrets are present |
| 10 | `Deployment/litellm` | Starts after DB init and `litellm-secret` |

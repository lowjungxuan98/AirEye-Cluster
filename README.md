# AirEye-Cluster

GitOps Kubernetes deployment platform for document workflow applications —
single-cluster ArgoCD with Kustomize, Vault-secured, Cloudflare-proxied.

- Architecture overview: [docs/architecture.md](docs/architecture.md)
- Deployment order: [docs/deployment-sequence.md](docs/deployment-sequence.md)
- Cloudflare proxy + Origin Cert TLS: [docs/cloudflare-proxy.md](docs/cloudflare-proxy.md)
- Disaster recovery: [docs/disaster-recovery.md](docs/disaster-recovery.md)

## Overview

AirEye-Cluster is a practical GitOps deployment platform managing the
infrastructure layer for a personal Kubernetes cluster. It uses ArgoCD for
continuous reconciliation, Kustomize for manifest composition, and
HashiCorp Vault with Vault Secrets Operator (VSO) for runtime secret
management.

This is a working demonstration of GitOps patterns suitable for a software
engineering portfolio: secret management, identity integration, object
storage, AI gateway proxying, and multi-component orchestration on a single
node. It is not an enterprise production platform.

## Relationship with AirEye

| Repository | Role |
|------------|------|
| **AirEye** (application repo) | Mobile/backend document workflow application — code, business logic, API |
| **AirEye-Cluster** (this repo) | Deployment and infrastructure layer — Kubernetes manifests, ingress, secrets wiring, database provisioning, supporting services |

The AirEye application repo produces container images published to
GitHub Container Registry. This repo deploys them via ArgoCD alongside the
supporting platform services.

## Architecture

A single-node cluster running all workloads in the `infra` namespace, fronted
by Cloudflare proxy with Origin Certificate TLS. ArgoCD watches the `main`
branch of this repository and reconciles state through sync-wave ordering.

See [docs/architecture.md](docs/architecture.md) for the component topology,
trust diagram, and sync wave rationale.

## Platform Components

| Component | Purpose | Source |
|-----------|---------|--------|
| ingress-nginx | Cluster ingress, hostNetwork | Upstream baremetal manifest |
| postgres | Database for Keycloak, Vault, LiteLLM, Langfuse | `postgres:18-alpine` |
| redis | Cache for ArgoCD, LiteLLM, Langfuse | `redis:8-alpine` |
| keycloak | Identity provider, OIDC for all services | `quay.io/keycloak/keycloak:26.6.1` |
| vault | Secrets backend (Postgres storage) | Helm chart `hashicorp/vault:2.0.0` |
| vault-secrets-operator | Sync Vault secrets into Kubernetes | Helm chart `vault-secrets-operator@1.4.0` |
| minio | S3-compatible object storage | `quay.io/minio/minio` (pinned `RELEASE.2025-09-07T16-13-09Z`) |
| argocd | GitOps controller | Upstream manifest `v3.4.1` |
| aireye-app | Application backend (AirEye) | `ghcr.io/lowjungxuan98/aireye/backend` |
| argocd-image-updater | Automatically updates pinned AirEye backend image tags in Git | `quay.io/argoprojlabs/argocd-image-updater` |
| litellm | Centralized AI API gateway | `ghcr.io/berriai/litellm:v1.83.14-stable.patch.3` |
| langfuse | LLM observability and tracing | Helm chart `langfuse:1.5.31` from upstream |

### Langfuse

[Langfuse](https://langfuse.com) provides LLM observability — tracing,
evaluation, and prompt management — for the LiteLLM gateway. Its deployment
is split: the ArgoCD Application (`argocd/applications/langfuse.yaml`) sources
the upstream Helm chart (including ClickHouse for analytics storage), while
the `langfuse/` directory in this repo provides VSO-managed secrets and
Postgres/MinIO init Jobs. The pre-initialized `air_eye` org and `LiteLLM`
project receive traces from LiteLLM callbacks automatically.

## Folder Structure

```text
.
├── argocd/                 # ArgoCD install, patches, ingress, and Applications
├── docs/                   # Architecture and operations documentation
├── aireye-app/             # Backend Deployment, Service, Ingress
├── ingress-nginx/          # Manually bootstrapped ingress controller
├── keycloak/               # Deployment, Service, Ingress, bootstrap Job
├── langfuse/               # VSO secrets and init Jobs (Helm chart deployed by ArgoCD Application)
├── litellm/                # LiteLLM Deployment, config, DB init, Service, Ingress
├── minio/                  # StatefulSet, console, Services, Ingress
├── postgres/               # StatefulSet, Service, PVC, init ConfigMap
├── redis/                  # StatefulSet, Service, PVC, smoke test
├── vault-secrets-operator/ # VaultConnection, VaultAuth, VaultStaticSecret resources
├── scripts/                # Local validation and cluster check scripts
├── namespace.yaml
└── kustomization.yaml      # ArgoCD root app entrypoint
```

## GitOps Workflow

ArgoCD reconciles this repository from `main`. Applications are defined
under `argocd/applications/`:

| Application | Sync Wave | Source |
|-------------|-----------|--------|
| `vault` | -2 | Helm chart (`hashicorp/vault`) + local `vault/` path |
| `vault-secrets-operator` | -1 | Helm chart (`vault-secrets-operator`) |
| `argocd-image-updater` | 0 | Local `argocd/image-updater/` path |
| `langfuse` | 1 | Helm chart (`langfuse/langfuse-k8s`) + local `langfuse/` path |
| `aireye-cluster` | 0+ | This repo root (`kustomization.yaml`) |

The root `aireye-cluster` Application manages all infrastructure and
workloads in the `infra` namespace through sync waves:

```text
wave -2  Application/vault                (Helm + local bootstrap/auth/unseal)
wave -1  Application/vault-secrets-operator
wave  0  Application/argocd-image-updater (controller + ImageUpdater CR)
wave  1  Application/langfuse             (Helm chart + init Jobs)
wave  0  VaultStaticSecret/server-secret, aireye-app-secret, litellm-secret
wave  0  infrastructure and services
wave  5  Hook(Sync)/litellm-postgres-init
wave 10  Deployment/aireye-app
wave 10  Deployment/litellm
PostSync Hook/keycloak-bootstrap, Hook/redis-smoke-test,
         Hook/vault-bootstrap (wave 0), Hook/vault-auth-config (wave 1)
```

Bootstrap-style Jobs run as ArgoCD Hooks (`PostSync` or `Sync`) with
`hook-delete-policy: BeforeHookCreation` instead of tracked resources with
`Replace=true`. This eliminates the OutOfSync churn that previously fired
on every reconcile.

## Deployment Sequence

See [docs/deployment-sequence.md](docs/deployment-sequence.md) for the
end-to-end bootstrap procedure, sync wave details, and teardown order.

## Bootstrap Order

```sh
# 1. Cluster ingress.
kubectl apply -k ingress-nginx

# 2. Install Cloudflare Origin Cert TLS Secrets (incl. vault-tls).
# See docs/cloudflare-proxy.md.

# 3. Pre-create the bootstrap secret with the Vault Postgres URL.
# ArgoCD's vault app cannot start without this key, since the
# Vault StatefulSet reads VAULT_PG_CONNECTION_URL from server-secret.
kubectl create namespace infra
kubectl create secret generic -n infra server-secret \
  --from-literal=VAULT_PG_CONNECTION_URL='postgresql://...'

# 4. Bootstrap ArgoCD and the self-managed Applications.
# ArgoCD will then deploy in sync-wave order:
#   wave -2  Application/vault          (Helm chart + bootstrap/auth-config Jobs + auto-unseal CronJob)
#   wave -1  Application/vault-secrets-operator
#   wave 0+  Application/aireye-cluster       (everything else)
kubectl apply --server-side=true --force-conflicts -k argocd
kubectl apply -k argocd/applications
```

`vault-bootstrap-secret` (Vault unseal key + root token) is created by the
`vault-bootstrap` Job on first sync and stays out of Git. The
`vault-auto-unseal` CronJob re-unseals Vault after pod restarts.

## Secrets and Security Model

Runtime secrets live exclusively in HashiCorp Vault and are synced into
Kubernetes Secrets by Vault Secrets Operator. No real secret values enter
this repository.

The Vault convention is KV-v2 mount `secret`. Three paths are used:

| Vault Path | VSO Destination | Consumers |
|------------|-----------------|-----------|
| `secret/aireye-cluster` | `server-secret`, `litellm-secret` | Postgres, Redis, MinIO, Keycloak, ArgoCD OIDC, LiteLLM, Langfuse |
| `secret/aireye-app-secret` | `aireye-app-secret` | aireye-app backend |
| `secret/langfuse-secret` | `langfuse-secret` | Langfuse |

### Required Vault Keys

LiteLLM requires:

```text
LITELLM_MASTER_KEY          # must start with sk-
LITELLM_SALT_KEY            # persistent value; do not rotate automatically
DATABASE_URL                # postgresql://<user>:<password>@postgres.infra.svc.cluster.local:5432/litellm
REDIS_HOST                  # redis.infra.svc.cluster.local
REDIS_PORT                  # 6379
REDIS_PASSWORD
OPENAI_API_KEY
DEEPSEEK_API_KEY
OPENROUTER_API_KEY
NVIDIA_NIM_API_KEY
```

LiteLLM SSO reuses the existing global Keycloak client values from
`OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`. VSO maps them into LiteLLM's
`GENERIC_CLIENT_ID` and `GENERIC_CLIENT_SECRET` keys and adds the Keycloak OIDC
endpoints.

The existing platform keys for Postgres, Redis, Keycloak, MinIO, ArgoCD, and
`aireye-app-secret` are still required by their respective workloads.

AirEye backend requires `REDIS_URL` at `secret/aireye-app-secret`. The backend
Deployment imports that Vault-synced Secret through `envFrom`, so adding the
key to Vault makes it available as an environment variable:

```text
REDIS_URL                   # redis://:<url-encoded REDIS_PASSWORD>@redis.infra.svc.cluster.local:6379/0
```

To derive it from the shared Redis password and patch the app Vault path:

```sh
./scripts/add-aireye-redis-url.sh
```

Langfuse requires additional keys at `secret/langfuse-secret` (NEXTAUTH_SECRET,
SALT, ENCRYPTION_KEY, LANGFUSE_INIT_PROJECT_PUBLIC_KEY,
LANGFUSE_INIT_PROJECT_SECRET_KEY, CLICKHOUSE_PASSWORD, S3_ACCESS_KEY_ID,
S3_SECRET_ACCESS_KEY) and `langfuse-keycloak-oidc` (Keycloak OIDC client
credentials). See `argocd/applications/langfuse.yaml` for the full schema.

## Responsible Use

This platform is designed for **legitimate document workflow services**:
document intake, transformation, storage, and retrieval through authenticated
APIs.

It is not intended for and must not be used for:

- Surveillance or hidden capture of user data
- Unauthorized data collection or exfiltration
- Credential theft, token harvesting, or permission bypassing
- Anti-detection or obfuscation workloads
- Any purpose that violates applicable laws or provider terms of service

AI gateway (LiteLLM) usage must comply with each upstream provider's terms of
service. No user data is collected by this infrastructure layer itself — data
handling is determined by the application layer.

## Validation

```sh
bash scripts/validate.sh
```

The script renders the root, `argocd`, and `argocd/applications`
entrypoints, then runs `yamllint` and `kubeconform` when installed.

Before or after a cluster sync, check ArgoCD, Vault Secrets Operator, and hook
Job health:

```sh
bash scripts/check-cluster-sync.sh
```

## Roadmap

Practical scenarios for extending this platform:

- **Document intake pipeline** — ingest scanned documents (PDF/images) through
  the AirEye backend, store in MinIO, index metadata in Postgres
- **Prompt-based document transformation** — LiteLLM-routed model calls for
  summarization, classification, or structured extraction from ingested
  documents
- **Langfuse observability** — surface LLM call quality metrics (latency, cost,
  token usage) from Langfuse trace data
- **Gateway API migration** — evaluate replacing ingress-nginx with Gateway API
  as ingress-nginx approaches archival (per upstream notes)
- **Off-cluster backups** — add pg_dump CronJob or Velero for Postgres and
  MinIO data (see [docs/disaster-recovery.md](docs/disaster-recovery.md))
- **Multi-tenant OIDC** — extend Keycloak realms for isolated application
  tenants

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for manifest guidelines, validation
requirements, and pull request expectations.

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability disclosure process and
security scope.

## Hosts

| Host | Service |
|------|---------|
| `argocd.lowjungxuan.dpdns.org` | ArgoCD UI |
| `keycloak.lowjungxuan.dpdns.org` | Keycloak |
| `vault.lowjungxuan.dpdns.org` | Vault UI |
| `minio.lowjungxuan.dpdns.org` | MinIO console |
| `s3.lowjungxuan.dpdns.org` | MinIO S3 API |
| `api.lowjungxuan.dpdns.org` | aireye-app backend |
| `litellm.lowjungxuan.dpdns.org` | LiteLLM UI/API |
| `langfuse.lowjungxuan.dpdns.org` | Langfuse UI |

## LiteLLM Verification

```sh
kubectl -n infra get vaultstaticsecret litellm-secret
kubectl -n infra get secret litellm-secret
kubectl -n infra rollout status deploy/litellm
curl -I https://litellm.lowjungxuan.dpdns.org/ui
curl -s https://litellm.lowjungxuan.dpdns.org/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

The UI is available at `https://litellm.lowjungxuan.dpdns.org/ui`. The OpenAI
compatible API is available at
`https://litellm.lowjungxuan.dpdns.org/v1/chat/completions`.
SSO uses `https://litellm.lowjungxuan.dpdns.org/sso/callback`; fallback
username/password login remains available at `/fallback/login`.

The initial model aliases in `litellm/configmap.yaml` are editable defaults.
Update the provider model names there when you choose the exact OpenAI,
DeepSeek, OpenRouter, and NVIDIA NIM models to expose.

## Conventions

- All workload resources land in `infra`; ArgoCD itself lives in `argocd`.
- Real secret values never enter git.
- LiteLLM model aliases live in `litellm/configmap.yaml`; provider keys come
  only from Vault/VSO.
- LiteLLM does not use VSO rollout restarts because startup runs Prisma
  migrations; restart it manually after changing LiteLLM secrets.
- Root kustomize adds the common `app.kubernetes.io/part-of` and
  `app.kubernetes.io/managed-by` labels.
- Root kustomize adds control-plane tolerations for workloads.

## Upstream Notes

- MinIO open-source archived 2026-04-25. Docker images stopped publishing
  after `RELEASE.2025-09-07T16-13-09Z`; this repo pins that release.
- ingress-nginx plans to archive after KubeCon 2026; consider Gateway API
  migration in the future.

## Operations Notes

- **Keycloak `master` realm Access Token Lifespan**: set to at least 5
  minutes. Sub-minute lifespans cause `argocd-server` to log
  `oidc: token is expired` ~10x/second from browser Watch streams. Sync
  itself is unaffected (the controller uses a Kubernetes SA token, not OIDC).
- **`aireye-app` uses a pinned backend image tag** with `imagePullPolicy: Always`. Pods do not
  auto-restart on a new image push; update `aireye-app/deployment.yaml` and let ArgoCD sync it
  to pick up a new image digest.

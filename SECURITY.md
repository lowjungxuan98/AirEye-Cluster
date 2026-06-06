# Security Policy

## Supported Versions

Only the `main` branch is actively maintained. This is a single-cluster
deployment platform — there are no versioned releases or backport branches.

## Scope

This policy covers the Kubernetes manifests, ArgoCD Application definitions,
Vault Secrets Operator configuration, ingress rules, and deployment topology in
this repository.

Out of scope: vulnerabilities in upstream projects (ingress-nginx, Vault,
Keycloak, MinIO, LiteLLM, Langfuse) should be reported to those projects
directly. Issues in the AirEye application codebase belong in the AirEye
application repository.

## What to Report

Areas of concern relevant to this repository:

- **Kubernetes RBAC and pod security.** Overly permissive ServiceAccounts,
  missing security contexts, or privilege escalation paths.
- **Vault / VSO misconfiguration.** Overly broad Vault policies,
  unauthenticated paths, or VaultStaticSecrets that expose sensitive values
  outside their intended consumers.
- **Secret leakage.** Real secrets, tokens, or API keys committed to this
  repository. VaultStaticSecret templates that inadvertently log or expose
  secret material.
- **Public ingress exposure.** Services unintentionally reachable without TLS,
  Cloudflare proxy, or authentication.
- **Object storage access.** MinIO buckets or IAM policies that allow
  unauthenticated or unintended access.
- **OIDC / Keycloak.** Misconfigured redirect URIs, client secret exposure, or
  authentication bypass risks.
- **LiteLLM provider keys.** Keys exposed in logs, ConfigMaps, VSO templates,
  or `envFrom` secret references that leak to sidecars.

## Vulnerability Disclosure

**Do not open a public issue if it would expose sensitive details about an
active vulnerability.**

Report security issues directly to **lowjungxuan@gmail.com**. Please include:

- A description of the issue and its potential impact
- Steps to reproduce, if applicable
- Affected file paths or component names

You will receive an acknowledgment within **5 business days**. The project
targets a **30-day** remediation timeline for confirmed issues, depending on
severity and complexity.

## Secrets Hygiene

- Real secret values must never be committed to this repository.
- The required Vault keys documented in the README are template names only —
  their actual values live exclusively in Vault.
- Use `scripts/validate.sh` to catch YAML rendering issues that could
  accidentally expose secrets.

## Dependency Security

This repository does not vendor dependencies. Container images and Helm charts
are pinned by tag or digest in their respective Kustomization or ArgoCD
Application files. Upstream images are pulled from:

- GitHub Container Registry (ghcr.io)
- Docker Hub (library/postgres, library/redis)
- Quay.io (quay.io/keycloak, quay.io/minio)
- HashiCorp Helm repository (vault, vault-secrets-operator)
- Langfuse Helm repository (langfuse)

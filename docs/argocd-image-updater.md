# Argo CD Image Updater

AirEye backend image updates are managed by Argo CD Image Updater.

## Implementation

- `argocd/applications/argocd-image-updater.yaml` creates the Image Updater ArgoCD Application.
- `argocd/image-updater/` installs the upstream controller into the `argocd` namespace.
- `argocd/image-updater/image-updater.yaml` watches the `aireye-cluster` Application for `ghcr.io/lowjungxuan98/aireye/backend`.
- Updates use the `semver` strategy and only accept numeric tags such as `0.2.12`.
- Git write-back updates the root `kustomization.yaml` `images` stanza on `main`.

## Vault Secret First

Create this Vault KV-v2 secret before syncing the Image Updater app:

```sh
vault kv put secret/aireye-cluster/argo \
  username=lowjungxuan98 \
  password=<github-token-with-repo-write-access>
```

VSO syncs that path into the `argocd` namespace as
`Secret/argocd-image-updater-git-creds`. The secret must contain `username` and
`password` because Image Updater's Git write-back uses HTTPS Git credentials.

## Sequence

1. Ensure `secret/argocd-image-updater-git-creds` exists in Vault.
2. Sync or apply `argocd/applications`.
3. Wait for `Application/argocd-image-updater` to be Healthy/Synced.
4. Confirm `VaultStaticSecret/argocd-image-updater-git-creds` is synced.
5. Confirm `ImageUpdater/aireye-app` is Ready.

Useful checks:

```sh
kubectl -n argocd get application argocd-image-updater
kubectl -n argocd get vaultstaticsecret argocd-image-updater-git-creds
kubectl -n argocd get secret argocd-image-updater-git-creds
kubectl -n argocd get imageupdater aireye-app -o yaml
kubectl -n argocd logs deploy/argocd-image-updater-controller
```

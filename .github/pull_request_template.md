## Summary

<!-- One paragraph describing the change and why. -->

## Changed Components

<!-- Check all that apply. -->

- [ ] ingress-nginx
- [ ] postgres
- [ ] redis
- [ ] keycloak
- [ ] vault / vault-secrets-operator
- [ ] minio
- [ ] argocd
- [ ] aireye-app
- [ ] litellm
- [ ] langfuse
- [ ] docs / scripts

## Deployment Impact

<!-- Which sync waves change? Is bootstrap order affected? Do existing workloads restart? -->

## Secret and Config Impact

<!-- New Vault paths? New VSO templates? New ConfigMap keys? Do existing secrets need a manual update? -->

## Validation Performed

<!-- What tests or checks were run? -->

- [ ] `bash scripts/validate.sh` passes
- [ ] `bash scripts/check-cluster-sync.sh` passes (if cluster access available)
- [ ] Manual testing notes (if applicable):

## Rollback Notes

<!-- How to revert safely. E.g., `git revert`, `kubectl rollout undo`, manual secret restore. -->

## Security and Privacy Checklist

- [ ] No secrets, tokens, or API keys in the diff
- [ ] No hardcoded credentials in ConfigMaps or env vars
- [ ] All ingresses require TLS
- [ ] Authentication is enforced where applicable
- [ ] Provider API keys are sourced from Vault only

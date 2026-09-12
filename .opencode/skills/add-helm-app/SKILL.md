---
name: add-helm-app
description: Add a new Helm release to the GitOps platform following the established pattern
---

## What I do
1. Add chart to `gen-helm-apps-full.sh` in the `charts` array
2. Set target namespace in the `NS` associative array
3. Run `./gen-helm-apps-full.sh` to generate `helm/apps/<app>.yaml`
4. Create `helm/releases/<name>/values.yaml` with initial overrides
5. Map secrets to ExternalSecrets → Vault (never commit plaintext)
6. Commit and push to main

## Key conventions
- Each app gets its own namespace (except orchestrator stuff)
- `helm/releases/<app>/values.yaml` is the primary values override path
- ArgoCD app name = helm release name
- Use `CreateNamespace` in AppProject, so AppProject auto-creates namespaces
- All secrets via ExternalSecrets → HashiCorp Vault

## When to use me
Use this skill when the user wants to onboard a new Helm chart to the platform.
Ask for: chart name, repo URL, target namespace, whether it needs ExternalSecrets.

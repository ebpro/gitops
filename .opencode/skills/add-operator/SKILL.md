---
name: add-operator
description: Onboard a new Kubernetes operator to the platform via ArgoCD Helm ApplicationSet
---

## What I do
1. Identify the operator's Helm chart (repo URL, chart name, version)
2. Add entry to `bootstrap/appset-helm.yaml` in the `list.elements` array
3. Set target namespace (usually `<operator>-system`)
4. Create `bootstrap/helm-values/<operator>.yaml` for external value overrides
5. If it creates CRDs, verify sync-wave ordering (CRDs before resources, usually wave 10)
6. Update `infrastructure/README.md` operator stack table
7. Commit and push to main

## Key conventions
- Operators go into `bootstrap/appset-helm.yaml` (list generator)
- External value files live in `bootstrap/helm-values/` and are referenced via raw GitHub URLs
- Sync waves: `10` = CRDs/core, `15` = foundations, `20` = apps, `25` = upgrades/managed
- All args/revert patches, `argocd.argoproj.io/sync-wave` annotation in metadata

## When to use me
Use when adding KEDA, VPA, Goldilocks, Descheduler, Crossplane, Falco, or any other controller/operator to the GitOps repo.

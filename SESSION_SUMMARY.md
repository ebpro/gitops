## Objective
- Get ArgoCD health evaluation working for CNPG `Cluster` resources so `postgresql-manifests` app shows `Healthy`/`Degraded` instead of `N/A`

## Important Details
- ArgoCD v3.4.5 has built-in resource_customizations directory embedded in the binary
- Custom health.lua override in `argocd-cmd-params-cm` with `postgresql.cnpg.io.v1/Cluster` key, `hs = { status = "Healthy" }` minimal Lua script)
- **Core blocker**: `"Ignore status for all objects"` log persists during reconciliation even after `resource.customizations.ignoreResourceUpdates.all` was removed from live `argocd-cm` — ArgoCD cluster-install defaults persist this key re-inject on every sync
- Even a zero-code Lua script (`hs = { status = "Healthy", message = "TEST"`) returns `health={}` — Lua script appears to NEVER execute for CNPG Cluster GVK
- Split-key format `resource.customizations/health.postgresql.cnpg.io.v1.Cluster` in `argocd-cm` is present but has no effect
- `argocd-cmd-params-cm` health scripts work for other GVKs (ExternalSecret, CRD, ClusterRole) but NOT CNPG Cluster
- CNPG Cluster CRD is `postgresql.cnpg.io.v1`, controller watches `Cluster.postgresql.cnpg.io`
- `"Ignore status for all objects"` originates from hardcoded ArgoCD defaults merged at controller startup, not from our ConfigMap data

## Work State
### Completed
- Removed `/status` from app-level `ignoreDifferences` in `app-postgresql.yaml`
- Removed legacy CNPG health.lua override from `argocd-cm.yaml`
- Added nil-guarded CNPG health.lua to `argocd-cmd-params-cm` overlay (`if obj == nil` -> Progressing)
- Added split-key CNPG health.lua to `argocd-cm.yaml` overlay
- Added kustomizing JSON patch `remove-status-stripping-patch` to target `argocd-cm` and erase `ignoreResourceUpdates.all`
- Pushed all fixes to git (`main`, commits 9c72dfc, da12f65, cd6e3e3, b2e8239)
- Verified live `argocd-cm` lacks `ignoreResourceUpdates.all` key, but `"Ignore status"` still logs

### Active
- Diagnosing why ArgoCD defaults orphan `ignoreResourceUpdates.all` into merged settings
- Verifying Lua execution path: health_ms ~18ms for 8 clusters but health=`{ nil } for nil implies never evaluated
- Need to find if CNPG Cluster is blocked by `resource.exclusions`, CRD annotations, or GVK mismatch

### Blocked
- `ignoreResourceUpdates.all` persists as ArgoCD cluster-install default merged into settings
- Lua health scripts NEVER execute for CNPG `Cluster` GVK despite correct ConfigMap entries
- `resource.exclusions` in cmd-params has `postgresql.cnpg.io/ClusterConfiguration` but NOT `Cluster`

## Next Move
1. Remove `resource.customizations.health.postgresql.cnpg.io/v1/Cluster` must match the ArgoCD internal GVK normalization
2. Check: If ArgoCD normalizes strip slashes (/) to dots (.) when storing ConfigMap keys, then normalization back to slashes on lookup fails because dots are already present
3. Try the `resource.customizations.health.postgresql.cnpg.io.v1.Cluster` key in `argocd-cm` IS being loaded but Lua execution is blocked by `/status` stripping (status is nil → Lua accesses nil.status → silent error → N/A)
4. To verify Lua execution tomorrow: Add `assert(false, "LUA BUG!")` to the script and check controller logs for Lua runtime errors

## Relevant Files
- `bootstrap/app-postgresql.yaml`: CNPG Cluster `ignoreDifferences` (now without `/status`)
- `bootstrap/argocd-overlay/patches/argocd-cm.yaml`: ConfigMap overlay with CNPG split-key health.lua (likely not loading)
- `bootstrap/argocd-overlay/patches/argocd-cmd-params-cm.yaml`: Block-format health smart health.lua with nil guard
- `bootstrap/argocd-overlay/kustomization.yaml`: Adds JSON patch target for `remove-status-stripping-patch.json`
- `bootstrap/argocd-overlay/patches/remove-status-stripping-patch.json`: JSON patch to remove `ignoreResourceUpdates.all` from argocd-cm
- `util/settings/settings.go` (ArgoCD source): `NormalizeDiff` applies `ignoreResourceUpdates`, merges defaults into settings
- `util/lua/lua.go` (ArgoCD source): `GetHealthScript)` receives `obj` with `/status` stripped if `ignoreResourceUpdates` matches

# Change-set inventory (all in /mnt/hdd/home/bruno/gitops, branch main)

## CREATE
1. `kubernetes/arc/node-arm64-arch-taint.yaml` — Kyverno ClusterPolicy (full body in CONTEXT.md).
2. `kubernetes/arc/kyverno-node-mutation-rbac.yaml` — ClusterRole `kyverno:update-nodes` (full body in CONTEXT.md).

## EDIT
3. `kubernetes/arc/kustomization.yaml` — add both new files to `resources:` (currently lists
   `arc-github-creds-external-secret.yaml` + 4 CRD files, total 8 lines):
   ```yaml
     - node-arm64-arch-taint.yaml
     - kyverno-node-mutation-rbac.yaml
   ```
4. `helm/releases/arc/arm-scale-set-values.yaml` — add `tolerations:` under `template.spec`
   (sibling of `nodeSelector:`, ~line 24). Body in CONTEXT.md. Do NOT touch `listenerTemplate`
   (line 40+) or any x64 file.
5. `bootstrap/app-arc-arm-runners.yaml` — line 20 valueURL `...arm-scale-set-values.yaml?v=3` → `?v=4`
   (force ArgoCD to re-fetch the changed remote values; this repo caches raw.githubusercontent valueFiles).
6. `helm/releases/kyverno/values.yaml` — EITHER add the chart's real `config:` hook with the intended
   `resourceFilters`+`excludeGroups` (verify schema first) OR add a comment block documenting the
   one-off CM patch + exact new string. See CONTEXT.md.
7. `bootstrap/appset-helm.yaml` — if (6) modified values.yaml, bump the kyverno valueURL `?v=1` → `?v=2`
   (kyverno app is around lines 84-91).

## DOCS (recorded here; apply during implementation, not this session)
8. `docs/cluster.md` — node/taint inventory (~lines 78-80) + finding #10 (~line 623): note the taint is
   now GitOps-enforced via Kyverno `node-arm64-arch-taint`; dated resolution 2026-09-11/12.
9. `kubernetes/arc/README.md` — add taint/toleration section: Kyverno re-applies the arm64 taint,
   ARM runners tolerate it, listeners stay on x64; note VM-reboot behaviour (runners vanish, taint persists).

## COMMIT
```
git add kubernetes/arc/node-arm64-arch-taint.yaml \
        kubernetes/arc/kyverno-node-mutation-rbac.yaml \
        kubernetes/arc/kustomization.yaml \
        helm/releases/arc/arm-scale-set-values.yaml \
        bootstrap/app-arc-arm-runners.yaml \
        helm/releases/kyverno/values.yaml \
        bootstrap/appset-helm.yaml \
        docs/cluster.md kubernetes/arc/README.md
git commit -m "feat(arc): enforce arm64 node taint via Kyverno and tolerate it in ARM runner template"
git push origin main
```
Do NOT stage the stray `arm-test.yaml`, `*.backup`, `*.bak` (see GIT.md).

## AFTER PUSH — one-off Kyverno CM patch (sanctioned exception; see CONTEXT.md for exact string)
1. Read-only verify webhook catch-all on Node.
2. `kubectl patch configmap kyverno -n kyverno --type merge -p '{"data":{"resourceFilters":"<NEW STRING>"}}'`

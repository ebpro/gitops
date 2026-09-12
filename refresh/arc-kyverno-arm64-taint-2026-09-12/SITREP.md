# SITREP — ARC / Kyverno arm64 taint + runner toleration
Updated: 2026-09-12T19:22:40Z   Job working dir: /mnt/hdd/home/bruno/gitops (main)

## Goal (user directive)
Keep `kubernetes.io/arch=arm64:NoSchedule` **persistent** on the ARM node via GitOps/Kyverno
(do NOT remove the taint), and let the ARC ARM scale set `ebpro-org-arm` schedule runners on it
by **adding tolerations** to the runner template. Finish the GitOps change-set, sync, verify.

## Verified live state (evidence, read-only)
| Item | Value | Status |
|---|---|---|
| ARM node | `lima-k3s-agent` — Ready, arch arm64, taint `kubernetes.io/arch=arm64:NoSchedule` present in etcd | confirmed |
| x64 node | `compute-lsis-2` | confirmed |
| ARC x64 set | `ebpro-org` — healthy | confirmed |
| ARC ARM set | `ebpro-org-arm` — runner `ebpro-org-arm-bbq7z-runner-pgl72` **Pending** in ns `arc-runners` (missing toleration) | confirmed |
| ARC listeners | `ebpro-org-574b8f8f-listener`, `ebpro-org-arm-574b8f8f-listener` — both on `compute-lsis-2` (intentional, unchanged) | confirmed |
| Local chart | `charts/gha-runner-scale-set` passes `template.spec` through → `tolerations` supported | confirmed |
| Kyverno | Helm app `kyverno` (`bootstrap/appset-helm.yaml`), chart `kyverno-3.5.0`, valueURL `helm/releases/kyverno/values.yaml?v=1` | confirmed |
| Kyverno CM | `kyverno/kyverno`, annotated `helm.sh/resource-policy: keep`, **unmanaged by ArgoCD/Helm**, `excludeGroups: system:nodes`, `resourceFilters` contains `[Node,*,*]` + `[Node/?*,*,*]` | confirmed |
| arm-scale-set-values.yaml | has `template.spec` (nodeSelector/imagePullSecrets/containers) — **no `tolerations` yet** | confirmed |
| app-arc-arm-runners.yaml | valueURL pinned `?v=3` | confirmed |
| kyverno/values.yaml | 8 lines, **no `config:` key** | confirmed |
| kubernetes/arc/ | `node-arm64-arch-taint.yaml` and `kyverno-node-mutation-rbac.yaml` **do NOT exist** → change-set not applied | confirmed |

## Decisions (settled)
- **Option A (minimal):** only add `template.spec.tolerations` for `kubernetes.io/arch=arm64:NoSchedule`
  in `arm-scale-set-values.yaml`. Do NOT touch `listenerTemplate` or x64 values.
- **Kyverno policy** with `admission: true` + `background: true`; `validationFailureAction: Audit`.
- Remove `[Node,*,*]` from the live Kyverno ConfigMap `resourceFilters` (keeps `[Node/?*,*,*]`) so the
  admission webhook processes Nodes; keep `excludeGroups: system:nodes`. This is the ONE sanctioned
  cluster-write exception (CM is unmanaged/`keep`).
- Background Node mutation needs RBAC → ClusterRole `kyverno:update-nodes` (aggregation label).

## Done
- Full SOTA 2026 ARC audit delivered; live state + chart + Kyverno CM verified; design validated;
  every file path + exact edit identified; PR #3 green.

## Pending (the fresh session does this)
- Create policy + RBAC, wire kustomization, add toleration, bump 2 valueURLs, handle Kyverno values
  fidelity, update docs, commit, push, apply the one-off CM patch, verify sync + runner scheduling,
  revalidate PR #2.

## Blockers / risks
- No confirmed execution of the earlier `builders/implement` delegation (attempts were interrupted) —
  verified above that **no code files were actually written**, so a clean start is safe.
- Exact `kyverno-3.5.0` values hook for `resourceFilters`/`excludeGroups` **unconfirmed** → do NOT
  invent schema; verify chart, else document the one-off patch in a comment block (see CONTEXT.md).
- Kyverno aggregation label must be verified against the base background-controller ClusterRole.
- PR #2 (`ci/multiarch-native-arm64`) blocked until PR #3 merges.

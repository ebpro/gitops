# Verification checklist (read-only)

## Git
- [ ] `git log --oneline -1` == the `feat(arc): ...` commit; pushed to origin/main.
- [ ] `git status --short` clean (no stray `arm-test.yaml`/`*.bak` accidentally committed).

## ArgoCD
- [ ] `kubectl get app -n argocd -o wide | grep -Ei 'arc|kyverno'` → Synced/Healthy
      (apps: `kubernetes-arc` or equivalent manifest app, `arc-arm-runners`, `kyverno`).

## Kyverno
- [ ] `kubectl get clusterpolicy node-arm64-arch-taint -o yaml` → Ready, admission+background true.
- [ ] `kubectl get clusterrole kyverno:update-nodes -o yaml` → present, aggregation label set.
- [ ] `kubectl get cm kyverno -n kyverno -o jsonpath='{.data.resourceFilters}'`
      → does NOT contain the standalone `[Node,*,*]`; still contains `[Node/?*,*,*]`.

## Node / taint
- [ ] `kubectl get node lima-k3s-agent -o jsonpath='{.spec.taints}'` → arm64 NoSchedule present.
- [ ] (persistence proof) force a re-add: delete+let kubelet/kyverno re-apply, or observe policy logs
      mutating the Node; taint must return.

## ARC runners
- [ ] `kubectl get pods -n arc-runners -o wide` → ARM runner `Running` on `lima-k3s-agent`
      (replacing `ebpro-org-arm-bbq7z-runner-pgl72`).
- [ ] `kubectl get pods -n actions-runner-controller -o wide` → both listeners still on `compute-lsis-2`.
- [ ] `kubectl get pods -n arc-runners -l github.com/arc/scale-set-id=ebpro-org -o wide` → x64 unchanged.
- [ ] `gh api /orgs/ebpro/actions/runners/scalesets` → `ebpro-org-arm` reports 1 runner online.

## Contract/CI (parallel track)
- [ ] PR #3 merged. [ ] PR #2 rebased post-merge; Jib multi-arch matrix; `imagetools inspect`
      shows `linux/amd64` + `linux/arm64`.

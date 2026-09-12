# SOTA 2026 start prompt — copy/paste into the fresh opencode session

---
ROLE: You are finishing a GitOps task in an existing K3s + ArgoCD + Kyverno + ARC platform.
Operate evidence-first; read-only cluster inspection is allowed, cluster mutation is NOT (single
documented exception below). All changes flow through git; ArgoCD auto-syncs (prune+selfHeal).

CONTEXT FOLDER (read these first, in order):
  /home/bruno/REFRESH/arc-kyverno-arm64-taint-2026-09-12/
  1. SITREP.md    2. CONTEXT.md    3. FILES.md    4. NEXT-STEPS.md    5. CHECKLIST.md    6. GIT.md

WORKING DIR: /mnt/hdd/home/bruno/gitops   branch: main   remote: git@github.com:ebpro/gitops.git

TASK:
Keep `kubernetes.io/arch=arm64:NoSchedule` persistent on ARM node `lima-k3s-agent` by enforcing it
with a Kyverno ClusterPolicy (admission + background), and let the ARC ARM scale set `ebpro-org-arm`
schedule runners by adding a matching toleration to the runner template. Do NOT remove the taint.
Do NOT change listener placement (listeners stay on x64 `compute-lsis-2`) or x64 values.

DO FIRST:
  git -C /mnt/hdd/home/bruno/gitops checkout main && git pull --ff-only
  git -C /mnt/hdd/home/bruno/gitops status --short
  ls /mnt/hdd/home/bruno/gitops/kubernetes/arc/        # the 2 new files must be absent (clean start)

EXECUTE the change-set in FILES.md (create policy + RBAC, wire kustomization, add toleration,
bump app-arc-arm-runners.yaml ?v=3->?v=4, handle kyverno values fidelity, update docs).
Rules:
  - Verify the kyverno-3.5.0 values schema before touching helm/releases/kyverno/values.yaml.
    If no real hook controls resourceFilters/excludeGroups, document the one-off patch in a comment
    block instead of inventing a key.
  - Validate with `kubectl kustomize kubernetes/arc` before commit.
  - Commit message: feat(arc): enforce arm64 node taint via Kyverno and tolerate it in ARM runner template
  - Push to origin main. Do NOT stage stray files (arm-test.yaml, *.backup, *.bak).

SINGLE SANCTIONED CLUSTER WRITE (after merge, only if the webhook is confirmed catch-all for Node):
  kubectl patch configmap kyverno -n kyverno --type merge -p '{"data":{"resourceFilters":"<NEW STRING>"}}'
  where <NEW STRING> is the INTENDED resourceFilters in CONTEXT.md (current string minus the
  standalone `[Node,*,*]`, keeping `[Node/?*,*,*]`). This CM is `helm.sh/resource-policy: keep` and
  unmanaged, so git cannot change it. Verify webhook catch-all first (read-only).

VERIFY with CHECKLIST.md (read-only). If a sync stalls, refresh the chain:
  kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite

MULTI-AGENT: if you are a lead orchestrator, delegate the file writes to `builders/implement` with a
COMPACT, GIT-ONLY, NO-MEDIA prompt that references this folder; do all cluster checks yourself
read-only. Never dump large logs.

PARALLEL TRACK (only after PR #3 merges): revalidate ebpro/notebook-java-rest-sample-quarkus PR #2
(ci/multiarch-native-arm64) — Jib multi-arch matrix, `imagetools inspect` shows amd64+arm64.

Report back: commit SHA, ArgoCD app states, ARM runner node placement, taint persistence, and any
residual risk (Kyverno values drift, RBAC aggregation, forged-header caveats).
---

# SOTA 2026 start prompt — copy/paste into a fresh opencode session

---
ROLE: You are diagnosing/fixing a SonarQube GitOps issue on a K3s + ArgoCD + CNPG + Vault platform.
Evidence-first. Read-only cluster/ES/DB inspection is allowed; direct cluster mutation is NOT —
all fixes flow through git (ArgoCD auto-syncs main with prune+selfHeal).

CONTEXT FOLDER (read in order):
  /home/bruno/REFRESH/sonarqube-267-empty-projects-2026-09-12/
  1. SITREP.md  2. CONTEXT.md  3. FILES.md  4. NEXT-STEPS.md  5. CHECKLIST.md  6. GIT.md

WORKING DIR: /mnt/hdd/home/bruno/gitops   remote: git@github.com:ebpro/gitops.git

PROBLEM: SonarQube 26.7.0.124771 shows an EMPTY project list. API `search_projects` returns
`total:15` but `components:[]`; `projects/search` returns `total:0`. DB + ES are consistent (15 TRK
projects, UUIDs match 1:1), indices GREEN, logs clean -> failure is downstream of ES.

LEADING ROOT CAUSE (unconfirmed): version skew — Community Branch Plugin + webapp are pinned to
**26.5.0** (values.yaml lines 5/40/53/55) while the chart (2026.4.1, appset-helm.yaml line 121)
ships server **26.7.0**. The 26.5.0 javaagent/webapp predates 26.7's UUID + `auth_` shadow-doc search
model, so Web resolves 0 objects. No 26.7 plugin release exists; PR #1280 (head f47c931) is the only
26.7-compatible candidate (unmerged/unreviewed).

DO FIRST:
  git -C /mnt/hdd/home/bruno/gitops worktree list          # a concurrent session may hold the tree
  git -C /mnt/hdd/home/bruno/gitops fetch origin
  # Claim an isolated worktree + branch (do NOT switch the shared tree / never add -A / stash):
  cd /home/bruno/REFRESH && ./claim.sh sonarqube-267-empty-projects-2026-09-12 origin/main
  cd /tmp/wt-sonarqube-267-empty-projects-2026-09-12

EXECUTE (NEXT-STEPS.md):
  1. Re-derive the symptom (read-only curl via Gap-Auth:admin + ES/_count + psql count).
  2. DECISIVE TEST: render the app WITHOUT the `=web` javaagent (line 55) and WITHOUT the 26.5.0
     webapp override (line 5) via a Git change + bump appset-helm.yaml line 123 `?v=3`->`?v=4`.
     Validate with helm template / argocd diff BEFORE merging. Confirm search_projects is non-empty.
     -> this restarts the SQ pod; COORDINATE the brief outage with Bruno first.
  3. Pick the permanent fix (align server down to 26.5.x, OR adopt a 26.7-compatible plugin fork,
     OR drop the plugin) with Bruno; implement in values.yaml; open a PR; merge; verify live.

HARD RULES
  - Git-push only. Never kubectl patch/apply/delete/exec-write on ArgoCD-owned resources.
  - Isolate with a git worktree; never checkout/add -A/stash the shared primary tree.
  - Bump the valueURL `?v=` on every values.yaml change or ArgoCD keeps the stale render.
  - Publish the fix by PR to main (merge is human-coordinated); keep the handoff on preservation/* branch.
  - Redact: no secret VALUES in any file; secret NAMES and Vault paths are fine.
  - If this job references screenshots/attachments: they exceeded the provider size limit and were
    dropped — re-send smaller/fewer, or re-derive from the read-only commands above.

CLEANUP when done: cd /home/bruno/REFRESH && ./claim.sh --release sonarqube-267-empty-projects-2026-09-12

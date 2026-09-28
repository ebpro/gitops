# CHECKLIST — resume path

[ ] Read SITREP.md -> CONTEXT.md -> FILES.md -> NEXT-STEPS.md -> GIT.md (this folder).
[ ] Detect contention: `git -C /mnt/hdd/home/bruno/gitops worktree list` (a concurrent session may hold the tree).
[ ] Re-derive evidence (NEXT-STEPS step 0, read-only) to confirm 26.7 server + 26.5.0 plugin still in place.
[ ] Run the DECISIVE experiment (NEXT-STEPS step 1) — disable =web javaagent via Git, NOT kubectl.
      [ ] coordinate the SQ pod restart with Bruno first (team-wide brief outage)
      [ ] edit values.yaml (+ bump ?v=3 -> ?v=4 on appset-helm.yaml line 123)
      [ ] validate render (helm template / argocd diff) before merge
[ ] Confirm search_projects returns non-empty components -> root cause proven.
[ ] Choose the permanent fix (NEXT-STEPS step 2) with Bruno; implement in values.yaml; PR; merge; verify live.
[ ] Clean up: `./claim.sh --release sonarqube-267-empty-projects-2026-09-12` once merged/abandoned.

RULES
- Git-push only; never kubectl patch/apply/delete on ArgoCD-managed resources.
- Never `git add -A`/`checkout`/`stash` in the shared tree while another worktree is active.
- Bump the valueURL `?v=` on EVERY values.yaml change or ArgoCD keeps the old render.
- No secret values in any handoff (Gap-Auth is a header name; Vault paths are references — fine).

# REFRESH — parallel-session handoff index
Regenerated: 2026-09-12T19:2xZ (by ARC/Kyverno session)
Every SOTA-2026 handoff lives in its own subfolder here. Read the folder's own docs to resume.

| Folder | Job | Finish-in (working dir) | Git preservation | Status / next |
|---|---|---|---|---|
| `arc-kyverno-arm64-taint-2026-09-12/` | ARC/Kyverno: persist arm64 node taint + tolerate in ARM runner set | `/mnt/hdd/home/bruno/gitops` (main) | ebpro/gitops `preservation/arc-kyverno-arm64-taint-2026-09-12` @ `0c761c8`, path `refresh/…` | **Job NOT implemented** (record-only). Clean start verified (no policy/RBAC/toleration files). Fresh session: run `FILES.md`→`NEXT-STEPS.md`→`CHECKLIST.md`; then one-off Kyverno CM patch (`CONTEXT.md`). |
| `backstage-keycloak-oidc-sota2026-bruno/` | Backstage ↔ Keycloak OIDC SSO | `/mnt/hdd/home/bruno/gitops` (main); build cwd `/tmp/backstage-oidc-source-prep` | **standalone repo** → gitea `bruno/refresh-handoff-backstage-oidc.git` (main @ `579c596`) | Read its `SITREP.md` / `START-SOTA-2026.md`. |
| `link-shortener-port9000-sota2026/` | link-shortener mgmt-port 9000 drift-gate (Woodpecker CI + GitOps probe fix) | `/mnt/hdd/home/bruno/link-shortener` (`fix/drift-gate-management-port-9000`); gitops `/mnt/hdd/home/bruno/gitops` | app repo branch `docs/sota-2026-handoff` (pushed to gitea) | Gitea PR #14 open. ⚠️ **DISCREPANCY:** handoff calls GitOps fix `b5fb287` "held/unpushed" but it is **already on `origin/main`**. Re-verify rollout state before acting. |
| `opencode-sota-7a05f7b-20260912T182248Z-2100180/` | OpenCode in-cluster agent (k3s deploy, Harbor image, SSO, LiteLLM) | `/mnt/hdd/home/bruno/gitops` (== `/home/bruno/gitops`); app cwd `kubernetes/opencode/` | ebpro/gitops `preservation/opencode-sota-7a05f7b-20260912T182320Z` @ `d0eb511` (doc fixes + `.opencode` configs, **not on main**) | Read `HARBOR_FINDING.md`→`README.md`→`START_SOTA_2026_PROMPT.md`. To bring doc fixes to main: cherry-pick `d0eb511`. |
| `ijava-feature-sonar-coverage-quality-gate-sota-2026-bd8e7d2/` | IJava: clear SonarQube quality gate (coverage/dup/violations) + finish `rdbmsSchema` refactor | `/mnt/hdd/home/bruno/opencode/ijava` (branch `feature/sonar-coverage-quality-gate`) | ebpro/IJava — `wip/sonar-handoff` @ `7216e53` **pushed** (uncommitted fixes backed up); feature branch kept clean @ `bd8e7d2`; also `uncommitted-work*.patch` in folder | Gate still **ERROR** at `bd8e7d2`. Read `SITREP.md`→`OPEN_ISSUES.md`→`START_SOTA_2026_PROMPT.md`. Tag `v1.4.6-pr12` **DO NOT TOUCH**; stable `v1.4.6` not published. `SONAR_TOKEN` is **env-only, never in files**. |
| `2026-refresh-ci-e2e-leadhandoff/` | Debug failing "End-to-End Tests" CI job (ebpro/starter-quarkus-microservices) | `/mnt/hdd/home/bruno/Documents/GitHub/starter-quarkus-microservices-main` | none yet (README only; session still writing) | ⚠️ **PARTIAL/IN-PROGRESS** as of snapshot — bundle files (`SITREP.md`,`DIAGNOSTIC-PLAN.md`,`RESTART-PROMPT-SOTA-2026.md`) not yet present. Owner session must finish + self-register here. |
## Cross-cutting hazards (read before touching git)
- **Shared working tree:** 4 handoffs (`arc-kyverno`, `backstage`, `opencode`, + `link-shortener` gitops half) all use the SAME repo `/mnt/hdd/home/bruno/gitops` (inode 41820162, also `/home/bruno/gitops`). It is currently checked out on `preservation/opencode-sota-7a05f7b-…` with stray untracked files (`arm-test.yaml`, `*.backup`, `*.bak`).
- **Multiple source repos:** `ebpro/gitops` (arc-kyverno, backstage, opencode, link-shortener gitops-half) vs `ebpro/IJava` (ijava job, remote https://github.com/ebpro/IJava.git). **Secret rule:** keep tokens env-only (e.g. ijava `SONAR_TOKEN`), never commit them into any handoff or repo file.
- **Do NOT `git checkout main` in the shared tree** if another session is mid-work — you'll yank its checkout. Use an isolated `git worktree` per job (what the ARC session did):
  `git -C /mnt/hdd/home/bruno/gitops worktree add /tmp/<job>-wt <base-ref>`
- **ArgoCD auto-sync** watches `main` (prune+selfHeal). Preservation/handoff branches are inert (not reconciled). Merging to main triggers reconcile.

## Naming convention for new handoffs (keep unique across parallel sessions)
`<job-slug>-<YYYY-MM-DD>` (job slug readable, date avoids same-day cross-job collisions).
If two sessions run the SAME job the same day, append a short id: `<job-slug>-<YYYY-MM-DD>-<4hex>`.
Always include: `WORKDIR.txt`, `SITREP.md`, `CONTEXT.md`, `FILES.md`, `NEXT-STEPS.md`, `CHECKLIST.md`,
`GIT.md`, `START-SOTA-2026.md` — and register the folder as a row in THIS index.

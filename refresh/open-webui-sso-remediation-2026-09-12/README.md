# Open WebUI SSO + DB remediation — SOTA-2026 handoff

Job: finish bringing **Open WebUI** to green on the GitOps platform. The feature manifests are
already committed and live on `origin/main` (`7a05f7b`). Two defects remain, both discovered during
bring-up and NOT yet fixed. This folder lets a fresh `SOTA 2026` session resume and finish the job
without re-doing discovery.

## TL;DR — two things left
1. **Issue 1 (app ESO not READY):** `secret/data/keycloak` may be missing key `clientSecretOpenWebUI`.
   The `keycloak-reconciler` hourly Job is *supposed* to create the Keycloak client and push that key.
   Diagnose why it hasn't, let it converge, or do a documented one-time Vault write as fallback.
2. **Issue 2 (CNPG/ESO ownership conflict):** `open-webui-db.yaml` uses `spec.managed.roles` pointing at
   secret `open-webui-db-app`, but the DB ExternalSecret also owns that secret (`creationPolicy: Owner`).
   Fix in git: drop `spec.managed`, add a separate `DatabaseRole`, publish by PR to `main`.

## Read order
`START-SOTA-2026.md` (the copy-paste prompt) -> `SITREP.md` -> `CONTEXT.md` -> `NEXT-STEPS.md`
-> `CHECKLIST.md` -> `GIT.md` -> `FILES.md` -> `VERIFICATION.md` -> `WORKDIR.txt` -> `SECRET_POLICY.md`.

## Where to work
Work ONLY in the isolated worktree (see `WORKDIR.txt`):
`cd /tmp/wt-open-webui-sso-remediation-2026-09-12`
Never `git checkout main` / `git add -A` / `git stash` in the shared primary tree — it is on another
session's branch with foreign untracked files. See `/home/bruno/REFRESH/CONCURRENCY.md`.

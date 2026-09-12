# Git / publishing (preserve all work, publish by PR, never touch main directly)

## Current verified state (2026-09-12)
- Open WebUI feature commit **`7a05f7b`** is ALREADY on `origin/main` (tip). All 9 manifests tracked.
  => The implemented feature work is preserved in git. No uncommitted feature work exists here.
- Shared primary tree `/mnt/hdd/home/bruno/gitops` is checked out on a DIFFERENT session's branch
  (`preservation/opencode-sota-7a05f7b-…`, tip `d0eb511`) with 3 foreign untracked files
  (`arm-test.yaml`, `helm/releases/pact-broker/values.yaml.backup`,
  `kubernetes/keycloak-realm/platform-realm-setup-job.yaml.bak`). NOT ours — do not stage them.

## This job's isolated workspace (created via claim.sh)
- Worktree: `/tmp/wt-open-webui-sso-remediation-2026-09-12`
- Branch:   `preservation/open-webui-sso-remediation-2026-09-12` (base `origin/main` @ `7a05f7b`)
- Claimed by: bruno@compute-lsis-2 (see `.claimed`)

## Publish flow (Issue 2 fix)
1. Edit ONLY in the worktree.
2. Stage by explicit path (NEVER `-A`/`.`):
   `git -C "$WT" add kubernetes/postgresql/open-webui-db.yaml kubernetes/postgresql/open-webui-dbrole.yaml`
3. Commit:
   `fix(open-webui): use DatabaseRole + ESO-owned secret per platform pattern`
4. Push the preservation branch and open a PR to `main`:
   `git -C "$WT" push -u origin preservation/open-webui-sso-remediation-2026-09-12`
5. Do NOT merge to main yourself unless explicitly asked — ArgoCD reconciles `main` (prune+selfHeal),
   so a main push deploys. Human-coordinated merge.

## Self-version this handoff (survives workstation reset)
Copy this folder into the worktree at `refresh/open-webui-sso-remediation-2026-09-12/`, stage by path,
include it in a docs commit on the preservation branch, push. (No secret values in these files — safe.)

## Cleanup (when merged/abandoned)
`cd /home/bruno/REFRESH && ./claim.sh --release open-webui-sso-remediation-2026-09-12`

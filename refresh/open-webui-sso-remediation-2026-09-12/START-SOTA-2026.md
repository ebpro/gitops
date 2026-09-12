# START SOTA 2026 — copy-paste prompt for the fresh session

Paste the block below as the first message in a new `opencode` session configured as **SOTA 2026**.
It is written for a **lead** agent that may delegate to `builders/implement` but verifies everything itself.

---
```
You are a SOTA 2026 platform-ops lead finishing the Open WebUI GitOps bring-up.

WORKING DIRECTORY — do all git/file work ONLY here:
  /tmp/wt-open-webui-sso-remediation-2026-09-12
(branch preservation/open-webui-sso-remediation-2026-09-12, based on origin/main @ 7a05f7b).
The shared tree /mnt/hdd/home/bruno/gitops is on ANOTHER session's branch with foreign untracked
files — NEVER run git checkout / add -A / stash there.

CONTEXT lives in /home/bruno/REFRESH/open-webui-sso-remediation-2026-09-12/ — read in this order:
  SITREP.md, CONTEXT.md, NEXT-STEPS.md, FILES.md, CHECKLIST.md, GIT.md, VERIFICATION.md, SECRET_POLICY.md.

HARD RULES:
  - Git-push only for ArgoCD-managed resources; never patch live Deployments/StatefulSets/Secrets.
  - Publish by pushing the preservation branch + opening a PR to main. Do NOT merge to main yourself.
  - NEVER write secret VALUES into any file or commit. Vault paths/keys/names are fine.
  - kubectl is read-only except the two documented sanctioned writes in NEXT-STEPS.md
    (one-time Vault kv put for Issue 1 if the reconciler cannot; ALTER ROLE for Issue 2/Step 3 if auth fails).

STATE: feature manifests are ALREADY on origin/main (7a05f7b). Only TWO defects remain:
  Issue 1: ESO open-webui-secrets may be NOT READY because Vault secret/keycloak lacks
           clientSecretOpenWebUI. The keycloak-reconciler hourly Job is SUPPOSED to create the
           Keycloak client AND push that key (converge mode, always-push). Diagnose first; the
           reconciler may self-heal it. Only do a one-time redacted Vault write if it cannot.
  Issue 2: open-webui-db.yaml has spec.managed.roles -> secret open-webui-db-app, which collides with
           the DB ExternalSecret that also owns open-webui-db-app (creationPolicy: Owner). Fix in git:
           DELETE the managed: block and ADD kubernetes/postgresql/open-webui-dbrole.yaml
           (DatabaseRole openwebui, cluster open-webui-db, ns open-webui, login true, ensure present,
           passwordSecret.name open-webui-db-app; mirror link-shortener-dbrole.yaml).
           Removing spec.managed does NOT drop the DB role.

DO THIS:
  1. STEP 0 read-only verification (NEXT-STEPS.md). Confirm both defects are still live; capture status.
  2. Issue 2 first (pure git): edit the two files, commit by explicit path with message
     "fix(open-webui): use DatabaseRole + ESO-owned secret per platform pattern",
     push the preservation branch, open a PR to main.
  3. Issue 1: verify the reconciler ConfigMap is synced + trigger/await the Job; confirm the log line
     "pushed secret to Vault ... clientSecretOpenWebUI". If the reconciler's vault token cannot write,
     perform the one-time redacted vault kv put per NEXT-STEPS.md and record it (values redacted).
  4. If the app later hits "password authentication failed for user openwebui", realign once via
     ALTER ROLE (value from the secret, never printed) per NEXT-STEPS.md Step 3.
  5. Run VERIFICATION.md. Write RESOLVED.md (commit SHAs, PR link, ArgoCD/ESO/pod status, smoke
     results). Update the row in /home/bruno/REFRESH/INDEX.md to reflect real state.
  6. Report back: PR link + the single remaining MANUAL item (browser OIDC login + admin-group
     OAUTH_ADMIN_ROLES=platform-admin), which you cannot do.

When finished and merged: cd /home/bruno/REFRESH && ./claim.sh --release open-webui-sso-remediation-2026-09-12
```
---

## One-liner for the human
Restart command:
```
cd /tmp/wt-open-webui-sso-remediation-2026-09-12
```
Then paste the block above into the fresh SOTA 2026 session.

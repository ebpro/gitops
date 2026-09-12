# CHECKLIST — tick as you go

## Pre-flight
- [ ] Read `WORKDIR.txt`; you are working in `/tmp/wt-open-webui-sso-remediation-2026-09-12`
- [ ] Did NOT run `git checkout`/`add -A`/`stash` in the shared primary tree
- [ ] No secret VALUES in any file/commit (SECRET_POLICY.md)

## Verify (read-only)
- [ ] ArgoCD app `open-webui` sync/health state captured
- [ ] `open-webui-secrets` ESO READY? if not, which key is missing (oauthClientSecret?)
- [ ] `open-webui-db-app` ownerRef: CNPG (bad) vs ExternalSecret (good)
- [ ] `clientSecretOpenWebUI` present in Vault `secret/keycloak`? (metadata get, no value)
- [ ] reconciler Job ran with open-webui in live ConfigMap? log line seen?

## Issue 2 (git)
- [ ] Removed `managed:` block from `open-webui-db.yaml`
- [ ] Added `open-webui-dbrole.yaml` (DatabaseRole, passwordSecret=open-webui-db-app)
- [ ] Committed by explicit path, message = `fix(open-webui): use DatabaseRole + ESO-owned secret per platform pattern`
- [ ] Pushed preservation branch; PR opened to main (NOT merged-to-main directly by me)
- [ ] After merge+sync: ownerRef kind=ExternalSecret; CNPG no longer claims the secret

## Issue 1 (Vault)
- [ ] Reconciler converged and pushed `clientSecretOpenWebUI` — OR documented one-time vault write done (redacted)
- [ ] `open-webui-secrets` ESO now READY; K8s secret has oauthClientSecret

## DB role realign (only if auth fails)
- [ ] `ALTER ROLE openwebui PASSWORD` from secret value (never printed)
- [ ] `SELECT current_user;` returns `openwebui`

## Final
- [ ] App pod `1/1 Running`; `/health` 200; LiteLLM `/v1/models` 200
- [ ] RESOLVED.md written with SHAs/PR/status; INDEX row updated to DONE
- [ ] Manual browser OIDC login + `OAUTH_ADMIN_ROLES=platform-admin` — LEFT FOR HUMAN (note it)

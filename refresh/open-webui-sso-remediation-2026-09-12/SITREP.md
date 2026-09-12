# SITREP — Open WebUI SSO + DB (as of 2026-09-12T20:1xZ)

## Status: feature MERGED to main; 2 bring-up defects OPEN
| Item | State | Evidence |
|---|---|---|
| App + DB manifests | ✅ on `origin/main` @ `7a05f7b` | `git branch -r --contains 7a05f7b` -> origin/main |
| ArgoCD app `open-webui` (helm-apps/k8s-apps AppSet) | ⚠️ likely degraded | see below |
| App ESO `open-webui-secrets` | ❌ likely NOT READY | depends on `clientSecretOpenWebUI` in Vault |
| DB ESO `open-webui-db-secret` | ⚠️ ownership conflict w/ CNPG | both target secret `open-webui-db-app` |
| CNPG `open-webui-db` | running but `spec.managed` conflict | `open-webui-db.yaml:13 managed:` present |
| Keycloak client `open-webui` | ⚠️ unverified | reconciler ConfigMap lists it; runtime unconfirmed |
| LiteLLM reachability | ✅ NetworkPolicy allows open-webui -> :4000 | `kubernetes/llm-gateway/cilium-networkpolicy.yaml` |
| Manual browser OIDC login | ❌ never done | out of band |

## The two defects
**Issue 1 — app ESO not READY.** `kubernetes/open-webui/external-secret.yaml` pulls
`secretKey: oauthClientSecret` from Vault `secret/keycloak` property `clientSecretOpenWebUI`. If that
key is absent, the whole ESO fails and the pod env `OAUTH_*`/`OPENAI_API_KEY`/`DATABASE_URL` are missing.
The `keycloak-reconciler` hourly Job (converge mode) is DESIGNED to create the Keycloak client AND push
`clientSecretOpenWebUI` to `secret/data/keycloak` (verified in `bootstrap/keycloak-reconciler/scripts/reconcile.py`:
`ensure_client` then `push_secret_to_vault` -> `vault kv put`). So usually this self-heals within an hour;
when it does not, the cause is one of: ConfigMap not synced yet, reconciler Vault token lacks write to
`secret/*`, or a prior client row blocking the push. Diagnose, don't guess.

**Issue 2 — CNPG vs ESO own the same secret.** `open-webui-db.yaml` declares
`spec.managed.roles[].passwordSecret.name = open-webui-db-app`, while
`open-webui-db-external-secret.yaml` targets the SAME secret `open-webui-db-app` with
`creationPolicy: Owner`. Two controllers fighting over one Secret => ESO blocked / ownerRef flip-flop.
Platform-correct pattern (precedent: `link-shortener-dbrole.yaml`, `database-roles.yaml`, and the
SonarQube `spec.roles`->DatabaseRole migration noted in AGENTS.md): **remove `spec.managed`, add a
separate `DatabaseRole`** whose `passwordSecret` references the ESO-owned secret. Removing `spec.managed`
does NOT drop the DB role; it just stops CNPG from wanting to own the Secret.

## Prior session
- A delegated `builders/implement` subagent (`ses_f70747387ffe1s2uH7HmPHKlNf`) died with
  `Subagent failed ... Cannot connect to API: The socket connection was closed unexpectedly.`
  It had NOT applied fixes — only the feature commit `7a05f7b` landed. Resume cleanly; do not assume any
  remediation was done.

## Immediate next action
Run `NEXT-STEPS.md` from the worktree. Issue 2 is a pure git change (safe, reviewable). Issue 1 is
diagnose-first; only do a one-time Vault write if the reconciler cannot.

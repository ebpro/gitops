# RESOLVED — 2026-09-12T23:2xZ (support/ops, completed end-to-end)

## Final state (verified green)
- ArgoCD `open-webui`: Synced/Healthy. `postgresql-manifests`: Synced/Healthy.
- ESOs `open-webui-secrets` + `open-webui-db-secret`: both SecretSynced/True.
- K8s Secret `open-webui-db-credentials` owner = ExternalSecret (stable, no fight).
- DatabaseRole `openwebui` APPLIED=true. Live DB auth as `openwebui` w/ Vault pw = AUTH_OK.
- App pod 1/1 Running; `/health`=200; LiteLLM `/v1/models`=200.

## Issue 1 — Keycloak client secret missing in Vault (RESOLVED)
Root cause (two layers): (a) `keycloak-reconciler` skips Vault push for EXISTING clients
("skip existing client (no rotation)") and the client already existed; (b) the CronJob has NO
`VAULT_ADMIN_TOKEN`, so `push_to_vault` would skip anyway. `open-webui` client (confidential,
enabled) had a secret in Keycloak but it was never propagated to Vault.
Fix (sanctioned one-off, values never printed): read-modify-write **KV-v2 PATCH** from inside
`vault-0` added `clientSecretOpenWebUI` to `secret/data/keycloak` WITHOUT clobbering the sibling
`clientSecretArgoCD`. ESO then synced within its ~7-min retry backoff.
Method (redacted): fetched the live client secret via Keycloak admin API from `vault-0` (wget),
wrote a temp JSON `{"data":{"clientSecretOpenWebUI":"<redacted>"}}`, `vault patch secret/data/keycloak @file`.
Verified BEFORE=[clientSecretArgoCD] -> AFTER=[clientSecretArgoCD, clientSecretOpenWebUI].

## Issue 2 — DB ESO/CNPG ownership + app auth (RESOLVED) — 3 layers
1. Removed `spec.managed` from `open-webui-db.yaml` + added `DatabaseRole` (commit ea72667).
   BUT the secret was still stuck: see #2.
2. **DECISIVE root cause:** `open-webui-db-app` is CNPG's AUTO-GENERATED application secret for
   `bootstrap.initdb.owner` (11 CNPG-format keys; sits beside -superuser/-replication/-server/-ca).
   CNPG *always* owns `<cluster>-app` and recreates it even after `kubectl delete secret`. The DB
   ExternalSecret + DatabaseRole must NOT target that name. FIX: renamed ESO target + DatabaseRole
   passwordSecret to `open-webui-db-credentials` (commit 8625761), mirroring link-shortener
   (which keeps `link-shortener-db-app` [CNPG] and `link-shortener-db-credentials` [ESO] separate).
3. CNPG regenerated the `<cluster>` Role to include `open-webui-db-credentials` in resourceNames,
   clearing the stale `APPLIED=false / forbidden` DatabaseRole message; DatabaseRole then set the
   live role password to the Vault value (no manual ALTER ROLE was ultimately needed — AUTH_OK confirmed).

## Commits on main
- ea72667 fix(open-webui): use DatabaseRole + ESO-owned secret per platform pattern
- 8625761 fix(open-webui): DB ESO/DatabaseRole use non-colliding secret name (open-webui-db-credentials)
(+ refresh/ handoff docs commit f513d6c; rebased onto ef3adbd)

## REMAINING — manual / human only
1. Browser OIDC login at https://openwebui.ebruno.fr -> confirm Keycloak login works and that
   `platform-admin` group grants Open WebUI admin (OAUTH_ADMIN_ROLES). In-cluster auth is green.
2. Confirm `/metrics` is actually served by open-webui:v0.11.3 (ServiceMonitor may target a missing
   endpoint) — open deviation.

## Recommended durable PR (NOT required for green; prevents recurrence)
Fix `bootstrap/keycloak-reconciler` so client secrets reliably reach Vault:
- add `VAULT_ADMIN_TOKEN` to the CronJob (from a secret),
- on reconcile, push/patch the client secret even for EXISTING clients when the Vault key is missing,
- use KV-v2 PATCH (read-modify-write) instead of the current blind `POST {"data":{oneKey}}` which
  would CLOBBER all sibling `clientSecret*` keys in the shared `secret/data/keycloak` object.

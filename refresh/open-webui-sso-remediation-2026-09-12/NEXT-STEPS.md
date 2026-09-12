# NEXT-STEPS — execute in order, from the worktree

`WT=/tmp/wt-open-webui-sso-remediation-2026-09-12`  (all file edits/commits happen here, never the shared tree)

## STEP 0 — verify current runtime (read-only, kubectl)
```
kubectl -n argocd get application open-webui -o wide 2>&1 | head
kubectl -n open-webui get externalsecret,secret,pods,cluster.postgresql.cnpg.io,databaserole 2>&1
kubectl -n open-webui describe externalsecret open-webui-secrets | tail -20
kubectl -n open-webui describe externalsecret open-webui-db-secret | tail -20
kubectl -n open-webui get secret open-webui-db-app -o jsonpath='{.metadata.ownerReferences}{"\n"}'
# Vault key presence (VALUE not printed): from a pod with VAULT_ADDR/token, e.g. vault ns:
#   vault kv get -field=clientSecretOpenWebUI secret/keycloak >/dev/null && echo PRESENT || echo MISSING
#   (or `kubectl exec -n vault <vault-pod> -- vault kv metadata get secret/keycloak` — key list only)
kubectl -n keycloak logs job/$(kubectl -n keycloak get jobs -o name | grep keycloak-reconciler | head -1 | cut -d/ -f2) --tail=40 2>&1
```
Decide: is Issue 1 (missing Vault key) real, and is Issue 2 (ownerRefs pointing at CNPG not ESO) real?

## STEP 1 — Issue 2: CNPG/ESO ownership (PURE GIT change, do this first — safe & reviewable)
Edit `kubernetes/postgresql/open-webui-db.yaml`: DELETE the `managed:` block (the 7 lines from
`  managed:` through the `name: open-webui-db-app` under passwordSecret). Leave `bootstrap.initdb` intact.
Create `kubernetes/postgresql/open-webui-dbrole.yaml` (mirror `link-shortener-dbrole.yaml`):
```
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: openwebui
  namespace: open-webui
spec:
  cluster:
    name: open-webui-db
  comment: open-webui application role
  connectionLimit: -1
  name: openwebui
  ensure: present
  login: true
  passwordSecret:
    name: open-webui-db-app
```
Confirm the AppSet syncs `kubernetes/postgresql` (it does — `open-webui-db.yaml` lives there and is applied).
Commit + push (by explicit path, never `-A`):
```
git -C "$WT" add kubernetes/postgresql/open-webui-db.yaml kubernetes/postgresql/open-webui-dbrole.yaml
git -C "$WT" commit -m "fix(open-webui): use DatabaseRole + ESO-owned secret per platform pattern"
git -C "$WT" push -u origin preservation/open-webui-sso-remediation-2026-09-12   # then open PR -> main
```
After merge to main + ArgoCD sync, verify secret is ESO-owned (ownerRef kind=ExternalSecret), NOT CNPG.

## STEP 2 — Issue 1: Keycloak client secret in Vault
Preferred: let the reconciler do it. Ensure the reconciler ConfigMap (with open-webui client) is SYNCED to
the live `keycloak-clients` ConfigMap in ns `keycloak` (`kubectl -n keycloak get cm keycloak-clients -o yaml | grep -A3 open-webui`).
Trigger/await the hourly CronJob. Check its log for `pushed secret to Vault ... key=clientSecretOpenWebUI`.
If the reconciler's `vault_token` cannot write `secret/*` (403), THEN do a documented one-time write from the
vault pod — value comes from Keycloak, NOT from a file. Fetch the live client secret in-cluster and push it
without echoing (see SECRET_POLICY.md). This is an out-of-band, one-off, recorded data op:
```
# inside vault pod, using a value obtained from Keycloak admin API (do not print):
#   CID=<open-webui client_id>; SECRET=<fetched from keycloak, not echoed>
#   vault kv put secret/keycloak <existing keys...> clientSecretOpenWebUI="$SECRET"
```
Record the exact command (values redacted) in this folder's `RESOLVED.md` for audit.

## STEP 3 — realign DB role password (AGENTS.md DatabaseRole trap)
If the app gets `FATAL: password authentication failed for user "openwebui"` after Step 1, the pre-existing
role password is stale vs the ESO secret. Realign once, value never printed:
```
PASS=$(kubectl -n open-webui get secret open-webui-db-app -o jsonpath='{.data.password}' | base64 -d)
kubectl -n open-webui exec -i open-webui-db-1 -c postgres -- \
  psql -U postgres -d openwebui -v pass="$PASS" <<'SQL'
ALTER ROLE openwebui WITH PASSWORD :'pass';
SQL
# verify (prints only the role name):
PGPASSWORD="$PASS" kubectl -n open-webui exec -i open-webui-db-1 -c postgres -- \
  psql "host=127.0.0.1 user=openwebui dbname=openwebui sslmode=disable" -tAc "SELECT current_user;"
```

## STEP 4 — final verification
See `VERIFICATION.md`. Then leave a `RESOLVED.md` here with: commit SHAs, PR link, ArgoCD/ESO/pod status,
smoke results, and the remaining MANUAL browser OIDC task.

## Order rationale
Issue 2 first because it's a deterministic git fix with no secret handling. Issue 1 may self-heal via the
reconciler; only do the out-of-band Vault write if it truly cannot. Step 3 only if auth actually fails.

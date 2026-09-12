# FILES — exact paths (in the worktree / on main)

## Files to CHANGE (Issue 2, in git)
- `kubernetes/postgresql/open-webui-db.yaml` — remove the `managed:` block (lines ~13-19: managed/roles/name
  `openwebui`/ensure/login/passwordSecret). Keep everything else (bootstrap.initdb, backup, storage, resources).
- `kubernetes/postgresql/open-webui-dbrole.yaml` — NEW. `DatabaseRole` for `openwebui` on cluster
  `open-webui-db`, ns `open-webui`, `ensure: present`, `login: true`, `passwordSecret.name: open-webui-db-app`.
  Copy the shape from `kubernetes/postgresql/link-shortener-dbrole.yaml` / `database-roles.yaml`.

## Files that REFERENCE the conflict (do not break; read-only unless needed)
- `kubernetes/postgresql/open-webui-db-external-secret.yaml` — ESO `open-webui-db-secret` OWNS
  `open-webui-db-app` (creationPolicy Owner). After removing CNPG `spec.managed`, ESO is sole owner. OK.
- `kubernetes/open-webui/external-secret.yaml` — app ESO; needs `clientSecretOpenWebUI` in Vault (Issue 1).
- `kubernetes/open-webui/deployment.yaml` — consumes both secrets via env; check exact env names/keys.

## Precedents to MIRROR
- `kubernetes/postgresql/link-shortener-dbrole.yaml`
- `kubernetes/postgresql/database-roles.yaml`
- SonarQube migration note in `AGENTS.md` (spec.roles -> DatabaseRole; ALTER ROLE realign).

## Reconciler (Issue 1 diagnosis, read-only)
- `bootstrap/keycloak-reconciler/configmap.yaml` (client spec incl. open-webui).
- `bootstrap/keycloak-reconciler/job-init.yaml` (reconcile.py embedded; `ensure_client`,
  `push_secret_to_vault`, `ensure_vault_path`, `converge`).
- Secrets it reads: `keycloak-admin-secret` (admin_username/admin_password), `vault-token-secret`
  (vault_token) — both ns `keycloak`.

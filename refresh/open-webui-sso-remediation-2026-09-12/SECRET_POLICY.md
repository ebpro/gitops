# Secret policy (HARD rules for this job)

- NEVER write any secret VALUE into a handoff file, a repo file, or a commit message.
- Vault PATHS, secret NAMES, and data KEYS are safe to document (they are not secrets).
- The Keycloak client secret for open-webui is a secret VALUE. It must flow:
  Keycloak (created by reconciler) -> Vault `secret/data/keycloak` key `clientSecretOpenWebUI`
  -> ESO `open-webui-secrets` -> K8s Secret `open-webui-secrets` key `oauthClientSecret` -> pod env.
- The DB app password flows: Vault `secret/data/postgresql/open-webui` (url/username/password)
  -> ESO `open-webui-db-secret` -> K8s Secret `open-webui-db-app` -> CNPG DatabaseRole + app DATABASE_URL.
- If a one-off `vault kv merge` / `ALTER ROLE` is needed, pass values via shell variables read from
  existing cluster secrets; never echo them. Example (value not printed):
  `PASS=$(kubectl get secret open-webui-db-app -n open-webui -o jsonpath='{.data.password}' | base64 -d)`
- `SONAR_TOKEN`-style tokens stay env-only. No tokens in git, ever.

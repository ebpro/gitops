# CONTEXT — architecture & wiring (read before changing anything)

## App
- Image `ghcr.io/open-webui/open-webui:v0.11.3`, namespace `open-webui`, single Deployment + Service
  (`http` 80->8080), PVC 10Gi `local-path` at `/app/backend/data`, ServiceMonitor on `/metrics`
  (unverified endpoint — open deviation).
- Deployed via AppSet path `kubernetes/open-webui` (see `bootstrap/appset-manifests.yaml`); AppSet
  uses `CreateNamespace=true` (the extra `namespace.yaml` is a harmless deviation).
- Ingress: Traefik IngressRoute `openwebui.ebruno.fr`, TLS `letsencrypt-ovh`, NO forwardAuth (SSO is
  app-native OIDC). A namespace-local `security-headers` Middleware is defined (deviation: not shared).

## Database (CNPG)
- Cluster `open-webui-db`, ns `open-webui`, image `...postgresql:18.4-system-trixie`, 1 instance,
  5Gi `local-path`, max_connections 200, `enableSuperuserAccess: true`.
- bootstrap.initdb: database `openwebui`, owner `openwebui`.
- Currently `spec.managed.roles` -> passwordSecret `open-webui-db-app`  (THE CONFLICT — Issue 2).
- Backups: Barman S3 `s3://backups/open-webui-db` via Garage endpoint `http://garage.garage.svc:3900`,
  creds from secret `open-webui-backup-s3`. ScheduledBackup present (`kubernetes/postgresql/scheduled-backups.yaml`).
- RW DNS: `open-webui-db-rw.open-webui.svc.cluster.local:5432`.

## Secrets chain
- DB: Vault `secret/data/postgresql/open-webui` (keys url/username/password) -> ESO `open-webui-db-secret`
  -> K8s Secret `open-webui-db-app` (url/username/password) -> CNPG role password + app `DATABASE_URL`.
- App: Vault `secret/data/open-webui` (webuiSecretKey, adminPassword) + `secret/data/keycloak`
  (clientSecretOpenWebUI) + `secret/data/postgresql/open-webui` (url) + `secret/data/llm-gateway`
  (litellmMasterKey) -> ESO `open-webui-secrets` -> K8s Secret `open-webui-secrets`.

## SSO (Keycloak)
- Central Keycloak (ns `keycloak`). Client `open-webui` is declared in the reconciler ConfigMap
  `bootstrap/keycloak-reconciler/configmap.yaml` with `vaultPath: secret/keycloak`,
  `vaultKey: clientSecretOpenWebUI`, redirect `https://openwebui.ebruno.fr/oauth/callback/keycloak`.
- The reconciler is a CronJob (hourly, converge) + one-time init Job; it creates/updates Keycloak clients
  from the ConfigMap and ALWAYS writes their client secrets into Vault KV-v2 at the configured path/key.
- App env (deployment.yaml): OIDC enabled against Keycloak; admin-group via `OAUTH_ROLES_CLAIM`/
  `OAUTH_ADMIN_ROLES=platform-admin` (verify exact env names in deployment.yaml).

## LLM backend
- Reuses LiteLLM at `http://litellm.llm-gateway.svc:4000`; `OPENAI_API_KEY` = litellm master key from
  Vault `secret/llm-gateway`. Cilium NetworkPolicy already allows open-webui -> llm-gateway:4000.

## Platform rules (AGENTS.md)
- Git-push only for ArgoCD-managed resources; never patch Deployments/StatefulSets/Secrets the chain owns.
- CNPG DatabaseRole with `ensure: present` does NOT re-set an EXISTING role's password (documented trap) —
  after switching to DatabaseRole, the DB role password may still be stale vs the ESO secret; realign once
  via psql `ALTER ROLE ... PASSWORD` (value read from the secret, never printed).

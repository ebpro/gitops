# Platform Progress

## Goal
- Complete Keycloak OIDC SSO across all platform services backed by Vault + ExternalSecrets Operator on single-node K3s.

## Constraints & Preferences
- Single-node K3s (compute-lcis-2, v1.35.5+k3s), Cilium CNI.
- ArgoCD auto-sync from git via AppSet → Helm apps + raw manifests.
- Secrets via Vault KV v2 + ExternalSecrets Operator.
- Traefik + Let's Encrypt OVH DNS-01 for Ingress TLS.
- Git-push-only workflow.

## Progress
### Done
- Vault fully rebuilt: stale PVC deleted, StatefulSet recreated, re-initialized with Shamir (1 key).
- Vault admin token created (`admin-full` policy, 95 chars, based on `hvs.CAES...`) with `vault-init` secret stored.
- All 9 Keycloak client secrets generated in Platform realm and stored in Vault KV v2 at path `secret/data/keycloak` and also stored in vault-init secret.
- ExternalSecrets Operator AppRole auth configured with read-only policy on `secret/data/*`.
- ClusterSecretStore `vault` configured. All ExternalSecrets using `key: keycloak` path (no double-nesting).
- Helm values fixed: Vault replicas `3` → `1`, all ExternalSecret `key: secret/data/keycloak` → `key: keycloak`.
- All Keycloak OIDC secrets restored to Vault and picked up by ExternalSecrets.
- ArgoCD mounted in kubectl to verify sync. All applications now show `Synced` status correctly.
- Kustomize apps that were deprecated are removed from operands (now fully Helm-based).

### Completed (2026-08-10)
- All Vault KV data restored: `secret/data/keycloak` (admin credentials, user passwords), all 10 OIDC client secrets at `secret/data/oidc/<app>`, and SAML certs (`devopsRealmScalingCert`, `sonarqubePrivateKeySecured`, `sonarqubeCertificateSecured`)
- All 29 ExternalSecrets now Ready=True (keycloak-secrets + sonarqube-saml previously failed)
- ArgoCD platform 35/39 apps Healthy ✅; 4 Unknown: argocd-image-updater, kube-prometheus, link-shortener, open-telemetry (metadata only, not breaking)
- microcks MongoDB auth fixed: `userM` password synced between secret and MongoDB admin user; microcks app 1/1 READY
- Plane pods now scheduling after stuck pods cleanup (Too many pods limit no longer hit)
- Legacy cleanup: 24 stuck pods force-deleted (backstage, ci, default, gitea, keycloak, microcks, plane), 20 old microcks-mongodb legacy RS deleted

### Completed (2026-08-18)
- Keycloak crash loop fixed (commits b34fed6, ea51148): removed invalid `subComponents`/devops import field that broke `--import-realm` JSON parsing on KC 26.7; `keycloak-0` Running, import clean.
- `IGNORE_EXISTING` import confirmed: existing `platform` realm is skipped on startup — live realm data is never touched by re-imports; startup still parses the file, so import-validity fixes are mandatory.
- C1 group RBAC activated live and verified end-to-end:
  - Created missing realm roles (`platform-admin`, `platform-engineer`, `developer`, `qa-team`, `security-team`, `readonly`) and group→realm-role mappings.
  - Created `microcks-app` client roles (`admin`, `manager`, `user`) and group→client-role mappings (platform-admins→admin, platform-engineers/developers→manager, readonly→user).
  - Token verification: bruno → `realm_access:['platform-admin']`, `resource_access.microcks-app:['admin']`; ci-runner → `developer`+`platform-engineer`, `microcks-app:['manager']`; gitops-user → `platform-engineer`, `microcks-app:['manager']`.
- Root-caused KC 26 "Account is not fully set up" (invalid_grant on password login): default user profile requires `firstName`/`lastName`; missing values trigger `VERIFY_PROFILE`. Fixed `ci-runner`/`gitops-user` live and in the realm file (commit aa09067).
- Setup job `keycloak-platform-realm-setup-20260818` completed (passwords + groups). GitOps source of truth (`platform-realm-configmap.yaml`) is now complete for future rebuilds: realm roles, client roles (`roles.client` map), groups with mappings, user names.
- Devops realm confirmed absent from live Keycloak (404); Nexus/SonarQube auth is via Traefik ForwardAuth, unaffected. Devops realm/SAML assets are dormant (orphan `devops-realm` CM in keycloak ns).

### In Progress
- Microcks MongoDB H3: staged image upgrade 4.4.29 → 5.0 → 6.0 → 7.0 via `mongodb.image.tag` + `?v` bump per step (pending)
- Microcks M1: document Vault 1h token refresh vs long-lived MongoDB user (rotation requires one-off `alterUser`) — report-only

### Blocked
- (none)

## Key Decisions
- Vault KV v2 base path is `secret` → ExternalSecret `key` only needs `keycloak` (not `secret/data/keycloak`).
- AppRole auth used for ExternalSecrets instead of static token (more secure; `external-secrets` policy limits to `secret/data/*`).
- Vault rem合规 Shamir in Helm values — auto-unseal can be added later via `server.autoUnseal`.
- `vault-init` secret stores both `root_token` (28-char init token) and `admin_token` (95-char full admin) to support Helm init container and manual admin.

## Next Steps
1. **Rebuild all Vault KV data** — postgresql/backstage, postgresql/harbor, postgresql/nexus, postgresql/gitea, postgresql/plane, postgresql/sonarqube, postgresql/keycloak, backstage
2. **Validate SSO OIDC**: Verify ArgoCD, Gitea, Harbor, Plane, Microcks OIDC all authenticate against Keycloak
3. **Vault autoUnseal**: Configure raft/wal for resilience (backwards compatible with Shamir fallback)
4. **Postgres cluster cleanup**: Remove deprecated manifest-synced postgres resources (now CNPG managed)
5. **Update AGENTS.md**: Corrected ArGoCD app statuses

## Critical Context
- **Vault Token Access**: `vault-init` secret in `vault` namespace stores `admin_token` (95-char `hvs.CAES...` full admin) and `root_token` (28 char) — this is key used by Helm init container and for all Vault CLI operations.
- **Vault Token State**: Updated 2026-07-13. Token is fresh from init container. Will need to rotate if SHA rebuilt.
- **ExternalSecrets key fix**: The `key: keycloak` (not `secret/data/keycloak`) prevents the path from doubling. All 10 manifests now consistent.
- **vault-approle K8s secret**: ExternalSecrets Operator detects `vault-approle` in `external-secrets` ns. needs proper role/secret-id.
- **Keycloak admin password**: Raw base64-encoded value from `keycloak-secrets` secret in `keycloak` namespace. Keycloak HTTP frontend URL and
- **Keycloak access**: `admin-cli` client with password from `keycloak-secrets` in `keycloak` namespace. All 9 confidential clients exist in `platform` realm with secrets real.
- **ArgoCD SSO OIDC**: Controlled by `helm/releases/argocd/oidc/credentials-secrets` K8s secret.
- **Plane app**: Last sync updated 2026-07-09. Target revision 1.6.0. Values file: `bootstrap/helm-values/plane.yaml`.

## Relevant Files
- `kubernetes/external-secrets/cluster-secret-store.yaml` — ClusterSecretStore for Vault (AppRole auth, `path: secret`, `version: v2`)
- `bootstrap/appset-manifests.yaml` — ArgoCD AppSet manifests (added `kubernetes/external-secrets` directory)
- `helm/releases/vault/values.yaml` — Vault Helm (replicas: 1, admin_token, OIDC init container)
- `bootstrap/helm-values/vault.yaml` — Vault base Helm values (secret/data/keycloak)
- `kubernetes/postgresql/keycloak-external-secret.yaml` — Keycloak postgres secrets from Vault
- `kubernetes/postgresql/argocd-oidc-external-secret.yaml` — ArgoCD OIDC secrets from Vault `keycloak` path
- `kubernetes/postgresql/argocd-server-oidc-credentials.yaml` — ArgoCD server OIDC client secret
- `kubernetes/postgresql/gitea-oidc-external-secret.yaml` — Gitea OIDC secrets from Vault
- `kubernetes/postgresql/plane-oidc-external-secret.yaml` — Plane OIDC secrets from Vault
- `kubernetes/postgresql/grafana-oidc-external-secret.yaml` — Grafana OIDC secrets from Vault
- `kubernetes/postgresql/harbor-oidc-external-secret.yaml` — Harbor OIDC secrets from Vault
- `kubernetes/postgresql/keycloak-external-secret.yaml` — Keycloak secrets from Vault
- `kubernetes/oauth2-proxy/oauth2-proxy-external-secret.yaml` — oauth2-proxy secrets from Vault
- `kubernetes/postgresql/proxy-external-secret.yaml` — Vault OIDC client secret from Vault
- `helm/releases/argocd/values.yaml` — ArgoCD OIDC config (`server.extraArgs.oidc.config`)
- `bootstrap/helm-values/harbor.yaml` — Harbor OIDC (`auth.oidc.loginPageUrl`, `oidc.issuer`)
- `bootstrap/helm-values/plane.yaml` — Plane Helm values (OIDC, ingress, etc.)
- `bootstrap/helm-values/kube-prometheus.yaml` — Grafana/Alertmanager OIDC config
- `bootstrap/k8s-apps/plane.yaml` — Deprecated (helm apps stored in bootstrap)

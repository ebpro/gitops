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
- **Microcks H3 done: MongoDB 4.4.29 → 7.0.18**, FCV chain 4.4→5.0→6.0→7.0 (commits 4aadf9b, 2cd1e36, 963e73a, b76d969, 12d8685).
  - Instance is empty: 1 collection `serviceState`, 0 documents, PVC 7 days old. Snapshot kept: `/tmp/opencode/backups/microcks-mongo-4.4.29-pre-H3-2026-08-18.gz` (346B, gzip-verified).
  - **Direct 4.4→7.0 jump is impossible even with zero documents**: mongod refuses to boot on a `featureCompatibilityVersion: 4.4` document (7.0 only accepts 6.0/6.3/7.0). Mandatory path: 5.0.32 → setFCV 5.0 → 6.0.26 → setFCV 6.0 → 7.0.18 → setFCV 7.0 (`confirm: true` required for 7.0). FCV bumps run as root via pod env (`MONGO_INITDB_ROOT_USERNAME`/`PASSWORD`, `adminUsername`/`adminPassword` keys).
  - Official mongo 6.0/7.0 images ship **mongosh only** (no legacy `mongo` shell — verified with one-shot pods on 5.0.32/6.0.26/7.0.18). Upstream chart 1.13.2 (and 1.14.0) readinessProbe hardcodes the legacy shell → 6.0+ pods would never go Ready.
  - **ArgoCD `postRender` is unusable on this cluster**: `applications.argoproj.io` CRD (v1alpha1 only) has no `postRender` schema field; the API server silently prunes it from every Application object.
  - Chart 1.13.2 vendored to `helm/vendor/microcks`; app source repointed to git (`path: helm/vendor/microcks`; note: adding a `chart:` field makes ArgoCD treat the source as a helm index repo → 404). Vendored probe is shell-agnostic (`mongosh … --eval ping` first, legacy `mongo` fallback) — works 4.4→7.0.
  - Verified: 7.0.18 pod 1/1, FCV=7.0, `serviceState: 0` (data intact), app root=200 and `/api/services`=401 (auth enforced), zero mongo errors after cutover (only transient `InterruptedAtShutdown` in the 13:51–13:58 Recreate window), ArgoCD Synced/Healthy.
- **Microcks M1 documented** (report-only, not executed): Vault↔MongoDB credential rotation runbook below — the 1h ExternalSecret refresh cannot re-credential a running MongoDB user.

- **Microcks integration phase A (2026-08-18): `microcks-ci` CI identity live and verified.**
  - Dedicated Keycloak client `microcks-ci` (confidential, no user flows, `serviceAccountsEnabled`) — reconciler `spec.json` (`bootstrap/keycloak-reconciler/configmap.yaml`) + realm export entry (generated secret backfilled, same pattern as other clients).
  - Role: service-account-microcks-ci → `microcks-app:admin` (CI creates import jobs/tests; Microcks reads `resource_access["microcks-app"]` regardless of azp). Applied + verified by git Job `keycloak-realm-microcks-ci-setup-20260818-r4` (`kubernetes/keycloak-realm/platform-realm-setup-microcks-ci.yaml`).
  - **KC 26 API gotcha**: `POST /users/{id}/role-mappings/clients/{client}` 404 "Role not found" unless the payload RoleRepresentation includes the role `id` (name+containerId alone is rejected). Payload used: `[{id,name,clientRole,composite,containerId}]`.
  - Vault: `secret/data/oidc/microcks-ci` (`clientSecret`) written one-off with root token (reconciler has no `VAULT_ADMIN_TOKEN`, so its create-path Vault push is skipped).
  - `keycloak-secrets` ExternalSecret: `clientSecretMicrocksCi` + template `CLIENT_SECRET_MICROCKS_CI` (syncs on its 1h refresh).
  - Verified E2E: `client_credentials` grant → token `azp=microcks-ci`, `resource_access.microcks-app.roles=["admin"]`.
  - Superseded jobs r1/r2/r3 (wrong endpoint/verify pattern) left for ArgoCD prune; mapping verified idempotent via r4.
  - **Phase plan (features first, app 1.14.0 upgrade last, in a separate window)**: A ✅ identity → B: commit live OpenAPI (`openapi.yaml`, captured from `/q/openapi`, OpenAPI 3.1 YAML, 5 paths) to Gitea app repo + create Microcks API (`microcks-cli import` from Woodpecker) → C: mock + test scenario + MCP endpoint demo → D: Woodpecker contract step (test live `/q/openapi` vs spec pre/post-deploy, fail-the-pipe on drift) + Woodpecker secrets for CI identity → E: Backstage `resource:api` catalog entry (stock `backstage:1.53.1` image — Microcks **plugin** needs a custom image build first; decide then) → F: app 1.13.2→1.14.0 (re-vendor chart, re-apply dual-shell readinessProbe patch, values diff, `?v` bump).

### In Progress
- (A pending tail: r4 job going green + ArgoCD prune of r1–r3; everything else is waiting on Gitea access)

### Blocked
- **Gitea access** (needed for phases B/D): `gitea-admin-secret` password is stale (basic auth 401; password sign-in is disabled, real admin password set at init), no local SSH key is authorized, no stored credentials. Need one of: Gitea admin PAT, fresh admin password, or user creates the Woodpecker org secrets manually. Also required: push access to `ebpro/link-shortener` (PAT with write:repository or a deploy key).

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

## M1 — MongoDB Credential Rotation Runbook (Microcks, report-only)
Chain: Vault KV-v2 `secret/data/microcks` (keys `username`/`password` = app user `userM` in db `microcks`; `adminUsername`/`adminPassword` = root user in db `admin`) → ClusterSecretStore `vault` (AppRole) → ExternalSecret `microcks/microcks-mongodb-connection` (`refreshInterval: 1h`) → K8s secret → pod env at container start.

**The gap:** the 1h refresh only re-fetches from Vault. Rotating a password in Vault does NOT run `alterUser` in MongoDB — the running mongod keeps the old user password until it is changed in-DB, and running pods keep the old env until recreated. Rotating Vault first without the in-DB step means the **next** pod rollout boots with a password MongoDB rejects → crash-loop.

**Safe procedure (one-off, maintenance window; DB is empty so risk is low):**
1. Generate new password X.
2. In-DB change first (one-off exec, no value printed): as root — `db.getSiblingDB("microcks").updateUser("userM", {pwd: "X"})` (and/or `db.getSiblingDB("admin").updateUser("<adminUsername>", {pwd: "X"})` if rotating admin).
3. Update Vault `secret/data/microcks` (`password` / `adminPassword`). ExternalSecret syncs the K8s secret within ≤1h (or sooner on next refresh).
4. Recreate both pods **via git only** (no `kubectl rollout restart`): flip a `commonAnnotations` value for app + mongodb in `helm/releases/microcks/values.yaml` (chart supports `commonAnnotations`), bump `?v`, push. Both workloads re-read env (X) and authenticate against mongod (X).
5. Verify: mongo pod 1/1, app pod 1/1, `/api/services` = 401, no new `MongoNodeIsRecovering`/auth errors.

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
- `bootstrap/app-microcks.yaml` — Microcks Application; git-hosted chart source (`path: helm/vendor/microcks`, no `chart` field), valueFiles `?v=7`
- `helm/vendor/microcks/` — Vendored chart 1.13.2; only `templates/deployment.yaml` modified (dual-shell readinessProbe, `timeoutSeconds: 1→5`)
- `helm/releases/microcks/values.yaml` — `mongodb.image.tag: 7.0.18`
- `kubernetes/postgresql/microcks-mongodb-external-secret.yaml` — Vault→K8s MongoDB creds (M1 chain)

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
  - Role: service-account-microcks-ci → `microcks-app:admin` (CI creates import jobs/tests; Microcks reads `resource_access["microcks-app"]` regardless of azp). Applied + verified by git Job `keycloak-realm-microcks-ci-setup-20260818-r4` (`kubernetes/keycloak-realm/platform-realm-setup-microcks-ci.yaml`). Superseded for full access by the cumulative mapping in `keycloak-microcks-roles-cumulative-20260818-r7` (1.13.2 requires `user` on read-detail paths).
  - **KC 26 API gotcha**: `POST /users/{id}/role-mappings/clients/{client}` 404 "Role not found" unless the payload RoleRepresentation includes the role `id` (name+containerId alone is rejected). Payload used: `[{id,name,clientRole,composite,containerId}]`.
  - Vault: `secret/data/oidc/microcks-ci` (`clientSecret`) written one-off with root token (reconciler has no `VAULT_ADMIN_TOKEN`, so its create-path Vault push is skipped).
  - `keycloak-secrets` ExternalSecret: `clientSecretMicrocksCi` + template `CLIENT_SECRET_MICROCKS_CI` (syncs on its 1h refresh).
  - Verified E2E: `client_credentials` grant → token `azp=microcks-ci`, `resource_access.microcks-app.roles=["admin"]`.
  - Superseded jobs r1/r2/r3 (wrong endpoint/verify pattern) left for ArgoCD prune; mapping verified idempotent via r4.
  - **Phase plan (features first, app 1.14.0 upgrade last, in a separate window)**: A ✅ identity → B ✅ OpenAPI committed + contract import from Woodpecker (pipeline green #75, REST import path) → C: mock + test scenario + MCP endpoint demo → D: Woodpecker contract step (test live `/q/openapi` vs spec pre/post-deploy, fail-the-pipe on drift) + Woodpecker secrets for CI identity → E: Backstage `resource:api` catalog entry (stock `backstage:1.53.1` image — Microcks **plugin** needs a custom image build first; decide then) → F: app 1.13.2→1.14.0 (re-vendor chart, re-apply dual-shell readinessProbe patch, values diff, `?v` bump).

### Completed (2026-08-19)
- **Phase B** (A is done: r4 Complete 1/1, r1–r3 pruned):
  - Topology corrected: live CI source is standalone **public** Gitea repo `bruno/link-shortener` (no `ebpro` org, no GitHub→Gitea mirror; Backstage entity `gitea.ebruno.fr/ebpro/gitops` is stale). Decision: Phase B/D changes go to Gitea; `openapi.yaml` also synced to the GitHub `gitops/link-shortener/` copy. Gitea PAT (bruno, read+write repository) provided — never committed.
  - Import proven via REST: `POST /api/artifact/upload?mainArtifact=true` → 201. CLI dead end documented: `quay.io/microcks/microcks-cli:1.13.2` doesn't exist (quay/Docker Hub publish nightly/sig tags only) — REST upload is the import path; `/api/artifact/download` (form `url=`) is the pipeline-friendly variant.
  - **RBAC gap found, fixed, live-verified (r7 Complete 1/1)**: Microcks 1.13.2 `SecurityConfiguration` is strict per-path, no hierarchy — `GET /api/services/{id}` and `/api/services/search` require `ROLE_user` even for admins (403 `insufficient_scope` with an admin-only grant; hit both the CI token and `platform-admins` UI users). Fix = cumulative role ladder: realm export (`platform-realm-configmap.yaml`) defines the `microcks-app` client roles `admin/manager/user` (live UUIDs pinned) and group mappings are cumulative (admins: admin+manager+user; engineers/developers: manager+user; readonly: user). Job `keycloak-microcks-roles-cumulative-20260818-r7` (`kubernetes/keycloak-realm/platform-realm-microcks-roles-job.yaml`) applied to the live realm (4 groups + `service-account-microcks-ci`) — **all 11 mappings verified [OK]** (commits 7538334/89c0f55/363f687).
    - E2E verified: fresh CI token now carries `resource_access.microcks-app.roles=["manager","admin","user"]`; `GET /api/services/{id}` → 200, `GET /api/services` → 200, `GET /api/services/search?name=link-shortener` → 200. Search param in 1.13.2 is **`name`** (`criterion` → 500 `pattern can not be null` from `findByNameLike(null)`). CI token lifespan is short (few minutes) — refetch per pipeline run.
    - **KC 26.7.0 kcadm gotchas (r5/r6 failures)**: generic `kcadm add <path> --payload` **does not exist** (`Did you mean: kcadm.sh add-roles?`, exit 2) — silent no-op; grants now go via REST POST over bash `/dev/tcp` with the kcadm-session admin token (no curl in the image, no awk either). Master admin token is short-lived → r6's user-grant section 401'd until r7 re-logs in + re-extracts the token before the SA grants.
  - **Service renamed to `link-shortener`**: `info.title` updated in `/tmp/opencode/openapi.yaml` → re-upload 201 → service `link-shortener:1.0.0-SNAPSHOT` (id `6a84d19dcc8d8f29c60e656f`, type REST, 7 ops); old `link-shortener API` (`6a84bf1ecc8d8f29c60e656c`) deleted (200).
  - **Mock endpoint finding (closed for our purposes)**: `/m/**` is unrouted (Spring 404 from the app itself); `/dynarest/**` is the `DynamicMockRestController` whose `getMockContext` **only matches `ServiceType.GENERIC_REST`** → 400 for our `REST`-type (OpenAPI-imported) service; `/api/mocks*` absent from the 1.13.2 spec. Consequence: the CI contract step is **import-based** (token → `POST /api/artifact/upload` → 201 + service listed) — deterministic, no mock dependency.
  - **Phase B done (2026-08-19): pipeline fully green — #75 `8bfbe16` success.** `clone` → `microcks-contract` (Keycloak `microcks-ci` token → `POST /api/artifact/upload` → 201) → `build` (Quarkus/Maven) → `docker-build-push` (`harbor.ebruno.fr/link-shortener/link-shortener:latest` pushed). Service live in Microcks as `link-shortener:1.0.0-SNAPSHOT`. `openapi.yaml` + `.woodpecker.yaml` on Gitea `bruno/link-shortener` main; GitHub gitops copy synced.
  - **Root cause 1 — Woodpecker v3 removed secret auto-injection** (v3.0.0): secrets must be mapped per step via `environment:\n  VAR:\n    from_secret: NAME`. This was the "parameter not set" failure.
  - **Root cause 2 — forge config-fetch 401** (pipelines `error`, no steps): per-user Gitea OAuth JWTs have **1h access-token lifetime** (Gitea 1.26 default) and Woodpecker v3.17 does **not** refresh them (no TOKEN env option on the gitea provider — verified from binary). Fixed via GitOps: `GITEA__oauth2__ACCESS_TOKEN_EXPIRATION_TIME=864000` (10d) + `REFRESH_TOKEN_EXPIRATION_TIME=2160` (90h) in `helm/releases/gitea/values.yaml` (the AppSet's real value source) + mirror in `bootstrap/helm-values/gitea-official.yaml` + `?v=5→6` bump (raw-URL valueFiles cache trap), commits a6030fb/3b11902. Bruno re-linked Gitea token in Woodpecker UI (one-time; new token = 240h). ⚠️ `ci-runner` (non-interactive) has **no Woodpecker user row** → first push will hit the same wall; needs one manual link or a service account.
  - **Root cause 3 — truncated Woodpecker secrets**: UI paste mangled `MICROCKS_CLIENT_SECRET` (86→17 chars) and `MICROCKS_HOST` had a trailing newline. Woodpecker stores secret `value` **plaintext** in DB `secrets` → fixed with byte-exact `UPDATE` (k8s `keycloak-secrets/CLIENT_SECRET_MICROCKS_CI` → secrets id 10, md5-verified; id 7 trimmed). UI re-entry is lossy; prefer this path for long secrets.
  - Woodpecker DB forensics: `pipelines.errors` (config-fetch jsonb), `log_entries` (hex-encoded step logs per `step_id`), `users` (per-user forge OAuth tokens).

### Findings & scope decisions (2026-08-19, Phase C)
- **Microcks 1.13.2 API archaeology (complete — jar forensics)**: streamed `app.jar` (132MB) via `kubectl exec cat` (no tar in image; podman store ≠ K3s containerd store) → extracted every controller route + DTO from class string pools and the bundled Angular app. Controllers live in `io/github/microcks/web` (NOT `rest`).
  - Confirmed routes: `PUT /api/services/{id}/operation` (body `OperationOverrideDTO` = defaultDelay, defaultDelayStrategy, dispatcher, dispatcherRules, parameterConstraints — no message bodies), `PUT /api/services/{id}/metadata`, `POST /api/tests` (body `TestRequestDTO` = serviceId, testEndpoint, timeout, filteredOperations, operationsHeaders, runnerType, secretName, oAuth2Context), `GET /api/tests/{id}`, `GET /api/tests/service/{id}`, `GET /api/tests/{id}/messages/{testCaseId}`, `POST /api/tests/{id}/testCaseResult`, **`POST /mcp/{service}/{version}` (+ `/sse`) — MCP endpoint exists in 1.13.2**, `/api/artifact/upload`, `/api/resources/{name}|/service/{id}`, `/api/copilot/samples/*`, `/dynarest/{service}/{version}/{resource}` (GENERIC_REST type only).
  - **Definitive: no message-creation REST endpoint exists in 1.13.2** (verified: ServiceController + TestController string pools + all 10 JS chunks — UI only ever calls `PUT .../operation` + `POST /api/tests`; `messagesMap` is read-only in UI).
  - **Mock/test content path = `example`/`examples` in the OpenAPI spec at artifact import**: `GET /api/services/{id}` returns `{service, messagesMap}` (keyed by operation name; empty when spec has no examples). No examples ⇒ empty mocks.
  - **Mock invocation = `/api/rest/{service}/{version}/**`** (`RestController`) — e.g. `GET /api/rest/link-shortener/1.0.0-SNAPSHOT/api/links/{code}`.
  - `Message` domain = `{content, headers, operationId, testCaseId, name, sourceArtifact}`; a test run replays each message's request against `testEndpoint` and compares with the expected response.
- **Contract-first SOTA 2026 scope (agreed with user)**:
  - **Phase C+ (NEW — Pact CDK loop)**: `quarkiverse/quarkus-pact` (provider + consumer, test scope). Trust verified: official Quarkiverse, maintained by **Holly Cummins (author of Pact-JVM)**, used in Quarkus Super Heroes, Apache-2.0, latest 1.6.0; config is via standard Pact JVM system properties (`-Dpact.brokerUrl`, `-Dpact.provider.version`, …) — no Quarkus config. In-cluster Pact Broker (`pact-broker` ns): CI must use `http://pact-broker.pact-broker.svc:80` + basic auth (user `pactbroker`, k8s secret key `user-password`) — public `pactbroker.ebruno.fr` sits behind Traefik `fwd-auth`. One `mvn verify` = consumer publish → provider verification (in-JVM Quarkus test, no separate server) → results publish to broker.
  - **Phase D (expanded)**: drift check gains quality gates — `spectral lint openapi.yaml` + `oasdiff break origin/main openapi.yaml` (fail on breaking change w/o version bump) + spec↔code drift (generate spec from Quarkus code via `quarkus-smallrye-openapi` — already in pom — and diff vs committed `openapi.yaml`).
  - Phase E: Backstage catalog links Microcks + Pact Broker on the `resource:api` entry. Phase F: Microcks 1.13.2→1.14.0 (NOT a blocker: MCP + per-operation overrides already exist in 1.13.2).
  - **Microcks↔Quarkus: no extension exists** (verified: none in Quarkiverse; 1.13.2 jar has no OTLP traffic-capture receiver — its OTel config is self-observability only).
  - **Extensions to add**: `quarkus-pact-provider`, `quarkus-pact-consumer` (test), `quarkus-opentelemetry` (main — feeds platform OTel stack; standard bridge if future Microcks adds traffic capture).
  - **Maven wrapper**: already in repo (`mvnw` 3.3.4, only-script, pinned Maven 3.9.16 = exact CI-image version). Fixes: `distributionUrl` → in-cluster Nexus (fresh CI containers must not reach repo.maven.apache.org); `.woodpecker.yaml` build → `./mvnw -s /tmp/settings-nexus.xml clean verify`, **drop `-DskipTests`** (Pact loop needs tests running in CI).
- **Phase C unblocked**: 7 realistic `example` payloads added to `openapi.yaml` (all ops + POST request body), pushed `58c516f` → pipeline re-imports → `messagesMap` should populate.
  - Remaining: mock curl via `/api/rest/...` → `POST /api/tests` (testEndpoint = mock base for self-consistent demo; Phase D repoints at the live app) → MCP JSON-RPC demo (`POST /mcp/link-shortener/1.0.0-SNAPSHOT`: initialize → tools/list → tools/call) → Pact smoke in a cluster maven pod (no JDK on the gitops host).

### Completed (2026-08-19, Phase C+ Pact loop)
- **Pact CDK loop verified green locally** (Quarkus 3.37.4 + `quarkiverse/quarkus-pact` 1.6.0, Java 25): consumer test 1/1, provider test 3/3 — provider runs the real app (Quarkus test) against the CNPG DB via local port `15432` (SCRAM bypass: JDBC URL with `?user=&password=` query params; **local-only**, CI needs env/secret DB config).
  - Pact DSL fix: response body is a **flat JSON array** → `like(Map.of(...))` per element (list-shaped matchers failed); dropped unneeded provider state.
  - **App bug fixed: `POST /api/links` 500** — `LinkResource.create()` now fills `shortcode` (`Link.randomCode()`) + `createdAt` when absent (entity is bound directly from the request JSON; request field is `targetUrl`). Commits `02911d9`, `a8ffba6` on Gitea `bruno/link-shortener` main → pipeline #29 success (16:36 UTC) → Harbor `:latest` carries the fix.
- **Stale `:1.0.1` image pin — full root cause, resolved (commit `3a105ed`)**:
  - Symptom: renders pinned `harbor.ebruno.fr/link-shortener/link-shortener:1.0.1` despite git `deployment.yaml` = `:latest`. Survived: ImageUpdater CR removal (`a4cae78`), manifest-cache flush, app-controller restart, hard refreshes. App object verified surgically clean (spec `kustomize: null` under 100 s of 2 s-interval monitoring during reconcile; 0 annotations/labels/managedFields; AppSet template clean; external image-updater pod inactive `images_updated=0`).
  - **Root cause**: ArgoCD is actually **v3.5.1** (not v2.14 as AGENTS.md says). The repo-server's `mergeSourceParameters` (`reposerver/repository/repository.go` ~L1863) reads **`.argocd-source-<appName>.yaml`** from the app's path **in the git repo** and applies it as a JSON merge-patch onto the `ApplicationSource` at render time — this is the image-updater's **git write-back target**. The pin file (`kustomize: images: […:1.0.1]`) was committed on Aug 15 by the updater's write-back (`eab8c76 "build: update of application link-shortener"`) and survived the CR deletion. Explains everything: clean app spec, clean AppSet, pin on every render, constant manifest cache-key FNV hash across revisions.
  - Fix (git-only): `git rm kubernetes/link-shortener/.argocd-source-link-shortener.yaml` → `3a105ed` → hard refresh → rev `a4cae78`→`3a105ed` → auto-sync → pod `link-shortener-787678d48b` `:latest` Running, app Synced/Healthy.
  - Live verification: `POST /api/links {"targetUrl":"https://example.com"}` → **200** with server-generated `shortcode` + `createdAt`; `GET /api/links/{code}` → 200; `DELETE` → 204 (test row removed).
  - ⚠️ Operational note: any future ArgoCD image-updater (or `.argocd-source*.yaml` file) in this repo **is load-bearing render state** — deleting the updater must also delete its write-back files (repo-wide check: `find . -name ".argocd-source*" -not -path "./.git/*"` — none remain).

### In Progress
- **Phase C+ (Pact CDK)**: local consumer/provider loop green (above). Next: wire Pact Broker into Woodpecker CI — `./mvnw -s /tmp/settings-nexus.xml clean verify` (drop `-DskipTests`; mvnw `distributionUrl` → in-cluster Nexus), broker via standard Pact JVM sysprops `-Dpact.brokerUrl=http://pact-broker.pact-broker.svc:80` + basic auth (`pactbroker` / k8s secret key `user-password`) + `-Dpact.provider.version=1.0.0`; CI DB config for provider test (env/secret, no SCRAM bypass).
- **Phase D**: drift step gets `spectral lint` + `oasdiff break` + code↔spec drift gate in `.woodpecker.yaml`.
- Phase E: Backstage `resource:api` links Microcks + Pact Broker. Phase F: Microcks 1.13.2→1.14.0 (separate window, re-vendor chart + dual-shell readinessProbe patch).

### Blocked
- Nothing.

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

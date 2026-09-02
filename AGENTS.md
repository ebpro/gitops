# GitOps Platform - Agent Rules

## Golden Rules
- **Git-push only — NO exceptions** — Never run `kubectl patch`, `kubectl apply`, `kubectl edit`, `kubectl set image`, or `kubectl delete` on any ArgoCD-managed resource. Fix things by editing files in this repo and committing/pushing. ArgoCD will reconcile automatically.
- **NEVER delete or bypass ArgoCD Applications** — Never `kubectl delete application`, never annotate `suspend`, never comment out AppSet entries to skip reconciliation. If an app is stuck, fix its source files (helm-values, manifests, ingress) and let ArgoCD re-render.
- **NEVER manage StatefulSets/Deployments/Services/ConfigMaps directly** — These are owned by ArgoCD. Cluster-side patches WILL be reverted by selfHeal. The only valid way to change them is through git.
- **NEVER use `kubectl patch`, `kubectl annotate`, `kubectl scale`, `kubectl apply`, `kubectl delete` or `kubectl exec` to 'fix' ArgoCD apps** — Even `kubectl scale statefulset --replicas=0/1` is forbidden. Edit the Helm values or manifests in git and push. ArgoCD reconciliation chain: `gitops-platform` app → `helm-apps` / `kubernetes-manifests` AppSets → individual Applications → live resources. If ArgoCD isn't picking up changes, verify the chain by checking `gitops-platform` sync status. **Never bypass it.**
- **ArgoCD auto-sync** — All apps use `automated: { prune: true, selfHeal: true }`. Changes propagate automatically, but the `gitops-platform` App often stalls due to GitHub API timeout. When changes aren't picked up within 2 minutes, **force reconcile the chain** by editing any file in the target `bootstrap/` or `helm/` directory and committing/pushing — the file change triggers ArgoCD's Git webhook to refresh faster than waiting for poll cycle.
- **Secrets in Vault** — All credentials live in HashiCorp Vault. Use ExternalSecrets to reference them. Never commit plaintext passwords.
- **Cilium CNI** — Tunnel mode, pod CIDR `10.42.0.0/24`, service CIDR `10.42.0.0/16`.
- **Single namespace per app** — Each app except orchestrator is deployed to its own namespace.
- **Immutable cluster state** — The cluster must NEVER be touched directly. All changes flow through git. Violating this rule causes split-brain: ArgoCD will detect drift and rollback within 180s. If an AppSet hasn't re-rendered, refresh `gitops-platform` app first, then wait for the chain to propagate.

## Architecture
- **K3s v1.35.5+k3s1** — Single-node cluster (`compute-lsis-2`), kernel `6.8.0-124-generic`
- **Cilium CNI** — Tunnel mode, eBPF observability
- **ArgoCD v3.5.1** — Auto-sync with prune/selfHeal
- **CloudNativePG v0.29+** — PostgreSQL management via `Cluster` CRDs
- **Vault + ExternalSecrets** — Secret management
- **Traefik + Cert-Manager** — Ingress (public/local DNS)
- **OpenTelemetry** — Observability (metrics → Prometheus, traces → Tempo, logs → Loki)

## Directory Structure
```
├── bootstrap/                    # ArgoCD ApplicationSets
│   ├── appset-helm.yaml          # Helm app definitions (list-based)
│   ├── appset-manifests.yaml     # Kustomize app definitions (git/git tree-based)
│   ├── app-nexus.yaml            # Standalone Helm app (Nexus)
│   ├── app-plane.yaml            # Standalone Helm app (Plane)
│   ├── app-vault.yaml            # Standalone Helm app (Vault)
│   ├── helm-values/              # External values files
│   └── k8s-apps/                 # Standalone manifests
├── clusters/                     # Cluster-specific overrides (future multi-cluster)
├── helm/
│   ├── apps/                     # Generated App manifests (via gen-helm-apps-full.sh)
│   └── releases/<name>/values.yaml  # Per-app Helm overrides (PRIMARY source of truth)
├── kubernetes/
│   ├── postgresql/               # CNPG Cluster definitions + ExternalSecrets
│   ├── ingress/                  # Traefik IngressRoute
│   ├── declarative/              # Declarative API resources
│   ├── csi-snapshot-controller/  # CSI driver configuration
│   └── cilium/                   # Cilium NetworkPolicies
└── gen-helm-apps-full.sh         # Utility to regenerate helm/apps/ definitions
```

## Bootstrap Flow
1. `bootstrap/appset-helm.yaml` — Creates ArgoCD Applications from list elements (most apps)
2. `bootstrap/appset-manifests.yaml` — Creates ArgoCD Applications from git tree directories
3. `bootstrap/app-nexus.yaml`, `app-plane.yaml`, `app-vault.yaml` — Standalone Applications

## Modifying Helm Apps
1. Edit `helm/releases/<app>/values.yaml`
2. Commit and push to main
3. ArgoCD auto-syncs — verify with `kubectl get app <app> -n argocd`
4. ArgoCD pull requests — verify status with `kubectl argocd app <app> sync`

## CloudNativePG Clusters
DNS pattern: `<cluster-name>-rw.<namespace>.svc.cluster.local:5432` (read-write/primary; a read-only `<cluster-name>-ro` variant is also created)

| CNPG Cluster | Namespace | Storage | Max Conns |
|---|---|---|---|
| `pact-broker-db` | `pact-broker` | 5Gi | 200 |
| `sonarqube-db` | `sonarqube` | 20Gi | 400 |
| `nexus-db` | `nexus` | 20Gi | 300 |
| `backstage-db` | `backstage` | 10Gi | 200 |
| `keycloak-db` | `keycloak` | 20Gi | 500 |
| `harbor-db` | `harbor` | 20Gi | 300 |
| `plane-db` | `plane` | 20Gi | 200 |
| `woodpecker-db` | `ci` | 10Gi | (default) |
| `link-shortener-db` | `link-shortener` | 20Gi | (default) |
| `matrix-db` | `synapse` | 10Gi | (default) |

**Managed via**: `kubernetes/postgresql/<db>-yaml` files synced by ArgoCD.
**Debug via**: `kubectl exec -it <cluster>-1 -n <ns> -- psql -U postgres -d <dbname>`
**ExternalSecrets**: `kubernetes/postgresql/*-external-secret.yaml` — Vault-backed app-user credentials

## Debugging Workflow
1. `kubectl get app <app> -n argocd -o yaml` → check sync/health status
2. `kubectl logs <pod> -n <namespace> -c <container> --tail=100` → check logs
3. `kubectl describe deployment/<app-name> -n <ns>` → check scheduling/health

## Troubleshooting Patterns
- **App stuck in Progressing**: Check pod logs, then check resource status
- **App OutOfSync**: `kubectl argocd app <app> diff` to see drift, fix in git
- **ArgoCD not picking up changes**: Verify the full reconciliation chain: `gitops-platform` (sync status) → `helm-apps`/`kubernetes-manifests` AppSets → individual Application → live resource. If AppSet wasn't updated, refresh `gitops-platform`: `kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite`. If Application wasn't updated, annotate it similarly. **Never patch the live resource** — fix the source files, commit, push, and refresh the chain.
- **ArgoCD ignores remote valueFile changes**: Apps that reference `valueFiles` via raw GitHub URLs (e.g. `https://raw.githubusercontent.com/.../values.yaml?v=N`) are cached aggressively. Even after pushing a new commit, ArgoCD won't re-download. **Bump the `?v=N` query param** in `bootstrap/appset-helm.yaml` to force a cache miss, then commit and push.
- **Helm chart drops pod-level settings**: Some charts do not propagate top-level `hostAliases`, `tolerations`, or `affinity` to the actual pod spec. Always verify with `kubectl get <resource> -o json | python3 -c "..."` to confirm the pod spec contains the expected fields. If missing, use the chart's supported mechanisms (e.g., `server.podTemplate`) instead.
- **CNPG `ScheduledBackup` cron needs 6 fields (with seconds)**: CNPG's cron parser requires `sec min hour day month weekday` (e.g. `0 0 3 * * *` = daily 03:00). A 5-field expr silently mis-parses (e.g. hourly `:03` storm). Fix `schedule:` in `kubernetes/postgresql/<db>-scheduled-backup.yaml`.
- **Vault `secret/` KV is writable with the root token** (verified 2026-08-20: PUT/read/DELETE all OK via `http://vault-active.vault.svc.cluster.local:8200`). The earlier "read-only even with root" note is obsolete. KV layout is flat/mixed (some parents are leaves, not dirs) → always address **full leaf paths** (`secret/data/<a>/<b>`), never try to list parents. AppRole (ESO) is intentionally read-scoped (403 on list, 200 on its keys).
- **CNPG image standardized**: all clusters now pin `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` in git. `matrix-db` was moved from the `keycloak` ns to `synapse` (2026-08-20).
- **gitops-platform OutOfSync**: Even after pushing commits, `gitops-platform` may go OutOfSync and stall. Run `kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite` to force a refresh. If it persists, check the cluster network and GitHub API availability.
- **Pact broker HAL links + UI base URL (single `PACT_BROKER_BASE_URL`)**: The broker generates ALL absolute URLs — HAL links (e.g. `pb:provider-pacts-for-verification`) **and** the rendered UI (CSS/JS/favicon tags + page links + `BASE_URL` JS global in `lib/pact_broker/ui/views/layouts/main.haml`) — from its configured base URL. A single in-cluster value breaks the public UI (browsers can't reach `pact-broker.pact-broker.svc` → unstyled page, dead links); a single public value 401s the anonymous CI pact-jvm `for-verification` POST behind `fwd-auth`. Fix (no chart fork needed): set `broker.config.baseUrl` in `helm/releases/pact-broker/values.yaml` to a **space-separated pair** `"http://pact-broker.pact-broker.svc:80 https://pactbroker.ebruno.fr"`. The broker's `Rack::PactBroker::SetBaseUrl` middleware (supported since broker v2.79.0; chart 6.1.0 passes the one env verbatim and the app space-splits it) picks per request the entry matching the request's scheme+host (X-Forwarded headers first, then Host-only, else first entry) — Traefik always sends `X-Forwarded-Proto/Host`, so public browsers match the public entry and in-cluster CI falls back to the in-cluster entry. **Keep the in-cluster URL first** — it is the fallback for non-matching requests, which is what keeps CI HAL links in-cluster. Debug resolved base URL: `curl -s http://pact-broker.pact-broker.svc:80/diagnostic/status/heartbeat` (in-cluster), or add `-H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: pactbroker.ebruno.fr'` (e.g. from the broker pod) to simulate a public request.
- **Image pinned in renders despite clean git/app spec**: ArgoCD v3 repo-server reads `.argocd-source.yaml` / `.argocd-source-<appName>.yaml` at the app's path **in the git repo** and merge-patches it onto the ApplicationSource at render time (image-updater git write-back target). These dotfiles are hidden from `kustomize build` (dotfiles ignored) → manifests look clean locally but ArgoCD renders differently. Audit with: `find . -name ".argocd-source*" -not -path "./.git/*"`. Removing an image-updater CR requires deleting its write-back file(s) too.
- **Plane version bump trap (immutable migrator Job + ArgoCD v3 memoization)**: The chart's migrator Job is named `plane-api-migrate-{{.Release.Revision}}`, and ArgoCD's helm render pins `.Release.Revision=1`. On a version bump the *completed* Job `plane-api-migrate-1` becomes immutable (`spec.template`) → the whole sync operation fails → `plane-api-wl` pods loop forever on "Waiting for database migrations to complete" (the api's `wait_for_migrations` command only polls the migration plan; migrations run in the Job). Fix: `kubectl delete job plane-api-migrate-1 -n plane` (one-off data-level op), then **change `targetRevision` in `bootstrap/app-plane.yaml`** — ArgoCD v3.5.x memoizes failed sync attempts per chart revision (`Skipping auto-sync: failed previous sync attempt to [X]`) and never auto-retries the same revision. The ArgoCD REST session API is unusable (admin password login disabled), so the git revision change is the only manual-sync lever. Note: chart files `plane-ce` 1.6.1/1.6.2 are near-identical (only `appVersion`/default `planeVersion` differ; our values pin the image) — **but** the templates embed `helm.sh/chart: plane-ce-<version>` and `app.kubernetes.io/version: <appVersion>` into pod/job **labels**, so bumping the chart *version* alone changes rendered pod templates → full rollout of all Plane workloads + Job template change → same immutability failure, with zero functional gain. 1.6.2 was tried 2026-08-20 and reverted; **1.6.1 is the settled state**.
- **Plane CE API tokens (`X-Api-Key` header, `/api/v1/` surface only)**: The web-app API (`/api/…`, session auth) 401s "Authentication credentials were not provided" for `Authorization: Token/Bearer` *and* `X-Api-Key` (e.g. `/api/users/me/`). Plane API tokens (`plane_api_*`, generated in Plane UI) work via the **`X-Api-Key`** header, but only on the **`/api/v1/`** surface (the `plane/api` subproject; `BaseAPIView.authentication_classes = [APIKeyAuthentication]` → looks up the `APIToken` model): `curl -H "X-Api-Key: <token>" https://plane.ebruno.fr/api/v1/users/me/` → 200. Unauthenticated `GET /api/instances/` exposes `instance.current_version` (drift guard). Platform token: Vault `secret/data/plane` key `apiToken` → ExternalSecret `plane-api-token` (ns `ci`, `kubernetes/ci/`) → Woodpecker secret `plane_api_token` → `verify-plane` pipeline step (token auth + version drift vs `PLANE_EXPECTED_VERSION`). Note: this Vault CLI has no `kv merge` (full re-`put` needed), and `vault-init`'s working admin key is `root_token` (`admin_token` is invalid); KV-v2 `vault kv put` paths must be user-paths (no `secret/data/` prefix — the prefix double-writes).
- **Gitea 1.26 OAuth app legacy-row migration gaps**: Upgrading Gitea to 1.26.x does NOT convert `oauth2_application` rows created under older Gitea. (1) `redirect_uris` must be a JSON array (e.g. `["https://app.example.fr/auth/gitea/callback/"]`) — legacy plain-text values 500 the authorize endpoint (`GetOAuth2ApplicationByClientID: invalid character 'h' looking for beginning of value`). (2) `client_secret` must store a **bcrypt hash** — `ValidateClientSecret` uses `bcrypt.CompareHashAndPassword`; legacy plaintext secrets fail token exchange with 400 `unauthorized_client: invalid client secret` (Plane symptom: `?error_code=5123&error_message=GITEA_OAUTH_PROVIDER_ERROR` loop). Rows fixed in-cluster 2026-08-20: Plane (id=6, both), Backstage (id=4, redirect_uris only — its client ID config is a separate issue). If the Gitea DB is ever restored/rebuilt, re-apply. Debug: `kubectl exec -n gitea gitea-postgresql-0 -- psql -U gitea -d gitea -c "SELECT id, name, left(client_secret,7), redirect_uris FROM oauth2_application;"` (healthy 1.26 rows: `$2b$` prefix, JSON-array redirect_uris).
- **Harbor OIDC client secret is DB-pinned after first install (env is seed-only)**: Harbor core reads `oidc_client_secret` from the `properties` table (core DB `registry` on `harbor-db-1`), stored as `<enc-v1>`+base64(IV‖AES-128-CFB(plaintext)) with the key from `/etc/core/key` (K8s secret `harbor-core`, persists across restarts). `CORE_OIDC_CLIENT_SECRET` (env) only seeds the row when it's absent — **rotating the secret in Vault/Keycloak leaves Harbor sending the stale secret** → Keycloak rejects with `invalid_client_credentials`, user sees `oauth2: "unauthorized_client"` (core log at `/core/controllers/oidc.go:141`, Keycloak event `CODE_TO_TOKEN_ERROR`). The keycloak-reconciler never rotates existing clients, so every rotation needs a manual Harbor DB update (2026-08-20 fix): encrypt the current Vault secret with the core key (round-trip-verify), `UPDATE properties SET v='<enc-v1>…' WHERE k='oidc_client_secret'` (backup old row first), drop `cache:cfgs` in `harbor-redis` db 0 if present (1-min TTL, usually gone), then bump `CORE_RESTART_TRIGGER` in `helm/releases/harbor/values.yaml` + the `?v=` on the harbor valueURL in `bootstrap/appset-helm.yaml` so core reloads from the DB. A clean start shows no `decrypt password failed`; that error line means a malformed blob.
- **Pod CrashLoopBackOff**: Check ALL container logs (sidecars may be the problem)
- **Maintenance mode (SonarQube)**: Database migration failed — check migration logs, verify DB schema and PKs match migration expectations
- **Data store not found (Nexus)**: JDBC driver missing, or storeProperties not correctly formatted
- **PVC stuck in Terminating**: `kubectl patch pv <pv> -p '{"metadata":{"finalizers":null}}'` as **LAST resort**
- **CNPG cluster stuck**: Check cluster config, verify ExternalSecret is creating the password correctly
- **CNPG `DatabaseRole` `ensure: present` does NOT re-set an existing role's password**: Applying a `DatabaseRole` with `ensure: present` to a role that **already exists** in the DB only records the secret's `resourceVersion` in `.status` — it does **not** run `ALTER ROLE … PASSWORD`. If the role pre-dates the role/secret wiring (or was created with a different password, e.g. during a `spec.roles`→`DatabaseRole` migration), the app's JDBC auth fails with `FATAL: password authentication failed for user "<role>"` and the app pod CrashLoopBackOffs — **even though the ESO→Secret→DatabaseRole chain all look green/Synced**. Telling sign: the secret `resourceVersion` never changed (ESO bumps it on any diff), so Vault was never rotated — the drift is on the **DB side**. Fix (data-level, sanctioned): align the DB role to the Vault value, never printed, via psql on the CNPG pod: `PASS=$(kubectl get secret <eso-secret> -n <ns> -o jsonpath='{.data.<key>}' | base64 -d)` then `kubectl exec -i -n <ns> <cluster>-1 -c postgres -- psql -U postgres -d <db> -v pass="$PASS" <<'SQL'` / `ALTER ROLE <role> WITH PASSWORD :'pass';` / `SQL`. Note: psql `:'var'` interpolation does **not** work under `-c` (reaches the server literally → syntax error); it must go via stdin. Verify with `PGPASSWORD="$PASS" psql "host=127.0.0.1 user=<role> dbname=<db> sslmode=disable" -tAc "SELECT current_user;"`. 2026-09-02: SonarQube role `app` drifted since the 2026-08-17 `spec.roles`→`DatabaseRole` migration → ~15-day silent outage; fixed by the ALTER ROLE above, pod self-recovered via crash-loop backoff (no pod delete needed).
- **Keycloak slow startup**: CNPG DB may not be ready — add init container retry loop (default 60s startup probe handles this)
- **Nexus proxy 404-poisoning (negative cache)**: `maven-central` proxy negative-cached a transient upstream 404 for the full `negativeCache.timeToLive` (was 1440 min). Symptom in Maven: `Unresolveable build extension: ... quarkus-maven-plugin ... Failed to read artifact descriptor for org.<g>:<a>:<v>` + `Unknown packaging: quarkus` (the packaging error is only the consequence). Diagnose: `kubectl exec -n nexus nexus-nexus3-0 -c nexus3 -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/repository/maven-central/<gav-path>` (loopback = ground truth; also test pod egress `curl https://repo1.maven.org/...`). **Never trust `nexus.ebruno.fr` as ground truth** — a 404 there can be an ingress-route artifact while in-cluster serving is fine (2026-08-21: `org.wildfly.common:wildfly-common:2.0.1` 404'd via the public ingress while `maven-public` loopback served 200). TTL is now 15 min (`helm/releases/nexus/values.yaml`).
- **SonarQube 26 project/role provisioning (no local admin password)**: the SQ pod has no `SONAR_ADMIN_PASSWORD`; built-in `admin` works **only** via HTTP-header SSO on loopback from inside the pod (`sonar.web.sso.enable=true`, one header does it all: `Gap-Auth`): `kubectl exec -n sonarqube sonarqube-sonarqube-0 -c sonarqube -- sh -c 'curl -s -H "Gap-Auth: admin" http://localhost:9000/...'` — this is SonarQube's break-glass path. The 26.x API surface changed: create project `POST /api/projects/create` param is **`project`** (not `projectKey`); grant a user `POST /api/permissions/add_user` (`projectKey`, `login`, `permission`; project perms: `admin, codeviewer, issueadmin, securityhotspotadmin, scan, user`); `/api/user_roles/update` and `/api/users/who_am_i` are gone; full webapi index at `GET /api/webservices/list`. Provisioned 2026-08-21: project `link-shortener` exists, `bruno@ebruno.fr` = project admin; the Woodpecker `sonar-qa` step authenticates with global token `ci` (USER_TOKEN, bruno, scope GLOBAL). Verify grants in `sonardb`: `user_roles.role` joined via `user_uuid`→`users.login` and `entity_uuid`→`projects.uuid` (project key column is **`kee`**).

## Operator-First Philosophy
We delegate operations to controllers (operators). Never manage `Deployment`, `StatefulSet`, or `Release` directly for critical infrastructure. Fix by editing git, never patching. The cluster should be self-healing.

## Operator Stack
| Operator          | Status      | Namespace                      | Purpose                        |
|-------------------|-------------|--------------------------------|--------------------------------|
| CloudNativePG     | ✅ Deployed | cnpg-system                    | PostgreSQL lifecycle           |
| External Secrets  | ✅ Deployed | external-secrets               | Vault → K8s Secrets            |
| Kyverno           | ✅ Deployed | kyverno                        | Policy enforcement             |
| OpenTelemetry     | 🚧 Deployed | opentelemetry-operator-system  | Observability instrumentation  |
| VPA               | 🚧 Deployed | vpa                            | Resource recommendations       |
| Velero            | ❌ Planned  | velero                         | Backup & restore               |
| KEDA              | ❌ Planned  | keda-system                    | Event-driven autoscaling       |
| Descheduler       | ❌ Planned  | kubesphere                     | Pod placement optimization     |
| Keycloak          | ✅ Deployed | keycloak                       | Central SSO / Identity Provider |
| ARC               | ✅ Deployed | actions-runner-controller      | GitHub Actions runners (App auth) |
| Microcks          | ✅ Deployed | microcks                       | API mocking / contract tests   |
| Trivy Operator    | ✅ Deployed | trivy-system                   | Image/manifest scanning        |
| Woodpecker CI     | ✅ Deployed | ci                             | VCS-hosted CI (v3)             |

## CNPG Strategy
**One dedicated cluster per critical app.** Isolates upgrades, tuning, and failover.
- DNS: `<cluster-name>-rw.<namespace>.svc.cluster.local:5432` (read-write/primary; `-ro` read-only variant also created)
- Storage class: `local-path` or `nfs-client` (tuned per-app)
- Managed via: `kubernetes/postgresql/<name>/*.yaml` synced by `bootstrap/appset-manifests.yaml`
- Debug: `kubectl exec -it <cluster>-1 -n <ns> -- psql -U postgres -d <dbname>`

## Platform v2 (Declarative Intent)
Future state: Developers declare **intent**, operators reconcile:
```yaml
kind: Application
metadata:
  name: payment-service
spec:
  database:
    engine: postgres
    size: small
  ingress:
    host: payment.example.com
  autoscaling:
    enabled: true
```
Behind the scenes, operators provision: CNPG Cluster, ExternalSecret + Vault, Traefik IngressRoute, KEDA scaler, OTel instrumentation, Prometheus monitoring, Loki logs, Tempo traces, Velero backups, Kyverno policies.

## ArgoCD Team Platform Status (2026-08-20)
```
healthy: 49/50 apps (98%)
  Synced/Healthy: all infra, identity, apps
  vault: Health Unknown, Sync (metadata-only app, by design)
```
**Full deep audit:** see `docs/deep-audit.md`.
## SSO & Identity Architecture
Platform is migrating to **Keycloak as single source of identity**. Central authentication via Keycloak Helm Chart (Quarkus), GitOps-managed realms.

### Authentication Matrix
| App | Protocol | Native SSO | Fallback Required |
|---|---|---|---|
| ArgoCD | OIDC | ✅ | — |
| Harbor | OIDC | ✅ | — |
| Gitea | OIDC | ✅ | — |
| Grafana | OIDC | ✅ | — |
| Vault | OIDC | ✅ | — |
| Backstage | OIDC | ✅ | — |
| Plane | OIDC/SAML | ✅ | — |
| Microcks | Keycloak | ✅ | — |
| Nexus OSS | RUT (`Gap-Auth`) | ✅ (RUT + sso-sync) | Local Basic for CI/break-glass |
| SonarQube CE | HTTP header (`Gap-Auth`) | ✅ (native CE 26+ header SSO) | Manual permissions (Phase 1) |
| Woodpecker CI | Gitea OAuth | ❌ | Gitea OAuth (indirect SSO via Keycloak) |

### Identity Model
```
Users → Groups → Roles → Application permissions
```
Groups: `platform-admins`, `platform-engineers`, `developers`, `security-team`, `qa-team`, `readonly`

### Known SSO Limitations

**Keycloak 26+ user profile** — the default profile requires `firstName`/`lastName` on every user. Users without them get a pending `VERIFY_PROFILE` required action and password grants fail with `400 invalid_grant: Account is not fully set up` (code flow is unaffected). Bot users created via API must set both fields.

**Keycloak realm import is `IGNORE_EXISTING`** — `kc.sh start --import-realm` only loads realms that do not exist yet (log: `KC-SERVICES0030 ... Strategy: IGNORE_EXISTING`). Rebooting the pod never re-syncs an existing realm from git; applying file changes to a live realm requires admin API/kcadm or a deliberate rebuild. The file is still fully parsed at startup, so invalid JSON always crash-loops the pod. **Schema-level corruption also crash-loops** (2026-08-21 incident): a realm export from the Keycloak admin console carried an invalid nested `roles` block inside the `microcks-app` client → `Unrecognized field "roles" (class org.keycloak.representations.idm.ClientRepresentation)` on every boot, 503s on all OIDC token endpoints (Woodpecker `microcks-contract` step failed). Fixed in `4fd1fc4` — client roles belong in the realm-level `roles.client` map, not inside the client object. The repo's own Woodpecker `validate-realm` step checks JSON well-formedness only, not Keycloak's import schema — after any admin-console export, grep client entries for a nested `"roles"` field.

**Keycloak 26.7.0 group membership endpoints** — the "classic" admin endpoints 404 on this build: `GET /admin/realms/{realm}/groups/{gid}/users`, `POST .../groups/{gid}/members/{uid}`, `POST .../users/{uid}/role-mappings/groups/{role}`. Use `PUT /admin/realms/{realm}/users/{user-id}/groups/{groupId}` to add a user to a group (204). Verify membership in the DB (`user_group_membership` joined to `user_entity`/`keycloak_group`) since `GET users/{id}` may report empty `groups` even after a successful PUT.

**Harbor has no group→role mapping** — the OIDC client scope is `openid profile email` (no `groups` claim), so Keycloak groups do **not** grant Harbor access. Harbor admin is the local `sysadmin_flag` in the `registry` DB (`harbor_user` table, pod `harbor-db-1`). `bruno@ebruno.fr` was set `sysadmin_flag=true` on 2026-08-20; a realm rebuild or CNPG restore reverts it. CI pushes use project-scoped robots — the backstage robot's **login** is `robot$library+backstage` (Harbor 3.x auto-prefixes the project name to the robot display name `backstage`; the old `robot$backstage` login 401s with an empty-grant token) on project `library` (Push+Pull), stored at Vault `secret/data/harbor/backstage` → ESO → `ci/woodpecker-harbor-backstage` (`kubernetes/ci/harbor-backstage-external-secret.yaml`); Woodpecker repo secrets `HARBOR_USERNAME`/`HARBOR_PASSWORD` map to it per-repo (pattern from `bruno/link-shortener` `.woodpecker.yaml`).

**Woodpecker CI** does not support native OIDC. Uses Gitea OAuth (indirect chain: Woodpecker → Gitea → Keycloak).

- `WOODPECKER_GITEA_URL` serves **both** OAuth redirects and API calls — Woodpecker v3+ ignores `WOODPECKER_GITEA_OAUTH`
- Always set `WOODPECKER_GITEA_URL` to the **public** Gitea URL — never an internal ClusterIP
- The Woodpecker helm chart `server-3.0.1` does not propagate top-level `hostAliases` to the pod spec — do not rely on it

### Nexus OSS SSO (RUT)
Nexus has no native OIDC. SSO is achieved with a custom `rutauth` capability: oauth2-proxy emits a `Gap-Auth` header (Keycloak user email) which Nexus authenticates as a local user; authorization comes from local roles.
- Realms active order: `["rutauth-realm", "NexusAuthenticatingRealm"]` — local Basic is kept for in-cluster CI/machines and break-glass.
- `nexus-nexus3-sso-sync` CronJob (every 15 min in `helm/releases/nexus/values.yaml` → `ssoSync`): mirrors `platform` realm group membership into local Nexus users + roles (`ssoSync.groups` mapping `group:role`), creates missing users with a random unusable password, prunes local users no longer in any mapped group. It never touches passwords; `ssoSync.protectedUsers` (admin, anonymous, machine accounts) are never pruned.
- Capability PUT through the REST API requires the server-side `id` + `version` in the payload (otherwise 500 NPE); GET-by-id is 405 — merge from the `GET /capabilities` list (see `scripts/configure.sh`).
- Residual risk: in-cluster clients can still bypass oauth2-proxy and hit Nexus with a forged `Gap-Auth` header or local Basic. No public `skip-auth-regex` exists for machines; a Cilium NetworkPolicy restricting in-cluster access is the planned mitigation.

### SonarQube SSO (HTTP Header)
SonarQube **Community Build 26+** has native header authentication (documented for CE on docs.sonarsource.com, `authentication/http-header`) — no Commercial edition, no OIDC plugin. It reuses the same oauth2-proxy `Gap-Auth` flow as Nexus, natively.
- SonarQube props (`helm/releases/sonarqube/values.yaml` → `sonarProperties`): `sonar.web.sso.enable=true` + `sonar.web.sso.loginHeader/nameHeader/emailHeader=Gap-Auth`. A fourth prop `sonar.web.sso.groupsHeader` (default `X-Forwarded-Groups`) exists for future group sync.
- oauth2-proxy v7.6.0 `addHeadersForProxying` sets the **response** header `GAP-Auth` (session email; `GAP-Auth` only, no other identity headers) on both `/checkauth` (catch-all → `static://200`) and `/oauth2/auth` (AuthOnly → 202). Traefik middleware `fwd-auth` (`kubernetes/ingress/sonarqube-middleware.yaml`) copies it to the upstream request via `authResponseHeaders: [Gap-Auth]`.
- Provisioning is JIT: SonarQube auto-creates the user on first login (DB `sonardb`, table `users`: `user_local=f`, `external_identity_provider=sonarqube`); email comes from the header.
- Authorization is **manual (Phase 1)**: groups + project/global permissions are granted via the SonarQube Admin UI/API. Group sync (`groupsHeader`) is future work and needs a Keycloak `groups` claim + groups header emission (v7.6.0 emits only `GAP-Auth`; the OIDC scope is `openid email profile`).
- Debug: `/api/users/who_am_i` is **removed in 26.x** — probe auth with `GET /api/ce/activity` (401 anon vs 200 auth) or `/api/system/health` (403 vs 200).
- Residual risk identical to Nexus: in-cluster clients can forge `Gap-Auth` directly; Cilium NetworkPolicy is the planned mitigation.

### Keycloak Deployment
- **Deployment**: Keycloak Quarkus via CodeCentric Helm chart
- **Database**: CNPG cluster (PostgreSQL), not H2
- **Availability**: Single pod on K3s (HA not possible on single node)
- **Config**: Realms imported via `KeycloakRealmImport` CRD — Git is source of truth
- **Backup**: Realm JSON export → Velero schedule

### Emergency Access
Break-glass accounts maintained locally for: Keycloak admin, Vault, ArgoCD, SonarQube, Nexus.

## Vault & ExternalSecrets Configuration
**Vault**: Rebuilt from scratch. Single Pod, Shamir unseal (1 key). Integration with Keycloak OIDC pending.
- Admin token stored in `vault-init` K8s secret
- Keycloak OIDC secrets stored at `secret/data/keycloak`
- AutoUnseal (raft/wal) being configured

**ExternalSecrets**: Configured with Vault AppRole auth (`vault-approle` role bound to `external-secrets` policy).
- ClusterSecretStore `vault` manages all cluster-scoped ExternalSecret references
- AppRole secrets stored in `vault` namespace for rotation readiness
- Pending: validate token, OIDC redirect URLs

## External File References (lazy-load when needed)
- @docs/deep-audit.md — full platform audit: state, inventory, fixes, residual defects
- @infrastructure/README.md — CNPG clusters, vault secret paths, storage classes, operator stack
- @README.md — Repository structure, management patterns

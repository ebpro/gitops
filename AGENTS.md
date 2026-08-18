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
- **K3s v1.31.5** — Single-node cluster (`compute-lsis-2`), kernel `6.8.0-124-generic`
- **Cilium CNI** — Tunnel mode, eBPF observability
- **ArgoCD v2.14+** — Auto-sync with prune/selfHeal
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
4. `bootstrap/k8s-apps/actions-runner-controller.yaml` — Standalone manifest

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
- **gitops-platform OutOfSync**: Even after pushing commits, `gitops-platform` may go OutOfSync and stall. Run `kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite` to force a refresh. If it persists, check the cluster network and GitHub API availability.
- **Pod CrashLoopBackOff**: Check ALL container logs (sidecars may be the problem)
- **Maintenance mode (SonarQube)**: Database migration failed — check migration logs, verify DB schema and PKs match migration expectations
- **Data store not found (Nexus)**: JDBC driver missing, or storeProperties not correctly formatted
- **PVC stuck in Terminating**: `kubectl patch pv <pv> -p '{"metadata":{"finalizers":null}}'` as **LAST resort**
- **CNPG cluster stuck**: Check cluster config, verify ExternalSecret is creating the password correctly
- **Keycloak slow startup**: CNPG DB may not be ready — add init container retry loop (default 60s startup probe handles this)

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

## ArgoCD Team Platform Status (2026-08-08)
```
healthy: 20/31 apps (65%)
  ArgoCD: vault, external-secrets, cloudnative-pg, kyverno, traefik, etc.
```
**Degraded (6)**: backstage-build, gitops-platform, kube-prometheus, mysql-proxy, oauth2-proxy, postgresql
**Unknown (2)**: kite-prometheus, nexus
**OutofSync (2)**: postgresql, plane
**Progressing (3)**: microcks, plane, vault
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

**Keycloak realm import is `IGNORE_EXISTING`** — `kc.sh start --import-realm` only loads realms that do not exist yet (log: `KC-SERVICES0030 ... Strategy: IGNORE_EXISTING`). Rebooting the pod never re-syncs an existing realm from git; applying file changes to a live realm requires admin API/kcadm or a deliberate rebuild. The file is still fully parsed at startup, so invalid JSON always crash-loops the pod.

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
- @infrastructure/README.md — CNPG clusters, vault secret paths, storage classes, operator stack
- @README.md — Repository structure, management patterns

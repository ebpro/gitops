# GitOps Platform - Agent Rules

## Golden Rules
- **Git-push only** — Never run `kubectl patch`, `kubectl apply`, or `kubectl edit` on managed resources. Fix things by editing files in this repo and committing.
- **ArgoCD auto-sync** — All apps use `automated: { prune: true, selfHeal: true }`. Changes propagate automatically.
- **Secrets in Vault** — All credentials live in HashiCorp Vault. Use ExternalSecrets to reference them. Never commit plaintext passwords.
- **Cilium CNI** — Tunnel mode, pod CIDR `10.42.0.0/24`, service CIDR `10.42.0.0/16`.
- **Single namespace per app** — Each app except orchestrator is deployed to its own namespace.

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
DNS pattern: `<cluster-name>-primary.<namespace>.svc.cluster.local:5432`

| CNPG Cluster | Namespace | Storage | Max Conns |
|---|---|---|---|
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
| Keycloak          | 🚧 Planned  | keycloak                       | Central SSO / Identity Provider |

## CNPG Strategy
**One dedicated cluster per critical app.** Isolates upgrades, tuning, and failover.
- DNS: `<cluster-name>-primary.<namespace>.svc.cluster.local:5432`
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
| Nexus OSS | — | ❌ | Traefik ForwardAuth |
| SonarQube CE | — | ❌ (Commercial only) | Traefik ForwardAuth |

### Identity Model
```
Users → Groups → Roles → Application permissions
```
Groups: `platform-admins`, `platform-engineers`, `developers`, `security-team`, `qa-team`, `readonly`

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

# Infrastructure

All database credentials and sensitive configuration are managed via External Secrets backed by HashiCorp Vault.

## Vault Secret Paths

| Vault Path | Key | Used By |
|---|---|---|
| `secret/data/postgresql/harbor` | `password` | Harbor, harbor-postgresql |
| `secret/data/postgresql/nexus` | `password` | Nexus, nexus-postgresql |
| `secret/data/postgresql/keycloak` | `password` | Keycloak, keycloak-db |
| `secret/data/postgresql/backstage` | `password` | Backstage, backstage-db |
| `secret/data/postgresql/pact-broker` | `password` | Pact Broker, pact-broker-db (CNPG `pactbroker` app user) |
| `secret/data/postgresql/link-shortener` | `url` + `username` + `password` | link-shortener deployment, link-shortener-db (CNPG `linkshortener` app user) |
| `secret/data/velero/s3` | `accessKeyId` + `secretAccessKey` | Velero |
| `secret/data/grafana` | `adminPassword` | Kube-Prometheus-Stack |
| `secret/data/sonarqube/monitoring` | `passcode` | SonarQube |
| `secret/data/backstage` | `jwtSecret` + `giteaToken` | Backstage |
| `secret/data/keycloak` | `adminPassword` + `realmSecret` | Keycloak admin |

## CloudNativePG Clusters

PostgreSQL instances are deployed via **CloudNativePG (CNPG)** operator as `Cluster` resources. DNS resolution: `<cluster-name>-rw.<namespace>.svc.cluster.local:5432` (read-write/primary; a read-only `<cluster-name>-ro` variant is also created by the operator)

### Cluster Specifications

**sonarqube-db** (`sonarqube` namespace)
- 20Gi PVC with `local-path` storage
- 400 max connections
- CPU: 250m/500m (req/limit), Memory: 512Mi/1Gi
- Service: `sonarqube-db-rw`

**nexus-db** (`nexus` namespace)
- 20Gi PVC with `local-path` storage
- 300 max connections
- CPU: 250m/500m (req/limit), Memory: 512Mi/1Gi
- Service: `nexus-db-rw`

**backstage-db** (`backstage` namespace)
- 10Gi PVC with `local-path` storage
- 200 max connections
- CPU: 250m/500m (req/limit), Memory: 512Mi/1Gi
- Service: `backstage-db-rw`

**keycloak-db** (`keycloak` namespace)
- 20Gi PVC with `local-path` storage
- 500 max connections
- CPU: 500m/1000m (req/limit), Memory: 1Gi/2Gi
- Service: `keycloak-db-rw`

**pact-broker-db** (`pact-broker` namespace)
- 5Gi PVC with `local-path` storage
- 200 max connections
- CPU: 250m/500m (req/limit), Memory: 512Mi/1Gi
- Service: `pact-broker-db-rw`

### CNPG Management
- Managed via raw K8s manifests in `kubernetes/postgresql/`, synced by ArgoCD
- ExternalSecrets for app-user credentials, Vault-backed
- Debug via: `kubectl exec -it <cluster>-1 -n <ns> -- psql -U postgres -d <dbname>`. `enableSuperuserAccess` is **true** on all clusters.

## Storage Classes
- **local-path** — Primary storage for most stateful workloads (CNPG, Nexus, etc.)
- **nfs-client** — For shared/file-based workloads that need cross-node access
- **garage** (future) — S3-compatible remote storage for Velero backups and CNPG Barman

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
| Keycloak          | 🚧 Deployed  | keycloak                       | Central SSO / Identity Provider |

## SSO & Identity
Central authentication via Keycloak (CodeCentric Operator) → GitOps-managed.

### Identity Groups
| Keycloak Group | ArgoCD Role | Grafana Role |
|---|---|---|
| `platform-admins` | `admin` | `Admin` |
| `platform-engineers` | `role:platform-engineers` | `Editor` |
| `developers` | `role:developers` | `Editor` |
| `readonly` | `role:readonly` | `Viewer` |

### Authentication Fallback
Apps without OAuth2 native SSO front **Traefik ForwardAuth** middleware backed by **oauth2-proxy** → Keycloak OIDC. oauth2-proxy v7 emits a `GAP-Auth` response header (user email), copied to the upstream by `authResponseHeaders`: SonarQube CE reads it natively (`sonar.web.sso.*Header=Gap-Auth`, CE 26+), Nexus OSS via the custom `rutauth` capability (see AGENTS.md).

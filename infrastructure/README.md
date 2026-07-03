# Infrastructure

All database credentials and sensitive configuration are managed via External Secrets backed by HashiCorp Vault.

## Secret paths in Vault

| Secret Path | Key | Used By |
|---|---|---|
| `secret/data/postgresql/harbor` | `password` | Harbor, harbor-postgresql |
| `secret/data/postgresql/nexus` | `password` | Nexus, nexus-postgresql |
| `secret/data/velero/s3` | `accessKeyId` + `secretAccessKey` | Velero |
| `secret/data/grafana` | `adminPassword` | Kube-Prometheus-Stack |
| `secret/data/sonarqube/monitoring` | `passcode` | SonarQube |

## PostgreSQL databases

PostgreSQL instances are deployed as standalone StatefulSets, not via Helm subcharts. Each database has:
1. An ExternalSecret that creates the PostgreSQL password Secret
2. The `pgbouncer-exporter` service for monitoring
3. Persistent volumes with 10-20Gi using `local-path` storage class

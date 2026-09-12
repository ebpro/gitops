---
name: cnpg-cluster
description: Create or modify a CloudNativePG Cluster for an application
---

## What I do
1. Create `kubernetes/postgresql/<app>-db.yaml` with `postgresql.cnpg.io/v1 Cluster` spec
2. Set instances (1 for dev/single-node, 3 for HA), storage class (`local-path` or `nfs-client`), and tuning params
3. If app requires a dedicated user/password, create `kubernetes/postgresql/<app>-external-secret.yaml` pointing to Vault path
4. ArgoCD syncs the Cluster via `bootstrap/appset-manifests.yaml` (git tree generator)
5. Verify with `kubectl get Cluster <name> -n <ns>` and `kubectl get pods -l cnpg.io/cluster=<name> -n <ns>`

## Key patterns
- Service DNS: `<cluster-name>-primary.<namespace>.svc.cluster.local:5432`
- `enableSuperuserAccess: true` recommended for debug on single-node K3s
- Max connections tuned per-app (e.g., 400 for SonarQube, 300 for Nexus)
- Backup via CNPG `Cluster.spec.backup` → `barmanObjectStore` (S3/Garage)

## When to use me
Use when provisioning a fresh DB for a new app, cloning/restoring a cluster, or tuning PostgreSQL parameters.

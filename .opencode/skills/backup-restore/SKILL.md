---
name: backup-restore
description: Manage backups and restore operations via Velero and CloudNativePG
---

## What I do
1. **Velero (Cluster/Backup/Schedule**: Create `Schedule` CRD for namespaces, `namespaces`, `snapshot-volumes: true`, `storage-location` (Garage S3)
3. **CNPG (App DB) Backup**: Define `Cluster.spec.backup` in `kubernetes/postgresql/<app>-db.yaml` pointing to S3/Garage. Create `Schedule` CR for automated `ClusterBackups`.
4. **Restore**: 
   - Velero: `kubectl apply -f restore-crd.yaml` or `velero restore create ...`
   - CNPG: Create `Cluster/<cluster>-restore` with `RecoverySource` pointing to `ScheduledBackup` or `VolumeSnapshot`

## Key patterns
- S3/Garage config: `secretRef: secrets/v2/velero`
- CNPG recovery: `ClusterBackus` does PITR or full restore. TimeofSnapshot`
- Verify: `kubectl get backups, restores, schedules -n velero` and `kubectl get clusterbackups, clusterrestores -n <df>

## When to use me
Use when setting up new app's backup policies or recovering from data loss/failure.

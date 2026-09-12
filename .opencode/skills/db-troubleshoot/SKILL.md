---
name: db-troubleshoot
description: Troubleshoot CloudNativePG and PostgreSQL database connectivity, schema, and data issues
---

## What I do
- Check CNPG cluster health: `kubectl get Cluster <name> -n <ns>`
- Check pod logs: `kubectl logs <cluster>-1 -n <ns>`
- Execute psql commands via `kubectl exec -it <cluster>-1 -n <ns> -- psql -U postgres -d <dbname>`
- Verify PostgreSQL service: `kubectl get svc <cluster>-primary -n <ns>`
- Check PVC attachables: `kubectl get pvc -l cnpg.io/cluster=<name> -n <ns>`
- Debug ExternalSecrets: `kubectl get externalsecret -n <ns> -o yaml`, verify Vault paths

## Key patterns
- CNPG cluster service: `<cluster>-primary.<namespace>.svc.cluster.local:5432`
- Database user dependencies: app-specific roles vs. superuser
- Migration issues: check schema version, truncate/recreate if fresh install
- Foreign Data Wrapper or PostgreSQL integration: verify CNPG cluster health

## When to use me
Use when a database-connected app fails to connect, schema mismatches, or data issues occur.

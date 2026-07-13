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

### In Progress
- Plane app OutOfSync issue: Helm chart version 1.6.0 Job templates have immutable label constraints that conflict with AutoHeal. Helm app is stuck progressing.
- Clean up outdated plane values as needed.
- Validate Keycloak SSO flows end-to-end.

### Blocked
- **Plane app**: `Job` `plane-api-migrate-1` and 7 other Jobs are OutOfSync due to immutable selector/label conflicts. ArGoCD can't replace them. Needs manual Job deletion then ArGoCD re-sync.
- **Keycloak SSO validation**:_oidc_secret keys may have been regenerated; need to update ArgoCD, Gitea, Harbor, and Plane helm values with new secrets.

## Key Decisions
- Vault KV v2 base path is `secret` → ExternalSecret `key` only needs `keycloak` (not `secret/data/keycloak`).
- AppRole auth used for ExternalSecrets instead of static token (more secure; `external-secrets` policy limits to `secret/data/*`).
- Vault rem合规 Shamir in Helm values — auto-unseal can be added later via `server.autoUnseal`.
- `vault-init` secret stores both `root_token` (28-char init token) and `admin_token` (95-char full admin) to support Helm init container and manual admin.

## Next Steps
1. **Resolve Plane app**: Delete 8 broken Jobs on cluster. ArGoCD will auto-recreate them fresh.
2. **Validate Enterprise SSO**: Verify ArgoCD, Gitea, Harbor, Plane, Microcks OIDC all authenticate against Keycloak.
3. **Vault auto-unseal**: Configure raft/wal autoUnseal for resilience (backwards compatible with Shamir fallback).
4. **Postgres cluster cleanup**: Remove deprecated manifest-synced postgres resources (now CNPG managed).
5. **External .md generation**: Update AGENTS.md with corrected ArgoCD app statuses.

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

# GitOps Platform — Deep Audit

**Date:** 2026-08-20 (live, read-only sweep + empirical probes)
**Method:** ArgoCD/pod/CNPG/ESO/Vault/Harbor/Gitea/Woodpecker/Backstage state captured live with `kubectl` + API probes; git state via `origin/main`.

## 1. Overall health

| Layer | State |
|---|---|
| Cluster | K3s **v1.35.5+k3s1** (client v1.34.2), single node `compute-lsis-2`, Cilium tunnel |
| ArgoCD | **v3.5.1** + image-updater v1.2.2, automated `{prune, selfHeal}`; 50 apps: **49 Synced/Healthy**, 1 (`vault`) Health Unknown — metadata-only app, by design |
| Databases | CNPG **10/10 healthy** (single instance each) |
| Secrets | Vault single pod (Shamir, 1 key), KV2 at `secret/`; **all ExternalSecrets Ready** (AppRole store, `path=secret`, `version=v2`) |
| Storage | `local-path` (primary), `nfs-rwx`; plane-db volume-snapshot class `test-snapshot-class` (naming debt) |
| Observability | loki + tempo + alloy; 54 Grafana dashboard ConfigMaps in `kube-prometheus`; app-level Prometheus remote-write (backstage) |

## 2. What was fixed since the 2026-08-08 audit (verified live 2026-08-20)

| Area | Before | Now |
|---|---|---|
| Arc app | OutOfSync | Synced/Healthy |
| `postgresql-manifests` | Degraded (`gitea-oidc` ESO stuck) | Healthy, all ESOs Ready |
| `keycloak-realm` + reconciler | broken (script kind + token plumbing) | CronJob Complete, 0/0 in ~5 s, 14 clients incl. woodpecker/microcks/synapse/vault |
| K3s | v1.31.5 | **v1.35.5** |
| Vault | rebuilt 2026-08-10 (Shamir, old data lost) | KV re-seeded; ESO paths all readable (2026-08-20) |
| Matrix | running in `keycloak` ns | **dedicated `synapse` + `element` namespaces** (2026-08-20); `matrix-token-setup` job green |
| Plane | chart bump trap (1.6.2 immutable Job, reverted) | settled on chart **1.6.1**; `plane-db` CNPG migration in flight (cluster 29 h, 20 Gi, max_connections 200) |
| Harbor | OIDC client secret in git values (leaked, public repo) | **rotated 2026-08-20** (5c3f65c), values scrubbed, `?v=6`; `harbor-init` bootstrapper app+tree removed |
| App inventory | 31 apps, 20 healthy | **50 apps, 49 healthy**; new `ci` manifests app (`kubernetes/ci`) |
| CNPG backups | harbor-db `ScheduledBackup` hourly `:03` storm | **6-field cron required (seconds)** — daily `0 0 3 * * *` (3a65d50) |
| Stray objects | `kc-client-secret` (2,652 restarts), `keycloak-debug`, `matrix-alertmanager-setup` (9 d), dead `fix-plane-rabbitmq` branch (75,862-line destructive rebase) | **all removed 2026-08-20** |

**New platform components since last audit:** ARC 0.14.2 + GitHub App scale-set `ebpro-org` (`actions-runner-controller` / `arc-runners` ns), Microcks 1.14.0 (vendored chart, dual-shell startup-probe patch), Pact Broker + CI contract loop (CI #42/#43 green) + contract gates (spectral/oasdiff/deploy-gate), Woodpecker v3 (`ci` ns, 2 agents), Garage S3, trivy-operator (`trivy-system` ns), `ci` manifests app.

## 3. Inventory

### 3.1 CNPG clusters (10/10 healthy)

All 10 clusters standardized on `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` (explicit `imageName` in git).

| Cluster | Namespace | Storage | Notes |
|---|---|---|---|
| `backstage-db` | `backstage` | 10Gi local-path | max connections 200 |
| `harbor-db` | `harbor` | 20Gi local-path | 300 max conns |
| `keycloak-db` | `keycloak` | 20Gi local-path | 500 max conns |
| `link-shortener-db` | `link-shortener` | 20Gi local-path | app user `linkshortener` |
| `nexus-db` | `nexus` | 20Gi local-path | 300 max conns |
| `pact-broker-db` | `pact-broker` | 5Gi local-path | |
| `plane-db` | `plane` | 20Gi local-path | 200 max conns; snapshot class `test-snapshot-class`; cluster created 2026-08-19 |
| `sonarqube-db` | `sonarqube` | 20Gi local-path | 400 max conns |
| `woodpecker-db` | `ci` | 10Gi local-path | |
| `matrix-db` | `synapse` | 10Gi local-path | moved from `keycloak` ns 2026-08-20 |

All with `enableSuperuserAccess: true`. Debug: `kubectl exec -it <cluster>-1 -n <ns> -- psql -U postgres -d <db>`.

### 3.2 Vault / ExternalSecrets

- Mount `secret/` (KV v2). ClusterSecretStore `vault`: AppRole auth, `path=secret`, `version=v2`, server `http://vault-active.vault.svc.cluster.local:8200`.
- **API is fully writable with the root token** (empirical 2026-08-20: PUT/read/DELETE of a probe key all OK). The "read-only even with root" note in `kubernetes/arc/README.md` was corrected.
- Root token: `vault-init` secret (ns `vault`), `policies: ['root']`, `ttl: 0` — no rotation. AppRole (ns `external-secrets`) is read-scoped per key (403 on list, 200 on its exact keys) — by design.
- Dead key `secret/data/github/arc-runner` (revoked PAT) purged 2026-08-20.
- **KV layout is mixed/flat**: top-level leaves sit alongside `data/...` leaves; some parents (e.g. `gitea`, `oidc`) are leaves, not directories, so `metadata/<parent>` list 404s while `data/<parent>/<leaf>` reads 200. Consumers use exact keys, so this is harmless but means **always reference full leaf paths**.

Known-good Vault leaf paths (read 200 via root):
`keycloak`, `gitea`, `gitea/admin`, `oidc/microcks-ci`, `oidc/harbor`, `microcks`, `harbor`, `backstage`, `github/arc-app`, `github/arc-runner` (purged), `postgresql/backstage` (+ per-cluster app creds).

### 3.3 Applications (50)

Core/Infra: argocd, argocd-image-updater, argo-image-updater, gitops-platform, cilium, coredns, csi-snapshot-controller, alertmanager, alertmanager-config, alloy, open-telemetry, observability, kube-prometheus, tempo, loki, dashboards, declarative, ingress, trivyoperator, cert-manager, traefik, kyverno, cloudnative-pg, external-secrets, nfs-client, vpa, vault, plane-manifests, postgresql-manifests.
Identity/SSO: keycloak, keycloak-realm, keycloak-reconciler, gitea, oauth2-proxy.
Apps: backstage, harbor, ci (Woodpecker v3), nexus, plane, sonarqube, microcks, pact-broker, link-shortener, element, synapse, garage, apicurio, arc, arc-controller, arc-org-runners.

### 3.4 Backstage (current)

- Chart 2.10.0, image `ghcr.io/backstage/backstage:1.53.1` (pod 2d17h), ns `backstage`.
- DB: `backstage-db` (CNPG, Vault `postgresql/backstage` app user `backstage`).
- Auth: Keycloak OIDC (native SSO). `backend.guest.enabled: true` (guest active).
- Catalog: remote `entities.yaml` (System/Group/Components/API). No custom plugins, RBAC, TechDocs, VPA, or per-app NetworkPolicy yet.
- Dashboard: `kubernetes/dashboards/backstage.yaml`. OTel Prometheus remote-write enabled.

## 4. Residual defects & fixes

### 4.1 Fixed this pass (2026-08-20)
- Removed stray pods `vault/kc-client-secret`, `keycloak/keycloak-debug`; stale `keycloak/matrix-alertmanager-setup` job (6 pods).
- Deleted destructive branch `fix-plane-rabbitmq` (local+origin).
- Purged dead Vault key `github/arc-runner`.
- Corrected `kubernetes/arc/README.md` read-only claim + this doc.
- Synced `AGENTS.md`.

### 4.2 Open — credential blockers (block Backend CI)
1. **Gitea admin**: Vault `gitea/admin` ≠ live Gitea DB (admin login 401). → reset admin password in Gitea UI, reseed Vault `gitea/admin`, then ESO re-syncs.
2. **Harbor admin**: `admin/Harbor12345` stale (login 401). → confirm/reset admin, reseed Vault `harbor` admin + `oidc/harbor`.
3. **Woodpecker CI vars** for `bruno/backstage`: `HARBOR_USERNAME`/`HARBOR_PASSWORD` (robot on `library`) + `GITEA_TOKEN` — to be created once #1/#2 are live.
4. **Keycloak admin password**: Vault `keycloak` admin grant returns 400 `invalid_grant` (stale). → reset + reseed `keycloak` adminPassword/adminToken.

### 4.3 Noted / deferred
- `vault` app reports Unknown (metadata-only manifests) — cosmetic.
- `plane-db`, `woodpecker-db` have **no CNPG image pin in git** (operator default currently 18.4). Decide: pin deliberately or accept operator default.
- `plane-db` snapshot class named `test-snapshot-class` — rename to a real class.
- Nexus RUT / SonarQube `Gap-Auth`: in-cluster clients can forge the header; Cilium NetworkPolicy is the planned mitigation.
- Vault AutoUnseal (raft/wal) still pending.
- `fix-plane-rabbitmq`-style destructive rebase risk — see branch naming in AGENTS.md.

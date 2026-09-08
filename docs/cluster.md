# GitOps Platform — Cluster Description & Audit

| Field | Value |
|---|---|
| Audit date | 2026-09-08 |
| Method | live read-only kubectl sweep + repository analysis |
| Scope | whole K3s cluster + GitOps repo (github.com/ebpro/gitops) |
| Status | 50/50 ArgoCD apps Synced/Healthy |

## 1. Overview

This platform is a GitOps-managed Kubernetes deployment built on a single-primary K3s
cluster with one additional arm64 worker node. ArgoCD is the exclusive control plane:
every Deployment, StatefulSet, Service, ConfigMap, Helm release, and operator CRD is
reconciled from the git repository `github.com/ebpro/gitops` (branch `main`). Direct
cluster mutation of ArgoCD-managed resources is prohibited by convention; all change
flows through commits that ArgoCD's auto-sync (`prune`, `selfHeal`) applies.

Core platform services follow an operator-first model: PostgreSQL is provisioned via
CloudNativePG `Cluster` CRDs (one dedicated cluster per critical application), secrets
are stored in HashiCorp Vault and delivered to workloads through External Secrets
Operator, identity is centralized on Keycloak (OIDC) with ForwardAuth fallback
(oauth2-proxy) for applications without native SSO, ingress is served by Traefik with
cert-manager-issued Let's Encrypt certificates, and a full OpenTelemetry-based
observability stack (Prometheus, Loki, Tempo, Grafana) covers metrics, logs, and
traces. A CI/CD toolchain (Woodpecker CI, Gitea, Harbor, SonarQube, Nexus, Argo
CD image-updater) completes the delivery pipeline.

This document was produced by a read-only `kubectl` sweep of the live cluster on
2026-09-08 combined with analysis of the repository. **Health verdict:** the platform
is functionally green — all 50 ArgoCD applications are Synced and Healthy, all workloads
report ready == desired replicas, no pod is Pending, in Error, or in CrashLoopBackOff,
all PVCs are Bound, and Kyverno reports zero policy violations. Material risks exist
but are contained: an unbacked-up new database, failing container-image vulnerability
scans on Plane images, a TLS certificate split-brain between the public ingress path
and in-cluster paths, one chronically restarting application (Apicurio), and
documentation drift against the live cluster. These are enumerated in Section 2 and
detailed in the findings sections of this document.

## 2. Executive summary

### Health dashboard

| Layer | State |
|---|---|
| Cluster | K3s v1.36.4+k3s1, 2 nodes Ready, 39 namespaces (all Active), 121 pods, 0 unhealthy |
| ArgoCD | v3.5.1, 50/50 Applications Synced + Healthy (100%) |
| Databases | 11/11 CNPG clusters healthy; 10/11 with daily backups — `link-shortener-ci-db` unbacked |
| Secrets | 35/35 ExternalSecrets Ready; Vault 1.21.2 unsealed, raft/HA |
| Storage | 41/41 PVCs Bound; 2 storage classes (`local-path`, `nfs-rwx`) |
| Ingress / TLS | 15 Ingresses + 10 IngressRoutes; 3/3 certificates READY (Let's Encrypt, expiry 2026-12-04); in-cluster cert split-brain flagged |
| Observability | All components Running |
| Security | Kyverno: 0 violations; 2 coverage gaps noted |

### Top-5 findings

1. **Unbacked database** — the new CNPG cluster `link-shortener-ci-db` has no
   `ScheduledBackup`; it is the only one of 11 clusters without daily backups.
2. **Trivy scan failures on Plane images** — Trivy scans of Plane images fail due to
   unauthenticated pulls from the upstream registry (HTTP 401 / rate-limiting).
3. **TLS split-brain** — public traffic terminates on valid Let's Encrypt certificates,
   while in-cluster paths present the Traefik default certificate. Root cause
   unconfirmed; 2 failed ACME orders observed.
4. **Apicurio chronic restarts** — 318 restarts in 28 days; the pod is still cycling at
   audit time.
5. **Documentation drift** — live cluster runs K3s v1.36.4 with 2 nodes and 11 CNPG
   clusters; repository docs still state v1.35.5, single-node, and 10 clusters.

## 3. Cluster platform

### Nodes

| Node | Role | Arch | Age | IP | OS / Kernel | Capacity | Usage at audit |
|---|---|---|---|---|---|---|---|
| compute-lsis-2 | control-plane | amd64 | 81d | 10.2.248.31 | Ubuntu 24.04.4 / kernel 6.8.0-136-generic, containerd 2.3.4 | 32 CPU / 65.7 GiB / 110 pods (allocatable 29 CPU / 58.4 GiB) | 14% CPU / 53% mem |
| lima-k3s-agent | worker | arm64 | 14h | 10.2.248.247 | kernel 6.8.0-138 | 8 CPU / 49.2 GiB / 110 pods | 2% CPU / 1% mem |

Both nodes are Ready. `lima-k3s-agent` joined on 2026-09-07 and carries **no taints**
— it is an active arm64 test node, not a cordoned spare. The control-plane node last
restarted around 2026-09-01T12:53Z (Ready since that timestamp).

### K3s version

The cluster runs **K3s v1.36.4+k3s1**. Repository documentation still records
v1.35.5 — the docs drifted by upgrade and need correction. The local `kubectl` client
is v1.34.2, which is minor-version-skewed against the server and emits a skew warning;
tooling should be updated alongside future upgrades.

### Networking (Cilium)

Cilium 1.20.0 provides CNI in **vxlan tunnel mode** with **KubeProxyReplacement**
enabled (Direct Routing for service traffic). IPAM allocates from `10.42.0.0/24` —
99 of 254 addresses used. Both nodes are mutually reachable through the mesh. L2
announcement is enabled (managed in git at `kubernetes/cilium/l2-announce.yaml`).
Caveat: the **Hubble flow buffer is 100% full** (4,095/4,095) at an observed ~182
flows/s, so network-flow visibility is currently dropping events; buffer size or
sampling should be reviewed if flow observability matters.

### Storage classes

| Storage class | Provisioner | Reclaim | Binding | Expansion |
|---|---|---|---|---|
| `local-path` (default) | local-path | Delete | WaitForFirstConsumer | **not supported** |
| `nfs-rwx` | nfs-client | Delete | Immediate | supported |

All 41 PVCs in the cluster are Bound.

### Capacity vs. usage

The control-plane node carries the full workload: 53% memory and 14% CPU at audit time.
Memory is the binding constraint on `local-path` storage with no expansion path — disk
growth requires manual PV management. The arm64 worker adds 8 CPUs / 49.2 GiB of
headroom at near-zero current usage, but as an untainted test node it offers no
placement guarantee for production workloads.

## 4. GitOps control plane

### Source of truth

The repository `github.com/ebpro/gitops`, branch `main`, is the single source of truth
for all cluster state. ArgoCD polls and reconciles from git; the cluster side is
treated as immutable except for data-level operations (documented case-by-case).

### Bootstrap chain

```
github.com/ebpro/gitops (main)
└── Application gitops-platform (root-app.yaml, sync-wave 0)
    └── path: bootstrap/
        ├── ApplicationSet helm-apps          (list generator, 21 apps)
        ├── ApplicationSet kubernetes-manifests (git generator, 17 apps)
        └── 11 standalone Applications (app-*.yaml)
        ⇒ 1 + 21 + 17 + 11 = 50 ArgoCD Applications, all automated {prune, selfHeal}
```

The root `gitops-platform` Application (sync-wave 0) renders `bootstrap/`, which
creates the two ApplicationSets and the standalone Applications. All 50 resulting
Applications run with `automated: { prune: true, selfHeal: true }`.

### Mechanics worth documenting

- **Remote valueFiles caching.** Helm apps reference values via
  `raw.githubusercontent.com` URLs carrying `?v=N` cache-bust parameters. ArgoCD caches
  remote valueFiles aggressively: after pushing a values change, the app will *not*
  re-download until the `?v=` parameter is bumped in `bootstrap/appset-helm.yaml`.
  Bump it, commit, and push to propagate.
- **Sync policy for manifest apps.** The git-generator (manifest) apps use
  `ServerSideApply` with `ApplyOutOfSyncOnly`, plus retry backoff (5 s × 2 attempts,
  max 1 m).
- **ignoreDifferences.** Used deliberately to absorb operator-injected defaults: CNPG
  defaults on `postgresql-manifests`, ExternalSecret conversion fields, and Plane
  workload churn. These entries are intentional, not drift.
- **.argocd-source dotfiles.** The ArgoCD v3 repo-server merge-patches
  `.argocd-source*.yaml` dotfiles found at an app's path in git onto the rendered
  source — this is where image-updater writes back pinned images. Audit with
  `find . -name ".argocd-source*"`; **none are currently present**.
- **Stale generator script.** `gen-helm-apps-full.sh` at the repo root is a stale
  artifact: it generates a `helm/apps/` directory that no longer exists, with
  placeholder `repoURL`s. It is historical only — the ApplicationSets above are the
  current generators of app definitions.

## 5. Application inventory

50 ArgoCD Applications, all Synced/Healthy at audit (2026-09-08). Derived from
1 root + 21 (`helm-apps` AppSet) + 17 (`kubernetes-manifests` AppSet) + 11 standalone.

| App | Namespace | Source | Purpose |
|---|---|---|---|
| **Control plane & infra** | | | |
| gitops-platform | argocd | repo path `bootstrap` (sync-wave 0, SSA) | self-referential root app syncing the bootstrap tree |
| argocd | argocd | bootstrap/argocd-overlay (sync-wave -999) | ArgoCD overlay configuration |
| argo-image-updater | argocd | chart argocd-image-updater 1.2.4 | image-update automation |
| argocd-image-updater | argocd | kubernetes/argocd-image-updater | image-updater CR wiring |
| traefik | kube-system | chart traefik 37.1.1 | ingress |
| coredns | kube-system | kubernetes/coredns | CoreDNS override |
| csi-snapshot-controller | kube-system | kubernetes/csi-snapshot-controller | volume snapshot controller |
| cert-manager | cert-manager | chart cert-manager v1.16.3 | TLS issuance |
| nfs-client | nfs-client | chart nfs-subdir-external-provisioner 4.0.18 | NFS storage provisioner |
| vpa | vpa | chart vertical-pod-autoscaler 0.10.0 | resource recommendations |
| kyverno | kyverno | chart kyverno 3.5.0 | policy engine |
| cloudnative-pg | cnpg-system | chart cloudnative-pg 0.29.0 | PostgreSQL operator |
| external-secrets | external-secrets | chart external-secrets 2.7.0 | Vault → K8s secrets |
| garage | garage | UPSTREAM github.com/deuxfleurs-org/garage v2.3.0 + local values | S3 object store (CNPG backup target) |
| postgresql-manifests | multi-ns | kubernetes/postgresql | CNPG clusters, ExternalSecrets, ScheduledBackups (ignoreDifferences absorbs operator defaults) |
| cilium | kube-system | kubernetes/cilium | Cilium NetworkPolicies, IP pool, L2 announce |
| ingress | multi-ns | kubernetes/ingress | Ingresses, IngressRoutes, middlewares, ClusterIssuer |
| **Identity & SSO** | | | |
| keycloak | keycloak | chart keycloak (CodeCentric) 18.0.0 | SSO / identity provider |
| keycloak-realm | keycloak | kubernetes/keycloak-realm | realm ConfigMap + setup jobs |
| keycloak-reconciler | keycloak | bootstrap/keycloak-reconciler | */15 CronJob realm reconciler |
| gitea | gitea | chart gitea 12.6.0 | Git host |
| oauth2-proxy | oauth2-proxy | kubernetes/oauth2-proxy | ForwardAuth SSO fallback (Gap-Auth emitter) |
| vault | vault | chart vault (HashiCorp) 0.32.0, multi-source | secrets engine |
| **Observability** | | | |
| kube-prometheus | kube-prometheus | chart kube-prometheus-stack 80.6.0 | metrics, Grafana, Alertmanager |
| loki | loki | chart loki 6.55.0 | logs |
| tempo | tempo | chart tempo 1.24.4 | traces |
| alloy | alloy | chart alloy (Grafana) 1.11.0 | OTel collector (logs→Loki, metrics) |
| open-telemetry | opentelemetry-operator-system | chart opentelemetry-operator 0.69.0 | OpenTelemetry operator |
| observability | multi-ns | kubernetes/observability | ServiceMonitors, OTel Instrumentations, Grafana PVC |
| dashboards | kube-prometheus | kubernetes/dashboards | 31 Grafana dashboard ConfigMaps |
| alertmanager | kube-prometheus | kubernetes/alertmanager | alert routing |
| alertmanager-config | kube-prometheus | kubernetes/alertmanager/alertmanager-config | Alertmanager configuration |
| trivyoperator | trivy-system | chart trivy-operator 0.35.0 | image/manifest scanning |
| **CI/CD & developer toolchain** | | | |
| woodpecker | ci | chart woodpecker 3.6.5 | CI server (2 agents, Gitea OAuth) |
| ci | ci | kubernetes/ci | Woodpecker ExternalSecrets (Harbor robots, Plane token) |
| arc | actions-runner-controller | kubernetes/arc | ARC CRDs + GitHub creds ExternalSecret |
| arc-controller | actions-runner-controller | chart gha-runner-scale-set-controller 0.14.2 (oci) | Actions Runner Controller |
| arc-org-runners | arc-runners | vendored chart charts/gha-runner-scale-set (local fix of upstream scalar-map bug) | GitHub Actions scale set |
| harbor | harbor | chart harbor 1.19.2 | container registry |
| nexus | nexus | helm/releases/nexus (repo path) | artifact proxy |
| sonarqube | sonarqube | chart sonarqube 2026.4.1 | code quality |
| pact-broker | pact-broker | chart pact-broker 6.1.0 | contract testing |
| microcks | microcks | vendored chart helm/vendor/microcks | API mocking / contract |
| declarative | plane, apicurio, gitea | kubernetes/declarative | legacy CNPG manifests + Apicurio registry 2.2.5 |
| **Applications** | | | |
| backstage | backstage | chart backstage 2.10.0 | developer portal |
| element | element | kubernetes/matrix/element | Matrix web client |
| synapse | synapse | kubernetes/matrix/synapse | Matrix server |
| link-shortener | link-shortener | kubernetes/link-shortener | Quarkus application (the platform's own service) |
| plane | plane | chart plane-ce 1.6.1 (helm.plane.so) + large ignoreDifferences | project management |
| plane-manifests | plane | kubernetes/plane | Plane auxiliary manifests |

## 6. Databases

All PostgreSQL runs as dedicated CloudNativePG `Cluster` CRDs (one per critical app).
Every cluster pins image `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie`, runs a
single instance, sets `enableSuperuserAccess: true`, and uses `local-path` storage.

| Cluster | Namespace | Storage | Max connections | Daily backup (UTC) | Backed up? |
|---|---|---|---|---|---|
| backstage-db | backstage | 10Gi | 200 | 01:15 | yes |
| harbor-db | harbor | 20Gi | (own schedule file) | yes |
| keycloak-db | keycloak | 20Gi | 500 | 03:30 | yes |
| link-shortener-db | link-shortener | 10Gi | 200 | 04:45 | yes |
| nexus-db | nexus | 20Gi | 300 | 02:30 | yes |
| pact-broker-db | pact-broker | 5Gi | 200 | 04:15 | yes |
| plane-db | plane | 20Gi | 200 | 00:45 | yes |
| sonarqube-db | sonarqube | 20Gi | 400 | 03:00 | yes |
| woodpecker-db | ci | 10Gi | default | 04:30 | yes |
| matrix-db | synapse | 10Gi | default | 04:00 | yes |
| link-shortener-ci-db | ci | 4Gi | 100 | **none** | **NO — no ScheduledBackup, zero backups (finding)** |

### Backup architecture

- CNPG `barmanObjectStore` → Garage S3 (namespace `garage`); 14-day retention.
- All crons use CNPG's 6-field format (seconds included). A 5-field expression
  silently mis-parses (e.g. an hourly `:03` storm) — gotcha documented in AGENTS.md.
- Every cluster with a schedule produced a completed backup on audit day. One
  historical failure: `woodpecker-db` on 2026-09-02 ("instance manager was restarted
  during backup"), since recovered.

### Credentials pattern

Vault leaf `secret/data/postgresql/<app>` → ExternalSecret → K8s Secret → CNPG
`DatabaseRole` (`ensure: present`) or the cluster bootstrap owner. Note the AGENTS.md
gotcha: applying a `DatabaseRole` with `ensure: present` to an **existing** role does
**not** re-run `ALTER ROLE … PASSWORD`, so DB-side password drift can persist even
while the ESO → Secret → DatabaseRole chain reports green.

### DNS pattern

`<cluster>-rw.<namespace>.svc.cluster.local:5432` (read-write / primary). The operator
also creates a read-only `<cluster>-ro` variant.

## 7. Secrets & identity

### Vault

Vault v1.21.2: single StatefulSet (`vault-0`, 2/2) plus the `vault-agent-injector`
webhook. Raft storage, HA enabled, mode active. Shamir unseal: 1 share / threshold 1;
unsealed at audit. KV v2 engine at `secret/`; the key layout is flat/mixed (some
parents are leaves, not directories) — always reference full leaf paths, never list
parents. Known leaves at audit:

`keycloak`, `gitea`, `gitea/admin`, `oidc/microcks-ci`, `oidc/harbor`, `microcks`,
`harbor`, `backstage`, `github/arc-app`, `postgresql/<app>`.

### External Secrets

ClusterSecretStore `vault` uses AppRole auth, read-scoped per key: 403 on list
operations, 200 on the exact configured keys. 35 ExternalSecrets cluster-wide, all
Ready at audit. Pattern: Vault leaf → ESO → K8s Secret consumed by workloads.

### Keycloak

CodeCentric Helm chart 18.0.0, CNPG-backed (`keycloak-db`). Realm JSON lives in git
(`kubernetes/keycloak-realm/platform-realm-configmap.yaml`) and is applied by setup
Jobs; the `keycloak-reconciler` CronJob (*/15) keeps the live realm in sync. The
import strategy is `IGNORE_EXISTING`: file changes to an *existing* realm are **not**
auto-reimported — syncing a live realm requires admin API/kcadm or a deliberate
rebuild. Keycloak 26.x admin-endpoint and user-profile quirks are documented in
AGENTS.md.

### SSO matrix

| App | Protocol | Native SSO | Fallback |
|---|---|---|---|
| ArgoCD | OIDC | yes | — |
| Harbor | OIDC | yes | — |
| Gitea | OIDC | yes | — |
| Grafana | OIDC | yes | — |
| Vault | OIDC | yes | — |
| Backstage | OIDC | yes | — |
| Plane | OIDC/SAML | yes | — |
| Microcks | Keycloak | yes | — |
| Nexus OSS | RUT (`Gap-Auth`) | yes (rutauth capability) | local Basic for CI / break-glass |
| SonarQube CE | HTTP header (`Gap-Auth`) | yes (native CE 26+) | manual permissions (Phase 1) |
| Woodpecker CI | Gitea OAuth | no | indirect SSO via Keycloak |

### ForwardAuth pattern

oauth2-proxy (namespace `oauth2-proxy`, v7.6.0) performs `/checkauth` against Keycloak
OIDC and emits a `GAP-Auth` **response** header carrying the user email. The Traefik
`fwd-auth` middleware (in `kubernetes/ingress/`) copies it to the upstream request via
`authResponseHeaders`. SonarQube reads it natively (`sonar.web.sso.*Header=Gap-Auth`);
Nexus consumes it via the custom `rutauth` capability. The Nexus `sso-sync` CronJob
mirrors Keycloak group membership into local Nexus users and roles every 15 minutes;
`protectedUsers` are never pruned.

Residual risk: in-cluster clients can bypass the proxy and forge `Gap-Auth` directly
against either application. The planned Cilium NetworkPolicy mitigation is still
unimplemented (see findings).

## 8. Networking & ingress

### Ingress surface

Traefik is the sole ingress controller (class `traefik`); public hosts follow
`*.ebruno.fr` (VIP `10.2.248.31`). All definitions live in `kubernetes/ingress/`.

- **15 Kubernetes Ingresses:** alloy, apicurio, argocd, backstage, woodpecker, element,
  external-secrets, garage (port 80), gitea, harbor, grafana, prometheus, microcks,
  microcks-grpc, vault.
- **10 Traefik IngressRoutes:** keycloak, link-shortener, nexus (×2), oauth2proxy,
  pact-broker, plane, sonarqube (×2), synapse.

### Middlewares (13)

`fwd-auth` (ForwardAuth → oauth2-proxy) with per-app header-copy variants for nexus,
pact-broker, and sonarqube; `proxy-headers`; `plane-body-limit`; `synapse-headers`.

### TLS

cert-manager issues via the ACME issuer `letsencrypt-ovh` (HTTP-01) plus a self-signed
issuer for OTel. Three Certificates are READY:

| Certificate | Issuer | Expiry |
|---|---|---|
| gitea-tls | Let's Encrypt | 2026-12-04 |
| harbor-tls | Let's Encrypt | 2026-12-04 |
| OTel self-signed | self-signed | — |

### TLS split-brain (root cause unconfirmed)

From the public vantage point, hosts serve valid Let's Encrypt certificates. In-cluster,
hitting the node IPs (`10.2.248.31` / `10.2.248.247`) with the same `Host` header
presents `CN=TRAEFIK DEFAULT CERT` (self-signed, expires 2027-09-08) instead. Traefik
runs a single replica with a 128 Mi PVC for its ACME store. Additionally, two 17-hour-old
CertificateRequests (`gitea-tls-1`, `harbor-tls-1`) are FAILED with ACME order
`state=invalid` (2026-09-07T12:17Z) while the Certificates themselves report READY. The
HTTP-01 path and Let's Encrypt rate limits should be investigated before the 2026-12-04
expiry.

### NetworkPolicies

14 exist in-cluster (argocd ×8, default ×4, kube-system ×2) plus 5 defined in git
(`kubernetes/cilium/`): argocd→keycloak, DNS egress, HTTPS egress, ci, loki, tempo. The
documented Nexus/SonarQube `Gap-Auth`-forgery NetworkPolicy mitigation is still
unimplemented.

## 9. Observability

### Stack

All components Running at audit:

| Component | Namespace | State |
|---|---|---|
| Prometheus (`prometheus-0` 2/2) | kube-prometheus | Running |
| Grafana (3/3) | kube-prometheus | Running |
| Alertmanager (`alertmanager-0` 2/2) | kube-prometheus | Running |
| Loki (`loki-0` 2/2) | loki | Running |
| Tempo (`tempo-0`) | tempo | Running |
| Alloy ×2 (one per node) | alloy | Running |
| node-exporter ×2 | kube-system | Running |
| kube-state-metrics | kube-prometheus | Running |
| matrix-webhook | kube-prometheus | Running |
| OpenTelemetry operator (2/2) | opentelemetry-operator-system | Running |

### Dashboards

31 Grafana dashboard ConfigMaps (`kubernetes/dashboards/`) covering: ArgoCD,
PostgreSQL, Vault, Keycloak, Gitea, Harbor, Nexus, SonarQube, Woodpecker, Pact Broker,
Microcks, Cilium/Hubble, Kyverno, Trivy, VPA, Kubernetes overview/nodes/pods, Loki
logs, OTel, and more.

### OpenTelemetry

Operator-managed `Instrumentation` CRs per application — backstage, sonarqube,
keycloak, nexus, microcks, link-shortener — defined in `kubernetes/observability/`.
Backstage additionally uses Prometheus remote-write.

### Hubble (Cilium flow visibility)

The flow buffer was 100% full at audit (4,095/4,095, ~182 flows/s) — flow events are
being dropped. Increasing the flow-log queue or disabling capture if unused is
recommended (finding).

### Top memory consumers at audit

Capacity-planning context:

| Workload | Memory |
|---|---|
| nexus | 2341 Mi |
| plane-worker | 2255 Mi |
| sonarqube | 1705 Mi |
| prometheus | 920 Mi |
| argocd-application-controller | 751 Mi |
| keycloak | 738 Mi |

## 10. CI/CD & developer toolchain

The delivery pipeline spans Gitea (git host), Woodpecker CI (pipeline execution),
Harbor and Nexus (artifacts), SonarQube and Pact Broker (quality gates / contracts),
and ArgoCD image-updater for CD. Deep gotchas live in AGENTS.md; only summaries here.

| Component | Version | Namespace | Role |
|---|---|---|---|
| Woodpecker CI | chart 3.6.5 | ci | CI server, 2 agents, own CNPG (`woodpecker-db`) |
| Gitea | chart 12.6.0 | gitea | Git host, OIDC against Keycloak |
| Harbor | chart 1.19.2 | harbor | Container registry (`harbor.ebruno.fr`) |
| Nexus OSS | repo path `helm/releases/nexus` | nexus | Maven/npm artifact proxy |
| SonarQube CE | chart 2026.4.1 | sonarqube | Static analysis (header SSO) |
| Trivy Operator | chart 0.35.0 | trivy-system | Cluster-wide image/manifest scanning |
| ARC | gha-runner-scale-set-controller 0.14.2 | actions-runner-controller / arc-runners | GitHub Actions runners |
| Microcks | vendored `helm/vendor/microcks` | microcks | API mocking / contract tests |
| Pact Broker | chart 6.1.0 | pact-broker | Contract registry |

### Woodpecker CI v3

Login via Gitea OAuth — an indirect SSO chain (Woodpecker → Gitea → Keycloak), since
Woodpecker has no native OIDC support. `WOODPECKER_GITEA_URL` serves **both** OAuth
redirects and API calls, and must be the **public** Gitea URL; the chart does not
propagate `hostAliases` (AGENTS.md gotcha). Robot/token credentials flow
Vault → ExternalSecret (`kubernetes/ci/`) → Woodpecker repo secrets.

### Repo pipeline (link-shortener)

`.woodpecker/woodpecker.yml` for the Quarkus link-shortener app:

```
quarkus-maven-builder (native build)
  → kaniko push → harbor.ebruno.fr/bruno/link-shortener:${CI_COMMIT_SHA}
  → trivy image scan (fails on CRITICAL)
  → ArgoCD webhook triggers sync
```

### Gitea

Git host with OIDC against Keycloak. The 1.26.x upgrade does not migrate legacy
`oauth2_application` rows: `redirect_uris` must be a JSON array and `client_secret` a
bcrypt hash, or the authorize/token endpoints fail cryptically (AGENTS.md gotcha).

### Harbor

Registry at `harbor.ebruno.fr`; OIDC login; robot accounts per project — logins are
auto-prefixed with the project name (e.g. `robot$library+backstage`). The OIDC client
secret is DB-pinned in the core database after first install — Vault-side rotation
requires a manual core-DB update (AGENTS.md gotcha).

### Nexus OSS

Maven/npm artifact proxy sourced from `helm/releases/nexus`. SSO via the custom
`rutauth` capability (`Gap-Auth` header) with local Basic kept for CI and break-glass.
The `sso-sync` CronJob mirrors Keycloak groups into local users/roles every 15 min.
Proxy negative-cache TTL was reduced to 15 min after a 404-poisoning incident
(AGENTS.md).

### SonarQube CE

2026.4.1; header SSO (`Gap-Auth`, native CE 26+); authorization is manual (Phase 1).
The 26.x API surface changes and the `Gap-Auth` loopback break-glass path are
documented in AGENTS.md.

### Trivy

Operator 0.35.0 scans images and manifests cluster-wide; pipelines additionally run a
`trivy` step that fails on CRITICAL. **DEGRADED for Plane images**: scan Jobs FATAL
on `artifacts.plane.so/makeplane/plane-{backend,admin}:v1.4.1` — unauthenticated
upstream pulls return 401/TOOMANYREQUESTS (BackoffLimitExceeded ×10). The 159 existing
VulnerabilityReports do not cover Plane — effectively unscanned (finding).

### ARC (Actions Runner Controller)

Controller (`arc-controller`) plus a GitHub-App-backed scale set (`arc-org-runners`)
in the `arc-runners` namespace. The scale-set chart is **vendored locally**
(`charts/gha-runner-scale-set`): upstream 0.14.2 renders scalar runner-container
fields as broken maps — the local copy ships the fix.

### Microcks

Vendored chart (`helm/vendor/microcks`) for API mocking and contract testing; includes
a dual-shell startup-probe patch in the vendored chart.

### Pact Broker

6.1.0; contract registry for the CI contract loop (pipelines publish/consume pacts;
gates via spectral/oasdiff/deploy-gate in app pipelines). The base URL is configured
as a space-separated pair (in-cluster + public) so HAL links resolve in-cluster while
UI links resolve publicly (AGENTS.md gotcha).

## 11. Storage

Storage classes are described in §3 (`local-path` default, `nfs-rwx`). At audit:
**41 PVs** (all RWO) and **41 PVCs**, all Bound — none stuck or unbound.

PV size distribution:

| PV size | Count |
|---|---|
| 10Gi | 11 |
| 20Gi | 8 |
| 5Gi | 7 |
| 50Gi | 4 |
| 2Gi | 4 |
| 1Gi | 3 |
| 8Gi | 1 |
| 4Gi | 1 |
| 128Mi | 1 |
| 10Mi | 1 |

Top consumers by requested capacity:

| Workload | Requested | Breakdown |
|---|---|---|
| harbor | ~76Gi | registry 50 + db 20 + redis 10 + trivy 5 + jobservice 5 |
| nexus | ~70Gi | data 50 + db 20 |
| kube-prometheus | ~65Gi | prometheus 50 + grafana 10 + alertmanager 5 |
| loki | 50Gi | — |
| sonarqube | ~41Gi | — |
| gitea | ~28Gi | — |
| plane | ~27Gi | — |
| keycloak | 20Gi | — |
| synapse | 20Gi | — |
| link-shortener | 10Gi | — |

The primary node's ephemeral disk (~196Gi) hosts all `local-path` volumes.
`local-path` has **no expansion support**, so disk growth requires manual PV/PVC
work (contrast: `nfs-rwx` supports expansion).

## 12. Security posture

### Kyverno

Kyverno 3.5.0 with 2 ClusterPolicies — `plane-admin-custom-nginx`,
`plane-sso-env-patch` — both Ready; **0 violations** (1 PolicyReport, 0 fail /
1 skip). Policy coverage is otherwise thin — see the NetworkPolicy gap below.

### NetworkPolicies

14 in-cluster (argocd ×8, default ×4, kube-system ×2) plus 5 in git
(`kubernetes/cilium/`, see §8). The documented mitigation for Nexus/SonarQube
`Gap-Auth` header forgery — restricting in-cluster access with Cilium
NetworkPolicies — is **still unimplemented**: in-cluster clients can forge the
header or use local Basic (residual risk, matches AGENTS.md).

### Image tag hygiene

5 mutable (`:latest`) tags found:

| Image | Where | Live? |
|---|---|---|
| ghcr.io/element-hq/synapse:latest | synapse-0 | yes |
| minio/minio:latest | plane-minio-wl-0 | yes |
| harbor.ebruno.fr/link-shortener/link-shortener:latest | link-shortener deployment | yes |
| docker.io/library/bash:latest | nexus init container | transient |
| minio/mc:latest | plane minio-bucket job | one-shot |

Recommend pinning tags or digests for reproducibility.

### Resource guarantees

A sample of deployment pod specs shows **gitea** and **oauth2-proxy** run with **no**
CPU/memory requests or limits; others sampled (link-shortener, pact-broker,
element-web, backstage) have them. On a 29-CPU allocatable node this is a QoS risk
under contention.

### Pre-staged unused TLS secrets

`*-tls` secrets exist in monitoring/, nexus/, pact-broker/, plane/, sonarqube/, and
arc/ but are referenced by no cert-manager Certificate (only the gitea/harbor
certificates exist) — dead weight to clean up.

### Secrets handling

No plaintext credentials found in git (spot-checked pattern: all values reference
ExternalSecrets/Vault). 35/35 ExternalSecrets Ready; the Vault AppRole is read-scoped
per key (§7).

### Image scanning status

Trivy operator is active cluster-wide, but Plane images are unscanned due to failing
pulls (see §10); 159 VulnerabilityReports exist for scanned images.

## 13. Audit findings

16 findings from the 2026-09-08 sweep: 5 major, 9 minor, 2 informational.

| # | Sev | Finding | Evidence | Recommended action |
|---|-----|---------|----------|--------------------|
| 1 | Major | New CNPG cluster has no backups | `link-shortener-ci-db` (ns `ci`, 4Gi) has no `ScheduledBackup`; zero Backup objects; the other 10 clusters all back up daily to Garage | Add a `ScheduledBackup` (CNPG 6-field cron, e.g. `0 50 4 * * *`, barmanObjectStore → Garage, 14d retention) under `kubernetes/postgresql/` |
| 2 | Major | Trivy cannot scan Plane images | 10 scan Jobs in `BackoffLimitExceeded`; FATAL on `artifacts.plane.so/makeplane/plane-{backend,admin}:v1.4.1` — unauthenticated pull → HTTP 401 / TOOMANYREQUESTS; 159 VulnerabilityReports exist but Plane is effectively unscanned | Supply registry credentials to Trivy (or mirror Plane images into Harbor and scan there) |
| 3 | Major | TLS split-brain between public and in-cluster paths | Public vantage serves valid Let's Encrypt certs; in-cluster requests to node IPs (10.2.248.31/10.2.248.247) with the same Host serve `CN=TRAEFIK DEFAULT CERT`; 2 failed `CertificateRequest`s (`gitea-tls-1`, `harbor-tls-1`, ACME order invalid, 2026-09-07T12:17Z) while Certificates report READY; LE expiry 2026-12-04 | Root cause unconfirmed — investigate HTTP-01/ACME path and Traefik certificate routing before the Dec 4 expiry |
| 4 | Major | Apicurio (declarative) chronic restart loop | 318 restarts over 28 days; pod still cycling at audit time; container has no resource limits | Diagnose OOM/liveness; set resource limits; pin the image |
| 5 | Major | Documentation drift vs live cluster | Docs state K3s v1.35.5, single node, 10 CNPG clusters, kernel 6.8.0-124; live is v1.36.4, 2 nodes (arm64 worker, untainted), 11 clusters, kernel 6.8.0-136 | Update AGENTS.md / infrastructure README; this document is the current reference |
| 6 | Minor | Zombie job stuck Terminating | `velero/velero-upgrade-crds` Terminating 62 days (finalizer `argocd.argoproj.io/hook-finalizer`, namespace already deleted) | Remove the finalizer / clean up the ArgoCD Application reference |
| 7 | Minor | Unmanaged namespace `reloader` | stakater reloader v1.4.21 (Deployment + ServiceAccount), created 2026-09-07T16:41Z, absent from git, no ArgoCD labels | Delete it or adopt it into GitOps |
| 8 | Minor | Mutable image tags (5) | `synapse:latest`, `minio/minio:latest`, `link-shortener:latest` (live), `bash:latest` (init container), `minio/mc:latest` (one-shot) | Pin tags/digests for reproducibility |
| 9 | Minor | Missing resource guarantees | gitea and oauth2-proxy pod specs have no CPU/memory requests or limits (others sampled have them) | Add requests/limits |
| 10 | Minor | Untainted arm64 test node | `lima-k3s-agent` (joined 2026-09-07) carries no taints; unowned `arm-test` pod present | Taint with NoSchedule or decommission after testing |
| 11 | Minor | Hubble flow buffer saturated | 4,095/4,095 at ~182 flows/s — flow visibility dropping events | Increase the flow-log queue or disable capture if unused |
| 12 | Minor | Dangling registry secret | `ghcr-jbase-test` docker-registry secret in harbor ns, unreferenced | Delete if unused |
| 13 | Minor | One historical backup failure | woodpecker-db 2026-09-02 "instance manager was restarted during backup" — recovered same day | Monitor; no action needed |
| 14 | Minor | Uncommitted repository changes | 4 modified (`.gitignore`, `AGENTS.md`, `kubernetes/link-shortener/deployment.yaml`, `opencode.json`) + untracked (`.opencode/`, `arm-test.yaml`, two `.bak` files) | Commit or revert so git stays the single source of truth |
| 15 | Info | Gap-Auth forgery mitigation unimplemented | Nexus/SonarQube residual risk (in-cluster clients can forge the `Gap-Auth` header or use local Basic); planned Cilium NetworkPolicies not yet in git | Implement the NetworkPolicies documented in AGENTS.md |
| 16 | Info | Mass pod restart event | Large share of pods restarted ≈2026-09-07T18:20Z, consistent with node churn around the arm64 agent join | Correlate with node events; no action if expected |

**Overall risk statement.** The platform is operationally sound: every ArgoCD app is Synced and Healthy, every database is healthy and connected, and secrets are fully automated. The two items with the most concrete exposure are the unbacked `link-shortener-ci-db` (a silent data-loss risk) and the unscanned Plane images (a security-visibility gap). The TLS split-brain is the item with the nearest hard deadline: it must be understood before the Let's Encrypt certificates expire on 2026-12-04.

## 14. Operational gotchas

The deep operational gotchas live in `AGENTS.md` (canonical, battle-tested). The most important ones, in one line each:

- **Never patch ArgoCD-managed resources in-cluster** — selfHeal reverts drift within ~180s; all changes flow through git.
- **ArgoCD caches remote valueFiles** — bump the `?v=N` query param in `bootstrap/appset-helm.yaml` after pushing values changes, or the app won't re-render.
- **Force the reconciliation chain** when git changes don't propagate: `kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite`, then let AppSets → Applications cascade.
- **CNPG `ScheduledBackup` crons need 6 fields** (seconds included) — a 5-field cron silently mis-parses.
- **CNPG `DatabaseRole` with `ensure: present` does NOT re-set an existing role's password** — align via `ALTER ROLE` (sanctioned data-level op) when app JDBC auth fails while the ESO chain is green.
- **Keycloak realm import is `IGNORE_EXISTING`** — pushing a changed realm file to an existing realm does nothing; also: Keycloak 26 requires `firstName`/`lastName` on every user, and 26.7's classic group-membership endpoints 404 (use `PUT .../users/{uid}/groups/{gid}`).
- **Gitea 1.26 OAuth legacy rows** — `redirect_uris` must be a JSON array and `client_secret` a bcrypt hash, or SSO token exchange 500s/400s.
- **Harbor's OIDC client secret is DB-pinned after first install** — Vault rotation requires a manual core-DB `UPDATE properties` (encrypted with the core key) plus a restart trigger.
- **Plane version-bump trap** — the migrator Job is immutable across chart revisions; bumping requires deleting the completed Job and changing `targetRevision` in `bootstrap/app-plane.yaml`; chart 1.6.1 is the settled state.
- **Pact broker base URL** — the single `PACT_BROKER_BASE_URL` must be a space-separated pair (in-cluster URL FIRST, then public) so both CI HAL links and the public UI resolve.
- **Nexus proxy 404-poisoning** — negative-cache TTL is now 15 min; never trust the public ingress as ground truth for a 404 — test loopback inside the nexus pod.
- **SonarQube break-glass** — no local admin password; use the `Gap-Auth: admin` header on loopback from inside the pod; 26.x changed the API surface (`project` not `projectKey`; `/api/users/who_am_i` removed).
- **URL-encode special characters in connection-string passwords** (`/ @ # = : + ?`) — otherwise URL parsing breaks cryptically downstream.
- **Woodpecker `WOODPECKER_GITEA_URL` must be the public Gitea URL** — it serves both OAuth redirects and API calls; v3+ ignores `WOODPECKER_GITEA_OAUTH`.

## 15. Appendix: audit method & key commands

**Method.** Read-only `kubectl` sweep performed 2026-09-08 (~05:20 UTC) covering nodes, namespaces, pods, workloads, restarts, storage, ArgoCD applications, CNPG clusters and backups, ExternalSecrets, Vault status, certificates, NetworkPolicies, Kyverno policies, Trivy reports, and resource usage, plus repository analysis of `github.com/ebpro/gitops` (branch `main`). No mutations were performed on the cluster or the repository.

**Key commands used (and to use when re-auditing):**

```bash
# ArgoCD sync state & drift
kubectl get app -n argocd -o custom-columns=NAME:.metadata.name,SRC:.spec.source.repoURL,HEALTH:.status.health.status
kubectl argocd app <app> diff

# Pod health
kubectl get pods -A --field-selector status.phase!=Running
kubectl get pods -A --sort-by=.status.containerStatuses[0].restartCount

# Databases & backups (CNPG)
kubectl get cluster,backup,barmanobjectstore -A

# Secrets & ExternalSecrets
kubectl get es,secret -A

# TLS state
kubectl get certificate,certificaterequest -A
openssl s_client -connect <host>:443 -servername <host> </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates

# Policies
kubectl get netpol -A
kubectl get clusterpolicy -n kyverno

# Security scanning coverage
kubectl get trivyvulnerabilityreport -A

# Resource usage
kubectl top nodes
kubectl top pods -A

# Repo hygiene
find . -name ".argocd-source*" -not -path "./.git/*"
git status --porcelain
```

This document supersedes the 2026-08-20 snapshot in `docs/deep-audit.md`, which is retained as a historical record.

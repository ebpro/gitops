# ARC (Actions Runner Controller) — 0.14.x

GitHub Actions ephemeral runners for org `ebpro`, scale-set architecture (SOTA 2026).

| Piece | Where |
|---|---|
| Controller deployment | helm app `arc-controller` (`bootstrap/appset-helm.yaml`), ns `actions-runner-controller` |
| Org scale set (`ebpro-org`) | helm app `arc-org-runners` (`bootstrap/app-arc-org-runners.yaml`), ns `arc-runners` |
| Arm scale set (`ebpro-org-arm`) | helm app `arc-arm-runners` (`bootstrap/app-arc-arm-runners.yaml`), ns `arc-runners` |
| Large scale set (`ebpro-org-large`) | helm app `arc-large-runners` (`bootstrap/app-arc-large-runners.yaml`), ns `arc-runners` |
| AI review scale set (`ebpro-ai-review`) | helm app `arc-ai-review-runners` (`bootstrap/app-arc-ai-review-runners.yaml`), ns `arc-runners` |
| GitHub App `arc-gitops-ebruno` (runner mgmt) | Vault `secret/data/github/arc-app` (`github_app_id`, `github_app_installation_id`, `github_app_private_key`) → ExternalSecret `arc-github-creds` (this dir) → K8s secret in `arc-runners` |
| Selftest workflow | `.github/workflows/arc-selftest.yaml` (workflow_dispatch; matrix legs `runs-on: [ebpro-org, linux, self-hosted, x64]` / `[..., arm64]`) |

## Jobs → runner scheduling (unified fleet labels, 2026-09-09)

Both scale sets carry the shared fleet label `ebpro-org` and differ only in the
arch label, so one selector family covers the whole fleet. The three selectors:

```yaml
runs-on: [ebpro-org, linux, self-hosted]            # portable — any arch (random)
runs-on: [ebpro-org, linux, self-hosted, x64]       # pin x86-64
runs-on: [ebpro-org, linux, self-hosted, arm64]     # pin arm64
```

Rendered labels per set (git → GitHub):

| Scale set | `runnerScaleSetLabels` (in git) | Runner labels on GitHub |
|---|---|---|
| `ebpro-org` | `[self-hosted, linux, ebpro-org, x64]` | `self-hosted linux ebpro-org x64` |
| `ebpro-org-arm` | `[self-hosted, linux, ebpro-org, arm64]` | `self-hosted linux ebpro-org arm64 ebpro-org-arm` |

ARC additionally registers each scale set's NAME as a runner label
automatically, so the scale-set-name labels remain usable as fine-grained
escape hatches:

- `runs-on: ebpro-org-arm` → arm set only.
- `runs-on: ebpro-org` → now matches **both** sets (the fleet label is shared);
  it no longer implicitly means "x64 set" — use the explicit `x64`/`arm64`
  selectors for arch-pinned work.

Notes:

- `x64` is the GitHub Actions convention (Docker/OCI call it `amd64`) — keep
  `x64`/`arm64` in labels and selectors.
- Runner labels are opaque strings: GitHub only checks that the job's
  `runs-on` set is contained in the runner's label set. Label correctness is
  guaranteed by each scale set's `template.spec.nodeSelector`
  (`kubernetes.io/arch: amd64`/`arm64`), which pins the runner pod to nodes of
  that arch — the label cannot drift from the machine.
- Historical (pre-unification): with per-set label sets, hybrids like
  `[self-hosted, linux, x64]` were observed not to trigger a scale event (job
  queued forever, verified 2026-08-20; no error raised anywhere). Use the
  selectors above — they all name the fleet explicitly.

### Usage rules

1. **Fleet selector only for arch-independent work.**
   `[ebpro-org, linux, self-hosted]` lands on a random arch — fine for
   arch-agnostic steps (lint, docs, platform-independent tests). When you build
   container images, the build node's arch IS the image arch (no QEMU/binfmt on
   the arm node), so image builds must pin their leg
   (`[ebpro-org, linux, self-hosted, x64]` / `[..., arm64]`).
2. **Fail fast on arch.** Echo `uname -m` as the first step of any job whose
   output is arch-sensitive, so a scheduling surprise fails loudly with
   evidence instead of producing a wrong-arch artifact.
3. **All sets scale to zero.** Every scale set runs `minRunners: 0` — there is
   no warm runner and no capacity floor; the first job after an idle period
   pays a cold start (pod schedule + image pull + registration). Scaling is
   job-driven, capped by `maxRunners`: org 4, large 2, arm 2, ai-review 1.
   The org (3→4) and large (1→2) raises of 2026-10-12 exploit the
   `pc-bruno-gpu` laptop's headroom (preferred runner node that may be powered
   off); with the laptop down the extra slots can stay Pending and jobs queue —
   `large` is opt-in/scale-to-zero, so that never stalls the default org pool
   (see the header comments in `helm/releases/arc/org-scale-set-values.yaml` /
   `large-scale-set-values.yaml`).

## Multiarch (no QEMU)

- Both scale sets are arch-pinned via `template.spec.nodeSelector`
  (`kubernetes.io/arch: amd64` / `arm64`) — required so x64 jobs can never land
  on the arm node (its dind has no binfmt, so amd64 job containers would fail
  to start).
- Native multiarch build pattern: workflow matrix over `[amd64, arm64]`, each
  leg `runs-on` its arch-pinned selector
  (`[ebpro-org, linux, self-hosted, x64]` / `[..., arm64]`) and builds its
  platform natively, pushing per-arch tags; a final job assembles the manifest
  list registry-side with `docker buildx imagetools create` (no local pull, no
  QEMU/binfmt anywhere).
- The arm node is `lima-k3s-agent` (Lima dev VM): if the VM reboots, arm
  runners vanish and queued arm jobs wait until it returns (GitHub has no
  timeout for self-hosted labels). With `minRunners: 0` there is no warm arm
  runner to lose — and no pre-warming either: the first arm job after the node
  returns cold-starts like any other.
- The runner image `quarkus-ci-runner` is multiarch (amd64+arm64 in Harbor);
  `docker:28-dind` and the listener image are multiarch too — same image refs
  on both sets.

## Node taint & toleration (arm64)

The arm node `lima-k3s-agent` is tainted `kubernetes.io/arch=arm64:NoSchedule` so
x64 work can never land on it (its dind has no binfmt). Two pieces keep this
consistent under GitOps:

- **Kyverno enforces the taint** — ClusterPolicy `node-arm64-arch-taint`
  (`node-arm64-arch-taint.yaml`) runs admission+background and re-applies the
  taint on any arm64 Node, so it survives kubelet re-provisioning (kubelet is in
  `excludeGroups: system:nodes`, which the background rescan covers). Background
  Node mutation is allowed by the `kyverno:update-nodes` ClusterRole
  (`kyverno-node-mutation-rbac.yaml`), aggregated into the Kyverno background
  controller via the `rbac.kyverno.io/aggregate-to-background-controller` label
  (no separate binding). Kyverno's `resourceFilters` must not exclude
  `[Node,*,*]` for the admission path to see Nodes — handled in
  `helm/releases/kyverno/values.yaml` (`config.resourceFiltersExclude`) plus a
  documented one-off patch to the live `keep`-annotated ConfigMap.
- **ARM runners tolerate it** — `helm/releases/arc/arm-scale-set-values.yaml`
  adds `template.spec.tolerations` for `kubernetes.io/arch=arm64:NoSchedule` so
  the `ebpro-org-arm` runner pod can be scheduled onto the tainted node. Listeners
  intentionally stay on the x64 node (`listenerTemplate` has no toleration).

**VM-reboot behaviour:** `lima-k3s-agent` is a Lima dev VM. If it reboots, the arm
runner pods vanish (and re-appear job-driven — `minRunners: 0`, so only when a new
arm job is dispatched once the node is back), but the taint itself persists and is
re-asserted by Kyverno — no manual re-taint needed.

## Ops notes

- The 0.14.2 controller does **not** watch the `githubConfigSecret` change: after
  rotating the GitHub App credentials in Vault/ExternalSecret, restart the
  controller pod (it recreates the listener) for the new config to propagate.
- Scale set CRUD is **not** in the public REST API (`.../scaling-set-definitions`
  is 404). Internal endpoint: `_apis/runtime/runnerscalesets` on the actions
  service URL, using the admin connection from
  `POST /actions/runner-registration` (`RemoteAuth <registration token>`).
  Read-only probes: `GET .../runnerscalesets` (labels/stats) and
  `GET .../runnerscalesets/{id}/acquirablejobs` (204 = no job acquired).
 - The rebuilt Vault's `secret/` KV API is **fully writable with the root token**
   (PUT/read/DELETE verified 2026-08-20). Provisioning can go directly through the
   API (`http://vault-active.vault.svc.cluster.local:8200`), not just the pod's
   sidecar path. The dead key `secret/data/github/arc-runner` (revoked PAT) was
   purged via API on 2026-08-20.

## GitHub App credential rotation runbook

Chain (everything below is git-managed except the GitHub App itself and the Vault
entry): GitHub org settings → Vault `secret/data/github/arc-app` (keys
`github_app_id`, `github_app_installation_id`, `github_app_private_key`) →
ExternalSecret `arc-github-creds` (`arc-github-creds-external-secret.yaml`,
`refreshInterval: 24h`) → Secret `arc-github-creds` in ns `arc-runners` → consumed
by all four scale sets via `githubConfigSecret` in
`helm/releases/arc/*-scale-set-values.yaml`. The target Secret is ESO-owned
(`creationPolicy: Owner`, `mergePolicy: Replace`) — never edit it by hand; it is
rebuilt from Vault. The Vault entry is created out-of-band; recreate it with
(root token in the `vault-init` secret; this Vault CLI has no `kv merge`, so all
keys must go in one full put; KV-v2 user path — no `secret/data/` prefix):

    vault kv put secret/github/arc-app github_app_id=<APP_ID> \
      github_app_installation_id=<INSTALLATION_ID> github_app_private_key=@new-key.pem

1. **New key at GitHub** — org settings → GitHub Apps → `arc-gitops-ebruno` →
   Private keys → generate; download the PEM. Old keys stay valid until deleted —
   delete the previous one only after step 5 passes.
2. **Back up first** — `vault kv get secret/github/arc-app`; store the previous
   values off-cluster (password manager). Never paste them into tickets, chat, git.
3. **Write the new values** — full re-`put` (command above, real values instead of
   placeholders; `@file` avoids PEM-newline quoting issues).
4. **Propagate** — ESO only re-reads Vault every 24h; force it now:
   `kubectl annotate externalsecret arc-github-creds -n arc-runners force-sync=$(date +%s) --overwrite`
   (trigger-only — selfHeal removing the annotation afterwards is harmless; ESO acts
   on first sight). Then restart the controller pod (delete it; the Deployment
   recreates it): 0.14.2 does not watch `githubConfigSecret` (see Ops notes), and
   controller restart is what recreates the listeners that mount the Secret.
5. **Verify** — `kubectl logs -n actions-runner-controller deploy/arc-controller --tail=100`
   shows no auth failures (401 / invalid-client / message-session errors), then
   dispatch `.github/workflows/arc-selftest.yaml` (workflow_dispatch): runner
   spin-up and a green job prove the App signature end-to-end.
6. **Rollback** — re-run steps 3–4 from the step-2 backup. Recovery is Vault-side
   only while the old key is still valid at GitHub.

## Harbor image-pull credential rotation (node-pull robot)

Runner image pulls use the pull-only Harbor robot `robot$quarkus-microservices+node-pull`
(project `quarkus-microservices`, action `repository:pull`, never expires), NOT the
out-of-band admin secret. Chain: Harbor robot → Vault `secret/harbor/node-pull`
(key `config` = compact `.dockerconfigjson` string, host key `https://harbor.ebruno.fr`)
→ ExternalSecret `harbor-node-pull` (`harbor-node-pull-external-secret.yaml`,
`refreshInterval: 24h`, ESO-owned template emits `kubernetes.io/dockerconfigjson`)
→ Secret `harbor-node-pull` in ns `arc-runners` → referenced by all four
`helm/releases/arc/*-scale-set-values.yaml` `imagePullSecrets`.

Rotation (Harbor API is admin-only; run from inside a `harbor-core` pod against
`http://localhost:8080`; the robot token is only ever returned on create/refresh):

1. Refresh the secret: `POST /api/v2.0/robots/{id}/refreshsecret` (or delete+recreate),
   capture the new `secret` (never print it).
2. Rebuild the dockerconfig with the same host-key format and write it as ONE full
   put (this Vault CLI has no `kv merge`):
   `vault kv put secret/harbor/node-pull config=@new-dockerconfig.json` (user path —
   no `secret/data/` prefix).
3. Force ESO: `kubectl annotate externalsecret harbor-node-pull -n arc-runners force-sync=$(date +%s) --overwrite`.
   Running runner pods keep working (pull secrets are read at pod start by kubelet;
   new runners pick up the rotated Secret immediately).
4. Verify: `curl -u "<robot-name>:<new-secret>" http://localhost:8080/v2/quarkus-microservices/quarkus-ci-runner/tags/list` → 200.

The legacy Secret `harbor-registry-secret` (ns `arc-runners`, admin creds) is deliberately
kept as the rollback path: revert the four values-file `imagePullSecrets` names to it.
Do not delete it until the robot path has soaked.

## CRDs (vendored)

`crds/` holds the 4 CRDs from `gha-runner-scale-set-controller` **0.14.2**
(`autoscalinglisteners`, `autoscalingrunnersets`, `ephemeralrunners`, `ephemeralrunnersets`).

ArgoCD does not install a Helm chart's `crds/` directory by default, so these are
synced here as raw manifests (same reason the app uses an explicit
`controllerServiceAccount` in its values).

**When you bump the controller chart version**: re-extract
`gha-runner-scale-set-controller-*/crds/*.yaml` from the new chart tarball,
replace these files, commit + push. (Chart: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`.)

## Node → Harbor pull path (host firewall contract)

Runner image pulls (`harbor.ebruno.fr/...`) are **kubelet/host-level network
operations** — pod-side `hostAliases` and in-cluster DNS are irrelevant to them.
The 2026-10-13 incident (runners on `pc-bruno-gpu` stuck in
`Init:ImagePullBackOff` pulling `quarkus-ci-runner`) was caused by the **host
firewall on compute-lsis-2**, not the cluster:

- The ingress VIP `10.2.248.31` is both the Traefik LoadBalancer IP and
  compute-lsis-2's own LAN IP. `harbor.ebruno.fr` has **no public A record by
  design** — TLS is ACME DNS-01 via OVH (`letsencrypt-ovh` resolver) — so the
  whole `*.ebruno.fr` platform is LAN/VPN-only.
- **LAN-side traffic to the VIP bypasses netfilter INPUT** because Cilium eBPF
  DNATs at TC-ingress on eth0 (documented quirk) — this is why in-cluster pulls
  served fine while WireGuard-side pulls failed. WG traffic (net
  `10.10.15.0/24`, compute-lsis-2 is the WG endpoint) arrives on `wg0` and hits
  ufw INPUT, where the default-deny silently DROPs it → `i/o timeout`.
- **Required host rule set** (keep ufw ENABLED; ufw is host administration,
  outside git — applied manually on compute-lsis-2):
  - already present: `22/tcp` and `6443/tcp` from Anywhere
  - add: `sudo ufw allow from 10.10.15.0/24 to any port 80 proto tcp`
  - add: `sudo ufw allow from 10.10.15.0/24 to any port 443 proto tcp`
  - add: `sudo ufw logging low`
- **Verification from a WireGuard peer:**
  - `nc -vz -w3 10.2.248.31 443` → succeeds
  - `curl -sk --connect-timeout 5 https://10.2.248.31/v2/ -H 'Host: harbor.ebruno.fr' -o /dev/null -w '%{http_code}\n'` → `401` (registry auth challenge — pull path healthy)
- **Regression symptom signature:** runner pods `Init:ImagePullBackOff` with
  `dial tcp 10.2.248.31:443: i/o timeout` **and** org scale-set slots exhausted
  (`maxRunners: 4`) — check the host ufw rule set above before suspecting the
  cluster.

# ARC (Actions Runner Controller) — 0.14.x

GitHub Actions ephemeral runners for org `ebpro`, scale-set architecture (SOTA 2026).

| Piece | Where |
|---|---|
| Controller deployment | helm app `arc-controller` (`bootstrap/appset-helm.yaml`), ns `actions-runner-controller` |
| Org scale set (`ebpro-org`) | helm app `arc-org-runners` (`bootstrap/app-arc-org-runners.yaml`), ns `arc-runners` |
| Arm scale set (`ebpro-org-arm`) | helm app `arc-arm-runners` (`bootstrap/app-arc-arm-runners.yaml`), ns `arc-runners` |
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
  timeout for self-hosted labels). `minRunners: 0` bounds the blast radius;
  first arm job pays a ~30–60s cold start.
- The runner image `quarkus-ci-runner` is multiarch (amd64+arm64 in Harbor);
  `docker:28-dind` and the listener image are multiarch too — same image refs
  on both sets.

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

## CRDs (vendored)

`crds/` holds the 4 CRDs from `gha-runner-scale-set-controller` **0.14.2**
(`autoscalinglisteners`, `autoscalingrunnersets`, `ephemeralrunners`, `ephemeralrunnersets`).

ArgoCD does not install a Helm chart's `crds/` directory by default, so these are
synced here as raw manifests (same reason the app uses an explicit
`controllerServiceAccount` in its values).

**When you bump the controller chart version**: re-extract
`gha-runner-scale-set-controller-*/crds/*.yaml` from the new chart tarball,
replace these files, commit + push. (Chart: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`.)

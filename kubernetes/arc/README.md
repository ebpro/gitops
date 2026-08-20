# ARC (Actions Runner Controller) — 0.14.x

GitHub Actions ephemeral runners for org `ebpro`, scale-set architecture (SOTA 2026).

| Piece | Where |
|---|---|
| Controller deployment | helm app `arc-controller` (`bootstrap/appset-helm.yaml`), ns `actions-runner-controller` |
| Org scale set (`ebpro-org`) | helm app `arc-org-runners` (`bootstrap/appset-helm.yaml`), ns `arc-runners` |
| GitHub App `arc-gitops-ebruno` (runner mgmt) | Vault `secret/data/github/arc-app` (`github_app_id`, `github_app_installation_id`, `github_app_private_key`) → ExternalSecret `arc-github-creds` (this dir) → K8s secret in `arc-runners` |
| Selftest workflow | `.github/workflows/arc-selftest.yaml` (workflow_dispatch, `runs-on: ebpro-org`) |

## Jobs → scale set routing (GitHub-side matching)

Documented forms only (github.com docs: *Using Actions Runner Controller runners in a workflow*):

```yaml
runs-on: ebpro-org                      # scale-set name (recommended)
runs-on: [linux, x64]                   # EXACT runnerScaleSetLabels set
```

Hybrids like `[self-hosted, linux, x64]` or `[self-hosted, linux, x64, ebpro-org]`
do **not** match — the job then stays queued forever and the listener sees no
scale event (verified 2026-08-20; no error is raised anywhere).

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

# ARC (Actions Runner Controller) — 0.14.x

GitHub Actions ephemeral runners for org `ebpro`, scale-set architecture (SOTA 2026).

| Piece | Where |
|---|---|
| Controller deployment | helm app `arc-controller` (`bootstrap/appset-helm.yaml`), ns `actions-runner-controller` |
| Org scale set (`ebpro-org`) | helm app `arc-org-runners` (`bootstrap/appset-helm.yaml`), ns `arc-runners` |
| GitHub PAT (runner mgmt) | Vault `secret/data/github/arc-runner` → ExternalSecret `arc-github-creds` (this dir) → K8s secret in `arc-runners` |
| Selftest workflow | `.github/workflows/arc-selftest.yaml` (workflow_dispatch, `[self-hosted, linux, x64]`) |

## CRDs (vendored)

`crds/` holds the 4 CRDs from `gha-runner-scale-set-controller` **0.14.2**
(`autoscalinglisteners`, `autoscalingrunnersets`, `ephemeralrunners`, `ephemeralrunnersets`).

ArgoCD does not install a Helm chart's `crds/` directory by default, so these are
synced here as raw manifests (same reason the app uses an explicit
`controllerServiceAccount` in its values).

**When you bump the controller chart version**: re-extract
`gha-runner-scale-set-controller-*/crds/*.yaml` from the new chart tarball,
replace these files, commit + push. (Chart: `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`.)

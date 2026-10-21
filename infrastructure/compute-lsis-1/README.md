# compute-lsis-1 host tooling

GitOps-tracked copy of the `lima-k3s-agent` VM config (`lima.yaml`) running on
`compute-lsis-1` (Mac Studio, arm64 k3s worker). The live copy lives at
`~/.lima/k3s-agent/lima.yaml` on that host; the `provision:` scripts run at
instance start.

## Repair history — 2026-10-21

The live file had a duplicate `provision:` key (YAML last-wins silently broke
all `limactl` commands on the instance) and was missing the `nfs-common` seed,
which caused a 4-day `nfs-client` FailedMount on the arm64 node. Fixed by
merging the duplicate provision blocks and adding the `nfs-common` install
script (both are reflected in the tracked `lima.yaml` here).

## Change procedure

Edit `lima.yaml` here, commit, then scp to the Mac over `~/.lima/k3s-agent/`.
One-off package ops go through `limactl shell k3s-agent`.

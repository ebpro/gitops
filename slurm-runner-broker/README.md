# slurm-runner-broker

Phase-1 broker for the **Slurm ephemeral-runner tier**: an in-cluster service that
watches GitHub org `ebpro-org` for queued workflow runs labelled
`[self-hosted, linux, x64, hpc]` and dispatches one Slurm job per matching queued
job on the SMS cluster (`sms-cluster.lis-lab.fr`, partition `ouranos`). Each Slurm
job boots an **ephemeral** `actions/runner` from the digest-pinned
`harbor.ebruno.fr/quarkus-microservices/quarkus-ci-runner@sha256:72ac7d9f…` enroot
image, which self-registers, runs exactly one job, and deregisters.

## Files

| File | Purpose |
|---|---|
| `broker.py` | Poller/dispatcher. **Python 3 stdlib only** (urllib, subprocess, json, logging). GitHub App → installation token (cached 55 min, pure-stdlib RS256 JWT), queued-run polling, lazy registration-token minting, ssh-stdin token delivery, `sbatch` dispatch, `squeue`-based state reconciliation, zombie-runner sweep, ssh backoff 30 s → 5 min, structured JSON logs on stdout. |
| `job-template.sh` | The `sbatch` script (submitted via stdin). Digest-keyed enroot image cache in the NFS-shared `$HOME/.cache/ebpro-runner` — one import per digest serves the whole cluster and survives `/scratch` wipes (node-local `flock` is only a per-node fast path; cross-node safety comes from atomic NFS rename of byte-identical temp installs), `ENVFILE` token sourcing, runner config/run, EXIT trap shredding the token file. Per-job work dirs stay on node-local `/scratch` (lazily created in-job); job logs go to persistent `$HOME/logs`. |
| `Dockerfile` | `python:3.12-slim` + `openssh-client` + `curl`, runs as uid/gid **10001**. |
| `.woodpecker.yaml` | Kaniko build + push to `harbor.ebruno.fr/library/slurm-runner-broker:sha-<short-sha>` and `:latest`. |

## Build (human step: repo does not exist yet)

1. Create a **Gitea** repo (e.g. `bruno/slurm-runner-broker`) and push this
   directory's contents **as-is** (this copy in `ebpro/gitops` is source-of-scaffold
   only — no ArgoCD app reads this path).
2. Add repo secrets `HARBOR_USERNAME` / `HARBOR_PASSWORD` = the
   `robot$library+backstage` credentials (Vault `secret/harbor/backstage`, same
   pattern as `bruno/link-shortener`).
3. Push to `main` → the pipeline builds and pushes the image.

## Deploy

The GitOps manifests and the operator runbook live in the same git repo at
[`kubernetes/slurm-runner-broker/`](../kubernetes/slurm-runner-broker/README.md)
(namespace `slurm-runner-broker`, synced by the `kubernetes-manifests` AppSet).
The Deployment starts at `replicas: 0`; raise it to `1` only after runbook steps
A–C are complete.

## Phase-1 limitations (by design)

* No `container:` jobs, no `services:`, no dind, no
  `ACTIONS_RUNNER_CONTAINER_HOOKS` (podman-in-enroot hook = Phase 2 spike).
* No `actions/cache` backend wiring (Phase 1 gap; workflows must not rely on it).
* Submission channel is **ssh + sbatch only** (no slurmrestd on SMS). The cluster
  talks to SMS as `emmanuel.bruno`; a dedicated `ghaci` Slurm account is future
  work (runbook §Phase-2).
* Broker state is in-memory: a restart may re-dispatch a still-queued run at most
  once; the losing ephemeral runner self-exits and the zombie sweeper deletes its
  registration after 10 min offline.

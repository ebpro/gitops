#!/bin/bash
# =============================================================================
# ebrunner job template — submitted on stdin by the slurm-runner-broker:
#     ssh <user>@sms 'exec sbatch --export ENVFILE=...,GH_ORG=...,RUNNER_IMAGE=...,... -' < job-template.sh
#
# sbatch flags set by the broker (CLI, not here): -p ouranos --time --cpus-per-task
# --mem --output=/scratch/$USER/gha-slurm/logs/ebrunner-%j.out --export (see below).
#
# --- ssh-stdin -> env-file delivery chain (Phase 1, token handling) ----------
# 1. Broker mints a GitHub org runner registration token LAZILY, right before
#    this submission (1 h lifetime; nothing is stored cluster-side in between).
# 2. Broker pipes it over ssh STDIN:  umask 077; cat > $HOME/.ebrunner-<uuid>.env
#    File content is exactly one line:  export RUNNER_TOKEN=<token>
#    HOME is NFS-shared to compute, so the batch job finds the file on the node.
#    The token NEVER appears in argv, in this script text, or in the Slurm KVS
#    (--export carries only the file PATH, never the value).
# 3. This script sources the file, and the EXIT trap shreds it (fallback rm for
#    filesystems without shred support) plus removes the run dir. Even if the
#    job is cancelled in PD, the broker's periodic GC removes stale files.
#
# --- Phase-1 limitations ------------------------------------------------------
# * No container:/services:/dind, no ACTIONS_RUNNER_CONTAINER_HOOKS (podman
#   hook spike = Phase 2), no actions/cache URL wiring.
# * /scratch/$USER is NODE-LOCAL: the logs dir must pre-exist on every
#   partition node (one-time bootstrap in the runbook) because slurmd opens
#   --output before this script runs.
# =============================================================================
#SBATCH --job-name=ebrunner-%j
#SBATCH --open-mode=truncate

set -Eeuo pipefail

: "${ENVFILE:?ENVFILE must be set by sbatch --export (path only, never the token)}"
: "${RUNNER_IMAGE:?RUNNER_IMAGE must be set by sbatch --export (digest-pinned oci ref)}"
: "${GH_ORG:?GH_ORG must be set by sbatch --export}"

S="/scratch/${USER:?slurmd must set USER}/gha-slurm"
RUNDIR="${S}/work/${SLURM_JOB_ID:-unknown}"

cleanup() {
    # Wipe the single-use token file, then the job-local run dir.
    shred -u "$ENVFILE" 2>/dev/null || rm -f "$ENVFILE" 2>/dev/null || true
    rm -rf "$RUNDIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT

mkdir -p "${S}/images" "${S}/work" "${S}/logs"

# --- materialize the runner token (env-file -> process env, nothing on argv of
# --- the submitting pipeline; config.sh below consumes it per the locked design)
. "$ENVFILE"
: "${RUNNER_TOKEN:?RUNNER_TOKEN not found in ${ENVFILE}}"

# --- enroot image cache keyed by DIGEST (never a tag) ------------------------
DIGEST="${RUNNER_IMAGE##*@}"                     # sha256:72ac...
IMGKEY="docker-${DIGEST//:/-}"                   # docker-sha256-72ac...
SQSH="${S}/images/${IMGKEY}.sqsh"

# Serialize first-import per node with a flock (300 s budget covers a cold pull).
exec 9>"${S}/images/.import.lock"
flock -w 300 9
if [ ! -f "$SQSH" ]; then
    TMP_SQSH="${SQSH}.tmp.${SLURM_JOB_ID:-$$}"
    # Harbor credentials come from ~/.netrc (NFS-shared HOME; runbook step B).
    enroot import -o "$TMP_SQSH" "docker://${RUNNER_IMAGE}"
    mv -f "$TMP_SQSH" "$SQSH"
fi
flock -u 9

# --- boot the ephemeral runner inside the image (workdir = RUNDIR) -----------
# The image ships /home/runner with config.sh + run.sh baked in; copy it into
# the node-local run dir so state (.runner, _work, _diag) lands on /scratch.
# $RUNNER_TOKEN and $SLURM_JOB_ID expand INSIDE the container env (enroot
# propagates the caller environment); the run/label/name contract is:
#   name ebrunner-$SLURM_JOBID (generic prefix REQUIRED for broker reconcile).
mkdir -p "$RUNDIR"
enroot start -w "$RUNDIR" "$SQSH" bash -c \
    'cp -a /home/runner/. '"$RUNDIR"'/ && cd '"$RUNDIR"' && ./config.sh --url https://github.com/'"$GH_ORG"' --token "$RUNNER_TOKEN" --ephemeral --unattended --labels hpc,self-hosted,linux,x64 --name ebrunner-$SLURM_JOBID && ./run.sh'

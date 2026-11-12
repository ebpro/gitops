#!/usr/bin/env bash
#
# fence-runner-node.sh — control-plane-side fence for a K3s CI runner node.
#
# PURPOSE
#   Fences a node as CI-unsafe in one gesture, from the HEALTHY control-plane
#   side: cordon + quarantine label + deletion of the ARC runner PODS still
#   sitting on that node. Laptop-side hooks (infrastructure/laptop/runner-*.sh)
#   are NOT a reliable fence: 2026-11-12 (pc-bruno-gpu) and 2026-10-13 both
#   showed drain/auto-drain silently skipped when the node could not reach the
#   API — and cordon alone does NOT evict already-scheduled pods, so 2 ARC
#   runner pods sat in Init:ImagePullBackOff on the fenced node for ~5h and
#   pinned 100% of maxRunners:2; queued jobs never got a runner (CI frozen).
#
# FOUR-LAYER FENCE MODEL
#   1. spec.unschedulable via cordon — the ONLY operative placement fence
#      today (proven to survive admission; a quarantine:NoSchedule taint was
#      accepted and erased in < 1s by sibling Kyverno policies rewriting the
#      atomic spec.taints list).
#   2. node label quarantine=true — carries declared intent; read by
#      infrastructure/laptop/runner-join.sh, which hard-stops (exit 1) and
#      refuses to uncordon a labelled node.
#   3. Kyverno taint policy (kubernetes/arc/node-quarantine-taint.yaml) — NOT
#      DEPLOYED today, its patchesJson6902 append never validated in
#      admission; this script must not depend on it.
#   4. Deleting the runner pods still on the node — the missing layer, added
#      by THIS script.
#
# POD vs CR SEMANTICS (the whole value of this tool)
#   Delete runner PODS only — NEVER the EphemeralRunner/EphemeralRunnerSet
#   CRs. With the CRs alive, pod recreation reuses the existing GitHub-side
#   runner registration, so jobs already assigned to those runnerIDs are
#   picked up with NO manual workflow re-run (measured 2026-11-12: healthy
#   runners on compute-lsis-2 in ~25s, PENDING=0 RUNNING=2, runnerIDs
#   14173/14174 resumed). Deleting the CRs risks orphaning assigned jobs.
#   (Verified for this ARC version and flow only.)
#
# NOTES
#   Runner PODs live in namespace 'arc-runners'; the controller and listeners
#   live in 'actions-runner-controller' — never confuse them. Non-interactive.
#
# EXAMPLES
#   ssh compute-lsis-2 'fence-runner-node.sh --dry-run pc-bruno-gpu'   # preview (read-only)
#   ssh compute-lsis-2 'fence-runner-node.sh pc-bruno-gpu'             # the real fence
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  fence-runner-node.sh [--dry-run] <node>                  # fence (adds layer 4)
  fence-runner-node.sh [--dry-run] --unfence --yes <node>  # lift the fence

Uses the ambient KUBECONFIG (this runs on an admin / control-plane machine);
override with `export KUBECONFIG=/path/to/kubeconfig`. The git-managed
node-ops ServiceAccount (kubernetes/arc/node-ops-rbac.yaml: nodes
get/list/patch, pods get/list/delete, pods/eviction create) already carries
every right this script needs, so a kubeconfig holding that token works too.
USAGE
}

DRY_RUN=0
UNFENCE=0
ASSUME_YES=0
FORCE=0
NODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --unfence) UNFENCE=1 ;;
    --yes) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -n "${NODE}" ]; then
        echo "ERROR: only one node may be fenced at a time (got '${NODE}' and '$1')" >&2
        exit 1
      fi
      NODE=$1
      ;;
  esac
  shift
done

if [ -z "${NODE}" ]; then
  usage >&2
  exit 1
fi

# Unfence is gated behind --yes on purpose. The precondition is the MEASURED
# data-plane criterion from the 2026-11-12 incident dossier — node 'Ready'
# proves nothing about the Cilium tunnel (see docs/network/
# runner-node-vlan-isolation-20261112.md §9 / §6.1.2). Checked before the
# preflight so it never needs cluster access to refuse.
if [ "${UNFENCE}" -eq 1 ] && [ "${ASSUME_YES}" -ne 1 ]; then
  {
    echo "ERROR: --unfence requires --yes, and only AFTER this precondition held:"
    echo "  On ${NODE}, 'cat /sys/class/net/cilium_vxlan/statistics/rx_packets' must"
    echo "  move STRICTLY ABOVE 0 under peer->node traffic. During the 2026-11-12"
    echo "  incident that counter sat at 0 across 166 240 transmitted packets while"
    echo "  the node was Ready — the tunnel was unidirectional and CI was dead."
    echo "  Reference: docs/network/runner-node-vlan-isolation-20261112.md §9 / §6.1.2."
  } >&2
  exit 1
fi

# --- preflight: fail fast, do not chain deeper calls on failure -----------
if ! probe_err=$(kubectl --request-timeout=5s get node "${NODE}" 2>&1 >/dev/null); then
  echo "ERROR: cannot read node '${NODE}' — API server unreachable / wrong kubeconfig" >&2
  echo "${probe_err}" >&2
  exit 1
fi
echo "Preflight OK: node '${NODE}' is visible in the API"

# --- unfence path ----------------------------------------------------------
if [ "${UNFENCE}" -eq 1 ]; then
  echo "==> Unfence ${NODE}: label removal + uncordon (taint removal stays manual)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "+ kubectl --request-timeout=20s label node ${NODE} quarantine- --overwrite  (dry-run: not executed)"
    echo "+ kubectl --request-timeout=20s uncordon ${NODE}                            (dry-run: not executed)"
  else
    kubectl --request-timeout=20s label node "${NODE}" quarantine- --overwrite
    kubectl --request-timeout=20s uncordon "${NODE}"
  fi
  echo "Manual step, ONLY if a quarantine:NoSchedule taint was ever re-posed:"
  echo "  kubectl taint nodes ${NODE} quarantine:NoSchedule-"
  exit 0
fi

# --- control-plane guard ----------------------------------------------------
# In this 3-node cluster the only other amd64-capable runner node is
# compute-lsis-2 itself, since lima-k3s-agent is arm64 and tainted
# kubernetes.io/arch=arm64:NoSchedule — fencing the control plane leaves amd64
# runners nowhere to be scheduled: CI dead by construction.
if cp_label=$(kubectl --request-timeout=20s get node "${NODE}" \
  -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null); then
  :
else
  cp_label=""
fi
if [ -n "${cp_label}" ] && [ "${FORCE}" -ne 1 ]; then
  {
    echo "ERROR: refusing to fence '${NODE}': it carries node-role.kubernetes.io/control-plane."
    echo "The only other amd64-capable runner node is compute-lsis-2 itself (lima-k3s-agent"
    echo "is arm64 and tainted kubernetes.io/arch=arm64:NoSchedule), so fencing the control"
    echo "plane leaves amd64 runners nowhere to be scheduled — CI dead by construction."
    echo "Re-run with --force only if that is really what you want."
  } >&2
  exit 1
fi

# HARD SAFETY GUARD for the delete step below. The only delete this tool may
# ever issue is a graceful `delete pod -n arc-runners <names...>`; the command
# string must contain the literal ' pod -n arc-runners '. EphemeralRunner and
# EphemeralRunnerSet CRs must NEVER be deleted by this tool: pod deletion with
# the CRs alive reuses the GitHub-side runner registration (assigned jobs are
# picked up without a manual re-run), while deleting the CRs risks orphaning
# those jobs.
assert_pod_delete() {
  case " $* " in
    *" pod -n arc-runners "*) return 0 ;;
    *)
      echo "INTERNAL ERROR: refusing delete for anything but 'pod -n arc-runners': $*" >&2
      exit 1
      ;;
  esac
}

run() {
  # Echo the exact command; execute it unless --dry-run (read-only steps are
  # run separately and always executed, even in dry-run).
  echo "+ $*"
  if [ "${DRY_RUN}" -eq 0 ]; then
    "$@"
  fi
}

enum_cmd="kubectl --request-timeout=20s get pods -n arc-runners --field-selector spec.nodeName=${NODE} -o jsonpath='<name per line>'"

echo "==> [1/6] Cordon ${NODE} (placement fence — layer 1)"
run kubectl --request-timeout=20s cordon "${NODE}"

echo "==> [2/6] Label ${NODE} quarantine=true (declared intent — layer 2, read by runner-join.sh)"
run kubectl --request-timeout=20s label node "${NODE}" quarantine=true --overwrite

echo "==> [3/6] Enumerate ARC runner pods still bound to ${NODE}"
# MUST be a field selector: an invented ARC pod label would silently match
# nothing and leave the maxRunners quota pinned — defeating this whole tool.
echo "+ ${enum_cmd}"
pods=$(kubectl --request-timeout=20s get pods -n arc-runners \
  --field-selector "spec.nodeName=${NODE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | awk 'NF')

cleared=0
if [ -z "${pods}" ]; then
  echo "==> [4/6] No runner pods to clear on ${NODE}"
else
  read -r -a pod_array <<< "${pods}"
  cleared=${#pod_array[@]}
  echo "==> [4/6] Deleting ${cleared} runner pod(s) on ${NODE}: ${pod_array[*]}"
  assert_pod_delete pod -n arc-runners "${pod_array[@]}"
  # Graceful delete on purpose: NO --force, NO --grace-period=0.
  run kubectl --request-timeout=20s delete pod -n arc-runners "${pod_array[@]}"
fi

echo "==> [5/6] Post-state"
echo "+ ${enum_cmd}"
remaining=$(kubectl --request-timeout=20s get pods -n arc-runners \
  --field-selector "spec.nodeName=${NODE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | awk 'NF')
if [ -n "${remaining}" ]; then
  echo "Runner pods still on ${NODE}: $(printf '%s' "${remaining}" | tr '\n' ' ')"
else
  echo "Runner pods still on ${NODE}: none"
fi
echo "+ kubectl --request-timeout=20s get ephemeralrunnerset -n arc-runners"
kubectl --request-timeout=20s get ephemeralrunnerset -n arc-runners
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "Dry-run: would have cleared ${cleared} runner pod(s). Cordon alone leaves already-scheduled pods in place — exactly how 2 pods pinned 100% of maxRunners:2 and froze CI for ~5h on 2026-11-12."
else
  echo "Cleared ${cleared} runner pod(s). Note: cordon alone would have left them in place pinning the ARC quota (2026-11-12: 2 pods = 100% of maxRunners:2, CI frozen ~5h)."
fi

echo "==> [6/6] Lift procedure"
cat <<EOF
NOT SELF-CLEANING — lifting the fence takes ALL THREE actions:
  kubectl label node ${NODE} quarantine-
  kubectl taint nodes ${NODE} quarantine:NoSchedule-   (only if it was ever re-posed)
  kubectl uncordon ${NODE}
Note: a clean runner-leave.sh deletes the Node object, so the label and taint
vanish with it and must be RE-POSED after any leave/join cycle.
EOF

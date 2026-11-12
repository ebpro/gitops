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
#   live in 'actions-runner-controller' — never confuse them. Non-interactive,
#   and NO MUTATION HAPPENS WITHOUT AN EXPLICIT --yes (fence and unfence alike;
#   --dry-run prints the exact commands and changes nothing). Every post-condition
#   this tool can check, it checks and exits non-zero on — it never just prints a
#   status and hopes the operator will read it.
#
# EXAMPLES
#   ssh compute-lsis-2 'fence-runner-node.sh --dry-run pc-bruno-gpu'       # preview (read-only)
#   ssh compute-lsis-2 'fence-runner-node.sh --yes pc-bruno-gpu'           # the real fence
#   ssh compute-lsis-2 'fence-runner-node.sh --unfence --yes pc-bruno-gpu' # lift (only after proving C1)
#
set -euo pipefail

# bash 4+ is REQUIRED: the pod enumeration is multi-line and must be collected
# with `mapfile`, which consumes the whole stream. `read -a` reads ONE line only,
# so it silently populates a single element — that is exactly how the documented
# incident shape (2 runners pinning both maxRunners:2 slots) got under-cleared:
# 1 of 2 deleted, exit 0, quota still full, CI still frozen.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: bash 4 or newer is required (mapfile); this shell is ${BASH_VERSION}." >&2
  exit 1
fi

usage() {
  cat <<'USAGE'
Usage:
  fence-runner-node.sh --yes [--dry-run] <node>            # fence (adds layer 4)
  fence-runner-node.sh --unfence --yes [--dry-run] <node>  # lift the fence

Confirmation is mandatory on every mutating path: --yes is REQUIRED to fence
(cordon + quarantine label + graceful deletion of the ARC runner pods on that
node) and to unfence (label removal + uncordon). Without it the script exits 1
before touching the API. --dry-run is exempt because it mutates nothing.

--force overrides the control-plane guard and is almost never what you want: the
only other amd64-capable runner node in this cluster is compute-lsis-2 itself
(lima-k3s-agent is arm64 and tainted kubernetes.io/arch=arm64:NoSchedule), so
fencing the control plane leaves amd64 runners nowhere to be scheduled — CI dead
by construction.

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

# --- constants (single source of truth: asserted, never re-typed) -----------
RUNNER_NS="arc-runners"               # runner PODs; NOT 'actions-runner-controller'
POD_RESOURCE="pod"                    # never EphemeralRunner / EphemeralRunnerSet
QUARANTINE_LABEL="quarantine=true"
CONTROL_PLANE_LABEL_KEY='"node-role.kubernetes.io/control-plane"'
# One enumeration template, shared by the executed call and by every preview, so
# --dry-run always shows the command that would really have run.
ENUM_TEMPLATE='{range .items[*]}{.metadata.name}{"\n"}{end}'
FENCE_MISS=()                         # incomplete-fence actions, printed by verify_fence

die() {
  echo "ERROR: $*" >&2
  exit 1
}

get_node_json() {
  # Prints the node object as JSON. A failed query is FATAL: nothing may be
  # inferred about a fence (or about control-plane status) from a query that did
  # not succeed — an API hiccup must never look like a clean verdict.
  local out
  if ! out=$(kubectl --request-timeout=20s get node "$1" -o json 2>&1); then
    echo "${out}" >&2
    die "cannot read node '$1' as JSON — refusing to infer anything from a failed query"
  fi
  printf '%s\n' "${out}"
}

# The C1 data-plane precondition from the 2026-11-12 incident dossier — node
# 'Ready' proves nothing about the Cilium tunnel (see docs/network/
# runner-node-vlan-isolation-20261112.md §9 / §6.1.2).
print_c1_precondition() {
  cat <<EOF
C1 data-plane precondition — an ASSERTION the operator makes by passing --yes
(the tool cannot measure the node's tunnel from the control plane):
  On ${NODE}, 'cat /sys/class/net/cilium_vxlan/statistics/rx_packets' must move
  STRICTLY ABOVE 0 under peer->node traffic. During the 2026-11-12 incident that
  counter sat at 0 across 166 240 transmitted packets while the node was Ready —
  the tunnel was unidirectional and CI was dead.
  Reference: docs/network/runner-node-vlan-isolation-20261112.md §9 / §6.1.2.
EOF
}

# --- confirmation gates: checked BEFORE the preflight, so a refusal never needs
# --- cluster access, and no mutation is reachable without an explicit --yes.
if [ "${UNFENCE}" -eq 1 ] && [ "${ASSUME_YES}" -ne 1 ]; then
  {
    echo "ERROR: --unfence requires --yes, and only AFTER this precondition held:"
    print_c1_precondition
  } >&2
  exit 1
fi

if [ "${UNFENCE}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ] && [ "${ASSUME_YES}" -ne 1 ]; then
  {
    echo "ERROR: refusing to mutate cluster state without an explicit --yes."
    echo "On '${NODE}', --yes authorises ALL of:"
    echo "  1. kubectl cordon ${NODE}                            (layer 1: spec.unschedulable)"
    echo "  2. kubectl label node ${NODE} ${QUARANTINE_LABEL}                    (layer 2: declared intent)"
    echo "  3. graceful kubectl delete pod -n ${RUNNER_NS} <every runner pod on ${NODE}>"
    echo "     (layer 4: releases the pinned ARC maxRunners quota; CRs are NEVER deleted)"
    echo "Re-run with --yes to execute, or --dry-run to preview the exact commands."
  } >&2
  exit 1
fi

# --- preflight: fail fast, do not chain deeper calls on failure --------------
if ! probe_err=$(kubectl --request-timeout=5s get node "${NODE}" 2>&1 >/dev/null); then
  echo "ERROR: cannot read node '${NODE}' — API server unreachable / wrong kubeconfig" >&2
  echo "${probe_err}" >&2
  exit 1
fi
echo "Preflight OK: node '${NODE}' is visible in the API"

# --- unfence path -------------------------------------------------------------
if [ "${UNFENCE}" -eq 1 ]; then
  echo "==> Unfence ${NODE}: label removal + uncordon (taint removal stays manual)"
  # Printed on EVERY unfence that will uncordon, --yes included. The flag is the
  # operator's assertion that C1 was measured; suppressing the record of C1 (as an
  # earlier revision did, by printing it only in the refusal branch) removed the
  # only reminder of what --yes claims to have verified.
  print_c1_precondition
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "+ kubectl --request-timeout=20s label node ${NODE} quarantine-  (dry-run: not executed)"
    echo "+ kubectl --request-timeout=20s uncordon ${NODE}                (dry-run: not executed)"
  else
    kubectl --request-timeout=20s label node "${NODE}" quarantine-
    kubectl --request-timeout=20s uncordon "${NODE}"
    # Read the node back: an incomplete lift must not be reported as success.
    if ! lift_json=$(kubectl --request-timeout=20s get node "${NODE}" -o json 2>&1); then
      echo "WARNING: the mutations were issued but the node could not be read back to confirm them:" >&2
      echo "${lift_json}" >&2
    else
      if grep -qE '"unschedulable"[[:space:]]*:[[:space:]]*true' <<< "${lift_json}"; then
        die "lift INCOMPLETE: ${NODE} still has .spec.unschedulable set — re-run: kubectl --request-timeout=20s uncordon ${NODE}"
      fi
      if grep -qE '"quarantine"[[:space:]]*:[[:space:]]*"true"' <<< "${lift_json}"; then
        die "lift INCOMPLETE: ${NODE} still carries ${QUARANTINE_LABEL} — re-run: kubectl --request-timeout=20s label node ${NODE} quarantine-"
      fi
      echo "Verified: ${NODE} is uncordoned and no longer labelled ${QUARANTINE_LABEL}."
    fi
  fi
  echo "Manual step, ONLY if a quarantine:NoSchedule taint was ever re-posed:"
  echo "  kubectl taint nodes ${NODE} quarantine:NoSchedule-"
  exit 0
fi

# --- control-plane guard ------------------------------------------------------
# In this 3-node cluster the only other amd64-capable runner node is
# compute-lsis-2 itself, since lima-k3s-agent is arm64 and tainted
# kubernetes.io/arch=arm64:NoSchedule — fencing the control plane leaves amd64
# runners nowhere to be scheduled: CI dead by construction.
# What matters is the label's EXISTENCE, never its value: the value varies with
# the provisioner (measured live 2026-11-13 on this cluster: compute-lsis-2
# carries "true"), so any value comparison is inert — match the key only. And a
# failed query is fatal: an API hiccup must never be read as "not a control plane".
node_json="$(get_node_json "${NODE}")"
if grep -qF "${CONTROL_PLANE_LABEL_KEY}" <<< "${node_json}"; then
  if [ "${FORCE}" -ne 1 ]; then
    {
      echo "ERROR: refusing to fence '${NODE}': it carries node-role.kubernetes.io/control-plane."
      echo "The only other amd64-capable runner node is compute-lsis-2 itself (lima-k3s-agent"
      echo "is arm64 and tainted kubernetes.io/arch=arm64:NoSchedule), so fencing the control"
      echo "plane leaves amd64 runners nowhere to be scheduled — CI dead by construction."
      echo "Re-run with --force only if that is really what you want."
    } >&2
    exit 1
  fi
  echo "WARNING: --force given — proceeding to fence the control-plane node '${NODE}'." >&2
fi

run() {
  # Echo the exact command; execute it unless --dry-run (read-only steps are
  # run separately and always executed, even in dry-run).
  echo "+ $*"
  if [ "${DRY_RUN}" -eq 0 ]; then
    "$@"
  fi
}

try_run() {
  # Mutation attempt. A failure is recorded rather than fatal, because the node
  # read-back at [3/7] is what decides whether the fence is complete — and that
  # check prints the EXACT action to re-run instead of dying mid-sequence with an
  # unexplained API error. Nothing exits 0 from here unless it is verified.
  if ! run "$@"; then
    echo "  STEP FAILED: $*" >&2
    return 1
  fi
  return 0
}

enumerate_runner_pods() {
  # Prints one runner pod name per line for ${NODE}. kubectl's exit status is
  # checked explicitly and propagated (its merged stderr is echoed first); only
  # then is the output filtered. Callers MUST use
  # `if ! x=$(enumerate_runner_pods)` so a failure cannot be swallowed: a failed
  # enumeration must never be mistaken for "no pods".
  local out
  if ! out=$(kubectl --request-timeout=20s get pods -n "${RUNNER_NS}" \
        --field-selector "spec.nodeName=${NODE}" \
        -o "jsonpath=${ENUM_TEMPLATE}" 2>&1); then
    echo "${out}" >&2
    return 1
  fi
  printf '%s\n' "${out}" | awk 'NF'
}

verify_fence() {
  # Post-condition check for layers 1 and 2, from the live node object.
  # $1 = 'enforce' (real run: a MISS is fatal) or 'info' (dry-run preview).
  # Returns 1 when the fence is incomplete.
  local mode="$1" bad=0 verify_json taints line
  verify_json="$(get_node_json "${NODE}")"

  if grep -qE '"unschedulable"[[:space:]]*:[[:space:]]*true' <<< "${verify_json}"; then
    echo "  OK   layer 1 — .spec.unschedulable is set (cordon in effect)"
  else
    bad=1
    FENCE_MISS+=("  MISS layer 1 — .spec.unschedulable NOT set")
    FENCE_MISS+=("       re-run: kubectl --request-timeout=20s cordon ${NODE}")
  fi

  if grep -qE '"quarantine"[[:space:]]*:[[:space:]]*"true"' <<< "${verify_json}"; then
    echo "  OK   layer 2 — label ${QUARANTINE_LABEL} present (runner-join.sh will refuse to uncordon)"
  else
    bad=1
    FENCE_MISS+=("  MISS layer 2 — label ${QUARANTINE_LABEL} NOT present")
    FENCE_MISS+=("       re-run: kubectl --request-timeout=20s label node ${NODE} ${QUARANTINE_LABEL} --overwrite")
    FENCE_MISS+=("       WARNING: infrastructure/laptop/runner-join.sh reads ONLY the quarantine")
    FENCE_MISS+=("       label and the quarantine taint — never spec.unschedulable. A cordoned but")
    FENCE_MISS+=("       unlabelled node is NOT protected against a laptop-side join, which would")
    FENCE_MISS+=("       uncordon it and bring a broken-data-plane node straight back into CI (the")
    FENCE_MISS+=("       original 2026-11-12 failure). Fix layer 2 before walking away.")
  fi

  # Informational only: layer 3 (the Kyverno taint policy) is NOT deployed and a
  # hand-written quarantine:NoSchedule taint is erased by sibling policies, so an
  # absent taint is deliberately NOT treated as a fence failure.
  taints=$(printf '%s\n' "${verify_json}" | awk '
    /"taints"[[:space:]]*:[[:space:]]*\[/ { in_taints = 1; next }
    in_taints && /^[[:space:]]*\],?$/     { in_taints = 0 }
    in_taints && match($0, /"key"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^"key"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      print s
    }' | tr '\n' ' ')
  echo "  INFO current spec.taints keys: ${taints:-none} (layer 3 not deployed — informational)"

  if [ "${bad}" -ne 0 ]; then
    for line in "${FENCE_MISS[@]}"; do
      if [ "${mode}" = "info" ]; then
        printf '%s\n' "${line}"
      else
        printf '%s\n' "${line}" >&2
      fi
    done
    return 1
  fi
  return 0
}

build_delete_cmd() {
  # Builds the delete argv ONCE — assert_pod_delete checks this very array and
  # run() executes it, so the guard can never be vacuous.
  delete_cmd=(kubectl --request-timeout=20s delete "${POD_RESOURCE}" -n "${RUNNER_NS}")
  local name
  for name in "${pod_array[@]}"; do
    delete_cmd+=("${name}")
  done
}

assert_pod_delete() {
  # HARD SAFETY GUARD on the argv that is about to be executed. The only delete
  # this tool may ever issue is a graceful `delete pod -n arc-runners <names...>`;
  # the EphemeralRunner / EphemeralRunnerSet CRs must NEVER be deleted here — pod
  # deletion with the CRs alive reuses the GitHub-side runner registration (so
  # assigned jobs are picked up without a manual re-run), while deleting the CRs
  # risks orphaning those jobs.
  local expected="$1"
  local -a cmd=("${delete_cmd[@]}")
  local i n="${#cmd[@]}" tok
  if [ "${n}" -lt 7 ] \
     || [ "${cmd[0]}" != "kubectl" ] \
     || [ "${cmd[1]}" != "--request-timeout=20s" ] \
     || [ "${cmd[2]}" != "delete" ] \
     || [ "${cmd[3]}" != "${POD_RESOURCE}" ] \
     || [ "${cmd[4]}" != "-n" ] \
     || [ "${cmd[5]}" != "${RUNNER_NS}" ]; then
    die "INTERNAL ERROR: delete argv is not 'kubectl --request-timeout=20s delete pod -n ${RUNNER_NS} <names>': $(printf '%q ' "${cmd[@]}")"
  fi
  if [ "${expected}" -lt 1 ] || [ "$((n - 6))" -ne "${expected}" ]; then
    die "INTERNAL ERROR: delete argv carries $((n - 6)) pod name(s) but ${expected} were enumerated — refusing to delete"
  fi
  for tok in "${cmd[@]}"; do
    case "${tok}" in
      --force|--grace-period*)
        die "INTERNAL ERROR: refusing a non-graceful delete token: ${tok}"
        ;;
    esac
  done
  for (( i = 6; i < n; i++ )); do
    case "${cmd[i]}" in
      -*)
        die "INTERNAL ERROR: refusing a pod name that looks like an option: $(printf '%q' "${cmd[i]}")"
        ;;
    esac
  done
}

enum_cmd="kubectl --request-timeout=20s get pods -n ${RUNNER_NS} --field-selector spec.nodeName=${NODE} -o jsonpath=${ENUM_TEMPLATE}"

echo "==> [1/7] Cordon ${NODE} (placement fence — layer 1)"
try_run kubectl --request-timeout=20s cordon "${NODE}" || true

echo "==> [2/7] Label ${NODE} ${QUARANTINE_LABEL} (declared intent — layer 2, read by runner-join.sh)"
try_run kubectl --request-timeout=20s label node "${NODE}" "${QUARANTINE_LABEL}" --overwrite || true

echo "==> [3/7] Verify the fence mutations actually hold (node read-back)"
if [ "${DRY_RUN}" -eq 1 ]; then
  if ! verify_fence info; then
    echo "  (dry-run: nothing was mutated, so the MISS lines above are informational)"
  fi
elif ! verify_fence enforce; then
  die "fence INCOMPLETE on ${NODE} — the exact actions to re-run are listed above; do not trust a partial fence"
fi

echo "==> [4/7] Enumerate ARC runner pods still bound to ${NODE}"
# MUST be a field selector: an invented ARC pod label would silently match
# nothing and leave the maxRunners quota pinned — defeating this whole tool.
echo "+ ${enum_cmd}"
pods=""
if ! pods="$(enumerate_runner_pods)"; then
  die "enumeration of ${RUNNER_NS} pods on ${NODE} FAILED — no delete attempted. Re-run once the API is reachable; a failed enumeration is never treated as an empty one."
fi

pod_array=()
if [ -n "${pods}" ]; then
  # mapfile, not `read -a`: it consumes the ENTIRE multi-line stream, which is
  # how every victim gets deleted in one gesture instead of just the first.
  mapfile -t pod_array <<< "${pods}"
fi

# Belt and braces: the collected count MUST equal the number of non-empty output
# lines, so a future single-line-only reader cannot silently under-delete again.
expected=$(printf '%s\n' "${pods}" | awk 'NF { n++ } END { print n + 0 }')
if [ "${#pod_array[@]}" -ne "${expected}" ]; then
  die "INTERNAL ERROR: enumerated ${expected} pod name line(s) but collected ${#pod_array[@]} — refusing a partial delete on ${NODE}"
fi

echo "==> [5/7] Clear runner pods on ${NODE} (layer 4 — releases the pinned ARC quota)"
cleared=0
if [ "${#pod_array[@]}" -eq 0 ]; then
  echo "  No runner pods to clear on ${NODE}"
else
  cleared="${#pod_array[@]}"
  echo "  Deleting ${cleared} runner pod(s) on ${NODE}:"
  for name in "${pod_array[@]}"; do
    # Validated BEFORE anything is deleted: a name that could turn into a
    # dangerous argument (option-like, whitespace, '/', glob metacharacter)
    # aborts the run without deleting anything.
    if [[ ! "${name}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
      die "refusing to delete: invalid pod name $(printf '%q' "${name}") returned by the ${NODE} enumeration"
    fi
    echo "    - ${name}"
  done
  build_delete_cmd
  assert_pod_delete "${expected}"
  # Graceful delete on purpose: NO --force, NO --grace-period=0.
  try_run "${delete_cmd[@]}" || true
fi

# Post-condition, ASSERTED on the executed path — and also when the enumeration
# above saw nothing, because a runner pod placed in the meantime would pin the
# quota again. If anything still sits on the node the ARC maxRunners quota may
# still be pinned and the fence did not achieve its purpose: name the residuals
# and fail non-zero, never just print them and exit 0.
if [ "${DRY_RUN}" -eq 0 ]; then
  echo "+ ${enum_cmd}   (post-delete re-check)"
  residual=""
  if ! residual="$(enumerate_runner_pods)"; then
    die "post-delete enumeration FAILED for ${NODE} — the fence outcome is UNVERIFIED; the ARC ${RUNNER_NS} maxRunners quota may still be pinned"
  fi
  if [ -n "${residual}" ]; then
    {
      echo "ERROR: the fence did NOT clear the runner quota on ${NODE}."
      echo "Residual ${RUNNER_NS} pod(s) still bound to it:"
      printf '%s\n' "${residual}" | awk '{ print "  - " $0 }'
      echo "The ARC maxRunners quota may STILL be pinned — CI can stay frozen."
      echo "Re-run this tool; if it persists, delete ONLY these pods (never the"
      echo "EphemeralRunner/EphemeralRunnerSet CRs) and investigate why they return."
    } >&2
    exit 1
  fi
  echo "  Verified: no ${RUNNER_NS} pod remains on ${NODE}."
fi

echo "==> [6/7] Post-state"
echo "+ kubectl --request-timeout=20s get ephemeralrunnerset -n ${RUNNER_NS}"
kubectl --request-timeout=20s get ephemeralrunnerset -n "${RUNNER_NS}"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "Dry-run: would have cleared ${cleared} runner pod(s). Cordon alone leaves already-scheduled pods in place — exactly how 2 pods pinned 100% of maxRunners:2 and froze CI for ~5h on 2026-11-12."
else
  echo "Cleared ${cleared} runner pod(s) and verified none remain. Note: cordon alone would have left them in place pinning the ARC quota (2026-11-12: 2 pods = 100% of maxRunners:2, CI frozen ~5h)."
fi

echo "==> [7/7] Lift procedure"
cat <<EOF
NOT SELF-CLEANING — lifting the fence takes ALL THREE actions:
  kubectl label node ${NODE} quarantine-
  kubectl taint nodes ${NODE} quarantine:NoSchedule-   (only if it was ever re-posed)
  kubectl uncordon ${NODE}
Note: a clean runner-leave.sh deletes the Node object, so the label and taint
vanish with it and must be RE-POSED after any leave/join cycle.
EOF

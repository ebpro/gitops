#!/usr/bin/env bash
#
# runner-netprobe.sh — systemd-timer heartbeat that AUTO-FENCES this CI runner
# node when ONLY the Kubernetes data plane is lost (control plane still up).
#
# WHY (the proven incident shape: 2026-10-13 and 2026-11-12, pc-bruno-gpu)
#   `Ready` + a reachable API server prove NOTHING about the Cilium tunnel
#   (2026-11-12 measured: cilium_vxlan rx_packets stayed at 0 across 166 240
#   transmitted packets while the node was Ready). When the tunnel dies under a
#   live node, already-scheduled ARC runner pods are NOT evicted by a later
#   cordon: they sit on the dead node pinning 100% of maxRunners:2 and CI is
#   frozen silently (~5h on 2026-11-12). Laptop-side hooks are not a fence
#   either (the 2026-11-12 auto-drain silently skipped off-VPN). This probe is
#   the missing self-fence ON THE LAPTOP: cordon + clear the runner pods, so
#   the laptop can never again freeze maxRunners silently while waiting for
#   someone to run infrastructure/node-fence/fence-runner-node.sh from the
#   healthy side.
#
# DECISION RULE — all three must hold before anything mutates:
#   1. CP-OK: TCP connect to 10.2.248.31:6443 succeeds. Without control-plane
#      control we could not cordon anyway, and CP-down is the OFF-VPN resting
#      state — the normal case of a laptop that simply left the lab. Never act.
#   2. DP-KO: TCP connect to a POD-TERMINATED target fails: VIP 10.2.248.31:443
#      has no host socket — kube-proxy DNATs it onto a remote Traefik pod, so
#      the SYN rides the overlay and any completed handshake proves the tunnel
#      end-to-end (same reasoning as runner-join.sh's data-plane preflight).
#      `ping` is deliberately NOT used: absent on these images and unreliable.
#      The KO must repeat STREAK_NEEDED consecutive times (default 3 ≈ a 90 s
#      anti-flap window).
#   3. LOCAL PROOF: a DP-KO only counts when corroborated by cilium_vxlan
#      rx_packets being FROZEN (delta 0) across the probe window — the exact
#      2026-11-12 signature. This matters because the VIP target can also fail
#      for REMOTE reasons (Trafer/VIP outage): if rx moved, the tunnel receives
#      and the failure is not ours — the strike is NOT counted and a healthy
#      node is never fenced on a remote-side failure. If the device is absent,
#      nothing can be measured: in tunnel mode no cilium_vxlan = no overlay, so
#      the absence itself corroborates. (A clean runner-leave also removes the
#      device — but then the node is already cordoned and every action below
#      is an idempotent no-op.)
#
# THE ACTION (what the 2026-11-12 mitigation was missing)
#   cordon <node>  →  enumerate arc-runners pods with --field-selector
#   spec.nodeName=<node>  →  delete them in ONE argv, validated by an
#   assertion BEFORE execution (pattern copied from fence-runner-node.sh's
#   assert_pod_delete)  →  read every post-condition back and fail LOUDLY
#   (never report success on a partial fence).
#
# WHAT IT NEVER DOES
#   - NEVER deletes the EphemeralRunner / EphemeralRunnerSet CRs (CI-2/CI-3 of
#     fence-runner-node.sh: deleting PODS with the CRs alive reuses the
#     GitHub-side runner registration, so already-assigned jobs resume with no
#     manual re-run — measured 2026-11-12; deleting CRs risks orphaning them).
#     The argv assertion makes `delete pod -n arc-runners <names…>` the only
#     delete this script can mechanically execute.
#   - NEVER sets the quarantine label or taint: the taint does not survive
#     Kyverno sibling admission (fence-runner-node.sh layer 3 — policy NOT
#     deployed), and the label is the human 3-gesture procedure's job
#     (runner-join.sh reads it). The operative fence is the cordon (layer 1).
#   - NEVER uncordons and NEVER removes a label: lifting stays human
#     (fence-runner-node.sh --unfence --yes requires the C1 proof first).
#     Consequence, by design: manually uncordoning a node whose data plane is
#     still dead gets re-fenced within ~90 s (3 new strikes).
#   - NEVER logs a secret: the script only ever knows the kubeconfig PATH.
#
# FAILURE DISCIPLINE
#   Missing kubeconfig / missing kubectl / any API hiccup on the decision path
#   → explicit log + exit 0 (fail-open on the alert, the timer must never
#   crash-loop). Only a broken argv (a programming error) exits non-zero.
#
# TEST / DRY-RUN HOOKS (all inert unless NETPROBE_DRYRUN=1)
#   NETPROBE_DRYRUN=1        print the mutating argv that WOULD run, execute
#                            none of it (gets stay real), exit 0. The strike
#                            counter uses a separate file (streak.dryrun) so
#                            tests never disturb the production counter.
#   NETPROBE_STATE_DIR=<dir> counter directory (default /run/runner-netprobe;
#                            override to run tests as an unprivileged user).
#   NETPROBE_FAIL_STREAK=<n> strike threshold (default 3).
#   NETPROBE_DEMO_PODS="a b" fake pod names for previewing the delete argv on
#                            a node that has none: they go through the SAME
#                            regex validation and the SAME assert_pod_delete
#                            as the production path. Ignored for real.
#   NETPROBE_DEMO_UNCORDON=1 pretend the node is schedulable to preview the
#                            cordon argv. Ignored for real.
#
# OPERATING NOTES
#   - Run by runner-netprobe.timer every ~30 s (see the unit comments). The
#     strike counter lives in ${STATE_DIR} (tmpfs → a reboot starts clean,
#     which is correct: the join flow re-proves the data plane anyway).
#   - A full fence pass resets the streak; while the data plane stays dead an
#     idempotent re-assert pass runs every ~90 s — cheap (one node get + one
#     pod list) and it catches late ghost pods (the 2026-10-13 class: pods
#     that reappear after the first fence).
#   - bash 5 target (Ubuntu laptop); requires bash 4+ for mapfile.
set -euo pipefail

# bash 4+ REQUIRED: the multi-line pod enumeration must be collected with
# `mapfile`, which consumes the WHOLE stream. `read -r -a` reads ONE line only
# → a single element → exactly how the 2026-11-12 incident shape (2 runners
# pinning both maxRunners:2 slots) got under-cleared: 1 of 2 deleted, exit 0,
# quota still full, CI still frozen. Documented in fence-runner-node.sh; do
# not regress it here.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf 'netprobe: ERROR: bash 4 or newer required (mapfile); this is %s\n' "${BASH_VERSION}" >&2
  exit 1
fi

# NODE_NAME is an explicit identity override (the dry-run/self-test hook documented
# in infrastructure/laptop/README.md). Whatever is resolved here — the override or
# the real hostname — is the value every log line and every kubectl argv below
# carries.
NODE="${NODE_NAME:-$(hostname 2>/dev/null || true)}"
# The node name lands in kubectl argv — a malformed name aborts before any
# command is built. Fail-open (exit 0): a machine that cannot name itself has
# nothing to fence.
if [ -z "${NODE}" ] || [[ ! "${NODE}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
  printf 'netprobe: ERROR: hostname %q is not a valid node name — exiting without action\n' "${NODE}" >&2
  exit 0
fi

log() { printf 'netprobe(%s): %s\n' "${NODE}" "$*"; }
# die() is reserved for INTERNAL assertion failures (a bug in this script).
# Everything operational fails open with log + exit 0 (see FAILURE DISCIPLINE).
die() { log "INTERNAL ERROR: $*"; exit 1; }

# --- constants (single source of truth: asserted, never re-typed) -------------
API_HOST="10.2.248.31"            # k3s control plane (compute-lsis-2) — host-terminated
API_PORT="6443"
VIP_HOST="10.2.248.31"            # Traefik LB VIP — NO host socket: DNAT onto a
VIP_PORT="443"                    # remote pod ⇒ every probe byte rides the overlay
RUNNER_NS="arc-runners"           # runner PODs; NOT 'actions-runner-controller'
POD_RESOURCE="pod"                # the ONLY resource kind this script may delete
KREQ="--request-timeout=10s"      # carried by EVERY kubectl call (ops discipline)
ENUM_TEMPLATE='{range .items[*]}{.metadata.name}{"\n"}{end}'
VXLAN_STAT_DIR="/sys/class/net/cilium_vxlan/statistics"
PROBE_TIMEOUT=6                   # per TCP probe, `timeout`-guarded

DRY_RUN="${NETPROBE_DRYRUN:-0}"
STREAK_NEEDED="${NETPROBE_FAIL_STREAK:-3}"
STATE_DIR="${NETPROBE_STATE_DIR:-/run/runner-netprobe}"
case "${STREAK_NEEDED}" in
  ''|*[!0-9]*) STREAK_NEEDED=3 ;;
esac
if [ "${STREAK_NEEDED}" -lt 1 ]; then
  STREAK_NEEDED=3
fi

# --- credentials: same explicit resolution as runner-auto-leave.sh ------------
# systemd gives system units NO HOME and a default PATH without the Nix
# profile, so neither may be inherited (the 2026-11-02…11-10 hook-silence
# incident: `$HOME` unbound + kubectl not findable). RUNNER_OPS_KUBECONFIG /
# RUNNER_KUBECTL override the candidate lists. The script only ever knows the
# PATH — never the token value, never logged.
KCONF=""
for c in "${RUNNER_OPS_KUBECONFIG:-}" "${HOME:+${HOME}/.kube/node-ops.conf}" \
         /home/bruno/.kube/node-ops.conf /root/.kube/node-ops.conf; do
  if [ -n "${c}" ] && [ -f "${c}" ]; then
    KCONF="${c}"
    break
  fi
done
if [ -z "${KCONF}" ]; then
  log "ERROR: no node-ops kubeconfig found (see infrastructure/laptop/README.md 'One-time install') — probe cannot reach the API, exiting without action"
  exit 0
fi
export KUBECONFIG="${KCONF}"

KUBECTL=""
for c in "${RUNNER_KUBECTL:-}" "$(command -v kubectl 2>/dev/null || true)" \
         /home/bruno/.nix-profile/bin/kubectl /usr/local/bin/kubectl \
         /usr/bin/kubectl /snap/bin/kubectl; do
  if [ -n "${c}" ] && [ -x "${c}" ]; then
    KUBECTL="${c}"
    break
  fi
done
if [ -z "${KUBECTL}" ]; then
  log "ERROR: no kubectl binary found — exiting without action"
  exit 0
fi

# --- state ---------------------------------------------------------------------
if ! mkdir -p "${STATE_DIR}" 2>/dev/null; then
  log "ERROR: cannot create state dir ${STATE_DIR} (NETPROBE_STATE_DIR?) — exiting without action"
  exit 0
fi
STREAK_FILE="${STATE_DIR}/streak"
if [ "${DRY_RUN}" = "1" ]; then
  STREAK_FILE="${STREAK_FILE}.dryrun"
fi

streak=0
if [ -r "${STREAK_FILE}" ]; then
  raw=""
  raw="$(head -n1 "${STREAK_FILE}" 2>/dev/null || true)"
  case "${raw}" in
    ''|*[!0-9]*) : ;;          # unreadable/malformed → restart at 0, never fatal
    *) streak="${raw}" ;;
  esac
fi

save_streak() {
  if ! printf '%s\n' "$1" > "${STREAK_FILE}" 2>/dev/null; then
    log "WARN: cannot write ${STREAK_FILE} — strike persistence degraded for this run"
  fi
}

# --- probes --------------------------------------------------------------------
tcp_probe() {
  # Plain TCP connect via bash's /dev/tcp. No `ping`: absent on these images
  # and unreliable here (AGENTS.md 2026-11-12 bullet). Non-zero on timeout
  # (124) or refusal — callers use it under `if`, so set -e is not involved.
  local host="$1" port="$2"
  # The single-quoted body is INTENTIONAL: the INNER bash expands ${1}/${2}
  # from the trailing args; expanding here would interpolate into the -c string.
  # shellcheck disable=SC2016
  timeout "${PROBE_TIMEOUT}" bash -c 'exec 3<>"/dev/tcp/${1}/${2}"' _ "${host}" "${port}" 2>/dev/null
}

read_counter() {
  # Echo the numeric content of a /sys counter file, empty when absent.
  local f="$1"
  if [ -r "${f}" ]; then
    head -n1 "${f}" 2>/dev/null | tr -dc '0-9' || true
  fi
}

kcall() {
  # EVERY read (get) this script performs: --request-timeout=10s plus an outer
  # `timeout` guard so the probe never blocks unbounded on a half-dead socket.
  # Reads are real even in dry-run ("les gets restent réels").
  timeout 15 "${KUBECTL}" "${KREQ}" "$@"
}

# --- mutating argv: built once, asserted, then executed or previewed -----------
run_argv() {
  # Prints the exact command. In dry-run it is NEVER executed; the `timeout`
  # wrapper only exists around real execution and is not part of the asserted
  # argv shape (the assertion is about what kubectl receives).
  printf '  + %q' "$@"
  printf '\n'
  if [ "${DRY_RUN}" = "1" ]; then
    log "    (dry-run: not executed)"
    return 0
  fi
  timeout 15 "$@"
}

assert_cordon() {
  local -a c=("$@")
  if [ "${#c[@]}" -ne 4 ] \
     || [ "${c[0]}" != "${KUBECTL}" ] \
     || [ "${c[1]}" != "${KREQ}" ] \
     || [ "${c[2]}" != "cordon" ] \
     || [ "${c[3]}" != "${NODE}" ]; then
    die "cordon argv is not '<kubectl> --request-timeout=10s cordon ${NODE}': $(printf '%q ' "${c[@]}")"
  fi
}

assert_pod_delete() {
  # HARD SAFETY GUARD on the argv about to be executed (pattern copied from
  # fence-runner-node.sh). The only delete this probe may ever issue is a
  # graceful `kubectl --request-timeout=10s delete pod -n arc-runners
  # <names…>`: the literal 'pod' at index 3 makes deleting the
  # EphemeralRunner/EphemeralRunnerSet CRs mechanically impossible, the
  # literal namespace makes deleting anything else impossible, and every name
  # is re-checked option-free and count-matched against the enumeration.
  local expected="$1"
  local -a c=("${delete_cmd[@]}")
  local i n="${#c[@]}" tok
  if [ "${n}" -lt 7 ] \
     || [ "${c[0]}" != "${KUBECTL}" ] \
     || [ "${c[1]}" != "${KREQ}" ] \
     || [ "${c[2]}" != "delete" ] \
     || [ "${c[3]}" != "${POD_RESOURCE}" ] \
     || [ "${c[4]}" != "-n" ] \
     || [ "${c[5]}" != "${RUNNER_NS}" ]; then
    die "delete argv is not '<kubectl> --request-timeout=10s delete ${POD_RESOURCE} -n ${RUNNER_NS} <names>': $(printf '%q ' "${c[@]}")"
  fi
  if [ "${expected}" -lt 1 ] || [ "$((n - 6))" -ne "${expected}" ]; then
    die "delete argv carries $((n - 6)) pod name(s) but ${expected} were enumerated — refusing to delete"
  fi
  for tok in "${c[@]}"; do
    case "${tok}" in
      --force|--grace-period*)
        die "refusing a non-graceful delete token: ${tok}"
        ;;
    esac
  done
  for (( i = 6; i < n; i++ )); do
    case "${c[i]}" in
      -*)
        die "refusing a pod name that looks like an option: $(printf '%q' "${c[i]}")"
        ;;
    esac
  done
}

enumerate_runner_pods() {
  # One runner pod name per line for ${NODE}. MUST be a field selector: an
  # invented ARC pod label would silently match nothing and leave the
  # maxRunners quota pinned. The kubectl status is propagated: callers use
  # `if ! x=$(enumerate_runner_pods)` so a FAILED enumeration can never be
  # mistaken for an EMPTY one (fence-runner-node.sh rule).
  local out
  if ! out=$(kcall get pods -n "${RUNNER_NS}" \
        --field-selector "spec.nodeName=${NODE}" \
        -o "jsonpath=${ENUM_TEMPLATE}" 2>&1); then
    printf '%s\n' "${out}" >&2
    return 1
  fi
  printf '%s\n' "${out}" | awk 'NF'
}

# --- the fence itself ------------------------------------------------------------
auto_fence() {
  # Returns 0 only when every step of the pass is verified (or is a proven
  # no-op); 1 on any incomplete/undecidable step — the caller then KEEPS the
  # streak so the next tick (~30 s) retries. Never partial-success-exits-quiet.
  local unsched rb pods expected name uniq_count residual
  local -a pod_array=()
  local -a delete_cmd=()  # consumed by assert_pod_delete via dynamic scope — same pattern as fence-runner-node.sh
  local mode="EXECUTE"
  if [ "${DRY_RUN}" = "1" ]; then
    mode="DRY-RUN — nothing below mutates"
  fi
  log "==> AUTO-FENCE (${mode}): cordon ${NODE} + clear ARC runner pods still bound to it"

  # [1] cordon (layer 1 — the ONLY operative fence; no label, no taint, see
  # header "WHAT IT NEVER DOES"). Read the live node first: cordon is skipped
  # when already unschedulable, and a failed read decides NOTHING.
  unsched=""
  if ! unsched="$(kcall get node "${NODE}" -o jsonpath='{.spec.unschedulable}' 2>&1)"; then
    log "ERROR: cannot read node ${NODE} — refusing to act on unverifiable state; retry next tick (${unsched%%$'\n'*})"
    return 1
  fi
  if [ "${DRY_RUN}" = "1" ] && [ "${NETPROBE_DEMO_UNCORDON:-0}" = "1" ]; then
    log "DEMO: NETPROBE_DEMO_UNCORDON=1 — pretending schedulable (real .spec.unschedulable='${unsched}'); dry-run only, ignored for real"
    unsched=""
  fi
  if [ "${unsched}" = "true" ]; then
    log "  [1/2] layer 1 already active (.spec.unschedulable=true) — cordon skipped (idempotent re-assert pass)"
  else
    log "  [1/2] cordon ${NODE}"
    local -a cordon_cmd=("${KUBECTL}" "${KREQ}" cordon "${NODE}")
    assert_cordon "${cordon_cmd[@]}"
    if ! run_argv "${cordon_cmd[@]}"; then
      log "ERROR: cordon command failed — streak kept, retry next tick"
      return 1
    fi
    if [ "${DRY_RUN}" = "1" ]; then
      log "    (dry-run: post-cordon read-back meaningless)"
    else
      rb=""
      if ! rb="$(kcall get node "${NODE}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)"; then
        rb=""
      fi
      if [ "${rb}" != "true" ]; then
        log "AUTO-FENCE INCOMPLETE: cordon issued but ${NODE} still schedulable on read-back — streak kept, retry next tick"
        return 1
      fi
      log "  verified: .spec.unschedulable=true"
    fi
  fi

  # [2] clear the runner pods (layer 4 — the missing piece: cordon alone does
  # NOT evict already-scheduled pods; that alone is what froze CI for ~5 h on
  # 2026-11-12). One argv, asserted BEFORE execution, then read back.
  log "  [2/2] enumerate ${RUNNER_NS} pods on ${NODE}"
  pods=""
  if ! pods="$(enumerate_runner_pods)"; then
    log "ERROR: enumeration of ${RUNNER_NS} pods on ${NODE} FAILED — no delete attempted; a failed enumeration is never an empty one"
    return 1
  fi
  if [ -n "${pods}" ]; then
    mapfile -t pod_array <<< "${pods}"
  fi
  expected="$(printf '%s\n' "${pods}" | awk 'NF { n++ } END { print n + 0 }')"
  if [ "${#pod_array[@]}" -ne "${expected}" ]; then
    die "enumerated ${expected} pod name line(s) but collected ${#pod_array[@]} — refusing a partial delete on ${NODE}"
  fi

  if [ "${DRY_RUN}" = "1" ] && [ -n "${NETPROBE_DEMO_PODS:-}" ]; then
    local -a demo_array=()
    IFS=' ' read -r -a demo_array <<< "${NETPROBE_DEMO_PODS}"
    if [ "${#demo_array[@]}" -gt 0 ]; then
      pod_array=("${demo_array[@]}")
      expected="${#demo_array[@]}"
      log "DEMO: NETPROBE_DEMO_PODS — planning the delete argv on ${expected} fake name(s) through the SAME validation and assert as production; dry-run only, ignored for real"
    fi
  fi

  if [ "${#pod_array[@]}" -eq 0 ]; then
    log "  no ${RUNNER_NS} pod on ${NODE} — nothing to clear (quota not pinned)"
    return 0
  fi

  for name in "${pod_array[@]}"; do
    # Validated BEFORE anything is deleted: empty, option-looking or otherwise
    # malformed names abort the whole pass without deleting anything.
    if [[ ! "${name}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
      die "refusing to delete: invalid pod name $(printf '%q' "${name}") from the ${NODE} enumeration"
    fi
  done
  # Duplicated names cannot legitimately occur (pod names are unique per ns) —
  # a duplicate signals a broken enumeration → refuse rather than under-clear.
  uniq_count="$(printf '%s\n' "${pod_array[@]}" | sort -u | wc -l | tr -dc '0-9')"
  if [ "${uniq_count}" -ne "${#pod_array[@]}" ]; then
    die "duplicate pod name in the ${RUNNER_NS}/${NODE} enumeration — refusing to delete"
  fi

  delete_cmd=("${KUBECTL}" "${KREQ}" delete "${POD_RESOURCE}" -n "${RUNNER_NS}")
  delete_cmd+=("${pod_array[@]}")
  assert_pod_delete "${expected}"
  log "  deleting ${#pod_array[@]} runner pod(s) on ${NODE} (graceful, CRs untouched):"
  for name in "${pod_array[@]}"; do
    log "    - ${name}"
  done
  if ! run_argv "${delete_cmd[@]}"; then
    log "ERROR: delete command failed — streak kept, retry next tick"
    return 1
  fi
  if [ "${DRY_RUN}" = "1" ]; then
    log "    (dry-run: post-delete re-check meaningless)"
    return 0
  fi

  # Post-condition: if anything still sits on the node the ARC maxRunners
  # quota may still be pinned — name the residuals and return INCOMPLETE
  # (never just print them and call it done).
  residual=""
  if ! residual="$(enumerate_runner_pods)"; then
    log "ERROR: post-delete enumeration FAILED — quota release UNVERIFIED; streak kept, retry next tick"
    return 1
  fi
  if [ -n "${residual}" ]; then
    log "AUTO-FENCE INCOMPLETE: ${RUNNER_NS} pod(s) still bound to ${NODE}:"
    printf '%s\n' "${residual}" | awk '{ print "  - " $0 }' | while IFS= read -r line; do log "${line}"; done
    log "  the ARC maxRunners quota may STILL be pinned — streak kept, next pass retries the clear"
    return 1
  fi
  log "  verified: no ${RUNNER_NS} pod remains on ${NODE} — quota released, CRs untouched"
  return 0
}

# =============================== main ===========================================
# [1] control plane: without it there is no control at all (and CP-down is the
# off-VPN resting state, never a fence condition).
if ! tcp_probe "${API_HOST}" "${API_PORT}"; then
  log "CP KO (tcp ${API_HOST}:${API_PORT}) — no control plane (off-VPN / API down): cannot cordon, nothing to do; strike kept at ${streak}"
  exit 0
fi

# [2] data plane, inside a counter window bracketing the probe itself. A real
# egress to the VIP generates the only peer→node traffic this window needs:
# on a live tunnel the SYN-ACK moves rx; the 2026-11-12 failure mode holds rx
# at 0 while tx climbs.
rx1="$(read_counter "${VXLAN_STAT_DIR}/rx_packets")"
tx1="$(read_counter "${VXLAN_STAT_DIR}/tx_packets")"

dp_ok=0
if tcp_probe "${VIP_HOST}" "${VIP_PORT}"; then
  dp_ok=1
fi
sleep 2
rx2="$(read_counter "${VXLAN_STAT_DIR}/rx_packets")"
tx2="$(read_counter "${VXLAN_STAT_DIR}/tx_packets")"

if [ "${dp_ok}" -eq 1 ]; then
  if [ "${streak}" -ne 0 ]; then
    log "recovered: CP OK + DP OK (tcp ${VIP_HOST}:${VIP_PORT}) — stale streak of ${streak} reset"
  fi
  save_streak 0
  exit 0
fi

# DP-KO: only a LOCALLY CORROBORATED failure may count as a strike.
if [ -n "${rx1}" ] && [ -n "${rx2}" ]; then
  rx_delta=$(( rx2 - rx1 ))
  tx_delta=$(( tx2 - tx1 ))
  if [ "${rx_delta}" -ne 0 ]; then
    log "DP KO but NOT corroborated: cilium_vxlan rx moved by ${rx_delta} in the probe window (tx ${tx_delta}) — the tunnel receives, so the failure is on the REMOTE side (Traefik/VIP outage). Never fencing a healthy node for that; streak kept at ${streak}"
    exit 0
  fi
  log "DP KO corroborated: cilium_vxlan rx FROZEN (delta 0, tx +${tx_delta} in window) — 2026-11-12 signature (rx stuck at 0 while tx climbed past 166 240, node Ready)"
else
  log "DP KO: cilium_vxlan device absent — in tunnel mode there is no overlay without it, so the absence itself corroborates (a clean runner-leave also removes the device; then the node is already cordoned and the fence pass below no-ops)"
fi

streak=$(( streak + 1 ))
save_streak "${streak}"
log "strike ${streak}/${STREAK_NEEDED}: CP OK + DP KO locally corroborated"
if [ "${streak}" -lt "${STREAK_NEEDED}" ]; then
  exit 0
fi

if auto_fence; then
  save_streak 0
  log "auto-fence pass COMPLETE (verified) — streak reset; while the data plane stays dead an idempotent re-assert pass runs every ${STREAK_NEEDED} strikes (~90s). LIFTING IS STILL HUMAN: fence-runner-node.sh --unfence --yes only after the C1 proof (AGENTS.md / infrastructure/node-fence/README.md)."
else
  log "auto-fence pass INCOMPLETE — streak kept at ${streak}; retry on the next failing tick"
fi
exit 0

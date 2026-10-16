#!/usr/bin/env bash
# Best-effort drain fired by runner-auto-leave.service (ExecStop) on ANY
# initiated poweroff/reboot/lid-suspend. MUST NEVER block shutdown: everything
# is timeout-guarded and the script always exits 0.
#
# Deliberately NO `set -e` — a failing/guarded step must not abort mid-shutdown
# nor mask the final `exit 0`.
#
# The teardown (stop k3s-agent + purge the Cilium host-network hijack) is now
# UNCONDITIONAL: it always runs, even when the API server is unreachable
# (off-VPN / café suspend) or the node-ops kubeconfig is absent, because it
# needs no cluster access and is what restores the laptop's plain-network
# resting state after a suspend (incident 2026-10-14). Only the graceful
# cordon/drain is gated on API reachability. Remaining known consequence when
# the API is unreachable: pods can linger Terminating on the offline node as
# zombie runner pods, keeping ARC capacity slots claimed (2026-10-13 ebpro-org
# starvation) — the hijack is no longer part of that consequence; fix the
# lingering pods per AGENTS.md: force-delete them, ARC self-heals.
set -u

NODE=$(hostname)
export KUBECONFIG="${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}"
# The graceful cordon/drain below is the ONLY API-dependent part. It runs when
# the node-ops kubeconfig exists AND the API server answers within the pre-check
# window. When either is false (off-VPN / café suspend / config never installed)
# we cannot drain — but control still falls through to the unconditional
# teardown below (stopping the agent and purging the Cilium hijack need no
# cluster access). Everything stays silenced (journal-only) and non-fatal: this
# runs during shutdown — no stdout, always exit 0. Never touch ~/.kube/config
# (localhost-only on this agent laptop).
if [ -f "${KUBECONFIG}" ] \
   && timeout 8 kubectl --request-timeout=5s get node "${NODE}" >/dev/null 2>&1; then
  timeout 20 kubectl --request-timeout=15s cordon "${NODE}" >/dev/null 2>&1 || true
  timeout 75 kubectl drain "${NODE}" \
    --ignore-daemonsets --delete-emptydir-data --force \
    --grace-period=30 --timeout=60s >/dev/null 2>&1 || true
fi

# De-hijack the host network before the unit's ordering tears k3s-agent down
# after us: a plain ExecStop leaves Cilium's cgroup socket-LB + fwmark policy
# rule in the kernel, and SUSPEND preserves kernel state — so after a lid-close
# the user's connections to the Traefik LB VIP (10.2.248.31) keep being
# diverted into a dead overlay (incident 2026-10-14). For poweroff/reboot this
# purge is redundant (kernel goes away anyway); for suspend it is the whole
# point. Both steps are timeout-guarded, silenced (journal-only) and never
# fatal — the script always exits 0. This teardown is now UNCONDITIONAL: the
# API-reachability check above gates ONLY the graceful drain, never this block,
# so the hijack is purged after every suspend even when the cluster is
# unreachable (no manual runner-net-cleanup.sh needed afterwards).
timeout 20 systemctl stop k3s-agent >/dev/null 2>&1 || true
CLEANUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runner-net-cleanup.sh"
[ -x "${CLEANUP}" ] || CLEANUP=/usr/local/bin/runner-net-cleanup.sh
[ -x "${CLEANUP}" ] && timeout 40 "${CLEANUP}" >/dev/null 2>&1 || true

exit 0

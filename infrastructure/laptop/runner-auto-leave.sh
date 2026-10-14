#!/usr/bin/env bash
# Best-effort drain fired by runner-auto-leave.service (ExecStop) on ANY
# initiated poweroff/reboot/lid-suspend. MUST NEVER block shutdown: everything
# is timeout-guarded and the script always exits 0.
#
# Deliberately NO `set -e` — a failing/guarded step must not abort mid-shutdown
# nor mask the final `exit 0`.
#
# When the API server is unreachable (off-VPN / café suspend) the pre-check
# skips us silently within seconds. Known consequence of that skip: pods can
# linger Terminating on the offline node as zombie runner pods, keeping ARC
# capacity slots claimed (2026-10-13 ebpro-org starvation) — fix per AGENTS.md:
# force-delete the pods on the node, ARC self-heals.
set -u

NODE=$(hostname)
export KUBECONFIG="${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}"
# Never touch ~/.kube/config (localhost-only on this agent laptop). If the
# node-ops kubeconfig was never installed, skip silently: this runs during
# shutdown — no stdout, no non-zero exit.
[ -f "${KUBECONFIG}" ] || exit 0

# Fast pre-check: if the node/API is not reachable within 5s, stay quiet.
timeout 8 kubectl --request-timeout=5s get node "${NODE}" >/dev/null 2>&1 || exit 0

timeout 20 kubectl --request-timeout=15s cordon "${NODE}" >/dev/null 2>&1 || true
timeout 75 kubectl drain "${NODE}" \
  --ignore-daemonsets --delete-emptydir-data --force \
  --grace-period=30 --timeout=60s >/dev/null 2>&1 || true

# De-hijack the host network before the unit's ordering tears k3s-agent down
# after us: a plain ExecStop leaves Cilium's cgroup socket-LB + fwmark policy
# rule in the kernel, and SUSPEND preserves kernel state — so after a lid-close
# the user's connections to the Traefik LB VIP (10.2.248.31) keep being
# diverted into a dead overlay (incident 2026-10-14). For poweroff/reboot this
# purge is redundant (kernel goes away anyway); for suspend it is the whole
# point. Both steps are timeout-guarded, silenced (journal-only) and never
# fatal — the script still always exits 0. NOTE: the API-unreachable early
# exits above intentionally keep skipping this too (documented consequence in
# the header; run sudo ./runner-net-cleanup.sh by hand after such a suspend).
timeout 20 systemctl stop k3s-agent >/dev/null 2>&1 || true
CLEANUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runner-net-cleanup.sh"
[ -x "${CLEANUP}" ] || CLEANUP=/usr/local/bin/runner-net-cleanup.sh
[ -x "${CLEANUP}" ] && timeout 40 "${CLEANUP}" >/dev/null 2>&1 || true

exit 0

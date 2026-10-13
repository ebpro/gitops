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
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Fast pre-check: if the node/API is not reachable within 5s, stay quiet.
timeout 8 kubectl --request-timeout=5s get node "${NODE}" >/dev/null 2>&1 || exit 0

timeout 20 kubectl --request-timeout=15s cordon "${NODE}" >/dev/null 2>&1 || true
timeout 75 kubectl drain "${NODE}" \
  --ignore-daemonsets --delete-emptydir-data --force \
  --grace-period=30 --timeout=60s >/dev/null 2>&1 || true

exit 0

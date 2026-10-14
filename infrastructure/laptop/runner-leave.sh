#!/usr/bin/env bash
# Graceful planned leave = cordon + drain + stop k3s-agent.
# This script does NOT power the machine off — it is safe to run on the
# workstation. When you later initiate any shutdown/reboot/suspend yourself,
# runner-auto-leave.service (installed by install.sh) performs the drain
# automatically.
#
# The node stays CORDONED after leaving (and comes back cordoned after any
# reboot) — use runner-join.sh to resume accepting work.
set -euo pipefail

NODE=$(hostname)
export KUBECONFIG="${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}"
if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: node-ops kubeconfig missing (${KUBECONFIG}) — run ./install.sh --token-file ... --ca-file ..." >&2
  exit 1
fi

# Fail fast with a readable cause (instead of raw memcache.go spam from
# cordon) when the API server is unreachable or the kubeconfig is wrong.
if ! probe_err=$(kubectl --request-timeout=5s get node "${NODE}" 2>&1 >/dev/null); then
  echo "ERROR: cannot reach the API server for node ${NODE} via ${KUBECONFIG}:" >&2
  echo "${probe_err}" >&2
  echo "Hints: is the VPN up? Did ./install.sh write ~/.kube/node-ops.conf?" >&2
  exit 1
fi

echo "==> Cordoning node ${NODE}"
kubectl cordon "${NODE}"

echo "==> Draining node ${NODE}"
kubectl drain "${NODE}" \
  --ignore-daemonsets --delete-emptydir-data --force \
  --grace-period=60 --timeout=300s

echo "==> Stopping k3s-agent"
sudo systemctl stop k3s-agent || true

# Stopping the unit does NOT remove Cilium's kernel-level hijack state (cgroup
# socket-LB programs + the fwmark 0x200/0xf00 policy rule survive the stop and
# keep black-holing host connections to the Traefik LB VIP over VPNs that drop
# the overlay UDP — incident 2026-10-14). Purge it. The helper re-execs under
# sudo itself; a PARTIAL verdict is surfaced but never fails the leave.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLEANUP="${SCRIPT_DIR}/runner-net-cleanup.sh"
[ -x "${CLEANUP}" ] || CLEANUP=/usr/local/bin/runner-net-cleanup.sh
if [ -x "${CLEANUP}" ]; then
  echo "==> Purging residual Cilium host-network state"
  "${CLEANUP}" || echo "WARN: runner-net-cleanup.sh reported problems — see output above" >&2
else
  echo "WARN: runner-net-cleanup.sh not found (script dir nor /usr/local/bin)" >&2
  echo "      — residual Cilium socket-LB/IP-rule state may persist; reboot clears it" >&2
fi

echo "Node left the cluster. It stays cordoned — run runner-join.sh to resume accepting work. Shutting down is now safe (auto-leave hook will no-op)."

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

echo "Node left the cluster. It stays cordoned — run runner-join.sh to resume accepting work. Shutting down is now safe (auto-leave hook will no-op)."

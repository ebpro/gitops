#!/usr/bin/env bash
# Graceful planned leave. Covers manual poweroff; unplanned poweroff/reboot/
# suspend handled by runner-auto-leave.service (installed by install.sh).
#
# Takes the laptop OUT of the cluster: cordon + drain, stop the k3s agent,
# power off. The node comes back CORDONED after the next boot — use
# runner-join.sh to resume accepting work.
set -euo pipefail

NODE=$(hostname)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> Cordoning node ${NODE}"
kubectl cordon "${NODE}"

echo "==> Draining node ${NODE}"
kubectl drain "${NODE}" \
  --ignore-daemonsets --delete-emptydir-data --force \
  --grace-period=60 --timeout=300s

echo "==> Stopping k3s-agent"
sudo systemctl stop k3s-agent || true

echo "==> Powering off"
sudo poweroff

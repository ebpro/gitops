#!/usr/bin/env bash
# Rejoin after a leave/boot: wait for the node to register and go Ready,
# uncordon it (a drained node comes back CORDONED and would accept no work),
# then pre-pull the CI runner image so the first job after boot is fast.
set -euo pipefail

NODE=$(hostname)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> Waiting for node ${NODE} to exist and be Ready (up to 180s)"
deadline=$((SECONDS + 180))
while true; do
  if kubectl get node "${NODE}" >/dev/null 2>&1 \
     && [ "$(kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = "True" ]; then
    break
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "ERROR: node ${NODE} not Ready within 180s — check k3s-agent + VPN" >&2
    exit 1
  fi
  sleep 5
done

echo "==> Uncordoning node ${NODE}"
kubectl uncordon "${NODE}"

IMG=harbor.ebruno.fr/quarkus-microservices/quarkus-ci-runner:sha-2d55143
if ! sudo nerdctl -n k8s.io image inspect "${IMG}" >/dev/null 2>&1; then
  echo "==> Pre-pulling runner image ${IMG}"
  # Non-fatal: harbor is only reachable on the lab network/VPN.
  sudo nerdctl -n k8s.io pull "${IMG}" || echo "WARN: pre-pull failed (VPN down?) — continuing"
fi

exit 0

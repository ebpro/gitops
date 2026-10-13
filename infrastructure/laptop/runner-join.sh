#!/usr/bin/env bash
# Rejoin after a leave/boot: wait for the node to go Ready, uncordon it (a
# drained node comes back CORDONED and would accept no work), warn about any
# non-runner taints, then pre-pull the CI runner image so the first job after
# boot is fast.
set -euo pipefail

NODE=$(hostname)
export KUBECONFIG="${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}"
if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: node-ops kubeconfig missing (${KUBECONFIG}) — run ./install.sh --token-file ... --ca-file ..." >&2
  exit 1
fi

# Fast API probe: distinguishes "cannot reach the API server" (VPN down, wrong
# kubeconfig) from "node not Ready yet" (handled by the poll loop below),
# instead of burning the whole 180s budget on a dead endpoint.
if ! probe_err=$(kubectl --request-timeout=5s get node "${NODE}" 2>&1 >/dev/null); then
  echo "ERROR: cannot query node ${NODE} via ${KUBECONFIG}:" >&2
  echo "${probe_err}" >&2
  echo "Hints: is the VPN up? Is the agent running? (systemctl is-active k3s-agent)" >&2
  exit 1
fi

echo "==> Waiting for node ${NODE} to be Ready (up to 180s)"
deadline=$((SECONDS + 180))
while true; do
  if [ "$(kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = "True" ]; then
    break
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "ERROR: node ${NODE} not Ready within 180s — check k3s-agent + VPN" >&2
    # Surface the kubelet's own excuse if the node object is still readable
    # (e.g. "Kubelet stopped posting node status").
    ready_msg=$(kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
    if [ -n "${ready_msg}" ]; then
      echo "Ready condition message: ${ready_msg}" >&2
    fi
    exit 1
  fi
  sleep 5
done

echo "==> Uncordoning node ${NODE}"
kubectl uncordon "${NODE}"

# Surface taints other than the intended runner taint — e.g. a stale
# node.cilium.io/agent-not-ready after an unclean leave silently blocks runner
# pods even on an Ready+uncordoned node. Never removed automatically.
unexpected_taints=$(kubectl get node "${NODE}" \
  -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}' 2>/dev/null \
  | grep -v -e '^workload=runner:NoSchedule$' -e '^[[:space:]]*$' || true)
if [ -n "${unexpected_taints}" ]; then
  echo "WARN: unexpected taint(s) on ${NODE} — runner pods may not schedule:" >&2
  while read -r t; do
    [ -n "${t}" ] && echo "WARN:   ${t} → remove with: kubectl taint nodes ${NODE} ${t}-" >&2
  done <<< "${unexpected_taints}"
fi

IMG=harbor.ebruno.fr/quarkus-microservices/quarkus-ci-runner:sha-2d55143
if ! sudo nerdctl -n k8s.io image inspect "${IMG}" >/dev/null 2>&1; then
  echo "==> Pre-pulling runner image ${IMG}"
  # Non-fatal: harbor is only reachable on the lab network/VPN.
  sudo nerdctl -n k8s.io pull "${IMG}" || echo "WARN: pre-pull failed (VPN down?) — continuing"
fi

exit 0

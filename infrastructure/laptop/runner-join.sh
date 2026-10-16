#!/usr/bin/env bash
# Rejoin after a leave/boot: wait for the node to go Ready, PROVE the cluster
# data plane is reachable over the current network (VPN must carry the Cilium
# overlay UDP), then uncordon (a drained node comes back CORDONED and would
# accept no work), warn about any non-runner taints, then pre-pull the CI
# runner image so the first job after boot is fast. Preflight failure keeps
# the node cordoned (fail-closed) — see README "Home vs lab operation".
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

# --- data-plane preflight (BEFORE uncordon, fail-closed) ----------------------
# Why: Cilium's host socket-LB hijacks LOCAL connections to the Traefik LB VIP
# (10.2.248.31) into the cluster overlay. On VPNs whose gateway drops the
# overlay's UDP underlay, uncordoning would (1) let the scheduler place runner
# pods here whose traffic can never reach the cluster and (2) leave the user's
# own browser connections to the VIP black-holed. Because this very probe is
# itself hijacked into the overlay, ANY HTTP answer — even 401/403/404/5xx
# (Harbor's 5xx is a separate, tracked DB outage) — PROVES the overlay
# traverses this network; only 000/timeout means it does not. Control plane
# reachability (6443, proven above) is NOT sufficient — TCP works while the
# tunnel is dead.
VIP=10.2.248.31
if ! systemctl is-active --quiet k3s-agent; then
  echo "ERROR: k3s-agent is not active — cannot prove the data plane before uncordoning." >&2
  echo "       Start it first: sudo systemctl start k3s-agent, then re-run this script." >&2
  exit 1
fi

echo "==> Data-plane preflight: probing https://${VIP}/ through the Cilium overlay (up to 120s)"
dp_deadline=$((SECONDS + 120))
while true; do
  code=$(curl -sk --connect-timeout 5 -m 8 -o /dev/null -w '%{http_code}' "https://${VIP}/" 2>/dev/null || true)
  if [ -n "${code}" ] && [ "${code}" != "000" ]; then
    echo "==> Data plane reachable over this network (HTTP ${code}) — safe to uncordon"
    break
  fi
  if [ "${SECONDS}" -ge "${dp_deadline}" ]; then
    echo "ERROR: data plane unreachable over this network (overlay UDP blocked by VPN" >&2
    echo "       gateway). Node left CORDONED — correct state for a remote laptop." >&2
    # Fail-closed teardown: k3s-agent is active (proven above) but its Cilium
    # host-network hijack keeps black-holing the operator's connections to the
    # VIP over this VPN. Best-effort stop + purge so the laptop always rests in
    # the plain-network state, then exit non-zero (the join did not succeed).
    # runner-net-cleanup.sh re-execs under sudo itself and refuses to run while
    # k3s-agent is active, so the stop must come first.
    echo "       Auto-teardown attempted: stopping k3s-agent and purging Cilium host-network state." >&2
    sudo systemctl stop k3s-agent || true
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    CLEANUP="${SCRIPT_DIR}/runner-net-cleanup.sh"
    [ -x "${CLEANUP}" ] || CLEANUP=/usr/local/bin/runner-net-cleanup.sh
    [ -x "${CLEANUP}" ] && "${CLEANUP}" || true
    exit 1
  fi
  sleep 10
done

echo "==> Uncordoning node ${NODE}"
kubectl uncordon "${NODE}"

# Surface taints other than the intended runner taint — e.g. a stale
# node.cilium.io/agent-not-ready after an unclean leave silently blocks runner
# pods even on an Ready+uncordoned node. Never removed automatically.
unexpected_taints=$(kubectl get node "${NODE}" \
  -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null \
  | grep -v -e '^workload=runner:NoSchedule$' -e '^[[:space:]]*$' || true)
if [ -n "${unexpected_taints}" ]; then
  echo "WARN: unexpected taint(s) on ${NODE} — runner pods may not schedule:" >&2
  while read -r t; do
    [ -n "${t}" ] && echo "WARN:   ${t} → remove with: kubectl taint nodes ${NODE} ${t}-" >&2
  done <<< "${unexpected_taints}"
fi

IMG=harbor.ebruno.fr/quarkus-microservices/quarkus-ci-runner:sha-2d55143
# k3s ctr talks directly to k3s' embedded containerd (stock k3s agent ships no
# nerdctl binary) and defaults to the k8s.io namespace — the one the kubelet
# reads — so a pre-pulled image is visible to runner pods without re-download.
if ! sudo k3s ctr images ls -q 2>/dev/null | grep -qxF "${IMG}"; then
  echo "==> Pre-pulling runner image ${IMG}"
  # Non-fatal: harbor is only reachable on the lab network/VPN.
  sudo k3s ctr images pull "${IMG}" || echo "WARN: pre-pull failed (VPN down?) — continuing"
fi

exit 0

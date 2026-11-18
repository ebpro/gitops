#!/usr/bin/env bash
# resolve-cluster-ip.sh — print the CURRENT InternalIP of the lima-k3s-agent
# worker, the only cluster address that serves the public HTTPS entrypoints
# (*.ebruno.fr via Traefik) reachable from this laptop.
#
# Why dynamic (measured 2026-11-18):
#   - The worker answers 443 with real *.ebruno.fr certificates on its current
#     InternalIP 10.2.248.247 — but that address is a DHCP LEASE (stable MAC
#     52:55:55:00:20:c6). It can change at any renewal. NOTHING in this kit may
#     hardcode it.
#   - The Traefik LB VIP 10.2.248.31:80/443 is DEAD from this laptop (campus
#     M1 — pod-terminated traffic through the Cilium tunnel fails). Never map
#     the *.ebruno.fr hosts onto it.
#
# Resolution chain (defence in depth):
#   1. source of truth: kubectl against the API (host-terminated on
#      10.2.248.31:6443, which WORKS from the laptop) using the node-ops
#      kubeconfig, bounded by --request-timeout + an outer timeout.
#   2. fallback: ask compute-lsis-2 over ssh to do the same lookup locally.
# If both fail: message on stderr, exit non-zero. Never guess, never cache.
#
# stdout: one IPv4 address. Everything else goes to stderr.
#
# Env overrides:
#   STANDALONE_LIMA_NODE      node name to resolve (default lima-k3s-agent)
#   RUNNER_OPS_KUBECONFIG     kubeconfig path (default $HOME/.kube/node-ops.conf,
#                             same convention as the sibling lifecycle scripts)
set -euo pipefail

NODE_NAME="${STANDALONE_LIMA_NODE:-lima-k3s-agent}"
KUBECONFIG_PATH="${RUNNER_OPS_KUBECONFIG:-${HOME:-/root}/.kube/node-ops.conf}"
JSONPATH='{.status.addresses[?(@.type=="InternalIP")].address}'
SSH_TARGET="${STANDALONE_SSH_TARGET:-compute-lsis-2}"

is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

ip=""
src=""
err_kubectl=""
err_ssh=""

# --- attempt 1: direct kubectl via the node-ops kubeconfig --------------------
# One call only; stdout captured, stderr kept for the failure message. The
# outer timeout is a backstop around kubectl's own --request-timeout=15s.
if ! command -v kubectl >/dev/null 2>&1; then
  err_kubectl="kubectl not on PATH"
elif [ ! -f "${KUBECONFIG_PATH}" ]; then
  err_kubectl="kubeconfig not found: ${KUBECONFIG_PATH}"
else
  kerr=$(mktemp)
  ip=$(timeout 20 kubectl --kubeconfig "${KUBECONFIG_PATH}" \
    --request-timeout=15s get node "${NODE_NAME}" -o "jsonpath=${JSONPATH}" 2>"${kerr}" || true)
  if is_ipv4 "${ip}"; then
    src="kubectl(${KUBECONFIG_PATH})"
  else
    err_kubectl=$(tr '\n' ' ' < "${kerr}")
    [ -n "${err_kubectl}" ] || err_kubectl="kubectl returned no IPv4 for node ${NODE_NAME}"
    ip=""
  fi
  rm -f "${kerr}"
fi

if ! is_ipv4 "${ip}"; then
  # --- attempt 2: ssh to the control plane and resolve there ------------------
  # Client-side expansions of NODE_NAME/JSONPATH are intended (SC2029); the
  # remote single quotes protect the jsonpath from the remote shell.
  # shellcheck disable=SC2029
  ip=$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_TARGET}" \
    "kubectl get node ${NODE_NAME} -o jsonpath='${JSONPATH}'" 2>/dev/null || true)
  if is_ipv4 "${ip}"; then
    src="ssh(${SSH_TARGET})"
  else
    err_ssh="ssh ${SSH_TARGET} lookup failed or returned no IPv4"
  fi
fi

if ! is_ipv4 "${ip}"; then
  {
    echo "ERROR: cannot resolve the current InternalIP of node '${NODE_NAME}'." >&2
    echo "  kubectl path : ${err_kubectl:-succeeded with a non-IPv4 answer}" >&2
    echo "  ssh path     : ${err_ssh:-not attempted / failed}" >&2
    echo "Hints: is the VPN up (API 10.2.248.31:6443 host-terminated must be reachable)?" >&2
    echo "       does ${KUBECONFIG_PATH} exist (see infrastructure/laptop/install.sh)?" >&2
  } >&2
  exit 1
fi

echo "resolved ${NODE_NAME} InternalIP ${ip} via ${src}" >&2
printf '%s\n' "${ip}"

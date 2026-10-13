#!/usr/bin/env bash
# One-time installer for the pc-bruno-gpu laptop runner-node. Run ON THE
# LAPTOP from a checkout of this repo:
#
#   cd infrastructure/laptop && ./install.sh [--token-file F --ca-file F]
#
# 1) Installs the runner-*.sh scripts to /usr/local/bin, enables AND starts the
#    runner-auto-leave systemd unit (auto-drain on poweroff/reboot/suspend).
# 2) Assembles ~/.kube/node-ops.conf for the GitOps-managed node-ops
#    ServiceAccount (kubernetes/arc/node-ops-rbac.yaml, synced by ArgoCD —
#    never kubectl-create it). The laptop runs k3s AGENT-ONLY, so the legacy
#    ~/.kube/config (localhost API server) is useless here and is never
#    created or modified by this installer. The token never lives in this repo;
#    copy it out of the cluster with the commands printed below, from a machine
#    that has cluster-admin access.
set -euo pipefail

SERVER="https://compute-lsis-2.lis-lab.fr:6443"
TOKEN_FILE=""
CA_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token-file) TOKEN_FILE="${2:?--token-file requires a path}"; shift 2 ;;
    --ca-file)    CA_FILE="${2:?--ca-file requires a path}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ "$(hostname)" != "pc-bruno-gpu" ]; then
  echo "ERROR: this installer is laptop-only (expected host pc-bruno-gpu, got $(hostname))." >&2
  exit 1
fi

cd "$(dirname "$0")"

echo "==> Installing scripts to /usr/local/bin"
for f in runner-join.sh runner-leave.sh runner-auto-leave.sh; do
  sudo cp "${f}" /usr/local/bin/
  sudo chmod 755 "/usr/local/bin/${f}"
done

echo "==> Installing, enabling + starting runner-auto-leave.service"
sudo cp runner-auto-leave.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable runner-auto-leave.service
# enable alone is NOT enough: a Type=oneshot RemainAfterExit unit that was
# never started stays INACTIVE until the first reboot, so its ExecStop drain
# hook would never fire on the next poweroff. Start it now to arm the hook.
sudo systemctl start runner-auto-leave.service

KUBECONF="$HOME/.kube/node-ops.conf"

if [ -z "${TOKEN_FILE}" ] || [ -z "${CA_FILE}" ]; then
  if [ -f "${KUBECONF}" ]; then
    echo "==> ${KUBECONF} already present — leaving it as is. Done."
    exit 0
  fi
  echo "==> No --token-file/--ca-file given and no ${KUBECONF} yet — skipping kubeconfig setup."
  cat <<'GUIDE'
To create it, first extract the node-ops credentials ON A CLUSTER-ADMIN MACHINE
(node-ops is least-privilege: cordon/drain of nodes only; never commit these
files or paste them into chat/tickets). NOTE: the dot in "ca.crt" must be
escaped in the jsonpath:

  kubectl get secret node-ops-token -n kube-system -o jsonpath='{.data.token}'   | base64 -d > /tmp/node-ops.token
  kubectl get secret node-ops-token -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/node-ops.ca.crt

Copy both files to this laptop (e.g. scp), then re-run:

  ./install.sh --token-file /tmp/node-ops.token --ca-file /tmp/node-ops.ca.crt

and shred/clean up the copies afterwards.
GUIDE
  exit 0
fi

[ -s "${TOKEN_FILE}" ] || { echo "ERROR: token file is empty: ${TOKEN_FILE}" >&2; exit 1; }
[ -s "${CA_FILE}" ]    || { echo "ERROR: CA file is empty: ${CA_FILE}" >&2; exit 1; }

echo "==> Writing ${KUBECONF} (node-ops SA against ${SERVER}) — ~/.kube/config is never touched"
mkdir -p "$HOME/.kube"
chmod 700 "$HOME/.kube"
CA_DEST="$HOME/.kube/node-ops-ca.crt"
install -m 0644 "${CA_FILE}" "${CA_DEST}"

umask 077
cat > "${KUBECONF}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: compute-lsis-2
    cluster:
      server: ${SERVER}
      certificate-authority: ${CA_DEST}
contexts:
  - name: node-ops
    context:
      cluster: compute-lsis-2
      user: node-ops
current-context: node-ops
users:
  - name: node-ops
    user:
      token: $(cat "${TOKEN_FILE}")
EOF
# cat > preserves the mode of a pre-existing file — enforce 0600 explicitly.
chmod 600 "${KUBECONF}"

echo "==> Done. Sanity check: kubectl --kubeconfig ~/.kube/node-ops.conf get node $(hostname)"

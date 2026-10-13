# Laptop runner-node tooling (pc-bruno-gpu)

Lifecycle scripts for the GPU laptop that serves as an ARC runner node. The
laptop runs k3s **agent-only** — no local API server — so all cluster access
goes through the GitOps-managed `node-ops` ServiceAccount
(`kubernetes/arc/node-ops-rbac.yaml`) via a dedicated kubeconfig.

## Scripts
| File | Purpose |
|---|---|
| `runner-leave.sh` | Planned graceful leave: cordon + drain, stop k3s-agent — no shutdown (workstation-safe). User-initiated poweroff/reboot/lid-suspend is covered by `runner-auto-leave.sh`. |
| `runner-join.sh` | Rejoin after boot: wait for Ready, uncordon, WARN on non-runner taints (never removes them), pre-pull the runner image. |
| `runner-auto-leave.sh` | Best-effort drain fired on ANY initiated poweroff/reboot/suspend. Always exits 0, prints nothing on shutdown. |
| `runner-auto-leave.service` | Type=oneshot RemainAfterExit unit; drain hook runs on ExecStop — must be **started** (not just enabled) to be armed. |
| `install.sh` | One-time installer: copies scripts + unit system-wide and writes the kubeconfig. |

## One-time install (on the laptop)
1. Clone/pull this repo on the laptop.
2. On a cluster-admin machine, extract the node-ops credentials (the dot in
   `ca.crt` must be escaped in the jsonpath):
   ```
   kubectl get secret node-ops-token -n kube-system -o jsonpath='{.data.token}'   | base64 -d > /tmp/node-ops.token
   kubectl get secret node-ops-token -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/node-ops.ca.crt
   ```
3. `scp` both files to the laptop, then
   `cd infrastructure/laptop && ./install.sh --token-file /tmp/node-ops.token --ca-file /tmp/node-ops.ca.crt`
4. Sanity check: `kubectl --kubeconfig ~/.kube/node-ops.conf get node "$(hostname)"`

## Why ~/.kube/node-ops.conf, never ~/.kube/config?
The laptop's legacy `~/.kube/config` points at `127.0.0.1:6443`, which does not
exist in agent-only mode — every kubectl call would "connection refused" or
hang. All scripts pin `KUBECONFIG=${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}`.

## Remote shutdown
`ssh bruno@pc-bruno-gpu sudo poweroff` fires the same drain hook
(runner-auto-leave.service ExecStop) as a local power-button press.

## Troubleshooting
- join/leave "connection refused" or 180s timeout ⇒ wrong/missing kubeconfig;
  re-run `./install.sh --token-file ... --ca-file ...`.
- "Kubelet stopped posting node status" ⇒ start the VPN, `sudo systemctl start
  k3s-agent`, then re-run `runner-join.sh`.
- Stale `node.cilium.io/agent-not-ready:NoSchedule` taint blocks runners ⇒
  remove it with the exact `kubectl taint nodes ...-` command the join WARN prints.
- After ANY drain the node returns **CORDONED** — always run `runner-join.sh`.
- Off-VPN suspend skips the auto-drain silently ⇒ zombie Terminating runner
  pods may hold ARC capacity; force-delete the pods on the node (see AGENTS.md).

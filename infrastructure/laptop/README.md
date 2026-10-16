# Laptop runner-node tooling (pc-bruno-gpu)

Lifecycle scripts for the GPU laptop that serves as an ARC runner node. The
laptop runs k3s **agent-only** — no local API server — so all cluster access
goes through the GitOps-managed `node-ops` ServiceAccount
(`kubernetes/arc/node-ops-rbac.yaml`) via a dedicated kubeconfig.

## Scripts
| File | Purpose |
|---|---|
| `runner-leave.sh` | Planned graceful leave: cordon + drain, stop k3s-agent, then purge residual Cilium host-network state via `runner-net-cleanup.sh` — no shutdown (workstation-safe). User-initiated poweroff/reboot/lid-suspend is covered by `runner-auto-leave.sh`. |
| `runner-join.sh` | Rejoin after boot: wait for Ready, **data-plane preflight** (refuses to uncordon unless the cluster overlay is proven reachable over the current network), uncordon, WARN on non-runner taints (never removes them), pre-pull the runner image. |
| `runner-net-cleanup.sh` | Purge helper: removes leftover Cilium ip-rules / nft tables / cgroup socket-LB eBPF programs that survive `systemctl stop k3s-agent`. Called by leave + auto-leave; idempotent, safe to run by hand (`sudo ./runner-net-cleanup.sh`). Never reboots. |
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

## k3s agent version pin
`install.sh` pins `K3S_VERSION="v1.36.4+k3s1"` / `K3S_CHANNEL="v1.36"` — the
channel is pinned to match the control-plane (compute-lsis-2); bump it together
with cluster upgrades. On a fresh laptop rebuild, `install.sh` prints the pinned
one-time `get.k3s.io` agent bootstrap command when `k3s-agent` is not active
(the k3s install itself is NOT automated; it needs the cluster node token).

## Why ~/.kube/node-ops.conf, never ~/.kube/config?
The laptop's legacy `~/.kube/config` points at `127.0.0.1:6443`, which does not
exist in agent-only mode — every kubectl call would "connection refused" or
hang. All scripts pin `KUBECONFIG=${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}`.

## Home vs lab operation
The laptop joins the cluster through Cilium's **tunnel overlay**, which rides
on UDP through the VPN underlay. Not every network path carries that UDP, so:

1. **Joining requires the VPN to carry the cluster tunnel UDP.**
   `runner-join.sh` now pre-tests this **before** uncordoning: it probes
   `https://10.2.248.31/` (the Traefik LB VIP) from the host — a connection
   that Cilium socket-LB itself hijacks into the overlay — and treats **any**
   HTTP answer as proof the overlay works end-to-end (401/403/404/5xx are
   fine; e.g. Harbor 5xx is a separate, tracked DB outage). Only 000/timeout
   fails. On failure the node stays **CORDONED** (fail-closed).
2. **A remote laptop that cannot pass the pre-test must stay left**: cordoned,
   `k3s-agent` stopped, cleanup run. That is a supported resting state, not a
   failure — the runner simply does not participate from that network.
3. **The hijack:** in tunnel mode Cilium keeps cgroup socket-LB eBPF programs
   and an `ip rule fwmark 0x200/0xf00 lookup 2004` policy route on the host,
   which divert every local connection to 10.2.248.31 into the overlay —
   and these **survive `systemctl stop k3s-agent`**. Symptom signature:
   `curl -k https://10.2.248.31/` returns `000` (timeout) while TCP 6443 to
   the API server works. Fix: `sudo systemctl stop k3s-agent &&
   sudo ./runner-net-cleanup.sh` (or reboot — the scripts never reboot).
   Documented incident: 2026-10-14.
4. **bpftool dependency:** detaching the cgroup eBPF programs (the piece that
   survives everything else) needs `bpftool`, from `linux-tools-common` +
   `linux-tools-$(uname -r)` — not installed by `install.sh` (no apt step
   there; install manually). Without bpftool the cleanup still removes the ip
   rules and nft tables and reports **PARTIAL**; a reboot is then the full
   reset.

## VPN dependency (lab access)
The laptop's lab access rides an **admin-managed WireGuard VPN**
(`wg-lum-users.lis-lab.fr:20023`) that is NOT git-managed by this repo. When
the tunnel is unhealthy, the laptop's supported state is the resting state:
cordoned, `k3s-agent` stopped, `runner-net-cleanup.sh` PASS.

- The provider profile ships full-internet supernet `AllowedIPs` (de-facto
  full tunnel) plus global DNS (`~.` via 139.124.5.131/132): if the tunnel
  data plane dies this black-holes **all** host internet, and combined with
  the Cilium agent hijack above it is doubly hazardous. The admin's own
  split-tunnel variant is the recommended laptop profile:
  `AllowedIPs = 139.124.0.0/16, 192.168.4.2/32, 10.2.248.0/24, 10.2.251.0/24`,
  with DNS search domains `ebruno.fr lis-lab.fr` instead of global `~.`.
  `runner-join.sh`'s VIP probe (`10.2.248.31/32`) is covered by
  `10.2.248.0/24`, so the preflight keeps working under split tunnel.
- Key hygiene: WireGuard private keys / preshared keys must **never** be
  committed to this repo or pasted into chats/tickets; on suspected exposure,
  rotate the peer key at wg-lum-users.

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
- Join exits 1 at the "Data-plane preflight" step ⇒ this VPN drops the overlay
  UDP; keep the node cordoned and run the cleanup (see "Home vs lab operation").
- `curl -k https://10.2.248.31/` = `000` while 6443 works, agent already stopped
  ⇒ leftover Cilium hijack state ⇒ `sudo ./runner-net-cleanup.sh` (or reboot).

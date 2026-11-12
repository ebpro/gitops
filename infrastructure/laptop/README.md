# Laptop runner-node tooling (pc-bruno-gpu)

Lifecycle scripts for the GPU laptop that serves as an ARC runner node. The
laptop runs k3s **agent-only** — no local API server — so all cluster access
goes through the GitOps-managed `node-ops` ServiceAccount
(`kubernetes/arc/node-ops-rbac.yaml`) via a dedicated kubeconfig.

## Scripts
| File | Purpose |
|---|---|
| `runner-leave.sh` | Planned graceful leave: cordon + drain, stop k3s-agent, then purge residual Cilium host-network state via `runner-net-cleanup.sh` — no shutdown (workstation-safe). User-initiated poweroff/reboot/lid-suspend is covered by `runner-auto-leave.sh`. |
| `runner-join.sh` | Rejoin after boot: wait for Ready, **data-plane preflight** (refuses to uncordon unless the cluster overlay is proven reachable over the current network; on failure prints the probes that discriminate "VPN drops overlay UDP" from user-VLAN ingress isolation — see `docs/network/runner-node-vlan-isolation-20261112.md`), **quarantine-fence hard-stop** (label `quarantine=true` and/or the quarantine taint → exit 1, never uncordons; lifting is two explicit kubectl commands, see `kubernetes/arc/node-quarantine-taint.yaml`), uncordon, WARN on other non-runner taints (never removes them; the quarantine taint is deliberately excluded from that advice), pre-pull the runner image pinned by immutable digest (same reference as `helm/releases/arc/*-scale-set-values.yaml`). |
| `runner-net-cleanup.sh` | Purge helper: removes leftover Cilium ip-rules / nft tables / cgroup socket-LB eBPF programs that survive `systemctl stop k3s-agent`. Called by leave + auto-leave; idempotent, safe to run by hand (`sudo ./runner-net-cleanup.sh`). Never reboots. |
| `runner-auto-leave.sh` | Best-effort drain fired on ANY initiated poweroff/reboot/suspend. Always exits 0, prints nothing on shutdown. Must run as **root** (it stops `k3s-agent`) and resolves its kubeconfig and `kubectl` path explicitly — the shutdown environment has neither `HOME` nor the Nix profile in `PATH`. |
| `runner-auto-leave.service` | Type=oneshot RemainAfterExit unit; drain hook runs on ExecStop — must be **started** (not just enabled) to be armed. `TimeoutStopSec=180` is a measured budget, see "Hook budget and why it is 180 s". No `User=` on purpose. |
| `logind-runner-node.conf` | systemd-logind drop-in source; installed to `/etc/systemd/logind.conf.d/99-runner-node.conf`. Keeps a lid movement from sleeping the node while on AC. See "Lid and suspend policy". |
| `install.sh` | One-time installer: copies scripts + unit system-wide, installs the logind drop-in, closes the GNOME lid action on AC, and writes the kubeconfig. |

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

## Hook budget and why `TimeoutStopSec` is 180

The drain hook runs while the machine is going down, so systemd can kill it
mid-flight. Worst-case cost, from the actual code paths:

| Stage | Budget |
|---|---|
| API gate: probe (2 s) + retry (15 s) | ≈ 20 s (hard-capped at 25 s) |
| `drain --grace-period=120` | up to 120 s |
| `systemctl stop k3s-agent` + `runner-net-cleanup.sh` | 20 s + 40 s (both `timeout`-guarded) |
| **total** | **≈ 163 s** |

Two failure modes if that budget is cut — e.g. a hand-edited `TimeoutStopSec=120`,
which is what the live unit actually carried until 2026-11-12: the drain gets
truncated, **and** `ExecStartPost` never runs, so the node is left **cordoned**
while its pods are force-deleted. Do not lower it. Verify the live value with:

```bash
systemctl show runner-auto-leave.service -p LoadState,UnitFileState,TimeoutStopUSec
# expect: LoadState=loaded UnitFileState=enabled TimeoutStopUSec=3min
```

## Lid and suspend policy

A lid movement is the likeliest way this "node" stops existing, and it has **two
independent decision layers** — closing one leaves the other live. Both values
below were read from the running system on 2026-11-12, not from config files
(`/etc/systemd/logind.conf` has no active directive at all here, i.e. everything
is default):

| Layer | Who decides | State found |
|---|---|---|
| systemd-logind | `HandleLidSwitch*` | `HandleLidSwitch="suspend"` (effective value over D-Bus), `HandleLidSwitchDocked="ignore"` |
| gnome-settings-daemon (`gsd-power`, live in the session) | `lid-close-ac-action` / `lid-close-battery-action` | no dconf override → schema default, `suspend` |

`install.sh` closes both for the **plugged-in** case only: it installs
`logind-runner-node.conf` as `/etc/systemd/logind.conf.d/99-runner-node.conf`
(`HandleLidSwitchExternalPower=ignore`) and writes `lid-close-ac-action='nothing'`
through dconf. On battery the lid still suspends, deliberately: unplugged **and**
lid shut means the machine is being put into a bag, and running hot on a draining
battery is worse than a suspend the hook handles gracefully (it fires on suspend
too). logind chooses its action as `HandleLidSwitchExternalPower` on AC,
`HandleLidSwitch` off AC and not docked, `HandleLidSwitchDocked` when docked —
which is why overriding only the external-power variant is both sufficient and
surgical.

- **`systemd-logind` is never restarted by `install.sh`.** Restarting it takes the
  live user session (graphical included) with it, and a plain `SIGHUP` toward a
  service without a handler would kill it outright (default disposition is
  terminate). The drop-in therefore applies at the **next reboot** — which is on
  the critical path anyway, since the unit's boot-time arming has to be validated
  after the k3s join regardless.
- **Read GNOME state with dconf, not gsettings.** The `gsettings` on `PATH` here is
  the linuxbrew build and it answers with *schema defaults* on several keys (it
  claims `sleep-inactive-ac-type='suspend'` where the user's real value is
  `'nothing'`). Use `dconf dump /org/gnome/settings-daemon/plugins/power/` (only
  *set* keys are listed; anything absent is the default) or `dconf read <key>`.
- **Swap is not an enrollment blocker.** `/swap.img` (8 GiB) is active with 0 B
  used, and `lima-k3s-agent` in this very cluster reports
  `status.nodeInfo.swap.capacity = 8 GiB` while running `v1.36.4+k3s1` — so k3s
  tolerates swap here, and the reflex "run `swapoff` before joining" would only
  buy an `/etc/fstab` edit. Memory is not this node's binding constraint either
  (61 GiB total vs ≈4 concurrent `org` runners at 15 Gi requests); **disk is**.

## Home vs lab operation
The laptop joins the cluster through Cilium's **tunnel overlay**, which rides
on UDP through the VPN underlay. Not every network path carries that UDP, so:

1. **Joining requires the VPN to carry the cluster tunnel UDP.**
   `runner-join.sh` now pre-tests this **before** uncordoning: it probes
   `https://10.2.248.31/` (the Traefik LB VIP) from the host — that address has
   **no host socket**: it is the k3s ServiceLB `svclb-traefik` DNAT onto a remote
   Traefik pod, which is exactly why the probe rides the cluster overlay and is a
   valid data-plane test. (Wording trap: the live `kube-system/cilium-config`
   **requests** `kube-proxy-replacement: "true"` — line 112 of the captured cm
   `/tmp/opencode/cilium_live_cm.json` — while the agent **runtime reports**
   `Partial` with `Host: Legacy`; both halves are true, and neither "KPR is off"
   nor "KPR is true" is accurate.) It treats **any**
   HTTP answer as proof the overlay works end-to-end (401/403/404/5xx are
   fine; e.g. Harbor 5xx is a separate, tracked DB outage). Only 000/timeout
   fails. On failure the node stays **CORDONED** (fail-closed) and the script
   prints the read-only probes that discriminate "VPN drops the overlay UDP"
   from the 2026-11-12 user-VLAN ingress-isolation failure
   (`docs/network/runner-node-vlan-isolation-20261112.md`). Join additionally
   **hard-stops (exit 1)** on the quarantine fence (label `quarantine=true`
   and/or quarantine taint — `kubernetes/arc/node-quarantine-taint.yaml`); the
   script never lifts or routes around it.
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
- **Drain hook silent on shutdown (the 2026-11-12 finding).** In the shutdown
  environment systemd gives the hook **neither `HOME` nor the Nix profile in
  `PATH`**, so `KUBECONFIG=${RUNNER_OPS_KUBECONFIG:-$HOME/.kube/node-ops.conf}`
  died on `HOME: unbound variable` *before* the teardown, and even with `HOME` set
  `kubectl` was not findable (it lives in `~/.nix-profile/bin`). Both are resolved
  explicitly in `runner-auto-leave.sh` now. To prove it without rebooting or
  touching a real node, run it as root with a clean environment against a node
  name that does not exist — the script exits 0 either way, and reaching the
  teardown line is what proves the fix:
  ```bash
  sudo env -i /usr/local/bin/runner-auto-leave.sh pc-bruno-gpu-does-not-exist; echo "rc=$?"
  # expect rc=0 (pre-fix it aborted on "HOME: unbound variable")
  ```
  Note `env -i` without `HOME` also makes kubectl write a `.kube/cache/` directory
  **relative to the current directory** — run it from a neutral cwd, never from
  this repo (`.gitignore` guards it, but do not rely on that).
- join/leave "connection refused" or 180s timeout ⇒ wrong/missing kubeconfig;
  re-run `./install.sh --token-file ... --ca-file ...`.
- "Kubelet stopped posting node status" ⇒ start the VPN, `sudo systemctl start
  k3s-agent`, then re-run `runner-join.sh`.
- Stale `node.cilium.io/agent-not-ready:NoSchedule` taint blocks runners ⇒
  remove it with the exact `kubectl taint nodes ...-` command the join WARN prints.
- After ANY drain the node returns **CORDONED** — always run `runner-join.sh`.
- Off-VPN suspend skips the auto-drain silently ⇒ zombie Terminating runner
  pods may hold ARC capacity. The supported remedy is **from the healthy
  control-plane side**: `infrastructure/node-fence/fence-runner-node.sh` (see
  AGENTS.md and `infrastructure/node-fence/README.md`) — copy it to the admin
  host, `--dry-run` first. It deletes the runner **pods** in ns `arc-runners`
  and never the `EphemeralRunner`/`EphemeralRunnerSet` CRs, which is precisely
  what preserves already-assigned jobs: with the CRs alive, pod recreation
  reuses the GitHub-side runner registration and the jobs resume without a
  manual workflow re-run.
- Join exits 1 at the "Data-plane preflight" step ⇒ either this VPN drops the
  overlay UDP, or the node sits on the user VLAN whose ingress isolation drops
  VXLAN replies (`docs/network/runner-node-vlan-isolation-20261112.md`) — the
  script prints the three read-only probes that tell the two apart. Keep the
  node cordoned and run the cleanup either way (see "Home vs lab operation").
- Join exits 1 with "QUARANTINED" ⇒ deliberate data-plane fence
  (`kubernetes/arc/node-quarantine-taint.yaml`). Do not uncordon by habit:
  lifting takes **ALL THREE** actions — `kubectl label node <n> quarantine-`,
  then `kubectl taint nodes <n> quarantine:NoSchedule-` **only if it was ever
  re-posed**, then `kubectl uncordon <n>` (the policy is NOT self-cleaning), and
  the label must be re-applied after any leave/join cycle — a clean leave deletes
  the Node object and both the label and the taint vanish with it. From the
  control plane, `infrastructure/node-fence/fence-runner-node.sh --unfence --yes <n>`
  does the label removal and the uncordon and prints the taint step as manual;
  `--unfence` **without** `--yes` refuses (exit 1, no cluster access needed) and
  prints the mandatory C1 precondition: on the node,
  `cat /sys/class/net/cilium_vxlan/statistics/rx_packets` must move **strictly
  above 0** under peer→node traffic — `Ready` proves nothing about the data plane
  (2026-11-12: that counter sat at `0` across 166 240 transmitted packets).
- `curl -k https://10.2.248.31/` = `000` while 6443 works, agent already stopped
  ⇒ leftover Cilium hijack state ⇒ `sudo ./runner-net-cleanup.sh` (or reboot).

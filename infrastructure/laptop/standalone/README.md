# Standalone runner kit — pc-bruno-gpu

Activation kit for using the GPU laptop as a CI machine **outside** the
cluster. It is the sibling of the k3s node lifecycle tooling in
`../README.md` (join/leave/netprobe): nothing here joins, cordons, uncordons
or otherwise touches the cluster node role — the two modes are independent.

## Why standalone

- The 2026-11-12 incident (user VLAN `10.2.251.0/24`, root cause M1-vs-M3
  still an open blocker — `docs/network/runner-node-vlan-isolation-20261112.md`)
  leaves the Cilium **pod-terminated** data plane unidirectional from this
  laptop. The k3s node is cordoned and quarantined **for good**, and
  `runner-netprobe.sh` re-fences it automatically if it ever comes back.
- The hardware is still excellent and idle: RTX A2000 8 GB, 61 GiB RAM.
- Standalone mode never crosses the broken tunnel: GitHub reachability, the
  Kubernetes API (`10.2.248.31:6443`), SSH to `compute-lsis-2` and HTTPS to
  the lima worker are all **host-terminated** flows — measured working from
  this laptop the evening of 2026-11-18.

## What the kit contains

| File | Role |
|---|---|
| `bin/resolve-cluster-ip.sh` | Prints the CURRENT InternalIP of `lima-k3s-agent` (kubectl via node-ops kubeconfig, ssh fallback). No hardcoded IP anywhere. |
| `bin/sync-ebruno-hosts.sh` | Maintains a managed `# BEGIN gitops-standalone (managed)` block in `/etc/hosts`. Default `--dry-run`; `--write` needs root. |
| `systemd/ebruno-hosts-sync.service` + `.timer` | Re-points `/etc/hosts` at boot + every 15 min (the worker address is a DHCP lease). |
| `bin/gh-runner-install.sh` | Phase 1: installs + registers a GitHub Actions runner (label `gpu-laptop`). |
| `bin/gh-runner-deregister.sh` | Phase 1 reversal: stop, uninstall, deregister, delete dir. |
| `bin/wp-agent-install.sh` | Phase 2 (**blocked**, see below): stages the Woodpecker agent under `./wp-agent/`. |
| `systemd/wp-runner-tunnel.service` | Phase 2 option (a): SSH tunnel exposing the cluster gRPC on `127.0.0.1:9000`. |

Everything is **kit-only**: this repo ships scripts + units; installing a
service is an explicit human `sudo` step, done from the laptop itself.
The laptop's k3s-agent stays in its resting state (stopped); standalone
mode does not require it at all.

## Dynamic cluster-IP resolution — read this first

`lima-k3s-agent` serves HTTPS `:443` (Traefik, valid `*.ebruno.fr` certs) on
its current InternalIP (`10.2.248.247` tonight) — **but that is a DHCP lease**
on a stable MAC. The address may change on any renewal, so:

- nothing in this kit hardcodes it — `resolve-cluster-ip.sh` reads the live
  value from the node object (`kubectl get node lima-k3s-agent` through the
  node-ops kubeconfig; ssh fallback via `compute-lsis-2`);
- `ebruno-hosts-sync` keeps the managed `/etc/hosts` block pointed at the
  live value; the timer heals a lease change within ≤ 15 min (or run
  `sudo ./bin/sync-ebruno-hosts.sh --write` right after one);
- if resolution fails (VPN down, worker gone), the sync script exits non-zero
  and **leaves the previous block untouched** — a stale mapping is preferred
  over an empty one, and it never rewrites `/etc/hosts` on a failed resolve;
- `10.2.248.31:80/443` is DEAD from this laptop (campus M1: pod-terminated
  traffic, ServiceLB DNAT onto a remote Traefik pod). The VIP is deliberately
  never mapped here. SSH to `10.2.248.247` is refused tonight — never target
  it for shell flows; `compute-lsis-2` is the ssh hop.

## Prerequisites

- VPN up; `~/.kube/node-ops.conf` present (written by `../install.sh`).
- Key-based, non-interactive ssh to `compute-lsis-2` works:
  `ssh -o BatchMode=yes -o ConnectTimeout=5 compute-lsis-2 hostname`
- `curl`, `tar`, `git` available; arch is `x86_64`.
- Sanity check of the whole resolution chain:

```bash
cd ~/gitops/infrastructure/laptop/standalone
./bin/resolve-cluster-ip.sh
```

Expected: one IPv4 line on stdout (a `resolved ... via ...` note goes to
stderr). Compare with the raw lookup when in doubt:

```bash
kubectl --kubeconfig ~/.kube/node-ops.conf --request-timeout=15s get node lima-k3s-agent -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
```

## Phase 1 — GitHub Actions runner (ready to run)

The runner is registered against the **organisation**, labelled
`gpu-laptop`, `--no-default-labels`: workflows must opt in explicitly.
Bare mode — see "Known limits" before scheduling container jobs.

1. Human, in the browser: create a one-time registration token at
   `https://github.com/organizations/ebpro-org/settings/runners/new`
   (org Settings → Security → General → Self-hosted runners → New runner).
   The token expires after ~1 h. It is pasted at the script's hidden prompt —
   never typed into argv, never logged by the kit.
2. Install (the `actions-runner/` dir appears under the current directory;
   an existing non-empty install makes the script stop — run the deregister
   script first):

```bash
cd ~/gitops/infrastructure/laptop/standalone
OWNER=ebpro-org LABELS=gpu-laptop ./bin/gh-runner-install.sh
```

   Without passwordless sudo the script finishes the registration and prints
   the two `sudo ./svc.sh ...` commands to run by hand.
3. Verify the service and the UI entry (label `gpu-laptop`, Idle):

```bash
cd ~/gitops/infrastructure/laptop/standalone/actions-runner
sudo ./svc.sh status
```

4. Reverse at any time (stops the service, deregisters via a fresh token,
   deletes the directory after confirmation — `--yes` skips the prompt):

```bash
cd ~/gitops/infrastructure/laptop/standalone
./bin/gh-runner-deregister.sh
```

### Activate the hosts sync (one-time, needs sudo)

Dry-run first — it prints the exact diff and writes nothing:

```bash
cd ~/gitops/infrastructure/laptop/standalone
./bin/sync-ebruno-hosts.sh --dry-run
```

Then install the units and arm the timer (paths in the `.service` assume
`~/gitops`; adjust + re-copy if the checkout moves — same install-by-hand
pattern as the netprobe units in `../README.md`):

```bash
cd ~/gitops/infrastructure/laptop/standalone
sudo cp systemd/ebruno-hosts-sync.service systemd/ebruno-hosts-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ebruno-hosts-sync.timer
```

Verify:

```bash
systemctl list-timers ebruno-hosts-sync.timer
grep -A5 'BEGIN gitops-standalone' /etc/hosts
curl -sI --connect-timeout 5 --max-time 15 https://gitea.ebruno.fr/ -o /dev/null -w 'gitea via hosts-block: %{http_code}\n'
```

Any HTTP code (even 401) proves the mapping + TLS path work; `000` means the
lease moved faster than the timer or the worker is down — re-run
`sudo ./bin/sync-ebruno-hosts.sh --write`.

## Phase 2 — Woodpecker agent (BLOCKED pending the gRPC exposure decision)

Measured 2026-11-18: Woodpecker's agent gRPC (Service `woodpecker-server`
port 9000, ns `ci`) answers **RST on every joinable IP** — Traefik routes
HTTP only and there is no NodePort. An agent started today has nothing to
dial. Two ways out:

- **(a) tunnel route** — works today, zero cluster change:
  `systemd/wp-runner-tunnel.service` keeps an SSH tunnel
  laptop → `compute-lsis-2` → `kubectl port-forward` up, landing the gRPC on
  `127.0.0.1:9000`.
- **(b) real exposure** — a TCPRoute/NodePort for gRPC decided **in this
  repo** and reconciled by ArgoCD. Deliberately out of this kit's scope
  (cluster change, and the Golden Rules keep it a git + human decision).

Tunnel first (user unit — it needs your ssh keys; linger keeps it up without
an open session):

```bash
cd ~/gitops/infrastructure/laptop/standalone
mkdir -p ~/.config/systemd/user
cp systemd/wp-runner-tunnel.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wp-runner-tunnel.service
loginctl enable-linger bruno
timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000' && echo TUNNEL_UP
```

Stage the agent (writes only under `./wp-agent/`: binary + 0600 `env` +
generated unit; the agent secret comes from the woodpecker-server deployment
env read on the cluster — you paste it at the hidden prompt):

```bash
cd ~/gitops/infrastructure/laptop/standalone
WP_SERVER=localhost:9000 ./bin/wp-agent-install.sh
```

Installing the generated unit is the documented human step echoed at the end
of the script (copy to `~/.config/systemd/user/`, `systemctl --user enable
--now wp-agent.service`). Under option (b), set `WP_SERVER` to the exposed
address instead and skip the tunnel.

## Known limits

- **DHCP lease churn.** The `*.ebruno.fr` mapping is only ever as fresh as the
  last sync (≤ 15 min, immediate at boot). A lease change inside that window
  = brief staleness; run the `--write` sync by hand to heal instantly.
- **HTTPS via the lima worker only.** `10.2.248.31` (VIP → remote Traefik pod)
  never works from this network; do not "fix" hosts entries back to it.
- **Bare workspace, no docker.** The laptop has no docker daemon: jobs that
  declare containers must ignore the `gpu-laptop` label (opt-in labels +
  `runs-on` choices in the workflows are the fence). Same story for
  Woodpecker: stage (a) is `WOODPECKER_BACKEND_LOCAL=true` only.
- **Registration tokens are ~1 h one-shots.** Configure right after creating;
  the svc.sh step failing later means "fresh token + re-run installer".
- **Tunnel flaps off-VPN.** `ExitOnForwardFailure` + `Restart=on-failure`
  make a dropped VPN a self-healing restart loop, not a silent lie; the
  agent simply waits for `127.0.0.1:9000`.
- **No container isolation** for standalone jobs: they run as `RUN_USER` on
  the workstation — treat anything scheduled onto `gpu-laptop` as running
  directly on bruno's laptop.

# Runner-node fence (`fence-runner-node.sh`)

Control-plane-side SOP for fencing a K3s CI runner node **without freezing ARC**.
The tool runs where the API server is reachable — an admin / control-plane host —
and never on the node being fenced. It is a single self-contained bash script
(`fence-runner-node.sh`, no dependencies beyond `kubectl` and `bash`).

## The problem this closes (CI-1: cordon is not a fence)

`kubectl cordon` only sets `spec.unschedulable` — it does **not** evict pods that
are already scheduled. On **2026-11-12** `pc-bruno-gpu` was fenced by cordon
alone and the two ARC `EphemeralRunner` pods still bound to it stayed in
`Init:ImagePullBackOff` for **~5 h**, silently consuming **100 %** of
`maxRunners: 2`. The listener therefore created nothing for the two queued jobs
and CI was frozen while every app looked healthy. The two smoking-gun
observations, verbatim:

```
kubectl get ephemeralrunnerset -n arc-runners
  ebpro-org-hflxm DESIRED=2 CURRENT=2 PENDING=2 RUNNING=0
```

```
cmd/ghalistener/scaler.(*Scaler).setDesiredWorkerState
  "assigned job":2,"decision":2,"min":0,"max":2,"currentRunnerCount":2
```

This is the **second** incident of the class: on **2026-10-13** zombie runner pods
held ARC capacity after an auto-drain that silently skipped because the laptop
was off-VPN and could not reach the API. Both incidents say the same thing —
**laptop-side hooks are not a reliable fence**; the cleanup must be executable
from the healthy control-plane side, which is why this tool exists.

**Namespaces — never confuse them:** runner **pods** live in `arc-runners`; the
controller and the listeners live in `actions-runner-controller`.

## Four-layer fence model

| # | Layer | What it does | Operative today? | Why |
|---|---|---|---|---|
| 1 | `spec.unschedulable` (set by `kubectl cordon`) | Blocks **new** pod placement on the node | **Yes — the only operative placement fence** | Proven to survive admission; a hand-written `quarantine:NoSchedule` taint was erased in < 1 s by sibling policies, `spec.unschedulable` was not |
| 2 | Node label `quarantine=true` | Carries **declared intent** | No scheduling effect by itself | Read by `infrastructure/laptop/runner-join.sh`, which hard-stops (exit 1) and refuses to uncordon a labelled node — so the fence survives a human at the keyboard |
| 3 | Kyverno `kubernetes/arc/node-quarantine-taint.yaml` (listed in `kubernetes/arc/kustomization.yaml`) | Would force a `quarantine:NoSchedule` taint | **NOT DEPLOYED** | Its commits are local/unpushed, and its `patchesJson6902` append has **never been validated in admission**. Measured 2026-11-12: a taint written by hand was accepted and erased in < 1 s by the sibling policies, because `Node.spec.taints` is an atomic list (whole-array replacement). This script must not depend on it |
| 4 | Deleting the runner **pods** still bound to the node | Releases the pinned `maxRunners` quota so replacement runners can be created elsewhere | **Yes — the missing layer, added by this tool** | Layers 1–3 change *placement*; only layer 4 removes pods that are already placed and already holding quota |

## Usage

```
Usage:
  fence-runner-node.sh [--dry-run] <node>                  # fence (adds layer 4)
  fence-runner-node.sh [--dry-run] --unfence --yes <node>  # lift the fence
```

| Flag | Effect (from the script's actual behaviour) |
|---|---|
| `--dry-run` | Echoes every mutating command with a `+` prefix and executes **none** of them. The read-only steps still run (node preflight, pod enumeration, post-state, `get ephemeralrunnerset`), so the preview is real cluster state, not a guess |
| `--unfence` | Lift path: removes the `quarantine` label and uncordons the node; the taint removal is printed as a manual step only. Returns **before** the control-plane guard |
| `--yes` | Mandatory companion of `--unfence`. Without it the script prints the C1 data-plane precondition (below) to stderr and exits 1 — **checked before the API preflight**, so the refusal never needs cluster access |
| `--force` | Fence path only: overrides the control-plane guard |
| `-h`, `--help` | Prints the usage above and exits 0 |

Behavioural rules worth knowing before you run it:

- **Exactly one node per invocation.** A second positional argument is refused
  (`only one node may be fenced at a time`). Unknown options exit 1.
- **Non-interactive**, `set -euo pipefail`; it never asks for confirmation.
- **Preflight fails fast:** `kubectl --request-timeout=5s get node <node>`; on
  failure it prints `cannot read node '<node>' — API server unreachable / wrong
  kubeconfig` and stops instead of chaining deeper.
- **Ambient `KUBECONFIG`** is used; override with `export KUBECONFIG=/path/to/kubeconfig`.
  A kubeconfig holding the git-managed `node-ops` ServiceAccount token works too.
- **The only delete it can ever issue is `delete pod -n arc-runners <names>`.** An
  internal guard refuses any other delete target. Pods are deleted **gracefully** —
  no `--force`, no `--grace-period=0`.
- Enumeration is by **field selector** (`--field-selector spec.nodeName=<node>`),
  deliberately not by pod label: an invented ARC label would silently match
  nothing and leave the quota pinned — defeating the whole tool.

### What the fence path prints

```
==> [1/6] Cordon <node> (placement fence — layer 1)
==> [2/6] Label <node> quarantine=true (declared intent — layer 2, read by runner-join.sh)
==> [3/6] Enumerate ARC runner pods still bound to <node>
==> [4/6] Deleting <n> runner pod(s) on <node>: <names>      (or "No runner pods to clear")
==> [5/6] Post-state   → re-enumeration + kubectl get ephemeralrunnerset -n arc-runners
==> [6/6] Lift procedure (the three actions below)
```

## Where to run it (this operator's access path)

The workstation kubeconfig is dead, so the supported path is over ssh to the
control plane. Always preview first:

```bash
timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'export KUBECONFIG=$HOME/.kube/config; bash /tmp/fence-runner-node.sh --dry-run pc-bruno-gpu'
```

The script is **not installed** on the admin host — it must be copied there (or be
otherwise available there) before use. Copy → run → clean up:

```bash
timeout 30 scp -o ConnectTimeout=10 -o BatchMode=yes \
  infrastructure/node-fence/fence-runner-node.sh compute-lsis-2:/tmp/

timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'export KUBECONFIG=$HOME/.kube/config; bash /tmp/fence-runner-node.sh pc-bruno-gpu'

timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'rm -f /tmp/fence-runner-node.sh'
```

### Control-plane guard

The fence path refuses a node carrying `node-role.kubernetes.io/control-plane`
unless `--force` is given, because in this cluster the only other amd64-capable
runner node **is `compute-lsis-2` itself**: `lima-k3s-agent` is arm64 and tainted
`kubernetes.io/arch=arm64:NoSchedule`. Fencing the control plane therefore leaves
amd64 runners nowhere to be scheduled — **CI dead by construction**.

## Pod vs CR — the rule that makes this work

**Delete the runner PODS. Never the `EphemeralRunner` / `EphemeralRunnerSet` CRs.**
With the CRs alive, pod recreation reuses the existing **GitHub-side runner
registration**, so jobs already assigned to those runnerIDs are picked up with
**no manual workflow re-run**. Deleting the CRs risks orphaning those assigned
jobs. *Verified for this ARC version and flow only* (measured 2026-11-12: healthy
runners on `compute-lsis-2` in ~25 s, `PENDING=0 RUNNING=2`, runnerIDs
**14173/14174** resumed on their own).

## Verification checklist after fencing

Run these from the control-plane side after the tool reports `[5/6]`:

| Check | Command | Expected |
|---|---|---|
| No pods left on the node | `kubectl get pods -n arc-runners --field-selector spec.nodeName=<node>` | no rows — the tool prints `Runner pods still on <node>: none` at `[5/6]` |
| Quota released | `kubectl get ephemeralrunnerset -n arc-runners` | `PENDING` draining to **0** and `RUNNING` recovering (measured 2026-11-12: `PENDING=0 RUNNING=2` within ~25 s) |
| Placement fence still up | `kubectl get node <node>` | `SchedulingDisabled` |
| Intent marker still up | `kubectl get node <node> -o jsonpath='{.metadata.labels.quarantine}'` | `true` — the label staying behind is **intended**, not a leak |

If `PENDING` does not drain, the pods were recreated back onto the fenced node —
that means layer 1 is not in effect; re-check `SchedulingDisabled` before anything
else.

## Lifting the fence — THREE actions, not two

The policy is **NOT self-cleaning**. Lifting requires all of:

```bash
kubectl label node <node> quarantine-
kubectl taint nodes <node> quarantine:NoSchedule-   # only if it was ever re-posed
kubectl uncordon <node>
```

`fence-runner-node.sh --unfence --yes <node>` performs the first and the third and
prints the second as a manual step (it cannot know whether a taint was ever
re-posed, and layer 3 is not deployed).

Note also: a clean `runner-leave.sh` **deletes the Node object**, so the label and
the taint vanish with it and must be **re-posed** after any leave/join cycle.

## Unfence precondition (C1) — a measurement, not `Ready`

Before uncordoning, the node's tunnel **data plane** must be proven, on the node:

```bash
cat /sys/class/net/cilium_vxlan/statistics/rx_packets
```

It must move **strictly above 0** under peer→node traffic. On 2026-11-12 that
counter stayed at **0** across **166 240** transmitted packets while the node
reported `Ready` and `NetworkUnavailable=False — Cilium is running`; the tunnel
was unidirectional and CI was dead. **`Ready` proves nothing about the data
plane.** `--unfence` without `--yes` refuses and prints exactly this precondition;
the full incident dossier is `docs/network/runner-node-vlan-isolation-20261112.md`
(§9 / §6.1.2).

## RBAC

**No RBAC change was needed.** The git-managed `node-ops` ServiceAccount
(`kubernetes/arc/node-ops-rbac.yaml`) already grants `pods: get,list,delete`
cluster-wide, plus `nodes: get,list,patch`, `pods/eviction: create` and
`daemonsets: get,list` — every right this script uses.

## Standing rulings

- **Nothing is applied to Cilium.** Cilium is outside git and outside ArgoCD, and
  a standing ruling says apply nothing to it. This tool touches node objects and
  pods only.
- **`pc-bruno-gpu` stays cordoned** until the M1-vs-M3 tcpdump measurement
  discriminates the tunnel failure (2026-11-12). Do not uncordon it.
- **`maxRunners` is deliberately NOT raised** (declined). The defect was dead pods
  silently holding quota, not too little quota.

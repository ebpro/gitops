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

Synopsis, verbatim from `fence-runner-node.sh --help`:

```
Usage:
  fence-runner-node.sh --yes [--dry-run] <node>            # fence (adds layer 4)
  fence-runner-node.sh --unfence --yes [--dry-run] <node>  # lift the fence

Confirmation is mandatory on every mutating path: --yes is REQUIRED to fence
(cordon + quarantine label + graceful deletion of the ARC runner pods on that
node) and to unfence (label removal + uncordon). Without it the script exits 1
before touching the API. --dry-run is exempt because it mutates nothing.

--force overrides the control-plane guard and is almost never what you want: the
only other amd64-capable runner node in this cluster is compute-lsis-2 itself
(lima-k3s-agent is arm64 and tainted kubernetes.io/arch=arm64:NoSchedule), so
fencing the control plane leaves amd64 runners nowhere to be scheduled — CI dead
by construction.

Uses the ambient KUBECONFIG (this runs on an admin / control-plane machine);
override with `export KUBECONFIG=/path/to/kubeconfig`. The git-managed
node-ops ServiceAccount (kubernetes/arc/node-ops-rbac.yaml: nodes
get/list/patch, pods get/list/delete, pods/eviction create) already carries
every right this script needs, so a kubeconfig holding that token works too.
```

| Flag | Effect (from the script's actual behaviour) |
|---|---|
| `--yes` | **Mandatory on every mutating path — fence and unfence alike.** It authorises exactly: fence → cordon + `quarantine=true` label + graceful `delete pod` of the runner pods on that node; unfence → label removal + uncordon. Both gates are checked **before the API preflight**, so a refusal needs no cluster access at all (measured: the refusal path issues **zero** `kubectl` calls) |
| `--dry-run` | The only mode exempt from `--yes`, because it mutates nothing: it echoes every mutating command with a `+` prefix and executes **none** of them. The read-only steps still run (node preflight, node read-back, pod enumeration, `get ephemeralrunnerset`), so the preview is real cluster state, not a guess — and the enumeration line it prints is the **same command string** the executed path runs (one shared template) |
| `--unfence` | Lift path: removes the `quarantine` label, uncordons, then **reads the node back** and exits 1 (`lift INCOMPLETE`) if either action did not hold. The taint removal is printed as a manual step only. Returns **before** the control-plane guard |
| `--force` | Overrides the control-plane guard. Using it on `compute-lsis-2` means **CI dead by construction** — `lima-k3s-agent` is arm64 and tainted `kubernetes.io/arch=arm64:NoSchedule`, so no other amd64-capable runner node remains |
| `-h`, `--help` | Prints the usage above and exits 0 |

Behavioural rules worth knowing before you run it:

- **`bash` 4 or newer is required** (`mapfile`, which consumes the whole
  multi-line enumeration). On older bash the script refuses immediately with
  `ERROR: bash 4 or newer is required (mapfile)` — `read -a` reads **one line
  only**, which is exactly how the original tool under-cleared: 1 of 2 pods
  deleted, exit 0, quota still pinned, CI still frozen.
- **Exactly one node per invocation.** A second positional argument is refused
  (`only one node may be fenced at a time`). Unknown options exit 1.
- **Non-interactive**, `set -euo pipefail`; it never asks for confirmation —
  `--yes` *is* the confirmation, and its absence is a hard refusal.
- **Preflight fails fast:** `kubectl --request-timeout=5s get node <node>`; on
  failure it prints `cannot read node '<node>' — API server unreachable / wrong
  kubeconfig` and stops instead of chaining deeper. Reading the node as JSON is
  **fatal on failure** too — nothing is ever inferred about a fence (or about
  control-plane status) from a query that did not succeed.
- **Ambient `KUBECONFIG`** is used; override with `export KUBECONFIG=/path/to/kubeconfig`.
  A kubeconfig holding the git-managed `node-ops` ServiceAccount token works too.
- **Every `kubectl` call carries `--request-timeout=`** (5 s preflight, 20 s
  otherwise) so the tool can never hang against an unreachable API server.
- **The only delete it can ever issue is `delete pod -n arc-runners <names>`.** An
  internal guard checks the very argv array that is about to be executed — target,
  namespace, one name per enumerated pod, no option-like token, no `--force` /
  `--grace-period` — and aborts on anything else. Pods are deleted **gracefully**.
- **Every victim name is validated before anything is deleted** (`[A-Za-z0-9]`
  with `._-` inside). A name with a space, a leading `-`, a `/` or a glob
  character aborts the run **without deleting anything** — it never becomes a
  dangerous argument.
- Enumeration is by **field selector** (`--field-selector spec.nodeName=<node>`),
  deliberately not by pod label: an invented ARC label would silently match
  nothing and leave the quota pinned — defeating the whole tool.
- **A failed enumeration is never an empty one:** it dies with
  `enumeration of arc-runners pods on <node> FAILED — no delete attempted`.


### What the fence path prints

Seven steps, `[1/7]` … `[7/7]`:

```
==> [1/7] Cordon <node> (placement fence — layer 1)
==> [2/7] Label <node> quarantine=true (declared intent — layer 2, read by runner-join.sh)
==> [3/7] Verify the fence mutations actually hold (node read-back)
==> [4/7] Enumerate ARC runner pods still bound to <node>
==> [5/7] Clear runner pods on <node> (layer 4 — releases the pinned ARC quota)
          Deleting <n> runner pod(s) on <node>: <one name per line>   (or "No runner pods to clear")
==> [6/7] Post-state   → kubectl get ephemeralrunnerset -n arc-runners
==> [7/7] Lift procedure (the three actions below)
```

Between `[5/7]` and `[6/7]`, on the executed (non-`--dry-run`) path, the tool
**re-enumerates the node** and prints either `Verified: no arc-runners pod
remains on <node>.` or the residual failure below. Under `--dry-run` the
re-check is skipped (nothing was deleted) and `[3/7]` reports the current
node state as information only.

### Failure modes (all exit non-zero — the tool never reports success it has not verified)

| Exit | Printed | Meaning / action |
|---|---|---|
| 1 | `refusing to mutate cluster state without an explicit --yes` + the 3 authorised actions | Fence path without `--yes` and without `--dry-run`. No `kubectl` call was made at all |
| 1 | `--unfence requires --yes, and only AFTER this precondition held:` + C1 | Unfence without `--yes`. No `kubectl` call was made |
| 1 | `cannot read node '<node>' — API server unreachable / wrong kubeconfig` | Preflight failed |
| 1 | `refusing to fence '<node>': it carries node-role.kubernetes.io/control-plane` | Control-plane guard. Only `--force` overrides it — see the warning below |
| 1 | `fence INCOMPLETE on <node> — the exact actions to re-run are listed above` | `[3/7]` node read-back shows layer 1 (`spec.unschedulable`) or layer 2 (the `quarantine` label) missing. It prints the **exact** `kubectl --request-timeout=20s cordon <node>` / `… label node <node> quarantine=true --overwrite` to re-run |
| 1 | `the fence did NOT clear the runner quota on <node>` + every residual pod name + `The ARC maxRunners quota may STILL be pinned — CI can stay frozen` | **Residual-pod failure:** pods remain on the node after the delete (or the post-delete enumeration itself failed). Re-run the tool; if it persists delete **only those pods** — never the CRs — and find out why they come back |
| 1 | `lift INCOMPLETE: <node> still has .spec.unschedulable set` / `still carries quarantine=true` | The unfence mutations did not hold; the exact re-run command is printed |
| 1 | `INTERNAL ERROR: …` | A self-check tripped (delete argv, collected-count vs enumerated-count, partial name list). Treat as a bug in the tool, not as a no-op: nothing was deleted |

**Why a missing layer 2 is dangerous even when layer 1 holds:**
`infrastructure/laptop/runner-join.sh` reads **only** the `quarantine` label and
the quarantine taint — never `spec.unschedulable`. A cordoned-but-unlabelled node
is therefore *not* protected against a laptop-side join: the join would uncordon
it and bring a node with a broken data plane straight back into CI — the original
2026-11-12 failure. That is why `[3/7]` calls layer 2 a MISS and dies rather than
reporting a partial fence as a success, and why it says "Fix layer 2 before
walking away".

## Where to run it (this operator's access path)

The workstation kubeconfig is dead, so the supported path is over ssh to the
control plane. Always preview first:

```bash
timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'export KUBECONFIG=$HOME/.kube/config; bash /tmp/fence-runner-node.sh --dry-run pc-bruno-gpu'
```

The script is **not installed** on the admin host — it must be copied there (or be
otherwise available there) before use. The host needs **bash ≥ 4** (`mapfile`);
`compute-lsis-2` runs bash 5.2.21. Copy → preview → run → clean up:

```bash
timeout 30 scp -o ConnectTimeout=10 -o BatchMode=yes \
  infrastructure/node-fence/fence-runner-node.sh compute-lsis-2:/tmp/

# preview — read-only, no --yes needed
timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'export KUBECONFIG=$HOME/.kube/config; bash /tmp/fence-runner-node.sh --dry-run pc-bruno-gpu'

# the real fence — --yes is mandatory, without it the tool exits 1 and changes nothing
timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'export KUBECONFIG=$HOME/.kube/config; bash /tmp/fence-runner-node.sh --yes pc-bruno-gpu'

timeout 60 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes compute-lsis-2 \
  'rm -f /tmp/fence-runner-node.sh'
```

### Control-plane guard

The fence path refuses a node carrying the `node-role.kubernetes.io/control-plane`
**label** unless `--force` is given. The guard tests the label key's **existence**
in the node JSON — never its value. Measured live here on 2026-11-13
(`kubectl get node compute-lsis-2 -o json`): `compute-lsis-2` carries
`"node-role.kubernetes.io/control-plane": "true"`, and the two workers
(`pc-bruno-gpu`, `lima-k3s-agent`) carry **no** `node-role` label at all, so the
guard does not fire on them. A value comparison would be version-dependent — and
the previous implementation compared the extracted **value** against the full
**key** string, a comparison that can never be equal under any value; that was
the real defect. The grep is precise: in that node JSON the quoted key
`"node-role.kubernetes.io/control-plane"` matches exactly **once** and the
`managedFields` form `"f:node-role.kubernetes.io/control-plane"` matches **zero**
times, so there is no managedFields false positive. A node whose JSON cannot be
read is treated as fatal: the guard exits 1 rather than assume "not a control
plane".

`--force` is the only override, and it is almost never right: the only other
amd64-capable runner node **is `compute-lsis-2` itself** — `lima-k3s-agent` is
arm64 and tainted `kubernetes.io/arch=arm64:NoSchedule` — so fencing the control
plane leaves amd64 runners nowhere to be scheduled: **CI dead by construction**.

## Pod vs CR — the rule that makes this work

**Delete the runner PODS. Never the `EphemeralRunner` / `EphemeralRunnerSet` CRs.**
With the CRs alive, pod recreation reuses the existing **GitHub-side runner
registration**, so jobs already assigned to those runnerIDs are picked up with
**no manual workflow re-run**. Deleting the CRs risks orphaning those assigned
jobs. *Verified for this ARC version and flow only* (measured 2026-11-12: healthy
runners on `compute-lsis-2` in ~25 s, `PENDING=0 RUNNING=2`, runnerIDs
**14173/14174** resumed on their own).

## Verification checklist after fencing

Run these from the control-plane side after the tool reports `[5/7]`:

| Check | Command | Expected |
|---|---|---|
| No pods left on the node | `kubectl get pods -n arc-runners --field-selector spec.nodeName=<node>` | no rows — the tool prints `Verified: no arc-runners pod remains on <node>.` right after `[5/7]` |
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
plane.** This block prints on **every** unfence that will actually uncordon —
`--yes` included (an earlier revision printed it only in the refusal branch, so
passing `--yes` suppressed the very precondition it is supposed to assert).
`--yes` is the **operator's assertion** that C1 was measured: the tool cannot
read the node's tunnel from the control plane. Without `--yes` the unfence
refuses outright, before any API call. The full incident dossier is
`docs/network/runner-node-vlan-isolation-20261112.md` (§9 / §6.1.2).

## RBAC

**No RBAC change was needed.** The git-managed `node-ops` ServiceAccount
(`kubernetes/arc/node-ops-rbac.yaml`) already grants `pods: get,list,delete`
cluster-wide, plus `nodes: get,list,patch`, `pods/eviction: create` and
`daemonsets: get,list` — every right this script uses.

## Verified by execution (2026-11-13)

What this rewrite is actually proven by — stated at the level the evidence supports.

**Proven by fake-`kubectl` shim traces** (20 cases, results in `/tmp/fn/results.txt`
at the time; the shim records every argv it is called with):

- the multi-pod fix — 2 and 3 enumerated victims produce **one**
  `delete pod -n arc-runners` argv carrying **all** the names; zero victims
  issues **no** delete at all
- a failing enumeration dies **without** attempting a delete
- invalid names (a space, a leading `-`) abort before any delete
- a non-empty post-delete re-check exits **non-zero** and names the residuals
- both `--yes` gates refuse with a completely **empty** kubectl argv log
- `--unfence --yes` prints C1 and runs `label … quarantine-` (no `--overwrite`)
  followed by `uncordon`
- an empty-valued control-plane label JSON still triggers the refusal, and
  `--force` overrides it; a `managedFields`-only occurrence does **not** trigger it
- 97 logged kubectl invocations, **0** missing `--request-timeout`

**Proven live, read-only only**:

- `--dry-run` against `compute-lsis-2` refuses at the control-plane guard when
  shown the real node JSON
- `--dry-run` against `pc-bruno-gpu` prints the full 7-step preview ending in
  "No runner pods to clear"
- the guard-string counts quoted above (1 vs 0 matches)
- `pc-bruno-gpu` state identical before and after (`true|unsched=true|taints=workload`),
  zero runner pods, `ephemeralrunnerset` rows unchanged

**NOT exercised**: **no live fence or unfence was ever executed** — no real
cordon, label, uncordon, or pod delete. The delete path's behaviour against a
real API server is therefore proven by shim argv trace, **not** by a live
deletion. The remaining untested scenario is a real fence on a node that
genuinely has stuck runner pods on it.

Static checks: `bash -n` clean and `shellcheck -s bash` clean at **all**
severities. The review finding this rewrite closes was a **BLOCK**.

## Standing rulings

- **Nothing is applied to Cilium.** Cilium is outside git and outside ArgoCD, and
  a standing ruling says apply nothing to it. This tool touches node objects and
  pods only.
- **`pc-bruno-gpu` stays cordoned** until the M1-vs-M3 tcpdump measurement
  discriminates the tunnel failure (2026-11-12). Do not uncordon it.
- **`maxRunners` is deliberately NOT raised** (declined). The defect was dead pods
  silently holding quota, not too little quota.

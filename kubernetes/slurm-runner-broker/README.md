# slurm-runner-broker — Operator Runbook (Phase 1)

Brings up the ephemeral-runner tier: an in-cluster broker (`Deployment`
`slurm-runner-broker`, currently `replicas: 0`) that polls GitHub org
`ebpro-org` for queued runs labelled `[self-hosted, linux, x64, hpc]` and
`sbatch`-es one ephemeral runner per queued job onto SMS partition `ouranos`
over `ssh emmanuel.bruno@sms-ext.lis-lab.fr` (forced command
`/usr/local/bin/ebrunner-gate` — see step A3 +
[`../../slurm-runner-broker/ebrunner-gate.sh`](../../slurm-runner-broker/ebrunner-gate.sh)).

Broker code/image scaffold: [`../../slurm-runner-broker/`](../../slurm-runner-broker/README.md).

Vault leaf `secret/data/slurm/broker` was provisioned 2026-10-19 and updated
the same day: it now carries `ssh_private_key` / `ssh_public_key` / `sms_host`
(= `sms-ext.lis-lab.fr`) / `slurm_user` / `known_hosts` (ed25519 pin — see A2).
ESO policy `external-secrets` (`secret/data/*` read+list) already covers it —
verified, no Vault change needed for ESO reads.

**The broker will not start** until steps A–C are complete: the broker key is
not yet in SMS `authorized_keys` and the forced-command gate is not yet
installed (step A), and no image is pushed yet (step C). The `replicas: 0`
Deployment keeps everything inert meanwhile.

Brokered key (audit fingerprint):
`SHA256:LfCHXlnnJ8NqjyF0eg1/XJrr5z3eoZVNe4cSpo3wNv4` (ED25519)

---

## Step A — SMS side: install the gate, authorize the broker key, verify `known_hosts`

> **Connectivity (verified 2026-10-19):** the submit gateway is
> `sms-ext.lis-lab.fr` → `192.168.4.2` with TCP/22 **OPEN** from both the
> workstation and in-cluster (the previous cluster-internal gateway name is
> dead: cluster-side NXDOMAIN). Broker-pod egress SNATs to the k3s node
> uplink IPs (`10.2.248.31` amd64 / `10.2.248.247` arm64), so the key's
> `from=` allowlist is `10.2.248.0/24`. Do step A over your own human ssh
> session to the SMS.

### A1. Paste the hardened public key into your SMS authorized_keys

> **Ordering:** the line pins `command="/usr/local/bin/ebrunner-gate"` — until
> A3 installs the gate, broker-key sessions fail (missing forced command).
> That is intentional: the key is inert until both halves exist.

Run on SMS (any authorized access path):

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
echo 'restrict,from="10.2.248.0/24",no-pty,command="/usr/local/bin/ebrunner-gate" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNORGDO6WO6brOnHO8geiseMqyf93WymLowzDHRq8Si slurm-runner-broker@ebpro-org' >> ~/.ssh/authorized_keys
```

Verify (once A3's gate is installed — this is one of the gate's allow-listed
commands; expect `/home/emmanuel.bruno`, no password):
`ssh -o BatchMode=yes emmanuel.bruno@localhost 'printf %s "$HOME"' && echo BROKER_KEY_OK`

### A2. Verify the `known_hosts` pin (ALREADY seeded in Vault — verify-only)

The host-key pin was written into the Vault leaf on 2026-10-19:
`sms-ext.lis-lab.fr ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINSgk2mAdOLBfQnjiabHLr1D65kPeMm52zc21uN+CYBc`
(host-key fingerprint `SHA256:hld4/x9bw43eb7bdc4oiz72pDykYBh/pzTFin7csaio`). The
hostname-form pin is deliberate: `broker.py` dials `SMS_HOST` with
`StrictHostKeyChecking=yes` + a dedicated `UserKnownHostsFile`, so ssh matches
the name it dialled. Nothing to write here — **verify only**:

```sh
# 1. key list (5 entries incl. known_hosts) + sms_host value
kubectl exec -i vault-0 -n vault -c vault \
  -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT" \
  vault kv get -format=json secret/slurm/broker \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['data']; print(sorted(d)); print(d['sms_host'])"
# expect: ['known_hosts','slurm_user','sms_host','ssh_private_key','ssh_public_key'] + sms-ext.lis-lab.fr

# 2. pinned line prints the expected host-key fingerprint
kubectl exec -i vault-0 -n vault -c vault \
  -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT" \
  vault kv get -field=known_hosts secret/slurm/broker \
  | ssh-keygen -l -f -
# expect: 256 SHA256:hld4/x9bw43eb7bdc4oiz72pDykYBh/pzTFin7csaio ... (ED25519)
```

(Optional independent re-check from any vantage that can reach
`sms-ext.lis-lab.fr:22`: `ssh-keyscan -T 10 sms-ext.lis-lab.fr` and compare the
ed25519 blob byte-for-byte. A mismatch is a **stop condition** — suspect a
man-on-the-side and confirm the key with the SMS admin before touching the pin.)

### A3. Install the `ebrunner-gate` forced command on the SMS

Copy `slurm-runner-broker/ebrunner-gate.sh` from this repo to the SMS and
install it as `/usr/local/bin/ebrunner-gate`, root-owned, mode `0755`. Do this
over your own human ssh session — the broker key cannot do it (that is the
point of the gate):

```sh
# from a machine with this checkout
scp slurm-runner-broker/ebrunner-gate.sh emmanuel.bruno@sms-ext.lis-lab.fr:/tmp/ebrunner-gate
ssh emmanuel.bruno@sms-ext.lis-lab.fr \
  'sudo install -o root -g root -m 0755 /tmp/ebrunner-gate /usr/local/bin/ebrunner-gate && shred -u /tmp/ebrunner-gate'
```

The gate's header comment carries the security model + the exact
authorized_keys line template (must match A1). If `sudo` is unavailable, the
SMS admin performs the install. After A1+A3, run the A1 verify line.

## Step B — SMS side: Harbor login for enroot + NFS cache/logs bootstrap

The compute nodes' `enroot import` authenticates against Harbor using
`~/.netrc` in `$HOME` (NFS-shared — one seed covers all nodes). Credentials
are the same robot account the cluster already uses for node pulls (Secret
`harbor-node-pull` in ns `arc-runners`). **Never print the extracted auth.**

```sh
kubectl get secret harbor-node-pull -n arc-runners -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d \
  | python3 -c 'import json,sys; a=json.load(sys.stdin)["auths"]["harbor.ebruno.fr"]["auth"]; print("machine harbor.ebruno.fr\nlogin %s\npassword %s" % tuple(__import__("base64").b64decode(a).decode().split(":",1)))' \
  | ssh emmanuel.bruno@sms-ext.lis-lab.fr 'umask 077; cat > ~/.netrc && chmod 600 ~/.netrc'
```

One-time NFS bootstrap — `--output=$HOME/logs/ebrunner-%j.out` (broker-resolved
absolute path) is opened by `slurmd` **before** the batch script runs, and the
image cache + logs live in `$HOME` (NFS-shared `nfs-cluster-1:/HOME`, mounted
identically on every node), so ONE mkdir covers the whole cluster:

```sh
ssh emmanuel.bruno@sms-ext.lis-lab.fr \
  'srun -p ouranos mkdir -p $HOME/.cache/ebpro-runner $HOME/logs'
```

> **Multi-node & wiped-scratch semantics:** the first job to see a new image
> digest imports once into the NFS `$HOME/.cache/ebpro-runner` cache and every
> ouranos node reuses it (wipe-surviving; concurrent cross-node imports are
> safe — atomic NFS rename of byte-identical files). Per-job work dirs stay on
> node-local `/scratch`, lazily re-created in-job after any wipe; job logs
> persist under `$HOME/logs`. Jobs opportunistically GC `.tmp.*` import orphans
> older than 4 h in the shared NFS cache (fresh in-progress imports on any node
> are never touched).

## Step C — Build the broker image (Gitea repo)

1. Create Gitea repo `bruno/slurm-runner-broker`; copy the scaffold directory
   [`slurm-runner-broker/`](../../slurm-runner-broker/) **as-is** (broker.py,
   job-template.sh, Dockerfile, .woodpecker.yaml, README.md) and push to `main`.
2. Repo secrets (Woodpecker): `HARBOR_USERNAME` = `robot$library+backstage`,
   `HARBOR_PASSWORD` = robot token from Vault `secret/data/harbor/backstage`
   (same pattern as `bruno/link-shortener`).
3. Pipeline pushes `harbor.ebruno.fr/library/slurm-runner-broker:latest`
   (`library` is a **public** Harbor project — no pull secret anywhere).
4. Confirm: `kubectl run srb-pull-test --image=harbor.ebruno.fr/library/slurm-runner-broker:latest --restart=Never -n default -- true` then
   delete the pod — or simply watch the broker pod come up in step D/E (image
   pull errors surface as `ErrImagePull`).

## Step D — Flip the broker on (git-only)

Edit `deployment.spec.replicas: 0 -> 1` in this directory, signed commit +
push. ArgoCD reconciles the chain (`gitops-platform` → `kubernetes-manifests`
AppSet → app `slurm-runner-broker`). If not picked up within ~2 min, nudge the
chain per repo rules:
`kubectl annotate application gitops-platform -n argocd argocd.argoproj.io/refresh=hard --overwrite`

Smoke the wiring before/after the flip:

```sh
kubectl get externalsecret -n slurm-runner-broker            # both Synced
kubectl get secret slurm-broker-ssh slurm-broker-github -n slurm-runner-broker
kubectl logs deploy/slurm-runner-broker -n slurm-runner-broker | head -5
# expect boot line "broker starting" with config echo; a hard-fail on the
# known_hosts file => Vault leaf pin missing (A2) or ESO not Synced yet.
```

## Step E — Smoke test the tier

Push to any repo in `ebpro-org`:

```yaml
# .github/workflows/hpc-smoke.yaml
name: hpc-smoke
on: workflow_dispatch
jobs:
  hello:
    runs-on: [self-hosted, linux, hpc, x64]
    steps:
      - run: |
          whoami; hostname; scontrol show config | head -5
          nproc; free -g | head -2
```

Expected chain (broker log, JSON lines): `queued run detected` →
`runner registration token minted` → `sbatch dispatched` (job id + env-file
path) → `squeue` poll `R` → GitHub shows runner `ebrunner-<jobid>` online →
job passes → runner `Offline`→ deleted (ephemeral self-deregister), Slurm job
`COMPLETED`, env-file shredded (`ls ~/.ebrunner-*.env` empty).

Failure triage: `sacct -j <id> -X -o jobid,state,exitcode,workdir` +
`cat $HOME/logs/ebrunner-<id>.out` (NFS-shared — readable from the SMS too).

## Step F — Phase-1 limitations / future work

* **No** `container:` jobs, `services:`, dind, container hooks, `actions/cache`.
* Submissions run as your `emmanuel.bruno` Slurm account (usage/accounting
  mixed with interactive work). Phase-2: dedicated `ghaci` account — then
  update Vault `slurm_user` + ConfigMap `SLURM_USER`, no image change.
* Registration tokens are 1 h GitHub-issued, single-use per runner boot,
  shredded at job end. Phase-2: JIT tokens + rotation hardening.
* Broker state is in-memory: a restart may re-dispatch a still-queued run once;
  the duplicate ephemeral runner self-exits and the zombie sweeper deletes its
  registration after >10 min offline (`squeue` reconciliation guards deletion
  of live ones).
* `/scratch` is node-local and periodically wiped: it holds ONLY per-job work
  dirs + the node-local import lock (lazily re-created in-job). The enroot
  image cache is cluster-wide in NFS `$HOME/.cache/ebpro-runner` — one import
  per digest for the whole cluster, no per-node seeding needed on new nodes.
* SMS must keep allowing ssh/22 from `10.2.248.0/24` to `sms-ext.lis-lab.fr`
  (step A banner); the key's `from=` option pins the same source range.
* Key rotation: re-run the Vault provisioning pattern
  `vault kv patch secret/slurm/broker ssh_private_key=... ssh_public_key=...`
  (never in git), replace the authorized_keys line from A1, restart the broker.

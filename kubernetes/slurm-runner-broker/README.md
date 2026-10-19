# slurm-runner-broker — Operator Runbook (Phase 1)

Brings up the ephemeral-runner tier: an in-cluster broker (`Deployment`
`slurm-runner-broker`, currently `replicas: 0`) that polls GitHub org
`ebpro-org` for queued runs labelled `[self-hosted, linux, x64, hpc]` and
`sbatch`-es one ephemeral runner per queued job onto SMS partition `ouranos`
over `ssh emmanuel.bruno@sms-cluster.lis-lab.fr`.

Broker code/image scaffold: [`../../slurm-runner-broker/`](../../slurm-runner-broker/README.md).

Vault leaf `secret/data/slurm/broker` was provisioned 2026-10-19 with
`ssh_private_key` / `ssh_public_key` / `sms_host` / `slurm_user` (version 1).
ESO policy `external-secrets` (`secret/data/*` read+list) already covers it —
verified, no Vault change needed for ESO reads.

**The broker will not start** until steps A–C are complete: `known_hosts` is
still missing from the Vault leaf (by design — see A2) and no image is pushed
yet. The `replicas: 0` Deployment keeps everything inert meanwhile.

Brokered key (audit fingerprint):
`SHA256:LfCHXlnnJ8NqjyF0eg1/XJrr5z3eoZVNe4cSpo3wNv4` (ED25519)

---

## Step A — SMS side: authorize the broker key + seed `known_hosts`

> **Connectivity prerequisite (verified 2026-10-19):** SMS (`10.0.0.101`)
> currently drops TCP/22 **and** ICMP from the 10.2.248.0/24 side — both this
> workstation and in-cluster probes (vault pod `nc -z 10.0.0.101 22`) fail.
> Before go-live, the SMS admin must allow ssh from the k3s node source
> (`compute-lsis-2`, 10.2.248.x) — the broker pod's traffic leaves via that
> node's SNAT. Do step A from an already-authorized access point.

### A1. Paste the public key into your SMS authorized_keys

Run on SMS (any authorized access path):

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNORGDO6WO6brOnHO8geiseMqyf93WymLowzDHRq8Si slurm-runner-broker@ebpro-org' >> ~/.ssh/authorized_keys
```

Verify (should print without password):
`ssh -o BatchMode=yes emmanuel.bruno@localhost true && echo BROKER_KEY_OK`

### A2. Generate `known_hosts` and add it to the Vault leaf

The Vault leaf intentionally lacks `known_hosts` — it can only be minted from
a network position that can reach SMS:22. From **that** machine (not the
cluster, until the firewall allows it):

```sh
ssh-keyscan -T 10 sms-cluster.lis-lab.fr > /tmp/sms-known_hosts
# sanity: expect >=1 line beginning "sms-cluster.lis-lab.fr ssh-ed25519 ..."
grep -c 'ssh-' /tmp/sms-known_hosts
kubectl exec -i vault-0 -n vault -c vault \
  -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT" \
  vault kv patch secret/slurm/broker known_hosts="$(cat /tmp/sms-known_hosts)"
shred -u /tmp/sms-known_hosts
```

(`kv patch` is a read-modify-write: the three existing keys are preserved —
confirmed by the read-back below.)

Verify the leaf is complete (4+1 keys):

```sh
kubectl exec -i vault-0 -n vault -c vault \
  -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT" \
  vault kv get -format=json secret/slurm/broker \
  | python3 -c "import json,sys; print(sorted(json.load(sys.stdin)['data']['data']))"
# expect: ['known_hosts','slurm_user','sms_host','ssh_private_key','ssh_public_key']
```

## Step B — SMS side: Harbor login for enroot + /scratch bootstrap

The compute nodes' `enroot import` authenticates against Harbor using
`~/.netrc` in `$HOME` (NFS-shared — one seed covers all nodes). Credentials
are the same robot account the cluster already uses for node pulls (Secret
`harbor-node-pull` in ns `arc-runners`). **Never print the extracted auth.**

```sh
kubectl get secret harbor-node-pull -n arc-runners -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d \
  | python3 -c 'import json,sys; a=json.load(sys.stdin)["auths"]["harbor.ebruno.fr"]["auth"]; print("machine harbor.ebruno.fr\nlogin %s\npassword %s" % tuple(__import__("base64").b64decode(a).decode().split(":",1)))' \
  | ssh emmanuel.bruno@sms-cluster.lis-lab.fr 'umask 077; cat > ~/.netrc && chmod 600 ~/.netrc'
```

One-time `/scratch` bootstrap — `--output=$S/logs/ebrunner-%j.out` is opened by
`slurmd` **before** the batch script runs, and `/scratch/emmanuel.bruno` is
**node-local**, so the dirs must pre-exist on every `ouranos` node:

```sh
ssh emmanuel.bruno@sms-cluster.lis-lab.fr \
  'srun -p ouranos mkdir -p /scratch/emmanuel.bruno/gha-slurm/{images,work,logs}'
# After adding NEW nodes to ouranos, repeat this line (Phase-2: move log dir to
# the NFS-shared HOME or provision via cluster-wide automount).
```

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
# expect boot line "broker starting" with config echo; hard-fail "known_hosts"
# => step A2 not done yet.
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
`cat /scratch/emmanuel.bruno/gha-slurm/logs/ebrunner-<id>.out` on the node.

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
* `/scratch` is node-local: image cache is per-node (each node pays one import
  per digest, flock-guarded); new ouranos nodes need the step-B mkdir for
  `--output` before their first runner lands.
* SMS firewall must keep allowing k3s-node → sms:22 (step A banner).
* Key rotation: re-run the Vault provisioning pattern
  `vault kv patch secret/slurm/broker ssh_private_key=... ssh_public_key=...`
  (never in git), replace the authorized_keys line from A1, restart the broker.

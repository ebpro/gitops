#!/usr/bin/env python3
"""Slurm ephemeral-runner broker (Phase 1).

Polls GitHub org queued workflow runs; for every queued job whose label set is
a superset of {hpc, self-hosted, linux, x64} it submits ONE Slurm batch job via
ssh+sbatch on the SMS cluster. Each Slurm job boots an ephemeral GitHub Actions
runner (actions/runner binary baked into the digest-pinned enroot image) that
self-registers, runs exactly one job, and deregisters.

Design invariants (Phase 1, see kubernetes/slurm-runner-broker/README.md):
  * Slurm is reached ONLY over ssh (no slurmrestd on SMS).
  * The runner registration token is minted LAZILY at sbatch time and delivered
    over ssh STDIN into a per-dispatch env file under $HOME on the cluster
    (HOME is NFS-shared to compute). It NEVER appears in argv, in the batch
    script text, or in any in-cluster file. The batch job shreds it on EXIT.
  * Broker state is in-memory only. At boot it reconciles live Slurm jobs
    (`squeue --me`, name prefix `ebrunner-`) and org runners (GET /orgs/{org}
    /actions/runners). A restart may therefore cause at most one duplicate
    dispatch per still-queued run; the losing ephemeral runner self-exits and
    the zombie sweeper removes its registration.
  * container:/services:/dind and actions/cache are NOT supported on this tier
    (documented Phase-1 gaps).

Python stdlib only (urllib, subprocess, json, time, logging, hashlib, ...).
GitHub App JWT (RS256) is signed with a minimal pure-stdlib RSA PKCS#1 v1.5
implementation (pow()); keys accepted: PEM PKCS#1 "RSA PRIVATE KEY" and PKCS#8
"PRIVATE KEY".
"""

import base64
import hashlib
import json
import logging
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

# ---------------------------------------------------------------------------
# Configuration (all from the broker-config ConfigMap via envFrom)
# ---------------------------------------------------------------------------
SMS_HOST = os.environ["SMS_HOST"]                      # sms-cluster.lis-lab.fr
SLURM_USER = os.environ["SLURM_USER"]                  # emmanuel.bruno (Phase 1; dedicated ghaci = runbook TODO)
ORG = os.environ["GH_ORG"]                             # ebpro-org
PARTITION = os.environ["SLURM_PARTITION"]              # ouranos
CPUS = os.environ["SLURM_CPUS"]                        # "8"
MEM = os.environ["SLURM_MEM"]                          # "16G"
WTIME = os.environ["SLURM_TIME"]                       # "01:30:00"
RUNNER_IMAGE = os.environ["RUNNER_IMAGE"]              # harbor...@sha256:... (digest REQUIRED)
MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL", "4"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "15"))

API = "https://api.github.com"
USER_AGENT = "slurm-runner-broker/0.1"
REQUIRED_LABELS = frozenset({"hpc", "self-hosted", "linux", "x64"})
RUNNER_PREFIX = "ebrunner-"                            # generic prefix: broker state reconciliation depends on it
RUNNER_NAME_RE = re.compile(r"^" + RUNNER_PREFIX + r"(\d+)$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_\-]+$")            # GH registration tokens are URL-safe alnum
JOB_LIVE_STATES = frozenset({"PD", "CF", "R", "SR", "SO", "CG", "TO"})  # count against MAX_PARALLEL
ZOMBIE_GRACE_SECONDS = 600                             # DELETE org runners offline > 10 min
ENVFILE_MAX_AGE_MIN = 120                              # GC stray env files older than 2 h
SSH_BACKOFF_BASE = 30
SSH_BACKOFF_MAX = 300

GH_CREDS_DIR = os.environ.get("GH_CREDS_DIR", "/etc/slurm-broker/github")
SSH_KEY = os.environ.get("SSH_KEY", "/home/broker/.ssh/id_ed25519")
SSH_PUB = os.environ.get("SSH_PUB", "/home/broker/.ssh/id_ed25519.pub")
KNOWN_HOSTS = os.environ.get("SSH_KNOWN_HOSTS", "/home/broker/.ssh/known_hosts")
TEMPLATE_PATH = os.environ.get("JOB_TEMPLATE", "/app/job-template.sh")


class JsonLogFormatter(logging.Formatter):
    def format(self, record):
        payload = {"ts": round(time.time(), 3), "level": record.levelname.lower(),
                   "event": record.getMessage()}
        for k, v in getattr(record, "fields", {}).items():
            payload[k] = v
        return json.dumps(payload, default=str)


log = logging.getLogger("broker")
_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(JsonLogFormatter())
log.addHandler(_h)
log.setLevel(logging.INFO)


def ainfo(**kw):
    log.info(kw.pop("event", "info"), extra={"fields": kw})


# ---------------------------------------------------------------------------
# Minimal RSA / PKCS#1 v1.5 / JWT (stdlib only)
# ---------------------------------------------------------------------------
_SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


def _der_len(buf, pos):
    lead = buf[pos]
    pos += 1
    if lead < 0x80:
        return lead, pos
    nbytes = lead & 0x7F
    if nbytes == 0 or nbytes > 8:
        raise ValueError("malformed DER length")
    return int.from_bytes(buf[pos:pos + nbytes], "big"), pos + nbytes


def _der_int(buf, pos):
    if buf[pos] != 0x02:
        raise ValueError("expected INTEGER at %d" % pos)
    ln, pos = _der_len(buf, pos + 1)
    return int.from_bytes(buf[pos:pos + ln], "big"), pos + ln


def _der_seq(buf, pos):
    if buf[pos] != 0x30:
        raise ValueError("expected SEQUENCE")
    ln, pos = _der_len(buf, pos + 1)
    return buf[pos:pos + ln], pos + ln


def _parse_pkcs1(der):
    content, _ = _der_seq(der, 0)
    vals, pos = [], 0
    for _ in range(9):
        v, pos = _der_int(content, pos)
        vals.append(v)
    _version, n, e, d = vals[0], vals[1], vals[2], vals[3]
    return n, e, d


def _load_rsa_private_pem(pem_text):
    """Return (n, e, d) from a PEM RSA key (PKCS#1 or PKCS#8)."""
    m = re.search(r"-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----", pem_text, re.S)
    if not m:
        raise ValueError("no PEM block found (expected BEGIN RSA PRIVATE KEY or PRIVATE KEY)")
    label, body = m.group(1), m.group(2)
    der = base64.b64decode(re.sub(r"\s+", "", body))
    if label == "RSA PRIVATE KEY":
        return _parse_pkcs1(der)
    if label == "PRIVATE KEY":  # PKCS#8: SEQ { INT ver, SEQ alg, OCTET STRING pkcs1 }
        content, _ = _der_seq(der, 0)
        _, pos = _der_int(content, 0)
        _, pos = _der_seq(content, pos)
        if content[pos] != 0x04:
            raise ValueError("PKCS#8: expected OCTET STRING")
        ln, pos = _der_len(content, pos + 1)
        return _parse_pkcs1(content[pos:pos + ln])
    raise ValueError("unsupported PEM label: %s (OpenSSH format not accepted)" % label)


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _rsa_pkcs1_sign(priv, message):
    n, _e, d = priv
    k = (n.bit_length() + 7) // 8
    digest_info = _SHA256_PREFIX + hashlib.sha256(message).digest()
    pad_len = k - len(digest_info) - 3
    if pad_len < 8:
        raise ValueError("RSA key too small for RS256")
    block = b"\x00\x01" + (b"\xff" * pad_len) + b"\x00" + digest_info
    sig = pow(int.from_bytes(block, "big"), d, n)
    return sig.to_bytes(k, "big")


def _app_jwt(app_id, priv):
    now = int(time.time())
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id},
                                separators=(",", ":")).encode())
    signing_input = header + b"." + claims
    return (signing_input + b"." + _b64url(_rsa_pkcs1_sign(priv, signing_input))).decode()


# ---------------------------------------------------------------------------
# GitHub App installation auth (token cached 55 min)
# ---------------------------------------------------------------------------
class GitHubClient:
    def __init__(self):
        with open(os.path.join(GH_CREDS_DIR, "github_app_id")) as f:
            self.app_id = f.read().strip()
        with open(os.path.join(GH_CREDS_DIR, "github_app_installation_id")) as f:
            self.installation_id = f.read().strip() or None
        with open(os.path.join(GH_CREDS_DIR, "github_app_private_key")) as f:
            self._priv = _load_rsa_private_pem(f.read())
        self._token = None
        self._token_exp = 0.0

    def _installation_token(self):
        if self._token and time.time() < self._token_exp:
            return self._token
        if not self.installation_id:
            raise RuntimeError("github_app_installation_id missing")
        data = self._raw("POST",
                         "/app/installations/%s/installation_tokens" % self.installation_id,
                         body={})
        self._token = data["token"]
        exp = time.time() + 3300  # 55 min hard cache cap (tokens live 1 h)
        iso = data.get("expires_at")
        if iso:
            try:
                t = time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
                exp = min(exp, time.mktime(t) - time.timezone - 60)
            except (ValueError, AttributeError):
                pass
        self._token_exp = exp
        ainfo(event="installation_token_refreshed", ttl_s=int(exp - time.time()))
        return self._token

    def _raw(self, method, path, body=None):
        req = urllib.request.Request(API + path, method=method)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Authorization", "Bearer " + _app_jwt(self.app_id, self._priv))
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, data=data, timeout=30) as r:
            return json.loads(r.read() or b"{}")

    def _inst(self, method, path, body=None):
        """API call with the installation token; one transparent refresh on 401."""
        for attempt in (1, 2):
            try:
                return self._raw_with_token(method, path, body)
            except urllib.error.HTTPError as e:
                if e.code == 401 and attempt == 1:
                    self._token = None
                    continue
                raise
        raise RuntimeError("unreachable")

    def _raw_with_token(self, method, path, body):
        req = urllib.request.Request(API + path, method=method)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Authorization", "Bearer " + self._installation_token())
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, data=data, timeout=30) as r:
            payload = r.read()
            return json.loads(payload) if payload.strip() else {}

    # -- endpoints used -----------------------------------------------------
    def queued_runs(self):
        out, page = [], 1
        while True:
            d = self._inst("GET", "/orgs/%s/actions/runs?status=queued&per_page=100&page=%d"
                           % (ORG, page))
            out.extend(d.get("workflow_runs", []))
            if page * 100 >= d.get("total_count", 0) or not d.get("workflow_runs"):
                return out
            page += 1

    def queued_hpc_jobs(self, repo_full_name, run_id):
        d = self._inst("GET", "/repos/%s/actions/runs/%s/jobs" % (repo_full_name, run_id))
        jobs = []
        for j in d.get("jobs", []):
            if j.get("status") != "queued":
                continue
            labels = {l.lower() for l in j.get("labels", [])}
            if REQUIRED_LABELS.issubset(labels):
                jobs.append(j)
        return jobs

    def registration_token(self):
        d = self._inst("POST", "/orgs/%s/actions/runners/registration-token" % ORG, body={})
        tok = d["token"]
        if not TOKEN_RE.match(tok):
            raise RuntimeError("unexpected registration token charset")
        return tok

    def runners(self):
        d = self._inst("GET", "/orgs/%s/actions/runners?per_page=100" % ORG)
        return d.get("runners", [])

    def delete_runner(self, runner_id):
        self._inst("DELETE", "/orgs/%s/actions/runners/%s" % (ORG, runner_id))


# ---------------------------------------------------------------------------
# SSH transport to the Slurm cluster
# ---------------------------------------------------------------------------
class SshError(RuntimeError):
    pass


class SmsClient:
    def __init__(self):
        self.home = None

    def _run(self, remote_cmd, stdin=None, timeout=60):
        argv = ["ssh",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "UserKnownHostsFile=" + KNOWN_HOSTS,
                "-i", SSH_KEY,
                "%s@%s" % (SLURM_USER, SMS_HOST),
                remote_cmd]
        p = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
        if p.returncode != 0:
            raise SshError("ssh rc=%d: %s" % (p.returncode, p.stderr.decode(errors="replace")[-400:]))
        return p.stdout

    def connect_check(self):
        if self.home is None:
            self.home = self._run('printf %s "$HOME"').decode().strip()
            if not self.home:
                raise SshError("empty $HOME on cluster")
        return self.home

    def write_envfile(self, token):
        """Deliver the runner token via ssh STDIN into a 0600 env file.

        Chain (documented in job-template.sh header too):
          POST registration-token -> token lives only in broker memory here;
          ssh 'umask 077; cat > $HOME/.ebrunner-<uuid>.env' with token bytes on
          stdin (never argv, never the batch script text). HOME is NFS-shared
          to compute so the batch job finds the file; it shreds it on EXIT.
        """
        path = "%s/.ebrunner-%s.env" % (self.home, uuid.uuid4().hex)
        content = ("export RUNNER_TOKEN=%s\n" % token).encode()
        self._run("umask 077; cat > %s && chmod 600 %s" % (path, path), stdin=content)
        return path

    def discard_envfile(self, path):
        try:
            self._run("shred -u %s 2>/dev/null || rm -f %s" % (path, path), timeout=30)
        except (SshError, subprocess.TimeoutExpired):
            ainfo(event="envfile_discard_failed", path=path)

    def gc_envfiles(self):
        try:
            self._run('find "$HOME" -maxdepth 1 -name ".ebrunner-*.env" -mmin +%d '
                      '-exec sh -c \'shred -u "$1" 2>/dev/null || rm -f "$1"\' _ {} \\;'
                      % ENVFILE_MAX_AGE_MIN, timeout=60)
        except (SshError, subprocess.TimeoutExpired):
            ainfo(event="envfile_gc_failed")

    def squeue(self):
        out = self._run("squeue --me -h -O jobid,name,state", timeout=45)
        jobs = []
        for line in out.decode(errors="replace").splitlines():
            parts = line.strip().split("|")
            if len(parts) < 3:
                continue
            jid, name, state = parts[0].strip(), parts[1].strip(), parts[2].strip()
            if name.startswith(RUNNER_PREFIX) and jid.isdigit():
                jobs.append((int(jid), name, state))
        return jobs

    def sbatch(self, template, envfile_path):
        """Submit job-template.sh via stdin; token is NOT in argv nor script."""
        export = "ENVFILE=%s,GH_ORG=%s,RUNNER_IMAGE=%s," \
                 "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" % (
                     envfile_path, ORG, RUNNER_IMAGE)
        argv = ["sbatch",
                "--export", export,
                "-p", PARTITION,
                "--time", WTIME,
                "--cpus-per-task", CPUS,
                "--mem", MEM,
                # Logs go to the NFS-shared HOME (persistent, visible from every
                # node) — /scratch is node-local and periodically wiped. Home is
                # NFS-mounted identically on SMS and compute, so the job finds
                # both this log path and the env file under the same $HOME.
                # self.home is resolved by connect_check() before any dispatch.
                "--output", "%s/logs/%s%%j.out" % (self.home, RUNNER_PREFIX),
                "-"]
        full = "exec " + " ".join(_shell_quote(a) for a in argv)
        out = self._run(full, stdin=template, timeout=90)
        m = re.search(r"Submitted batch job (\d+)", out.decode())
        if not m:
            raise SshError("unparsable sbatch output: %r" % out[:200])
        return int(m.group(1))


def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------------------
# Broker core
# ---------------------------------------------------------------------------
class Broker:
    def __init__(self, gh, sms):
        self.gh = gh
        self.sms = sms
        # gh_run_id -> {"repo": full_name, "jobs": {gh_job_id: {"slurm": int,
        #                  "envfile": str, "attempts": int}}}
        self.dispatched = {}
        self.offline_since = {}  # runner_id -> first-seen-offline ts (reconciled at boot)

    # -- boot reconciliation -------------------------------------------------
    def reconcile(self):
        live = {jid for jid, _n, st in self.sms.squeue() if st in JOB_LIVE_STATES}
        ainfo(event="boot_reconcile", live_slurm_jobs=sorted(live))
        return live

    # -- dispatch ------------------------------------------------------------
    def poll_once(self, live):
        runs = self.gh.queued_runs()
        queued_ids = {r["id"] for r in runs}

        # Forget dispatches whose runs left the queued state (claimed or gone).
        # Env-file lifecycle is owned by each job's EXIT trap; anything orphaned
        # (e.g. cancelled in PD) is reaped by the periodic gc_envfiles().
        for rid in list(self.dispatched):
            if rid not in queued_ids:
                del self.dispatched[rid]

        active = len(live)
        for run in runs:
            rid = run["id"]
            repo = run["repository"]["full_name"]
            entry = self.dispatched.get(rid)

            if entry is None:
                if active >= MAX_PARALLEL:
                    ainfo(event="cap_reached", active=active, skipped_run=rid)
                    continue
                try:
                    jobs = self.gh.queued_hpc_jobs(repo, rid)
                except urllib.error.HTTPError as e:
                    if e.code in (404, 410):
                        continue
                    raise
                if not jobs:
                    continue
                self.dispatched[rid] = entry = {"repo": repo, "jobs": {}}
                for j in jobs:
                    if active >= MAX_PARALLEL:
                        break
                    result = self._dispatch_one(j["id"])
                    if result is not None:
                        slurm_id, envfile = result
                        entry["jobs"][j["id"]] = {"slurm": slurm_id, "envfile": envfile,
                                                  "attempts": 1}
                        active += 1
                ainfo(event="run_dispatched", run=rid, repo=repo,
                      jobs={str(k): v["slurm"] for k, v in entry["jobs"].items()})

            else:
                # Run still queued: did any dispatched job die before claiming it?
                for gh_job_id, meta in list(entry["jobs"].items()):
                    if meta["slurm"] in live:
                        continue
                    # Slurm job gone; runner never (yet) flipped the run out of queued.
                    if meta["attempts"] >= 3:  # initial + 2 resubmits
                        ainfo(event="dispatch_gave_up", run=rid, job=gh_job_id,
                              attempts=meta["attempts"])
                        continue
                    if active >= MAX_PARALLEL:
                        continue
                    result = self._dispatch_one(gh_job_id)
                    if result is not None:
                        new_id, envfile = result
                        meta["slurm"] = new_id
                        meta["envfile"] = envfile
                        meta["attempts"] += 1
                        active += 1
                        ainfo(event="resubmitted", run=rid, job=gh_job_id,
                              slurm=new_id, attempt=meta["attempts"])
        return active

    def _dispatch_one(self, gh_job_id):
        """Mint token -> ssh-deliver env file -> sbatch. Returns (slurm_id, envfile) or None."""
        try:
            token = self.gh.registration_token()  # LAZY mint, 1 h lifetime
            envfile = self.sms.write_envfile(token)
        except (urllib.error.URLError, urllib.error.HTTPError, SshError) as e:
            ainfo(event="token_delivery_failed", job=gh_job_id, err=str(e)[:300])
            return None
        try:
            with open(TEMPLATE_PATH, "rb") as f:
                template = f.read()
            return self.sms.sbatch(template, envfile), envfile
        except (SshError, subprocess.TimeoutExpired, OSError) as e:
            ainfo(event="sbatch_failed", job=gh_job_id, err=str(e)[:300])
            self.sms.discard_envfile(envfile)
            return None

    # -- zombie runner sweep --------------------------------------------------
    def sweep_runners(self, live):
        try:
            runners = self.gh.runners()
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            ainfo(event="runner_list_failed", err=str(e)[:200])
            return
        seen = set()
        for r in runners:
            m = RUNNER_NAME_RE.match(r.get("name", ""))
            if not m:
                continue  # never touch non-broker runners
            rid = r["id"]
            seen.add(rid)
            slurm_id = int(m.group(1))
            if r.get("status") == "offline" and slurm_id not in live:
                since = self.offline_since.setdefault(rid, time.time())
                if time.time() - since > ZOMBIE_GRACE_SECONDS:
                    try:
                        self.gh.delete_runner(rid)
                        ainfo(event="zombie_runner_deleted", runner=rid, name=r["name"])
                    except (urllib.error.URLError, urllib.error.HTTPError) as e:
                        ainfo(event="zombie_delete_failed", runner=rid, err=str(e)[:200])
                    self.offline_since.pop(rid, None)
            else:
                self.offline_since.pop(rid, None)


def _config_guard():
    if "@sha256:" not in RUNNER_IMAGE:
        raise SystemExit("RUNNER_IMAGE must be digest-pinned (@sha256:...); tags are rejected")
    for p in (SSH_KEY, KNOWN_HOSTS, TEMPLATE_PATH,
              os.path.join(GH_CREDS_DIR, "github_app_id"),
              os.path.join(GH_CREDS_DIR, "github_app_installation_id"),
              os.path.join(GH_CREDS_DIR, "github_app_private_key")):
        if not os.path.exists(p):
            raise SystemExit("missing required file: %s" % p)


def main():
    _config_guard()
    gh = GitHubClient()
    sms = SmsClient()
    broker = Broker(gh, sms)
    ainfo(event="broker_start", org=ORG, host=SMS_HOST, partition=PARTITION,
          image=RUNNER_IMAGE, max_parallel=MAX_PARALLEL, poll_seconds=POLL_SECONDS)

    ssh_backoff = 0
    gc_counter = 0
    boot_done = False
    while True:
        cycle_start = time.time()
        try:
            sms.connect_check()
            ssh_backoff = 0
            if not boot_done:
                # Boot reconciliation: live Slurm jobs (ebrunner- prefix) + org
                # runners give the minimum state to resume without double-bookings
                # (see module docstring for the duplicate-dispatch race window).
                broker.reconcile()
                broker.sweep_runners(set())
                boot_done = True
        except (SshError, subprocess.TimeoutExpired) as e:
            ssh_backoff = min(max(ssh_backoff * 2, SSH_BACKOFF_BASE) if ssh_backoff
                              else SSH_BACKOFF_BASE, SSH_BACKOFF_MAX)
            ainfo(event="ssh_backoff", wait=ssh_backoff, err=str(e)[:300])
            time.sleep(ssh_backoff)
            continue

        try:
            live = {jid for jid, _n, st in sms.squeue() if st in JOB_LIVE_STATES}
            active = broker.poll_once(live)
            broker.sweep_runners(live)
            gc_counter += 1
            if gc_counter % 40 == 1:  # ~ every 10 min at 15 s poll
                sms.gc_envfiles()
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            ainfo(event="github_api_error", err=str(e)[:300])
        except (SshError, subprocess.TimeoutExpired) as e:
            ainfo(event="ssh_error", err=str(e)[:300])
        except Exception as e:  # noqa: BLE001 - top-level guard, keep the loop alive
            ainfo(event="unhandled_error", err=repr(e)[:400])

        elapsed = time.time() - cycle_start
        time.sleep(max(1.0, POLL_SECONDS - elapsed))


if __name__ == "__main__":
    main()

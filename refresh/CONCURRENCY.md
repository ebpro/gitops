# Concurrent sessions on ONE shared directory — note + SOTA practice
Snapshot: 2026-09-12 (written by the ARC/Kyverno session)
Scope: many parallel `opencode` sessions resuming different jobs against the same machine.

## The situation (verified, read-only)
- One physical GitOps working tree serves several jobs at once:
  `/mnt/hdd/home/bruno/gitops` and `/home/bruno/gitops` are the **same repo**
  (verified identical inode `41820158`).
- At snapshot time that tree was checked out on **another session's** branch
  (`preservation/opencode-sota-7a05f7b-…`) and carried **foreign untracked files**
  (`arm-test.yaml`, `helm/releases/pact-broker/values.yaml.backup`,
  `kubernetes/keycloak-realm/platform-realm-setup-job.yaml.bak`).
- Four handoffs (arc-kyverno, backstage, opencode, link-shortener's gitops-half) all
  target this one tree; a fifth (ijava) uses a different repo (`ebpro/IJava`).
- `/home/bruno/REFRESH/` is **not** a git repo — handoff folders are unversioned unless a
  session explicitly pushes them somewhere (see INDEX.md per-job "Git preservation" column).

## Why a single shared checkout is dangerous for agents
A git working tree holds exactly ONE checked-out branch + ONE staging index at a time.
Concurrent agents sharing it race on that shared mutable state:
- **Branch yank:** session B runs `git checkout main` while A is mid-edit → A's tree
  silently swaps under it; A commits onto the wrong base.
- **Index clobber:** `git add -A` / `git stash` in one session sweeps up another session's
  untracked or staged files (the stray `*.bak`/`arm-test.yaml` above would ride along).
- **HEAD race:** two commits/merges interleaving → wrong parentage, lost work, reflog churn.
- **ArgoCD coupling:** anything pushed to `main` reconciles (prune+selfHeal). A careless
  direct-to-main push from one session deploys the *other* session's half-finished edits too.
- **Handoff drift:** unversioned REFRESH folders vanish if the workstation is reset.

## SOTA practice — one worktree + one branch per session (never touch the primary tree)
Git worktrees give each session its own checkout dir + own HEAD, while sharing the single
`.git` object store (cheap, no re-clone). Adopt this per session:

1. **Claim + register first.** Before editing, append a row to `INDEX.md` (job, working dir,
   branch, base SHA, timestamp). Treat INDEX.md as the single source of truth for who owns what.
2. **Never `checkout`/`add -A`/`stash` in the shared primary tree.** Isolate:
   ```
   git -C /mnt/hdd/home/bruno/gitops fetch origin
   git -C /mnt/hdd/home/bruno/gitops worktree add /tmp/wt-<job> -b preservation/<job> <base-ref>
   cd /tmp/wt-<job>   # do ALL file edits + commits here
   ```
   Pick `<base-ref>` deliberately (`origin/main` for a clean job, or a known commit) and record it.
3. **Stage explicitly**, by path — never `-A`/`.` — so foreign untracked files are impossible to sweep.
4. **Publish via a preservation branch + PR, not direct `main`.**
   `git push -u origin preservation/<job>` then open a PR. Merge order is a human-coordinated
   decision; the branch is inert to ArgoCD until it reaches `main`.
5. **Redact before any commit.** No tokens/secret values in handoff or repo files (env-only,
   e.g. `SONAR_TOKEN`). Vault paths/secret NAMES are fine; secret VALUES are not.
6. **Cluster is read-only** (git-push-only platform). The ONLY sanctioned write is a documented
   one-off patch, executed once, recorded in the handoff (see the ARC Kyverno CM exception).
7. **Clean up.** When the job merges or is abandoned:
   `git -C /mnt/hdd/home/bruno/gitops worktree remove /tmp/wt-<job>` (branch/PR stays on origin).
8. **Version the handoff itself.** Push the REFRESH folder into a `refresh/<job>/` path on the
   job's preservation branch so the map survives resets (what the ARC session did).

## Escape hatches when isolation isn't possible
- If you MUST use the shared tree: `git -C <tree> stash push -u` is forbidden (sweeps others);
  instead create a throwaway branch from current HEAD, work, commit only your paths, then
  `git worktree` the next job.
- If a foreign branch/commit is blocking: do NOT delete it; report to the owner session.
- Detect contention cheaply: `git -C <tree> status -sb` + `git worktree list` + the `.claimed`
  marker in each REFRESH folder before starting.

## Helper: `claim.sh` (mechanizes steps 1–4 + 7)
The ARC session ships `/home/bruno/REFRESH/claim.sh` so parallel sessions follow the practice
without remembering the commands. It is dry-tested and self-cleaning.

```
# claim a job (isolated worktree + preservation branch + .claimed marker + INDEX row)
./claim.sh <job-slug> [base-ref]        # base-ref defaults to origin/main
# then ONLY work inside the printed worktree path; push by PR, never to main.

# finish / abandon (removes worktree + LOCAL branch + marker; keeps remote branch & INDEX row
# so a merged job can be marked DONE by hand)
./claim.sh --release <job-slug>
```
Env overrides: `GITOPS_REPO`, `REFRESH_DIR`, `WT_ROOT`, `NO_FETCH=1`.
Guards: refuses to clobber an existing worktree path; never uses `git add -A`; inserts the INDEX
row idempotently (fixed-string match, one row per job).

## One-line rule
> **A shared checkout is a shared race condition. Give every concurrent session its own
> worktree and its own branch; register both in `INDEX.md`; publish by PR, never by `main`.**

#!/usr/bin/env bash
# claim.sh — SOTA concurrency helper for parallel opencode sessions sharing one repo.
# See CONCURRENCY.md. One step: isolated git worktree + branch + .claimed marker + INDEX row.
#
# Usage:
#   ./claim.sh <job-slug> [base-ref]      # default base-ref = origin/main
#   ./claim.sh --release <job-slug>       # remove worktree + local branch + marker
#
# Env overrides:
#   GITOPS_REPO   (default /mnt/hdd/home/bruno/gitops)
#   REFRESH_DIR   (default /home/bruno/REFRESH)
#   WT_ROOT       (default /tmp)
#   NO_FETCH=1    (skip `git fetch origin`)
set -euo pipefail

REPO="${GITOPS_REPO:-/mnt/hdd/home/bruno/gitops}"
REFRESH="${REFRESH_DIR:-/home/bruno/REFRESH}"
WT_ROOT="${WT_ROOT:-/tmp}"

die(){ echo "claim.sh: ERROR: $*" >&2; exit 1; }
info(){ echo "claim.sh: $*"; }

[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "not a git repo: $REPO"
[ "${1:-}" != "" ] || die "usage: claim.sh <job-slug> [base-ref] | --release <job-slug>"

if [ "${1:-}" = "--release" ]; then
  JOB="${2:-}"; [ -n "$JOB" ] || die "--release needs <job-slug>"
  [[ "$JOB" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad job-slug: $JOB"
  BRANCH="preservation/$JOB"; WT="$WT_ROOT/wt-$JOB"; HANDOFF="$REFRESH/$JOB"
  info "releasing $JOB"
  git -C "$REPO" worktree remove "$WT" --force 2>/dev/null && info "removed worktree $WT" || info "no worktree at $WT"
  git -C "$REPO" worktree prune
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 && info "deleted local branch $BRANCH" || info "branch $BRANCH in use elsewhere — left as-is"
  fi
  rm -f "$HANDOFF/.claimed" && info "removed $HANDOFF/.claimed" || true
  info "NOTE: remote preservation branch (if pushed) is intentionally kept."
  exit 0
fi

JOB="$1"; BASE="${2:-origin/main}"
[[ "$JOB" =~ ^[A-Za-z0-9._-]+$ ]] || die "job-slug must match [A-Za-z0-9._-]+ (no slash/space): $JOB"
BRANCH="preservation/$JOB"; WT="$WT_ROOT/wt-$JOB"; HANDOFF="$REFRESH/$JOB"

[ "${NO_FETCH:-0}" = "1" ] || git -C "$REPO" fetch --quiet origin || info "WARN: fetch failed; continuing with local refs"

[ -e "$WT" ] && die "worktree path already exists: $WT (use --release first)"
git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" \
  && info "branch $BRANCH exists; reusing (git refuses same branch in two worktrees)" \
  || true

info "creating worktree $WT on $BRANCH"
if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO" worktree add "$WT" "$BRANCH"
else
  SHA="$(git -C "$REPO" rev-parse --verify "$BASE" 2>/dev/null)" || die "cannot resolve base-ref: $BASE"
  git -C "$REPO" worktree add -b "$BRANCH" "$WT" "$BASE"
fi

SHA="$(git -C "$WT" rev-parse HEAD)"; SHORT="$(git -C "$WT" rev-parse --short HEAD)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; USER="$(id -un)"; HOST="$(hostname)"

mkdir -p "$HANDOFF"
cat > "$HANDOFF/.claimed" <<EOF
job=$JOB
branch=$BRANCH
base_ref=$BASE
head=$SHA
worktree=$WT
refresh=$HANDOFF
claimed_by=$USER@$HOST
claimed_at=$TS
pid=$$
EOF
info "wrote $HANDOFF/.claimed"

INDEX="$REFRESH/INDEX.md"
[ -f "$INDEX" ] || cat > "$INDEX" <<EOF
# REFRESH — parallel-session handoff index
(auto-created by claim.sh — please complete the header/hazards sections)

| Folder | Job | Finish-in (working dir) | Git preservation | Status / next |
|---|---|---|---|---|
EOF

if grep -qF "\`$JOB/\`" "$INDEX"; then
  info "INDEX already has a row for $JOB — not duplicating"
else
  ROW="| \`$JOB/\` | TODO: describe job | RECORD finish-in cwd | \`$BRANCH\` @ \`$SHORT\` | CLAIMED $TS by $USER@$HOST — fill in + push by PR. |"
  python3 - "$INDEX" "$ROW" <<'PY'
import sys
p,row=sys.argv[1],sys.argv[2]
lines=open(p).read().split("\n")
out=[];done=False
def is_table_row(l): return l.startswith("|")
# prefer inserting before the first non-table line after the table (e.g. a heading)
for i,l in enumerate(lines):
    if not done and (l.startswith("## ") or l.strip()==""):
        # find previous line; only insert if we're right after a table
        j=len(out)-1
        while j>=0 and out[j].strip()=="": j-=1
        if j>=0 and out[j].startswith("|"):
            out.append(row); done=True
    out.append(l)
if not done:
    # fallback: append
    if out and out[-1].strip()!="": out.append("")
    out.append(row)
open(p,"w").write("\n".join(out))
PY
  info "appended INDEX row for $JOB"
fi

cat <<EOF

  ✅ Claimed. Now WORK ONLY INSIDE THE WORKTREE:
     cd "$WT"
  - Edit files there; stage by explicit path (never 'git add -A').
  - Publish: git push -u origin "$BRANCH"  then open a PR (do NOT push to main).
  - Done/abandoned: $0 --release "$JOB"
EOF

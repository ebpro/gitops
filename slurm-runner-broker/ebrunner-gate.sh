#!/usr/bin/env bash
# =============================================================================
# ebrunner-gate — forced-command SSH wrapper for the slurm-runner-broker key
#
# INSTALL TARGET (SMS submit gateway, see runbook step A3):
#   /usr/local/bin/ebrunner-gate    root:root, mode 0755
#   kubernetes/slurm-runner-broker/README.md ("Step A — A3")
#
# EXACT AUTHORIZED_KEYS LINE TEMPLATE (real key material lives in runbook A1;
# never paste a placeholder there):
#   restrict,from="10.2.248.0/24",no-pty,command="/usr/local/bin/ebrunner-gate" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNORGDO6WO6brOnHO8geiseMqyf93WymLowzDHRq8Si slurm-runner-broker@ebpro-org
#
# SECURITY MODEL
# The broker ED25519 key (fingerprint
# SHA256:LfCHXlnnJ8NqjyF0eg1/XJrr5z3eoZVNe4cSpo3wNv4) is a CAPABILITY key:
# sshd forces this script for every session and the raw client request arrives
# verbatim in $SSH_ORIGINAL_COMMAND. Only the fixed command shapes the broker
# actually emits (slurm-runner-broker/broker.py, class SmsClient) are executed;
# everything else is denied and logged to syslog (tag ebrunner-gate).
#
#   WHAT THE KEY CAN DO (allow-list; nothing else):
#     1. printf %s "$HOME"                                    — connect_check
#     2. umask 077; cat > $HOME/.ebrunner-<32hex>.env && chmod 600 …  [stdin]
#     3. exec 'sbatch' '--export' 'ENVFILE=$HOME/.ebrunner-<32hex>.env,…'
#        '-p' 'ouranos' '--time' … '--cpus-per-task' … '--mem' …
#        '--output' … '-'                                     — submit  [stdin]
#     4. squeue --me -h -O jobid,name,state                   — reconcile
#     5. shred -u $HOME/.ebrunner-<32hex>.env 2>/dev/null || rm -f …  — discard
#     6. the fixed find-based stale-env-file GC one-liner (byte-exact)
#
#   WHAT THE KEY CANNOT DO: an interactive shell or PTY (restrict + no-pty +
#   forced command), ANY other command/flag/subsystem (scp, sftp, netcat,
#   git-receive-pack, …), file access beyond the $HOME/.ebrunner-<32hex>.env
#   shape, port/agent/X11/env forwarding (restrict), reading stdin contents
#   (the gate never consumes stdin: it is inherited by cat/sbatch untouched).
#
#   STRENGTHS: strict anchored ERE allow-list. The payload is never eval'd and
#   never re-parsed by a shell: the sbatch token stream is validated against a
#   metacharacter-free alphabet, rebuilt into an argv array, and exec'd
#   directly; the cat/shred forms run fixed sh snippets that receive the
#   matched path as positional DATA ("$1"), never as script text. Denials log
#   the first 200 bytes of the attempt to syslog and print a generic message.
#
#   PAIRED MAINTENANCE: this allow-list mirrors broker.py's SmsClient. If any
#   remote command shape changes, update this gate in the SAME commit and
#   reinstall on the SMS (runbook A3). The partition pin ('ouranos') and the
#   GC literal (-mmin +120) intentionally hard-pin ConfigMap/broker constants.
# =============================================================================
set -u

deny() {
  local why="$1" probe="${SSH_ORIGINAL_COMMAND:-}"
  if command -v logger >/dev/null 2>&1; then
    logger -t ebrunner-gate -- \
      "denied reason=${why} user=${USER:-?} client=${SSH_CLIENT:-?} cmd=${probe:0:200}" || true
  fi
  printf '%s\n' "ebrunner-gate: command not permitted" >&2
  exit 1
}

cmd="${SSH_ORIGINAL_COMMAND-}"

# No payload => interactive shell / subsystem request. Never allowed for this key.
[ -n "$cmd" ] || deny "no-command"

# Anchored patterns below are single-line; refuse anything with newlines/CR.
case "$cmd" in
  *[$'\n\r']*) deny "newline" ;;
esac

# --- $HOME-derived strict env-file shape --------------------------------------
# Escape ERE metacharacters in $HOME so the allow-list cannot be widened by an
# exotic home path (lab homes are /home/<user>).
esc=$HOME
for c in '\' '^' '$' '.' '[' ']' '(' ')' '?' '*' '+' '|' '{' '}'; do
  esc=${esc//"$c"/"\\$c"}
done
envf="${esc}/\\.ebrunner-[0-9a-f]{32}\\.env"

# --- byte-exact literals (fixed commands; [ == ] is a literal compare) --------
HOME_LIT='printf %s "$HOME"'                                # broker.py L322
SQUEUE_LIT='squeue --me -h -O jobid,name,state'             # broker.py L356
# broker.py L349-351 (GC of stale ~/.ebrunner-*.env; every byte pinned below is
# the embedded constant, so no attacker-controlled byte reaches this sh -c):
GC_LIT=$'find "$HOME" -maxdepth 1 -name ".ebrunner-*.env" -mmin +120 -exec sh -c \'shred -u "$1" 2>/dev/null || rm -f "$1"\' _ {} \\;'

if [ "$cmd" = "$HOME_LIT" ]; then
  exec printf %s "$HOME"
fi

if [ "$cmd" = "$SQUEUE_LIT" ]; then
  exec squeue --me -h -O jobid,name,state
fi

if [ "$cmd" = "$GC_LIT" ]; then
  exec /bin/sh -c "$GC_LIT"
fi

# --- (i) env-file write via stdin: broker.py L338 ------------------------------
# umask 077; cat > <envf> && chmod 600 <envf>   (both path occurrences must agree)
re_write="^umask 077; cat > (${envf}) && chmod 600 (${envf})\$"
if [[ $cmd =~ $re_write ]]; then
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] || deny "write-path-mismatch"
  exec /bin/sh -c 'umask 077; cat > "$1" && chmod 600 "$1"' _ "${BASH_REMATCH[1]}"
fi

# --- (iv) env-file discard: broker.py L343 -------------------------------------
# shred -u <envf> 2>/dev/null || rm -f <envf>
re_disc="^shred -u (${envf}) 2>/dev/null [|][|] rm -f (${envf})\$"
if [[ $cmd =~ $re_disc ]]; then
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] || deny "discard-path-mismatch"
  exec /bin/sh -c 'shred -u "$1" 2>/dev/null || rm -f "$1"' _ "${BASH_REMATCH[1]}"
fi

# --- (ii) sbatch via stdin: broker.py L372-381 ----------------------------------
# broker.py builds: "exec " + shell-quoted argv (each token 'single quoted', no
# token ever contains a quote/space), fixed flag order. Token alphabet below
# excludes every shell metacharacter, quote, space and glob character, so the
# rebuilt argv is the ONLY interpretation of the payload — no eval, no shell.
case "$cmd" in
  "exec "*)
    body=${cmd#exec }
    case "$body" in
      "\""*) deny "sbatch-quoting" ;;          # no double quotes anywhere
    esac
    case "$body" in
      "'"*"'" ) ;;                              # shape ok: starts+ends with quote
      *) deny "sbatch-quoting" ;;
    esac
    body=${body#\'}
    body=${body%\'}
    SEP=$'\037'
    BOUND="' '"
    body=${body//"$BOUND"/$SEP}
    IFS=$SEP read -r -a argv <<< "$body"

    [ "${#argv[@]}" -eq 14 ] || deny "sbatch-arity"
    for a in "${argv[@]}"; do
      [[ $a =~ ^[-A-Za-z0-9_./:%=+@,]+$ ]] || deny "sbatch-token"
    done
    [ "${argv[0]}" = "sbatch" ]                 || deny "sbatch-argv0"
    [ "${argv[1]}" = "--export" ]               || deny "sbatch-export-flag"
    [ "${argv[3]}" = "-p" ]       &&
      [ "${argv[4]}" = "ouranos" ]              || deny "sbatch-partition"
    [ "${argv[5]}" = "--time" ]                 || deny "sbatch-time-flag"
    [[ ${argv[6]} =~ ^[0-9][0-9:.-]{0,15}$ ]]   || deny "sbatch-time-value"
    [ "${argv[7]}" = "--cpus-per-task" ]        || deny "sbatch-cpus-flag"
    [[ ${argv[8]} =~ ^[0-9]{1,4}$ ]]            || deny "sbatch-cpus-value"
    [ "${argv[9]}" = "--mem" ]                  || deny "sbatch-mem-flag"
    [[ ${argv[10]} =~ ^[0-9]{1,8}[A-Za-z]{0,2}$ ]] || deny "sbatch-mem-value"
    [ "${argv[11]}" = "--output" ]              || deny "sbatch-output-flag"
    [[ ${argv[12]} =~ ^/[A-Za-z0-9._/%-]{1,190}$ ]] || deny "sbatch-output-value"
    [ "${argv[13]}" = "-" ]                     || deny "sbatch-stdin"
    # --export payload: ENVFILE=<exact env-file shape>,GH_ORG=…,RUNNER_IMAGE=…,
    # PATH=<fixed>. The script itself arrives on stdin (argv "-" -> exec below
    # inherits the session stdin untouched; the gate never reads it).
    re_export="^ENVFILE=${envf},GH_ORG=[A-Za-z0-9._-]{1,64},RUNNER_IMAGE=[A-Za-z0-9._:@/+-]{1,256},PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\$"
    [[ ${argv[2]} =~ $re_export ]] || deny "sbatch-export-value"
    exec "${argv[@]}"
    ;;
esac

deny "no-match"

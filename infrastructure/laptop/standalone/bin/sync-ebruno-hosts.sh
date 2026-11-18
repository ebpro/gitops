#!/usr/bin/env bash
# sync-ebruno-hosts.sh — keep a MANAGED BLOCK in /etc/hosts pointing the
# *.ebruno.fr app hostnames at the CURRENT lima-k3s-agent InternalIP, resolved
# dynamically via resolve-cluster-ip.sh (the address is a DHCP lease — see the
# resolver's header; 10.2.248.31 is dead for HTTPS from this laptop, so the VIP
# is deliberately never used).
#
# Default mode is DRY-RUN: prints the unified diff, writes NOTHING.
# --write applies the change and must run as root (sudo); the script refuses
# politely otherwise. The replacement is atomic: the new file is built in a
# temp file created INSIDE /etc (same filesystem) and moved over /etc/hosts
# (rename is atomic). No shell `>` redirect ever touches /etc/hosts.
#
# The managed block is delimited by the two marker lines below; everything
# outside them is preserved verbatim. Re-running is a no-op when in sync
# (idempotent), which is what makes the systemd timer safe.
#
# Env overrides:
#   EBRUNO_HOSTS_FILE   hosts file to manage (default /etc/hosts — tests only)
#   EBRUNO_HOSTS        space-separated hostnames (defaults below)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVER="${SCRIPT_DIR}/resolve-cluster-ip.sh"
HOSTS_FILE="${EBRUNO_HOSTS_FILE:-/etc/hosts}"

MARK_BEGIN="# BEGIN gitops-standalone (managed)"
MARK_END="# END gitops-standalone (managed)"

# Extensible list: add one hostname per line, nothing else changes.
DEFAULT_HOSTS="gitea.ebruno.fr harbor.ebruno.fr woodpecker.ebruno.fr pactbroker.ebruno.fr"
read -r -a HOSTS <<< "${EBRUNO_HOSTS:-$DEFAULT_HOSTS}"

usage() {
  sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo "usage: $(basename "$0") [--dry-run|--write]" >&2
}

MODE="dry-run"
for arg in "$@"; do
  case "${arg}" in
    --dry-run) MODE="dry-run" ;;
    --write)   MODE="write" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: ${arg}" >&2; usage; exit 2 ;;
  esac
done

[ -f "${HOSTS_FILE}" ] || { echo "ERROR: ${HOSTS_FILE} not readable" >&2; exit 1; }

# --- resolve the live IP (bounded: the resolver caps its own attempts) --------
if [ ! -f "${RESOLVER}" ]; then
  echo "ERROR: resolver missing at ${RESOLVER}" >&2
  exit 1
fi
ip=$(timeout 60 bash "${RESOLVER}") || {
  echo "ERROR: cluster IP resolution failed — /etc/hosts left untouched" >&2
  exit 1
}

# --- build the managed block ---------------------------------------------------
block="${MARK_BEGIN}"$'\n'
for h in "${HOSTS[@]}"; do
  block+="${ip} ${h}"$'\n'
done
block+="${MARK_END}"

# --- rebuild the file: strip the old block, append the new one -----------------
# Literal line comparison against the markers (no regex metachar concerns).
strip_block() {
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0 == b { inblk = 1; next }
    $0 == e { inblk = 0; next }
    !inblk  { print }
  ' "$1"
}

tmp_new=$(mktemp /tmp/ebruno-hosts-new.XXXXXX)
tmp_final=""
trap 'rm -f "${tmp_new}" "${tmp_final:-}"' EXIT
{
  strip_block "${HOSTS_FILE}"
  printf '%s\n' "${block}"
} > "${tmp_new}"

# Normalise: the comparison and the write use the same bytes.
if diff -q "${HOSTS_FILE}" "${tmp_new}" >/dev/null 2>&1; then
  echo "OK: ${HOSTS_FILE} already in sync with the managed block (${ip})"
  exit 0
fi

if [ "${MODE}" = "dry-run" ]; then
  echo "DRY-RUN: proposed change to ${HOSTS_FILE} (nothing written):"
  diff -u "${HOSTS_FILE}" "${tmp_new}" && true
  echo "Apply with: sudo ${BASH_SOURCE[0]} --write"
  exit 0
fi

# --- write mode: root only ------------------------------------------------------
# Strict for anything under /etc; an explicitly overridden EBRUNO_HOSTS_FILE
# outside /etc is the sanctioned sandbox for tests (see README/dev notes).
if [ "$(id -u)" -ne 0 ]; then
  case "${HOSTS_FILE}" in
    /etc/*)
      echo "ERROR: --write needs root (the file lives in /etc)." >&2
      echo "       Re-run as: sudo ${BASH_SOURCE[0]} --write" >&2
      echo "       Or just inspect first: ${BASH_SOURCE[0]} --dry-run" >&2
      exit 1
      ;;
    *) echo "NOTE: sandbox write to ${HOSTS_FILE} as $(id -un) (not /etc)" >&2 ;;
  esac
fi

# Temp file in the SAME directory (same fs) → mv is an atomic rename. Mode is
# set before the move so /etc/hosts is never briefly 0600-root-only via mktemp.
tmp_final=$(mktemp "${HOSTS_FILE}.gitops.XXXXXX")
cp "${tmp_new}" "${tmp_final}"
chmod 0644 "${tmp_final}"
chown root:root "${tmp_final}" 2>/dev/null || true
mv -f "${tmp_final}" "${HOSTS_FILE}"
echo "OK: managed block in ${HOSTS_FILE} now points at ${ip} (${#HOSTS[@]} hosts)"

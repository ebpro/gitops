#!/usr/bin/env bash
# gh-runner-deregister.sh — reversible counterpart of gh-runner-install.sh:
# stop the service, uninstall it, deregister the runner from GitHub, and
# (after explicit confirmation) delete the runner directory.
#
# Usage:  ./gh-runner-deregister.sh [--yes]
#   --yes   skip the interactive confirmation before rm -rf RUNNER_HOME
#
# Deregistration uses `config.sh remove --token`, which needs a FRESH
# registration-style token (the original one is long expired; tokens live
# ~1 h). Create one at:
#   https://github.com/organizations/<OWNER>/settings/runners/new
# The token is read via a hidden prompt (or WP-free env REG_TOKEN), never
# echoed. If removal fails (offline registration, expired token), the script
# still tears the local side down and prints where to delete the stale entry
# in the GitHub UI — an orphan "offline" runner is inert but confusing.
#
# svc.sh stop/uninstall need sudo: same policy as the installer — use root or
# passwordless sudo silently, otherwise plain sudo (interactive prompt).
set -euo pipefail

RUNNER_HOME="${RUNNER_HOME:-$PWD/actions-runner}"
YES=0
for arg in "$@"; do
  case "${arg}" in
    --yes) YES=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: ${arg} (only --yes)" >&2; exit 2 ;;
  esac
done

RUNNER_HOME=$(realpath "${RUNNER_HOME}")
case "${RUNNER_HOME}" in
  ""|"/"|"/home"|"/home/bruno") echo "ERROR: refusing to treat '${RUNNER_HOME}' as a runner dir" >&2; exit 2 ;;
esac
[ -f "${RUNNER_HOME}/.runner" ] || {
  echo "ERROR: no configured runner at ${RUNNER_HOME} (.runner missing) — nothing to do." >&2
  echo "         If you moved it, re-run with RUNNER_HOME=/its/path." >&2
  exit 1
}
cd "${RUNNER_HOME}"

# --- sudo wrapper (stop/uninstall are systemd operations) ----------------------
SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then SUDO=(sudo -n); else SUDO=(sudo); fi
fi
run_svc() {
  if [ "${#SUDO[@]}" -gt 0 ]; then "${SUDO[@]}" ./svc.sh "$@"; else ./svc.sh "$@"; fi
}

echo "==> Stopping the runner service"
run_svc stop || echo "WARN: svc.sh stop failed (already stopped?) — continuing" >&2

echo "==> Uninstalling the runner service"
run_svc uninstall || echo "WARN: svc.sh uninstall failed — continuing" >&2

# --- deregister from GitHub -------------------------------------------------------
if [ -z "${REG_TOKEN:-}" ]; then
  printf 'Fresh registration token to remove the runner (hidden; create one in the org runners settings): '
  read -r -s REG_TOKEN; echo
fi
removed=1
if [ -n "${REG_TOKEN}" ]; then
  echo "==> Removing the runner registration"
  ./config.sh remove --token "${REG_TOKEN}" || removed=0
  unset REG_TOKEN
else
  echo "WARN: no token provided — skipping API deregistration" >&2
  removed=0
fi
if [ "${removed}" -ne 1 ]; then
  echo "WARN: the runner is NOT deregistered. Delete it by hand:" >&2
  echo "      Settings -> Security -> General -> Self-hosted runners -> the '${RUNNER_HOME##*/}' entry -> Remove" >&2
  echo "      (org settings page: https://github.com/organizations/ebpro-org/settings/runners )" >&2
fi

# --- delete the directory (explicit confirmation) ---------------------------------
if [ "${YES}" -ne 1 ]; then
  printf 'Delete the whole runner directory %s ? [y/N] ' "${RUNNER_HOME}"
  read -r answer
  case "${answer}" in
    [yY]*) ;;
    *) echo "Kept ${RUNNER_HOME} — service is down; re-run with --yes (or rm -rf by hand) to finish."; exit 0 ;;
  esac
fi
rm -rf "${RUNNER_HOME}"
echo "OK: runner directory ${RUNNER_HOME} deleted. Reinstall any time with gh-runner-install.sh."

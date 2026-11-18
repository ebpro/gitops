#!/usr/bin/env bash
# gh-runner-install.sh — Phase 1 of the standalone kit: install a GitHub
# Actions runner on this laptop OUTSIDE the cluster (the k3s node role is
# fenced for the foreseeable future — campus M1, see README.md).
#
# Inputs (env, or positional: $1=OWNER $2=LABELS):
#   OWNER         org owning the runners        (default ebpro-org)
#   LABELS        comma-separated labels        (default gpu-laptop)
#   REG_TOKEN     registration token, REQUIRED. Deliberately NOT accepted as
#                 a positional argument or flag: argv is visible in `ps` and
#                 shell history. Provide it via env or let the hidden prompt
#                 (read -rs) ask — it is never echoed nor logged.
#   RUNNER_HOME   install dir                   (default ./actions-runner)
#   RUNNER_VERSION  pin a release tag like v2.327.1 (default: latest via API)
#   RUN_USER      user the service runs as      (default $SUDO_USER or you)
#
# The runner works BARE: this laptop has no docker daemon, so jobs that need
# containers must not target the gpu-laptop label (README "Known limits").
#
# svc.sh install/start need sudo: when passwordless sudo is unavailable the
# script stops AFTER configuring and prints the exact two commands for a
# human — the runner registration itself is already done at that point.
# Reversal: gh-runner-deregister.sh.
set -euo pipefail

OWNER="ebpro-org"
LABELS="gpu-laptop"
RUNNER_HOME="${RUNNER_HOME:-$PWD/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUN_USER="${RUN_USER:-${SUDO_USER:-$(id -un)}}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ $# -gt 2 ] && { echo "ERROR: usage: [OWNER] [LABELS] (token NEVER on argv)" >&2; exit 2; }
OWNER="${1:-$OWNER}"
LABELS="${2:-$LABELS}"

die() { echo "ERROR: $*" >&2; exit 1; }
for dep in curl tar git; do
  command -v "${dep}" >/dev/null 2>&1 || die "missing dependency: ${dep}"
done
[ "$(uname -m)" = "x86_64" ] || die "only linux-x64 is supported by this script (arch: $(uname -m))"

# --- refuse to step on an existing runner --------------------------------------
if [ -d "${RUNNER_HOME}" ] && [ -n "$(ls -A "${RUNNER_HOME}" 2>/dev/null)" ]; then
  die "a runner install already exists at ${RUNNER_HOME} — remove it first with gh-runner-deregister.sh (reversible flow), or point RUNNER_HOME elsewhere"
fi

# --- registration token (hidden prompt when absent) ----------------------------
if [ -z "${REG_TOKEN:-}" ]; then
  echo "Create a one-time registration token (expires after ~1 h):"
  echo "  https://github.com/organizations/${OWNER}/settings/runners/new"
  echo "  (Settings -> Security -> General -> Self-hosted runners -> New runner)"
  printf 'Registration token (input hidden): '
  read -r -s REG_TOKEN; echo
  [ -n "${REG_TOKEN}" ] || die "no token provided — nothing was installed"
fi

# --- resolve the release ---------------------------------------------------------
echo "==> Resolving actions/runner release"
if [ -n "${RUNNER_VERSION}" ]; then
  tag="${RUNNER_VERSION}"
else
  api_json=$(curl -fsS --connect-timeout 5 --max-time 15 \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/actions/runner/releases/latest) \
    || die "cannot reach api.github.com (rate limit? VPN?)"
  tag=$(printf '%s' "${api_json}" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  [ -n "${tag}" ] || die "could not parse tag_name from the latest-release API answer"
fi
ver="${tag#v}"
asset="actions-runner-linux-x64-${ver}.tar.gz"
url="https://github.com/actions/runner/releases/download/${tag}/${asset}"
echo "==> Using ${tag} (${asset})"

# --- download + checksum ----------------------------------------------------------
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
echo "==> Downloading (bounded to 300 s)"
curl -fL --connect-timeout 5 --max-time 300 -o "${tmpdir}/${asset}" "${url}" \
  || die "download failed: ${url}"

sumfile="${tmpdir}/${asset}.sha256"
if curl -fsS --connect-timeout 5 --max-time 15 -o "${sumfile}" "${url}.sha256" 2>/dev/null \
   && [ -s "${sumfile}" ] && command -v sha256sum >/dev/null 2>&1; then
  expected=$(awk '{print $1}' "${sumfile}")
  actual=$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')
  [ "${expected}" = "${actual}" ] || die "sha256 MISMATCH for ${asset} (expected ${expected}, got ${actual}) — refusing to install"
  echo "==> sha256 verified"
else
  # actions/runner does not publish a per-asset .sha256 sidecar (checked at
  # write time); integrity then rests on HTTPS from github.com + the optional
  # RUNNER_VERSION pin. Warn, do not silently pretend.
  echo "WARN: no sha256 sidecar available — integrity relies on HTTPS (+ pin RUNNER_VERSION for reproducible installs)" >&2
fi

# --- unpack + configure ------------------------------------------------------------
echo "==> Installing into ${RUNNER_HOME}"
mkdir -p "${RUNNER_HOME}"
tar -xzf "${tmpdir}/${asset}" -C "${RUNNER_HOME}"

cd "${RUNNER_HOME}"
echo "==> Configuring for https://github.com/${OWNER} (labels: ${LABELS})"
./config.sh --url "https://github.com/${OWNER}" --token "${REG_TOKEN}" \
  --labels "${LABELS}" --no-default-labels --unattended
unset REG_TOKEN
echo "==> Token cleared from the environment"

# --- service (sudo territory) --------------------------------------------------------
echo "==> Installing the systemd service (user: ${RUN_USER})"
if [ "$(id -u)" -eq 0 ]; then
  ./svc.sh install "${RUN_USER}"
  ./svc.sh start
elif sudo -n true 2>/dev/null; then
  sudo -n ./svc.sh install "${RUN_USER}"
  sudo -n ./svc.sh start
else
  echo ""
  echo "CONFIGURED but NOT INSTALLED as a service: this step needs sudo and" >&2
  echo "passwordless sudo is not available for $(id -un). Run these two commands yourself:" >&2
  echo "  cd ${RUNNER_HOME} && sudo ./svc.sh install ${RUN_USER} && sudo ./svc.sh start" >&2
  echo "The registration token may expire before you do — if svc.sh fails later," >&2
  echo "re-run this script with a fresh token." >&2
  exit 0
fi

echo "==> Done. Verify with:"
echo "    cd ${RUNNER_HOME} && sudo ./svc.sh status"
echo "    https://github.com/organizations/${OWNER}/settings/runners   (label ${LABELS}, Idle)"
echo "Remember: bare runner, no docker — container-based jobs must not target '${LABELS}'."

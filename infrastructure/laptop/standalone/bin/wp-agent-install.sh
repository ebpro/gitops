#!/usr/bin/env bash
# wp-agent-install.sh — Phase 2 of the standalone kit. CONDITIONNELLE / BLOCKED.
#
# Why conditional (measured 2026-11-18): the Woodpecker server gRPC endpoint
# (Service woodpecker-server port 9000, ns ci) is NOT exposed on any IP this
# laptop can join — TCP :9000 is RST on BOTH nodes (10.2.248.31: the Traefik
# entrypoints are HTTP-routed only, no gRPC route and no NodePort; and the
# lima worker, where only 443/6443-class host ports answer). So an agent
# started today has nothing to connect to. Two unblock paths:
#   (a) TUNNEL ROUTE: run systemd/wp-runner-tunnel.service (ssh -> 
#       compute-lsis-2 -> kubectl port-forward) and point the agent at
#       localhost:9000 (the default below). Works today, one SSH session.
#   (b) REAL EXPOSURE: a TCPRoute/NodePort for gRPC decided IN GIT and
#       reconciled by ArgoCD. Out of scope for this kit (cluster change).
# Until (a) or (b) is standing, this script only STAGES files under
# ./wp-agent/ — binary, root-only env file, unit template. It installs NO
# service and writes nothing outside its staging dir: activation is a
# documented human step (README "Phase 2").
#
# Inputs (env):
#   WP_SERVER      host:port the agent dials  (default localhost:9000 = tunnel)
#   WP_TOKEN       agent secret, REQUIRED.    (env or hidden read -rs prompt;
#                  never echoed; stored only in wp-agent/env, chmod 600)
#   WP_AGENT_HOME  staging dir                (default ./wp-agent)
#   WP_VERSION     pin e.g. v3.5.3            (default: latest via GitHub API)
set -euo pipefail

WP_SERVER="${WP_SERVER:-localhost:9000}"
WP_AGENT_HOME="${WP_AGENT_HOME:-$PWD/wp-agent}"
WP_VERSION="${WP_VERSION:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
[ "${1:-}" != "--help" ] || { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -eq 0 ] || die "no positional arguments — configure via WP_SERVER / WP_TOKEN / WP_AGENT_HOME env"
command -v curl >/dev/null 2>&1 || die "missing dependency: curl"
[ "$(uname -m)" = "x86_64" ] || die "this script stages a linux-amd64 agent only (arch: $(uname -m))"

# --- agent secret (hidden prompt; persisted ONLY in the 0600 env file) ----------
if [ -z "${WP_TOKEN:-}" ]; then
  printf 'Woodpecker agent secret (hidden; cluster-side value, see README): '
  read -r -s WP_TOKEN; echo
  [ -n "${WP_TOKEN}" ] || die "no WP_TOKEN provided — nothing was staged"
fi

# --- resolve the latest release and the agent asset -------------------------------
echo "==> Resolving woodpecker-ci/woodpecker release"
api_url="https://api.github.com/repos/woodpecker-ci/woodpecker/releases/latest"
if [ -n "${WP_VERSION}" ]; then
  tag="${WP_VERSION}"
  api_url="https://api.github.com/repos/woodpecker-ci/woodpecker/releases/tags/${tag}"
fi
api_json=$(curl -fsS --connect-timeout 5 --max-time 15 \
  -H 'Accept: application/vnd.github+json' "${api_url}") \
  || die "cannot reach the GitHub releases API (rate limit? VPN?)"
[ -n "${tag}" ] || tag=$(printf '%s' "${api_json}" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
[ -n "${tag}" ] || die "could not parse tag_name from the API answer"

agent_url=$(printf '%s' "${api_json}" \
  | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' \
  | sed 's/.*"\(https[^"]*\)"/\1/' \
  | grep -E '/woodpecker-agent-linux-amd64(\.gz|\.xz|\.tar\.gz)?$' \
  | head -n1)
[ -n "${agent_url}" ] || die "no woodpecker-agent-linux-amd64 asset found in ${tag} — check the release page and pin WP_VERSION"
asset=${agent_url##*/}
echo "==> Using ${tag} / ${asset}"

# --- download, checksum (if published), stage binary --------------------------------
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
curl -fL --connect-timeout 5 --max-time 300 -o "${tmpdir}/${asset}" "${agent_url}" \
  || die "download failed: ${agent_url}"

verified=0
if command -v sha256sum >/dev/null 2>&1; then
  # 1) per-asset sidecar, 2) aggregate sums file — verify whichever exists.
  if curl -fsS --connect-timeout 5 --max-time 15 -o "${tmpdir}/sum" "${agent_url}.sha256" 2>/dev/null \
     && [ -s "${tmpdir}/sum" ]; then
    expected=$(awk '{print $1}' "${tmpdir}/sum")
    verified=1
  elif sums_url=$(printf '%s' "${api_json}" \
       | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' \
       | sed 's/.*"\(https[^"]*\)"/\1/' \
       | grep -E '/(sha256sums|checksums)(\.txt)?$' | head -n1) \
     && [ -n "${sums_url}" ] \
     && curl -fsS --connect-timeout 5 --max-time 30 -o "${tmpdir}/sums" "${sums_url}"; then
    expected=$(awk -v n="${asset}" '$2==n || $2=="./"n {print $1; exit}' "${tmpdir}/sums")
    [ -n "${expected}" ] && verified=1
  fi
  if [ "${verified}" -eq 1 ]; then
    actual=$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')
    [ "${expected:-}" = "${actual}" ] || die "sha256 MISMATCH for ${asset} — refusing to stage"
    echo "==> sha256 verified"
  else
    echo "WARN: no published checksum found for ${asset} — integrity rests on HTTPS (+ pin WP_VERSION)" >&2
  fi
fi

mkdir -p "${WP_AGENT_HOME}/bin"
case "${asset}" in
  *.tar.gz) tar -xzf "${tmpdir}/${asset}" -C "${WP_AGENT_HOME}/bin" ;;
  *.gz)     gunzip -c "${tmpdir}/${asset}" > "${WP_AGENT_HOME}/bin/woodpecker-agent" ;;
  *)        cp "${tmpdir}/${asset}" "${WP_AGENT_HOME}/bin/woodpecker-agent" ;;
esac
chmod 0755 "${WP_AGENT_HOME}/bin/woodpecker-agent"

# --- env file (root-free but 0600) + unit template ------------------------------------
umask 077
printf 'WOODPECKER_SERVER=%s\nWOODPECKER_AGENT_SECRET=%s\nWOODPECKER_BACKEND_LOCAL=true\n' \
  "${WP_SERVER}" "${WP_TOKEN}" > "${WP_AGENT_HOME}/env"
unset WP_TOKEN
chmod 0600 "${WP_AGENT_HOME}/env"

WP_AGENT_HOME=$(realpath "${WP_AGENT_HOME}")
cat > "${WP_AGENT_HOME}/wp-agent.service" <<UNIT
# Generated by wp-agent-install.sh — review, then install as a USER unit
# (this is deliberately NOT pushed into /etc/systemd by the script):
#   mkdir -p ~/.config/systemd/user
#   cp ${WP_AGENT_HOME}/wp-agent.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now wp-runner-tunnel.service wp-agent.service
# WOODPECKER_BACKEND_LOCAL=true: the laptop has no docker daemon, so only
# pipelines with backend: local steps can run here (README "Known limits").
[Unit]
Description=Woodpecker CI agent (standalone laptop, bare local backend)
After=network-online.target wp-runner-tunnel.service
Wants=wp-runner-tunnel.service

[Service]
Type=simple
ExecStart=${WP_AGENT_HOME}/bin/woodpecker-agent
EnvironmentFile=${WP_AGENT_HOME}/env
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT

echo "==> Staged under ${WP_AGENT_HOME}: bin/woodpecker-agent, env (0600), wp-agent.service"
echo "Connectivity precondition (tunnel route): the gRPC port must answer locally first —"
echo "  systemctl --user enable --now wp-runner-tunnel.service"
echo "  timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000' && echo TUNNEL_UP"
echo "Then install + start the agent unit (commands echoed inside wp-agent.service)."

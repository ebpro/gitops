#!/usr/bin/env bash
# runner-net-cleanup.sh - purge residual Cilium kernel-level networking state
# from the host AFTER k3s-agent has been stopped. Shared by runner-leave.sh
# and runner-auto-leave.sh; safe to run by hand.
#
# WHY: in tunnel mode Cilium installs cgroup socket-LB eBPF programs plus an
# `ip rule fwmark 0x200/0xf00 lookup 2004` policy route on the host, which
# HIJACK every local connection to the Traefik LB VIP 10.2.248.31 into the
# cluster overlay. `systemctl stop k3s-agent` does NOT undo this - verified
# live 2026-10-14 (documented incident): after the stop, `ip rule show` still
# listed `9: from all fwmark 0x200/0xf00 lookup 2004` and
# `nft list ruleset | grep -ciE 'cilium|10.2.248'` still returned 37. While
# the laptop is remote on a VPN whose gateway drops the overlay's UDP underlay,
# those hijacked connections then black-hole (curl to the VIP = 000) and the
# user's web access to the lab apps breaks even though the runner "left".
#
# Purge order (each step detects, acts, reports; absence is silently OK -
# idempotent, safe to re-run):
#   (a) ip rules matching `fwmark 0x200/0xf00` or `lookup 2004`
#   (b) every nft table whose name contains "cilium"
#   (c) every cilium-named eBPF program attached under the unified cgroup
#       trees (/sys/fs/cgroup, plus /run/cilium/cgroupv2 when present)
#   (d) best-effort: cilium_net / cilium_host / cilium_vxlan leftover links
#
# NEVER issues reboot/poweroff. NEVER installs packages (install.sh owns
# provisioning). Exits 0 even on PARTIAL; the PASS/PARTIAL verdict is in the
# summary.
set -euo pipefail

# --- root: re-exec under sudo when needed ------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  fi
  echo "ERROR: needs root (sudo) and sudo is unavailable." >&2
  exit 1
fi

# --- guard: the agent must be stopped or it just re-attaches everything ------
if systemctl is-active --quiet k3s-agent; then
  echo "ERROR: stop k3s-agent first (sudo systemctl stop k3s-agent) - the agent" >&2
  echo "       re-installs the hijack state faster than this script can purge it." >&2
  exit 1
fi

# --- (a) Cilium policy-routing rules ------------------------------------------
echo "==> (a) Cilium policy-routing ip rules"
rules=$(ip -o rule show | grep -E 'fwmark 0x200/0xf00|lookup 2004' || true)
if [ -z "${rules}" ]; then
  echo "    none present"
else
  while read -r pref rest; do
    [ -n "${pref}" ] || continue
    pref="${pref%:}"
    if ip rule del pref "${pref}" 2>/dev/null; then
      echo "    removed ip rule fwmark 0x200/0xf00 policy entry (pref ${pref}: ${rest})"
    else
      echo "    WARN: could not delete ip rule pref ${pref}: ${rest}" >&2
    fi
  done <<< "${rules}"
fi

# --- (b) Cilium nftables tables ------------------------------------------------
echo "==> (b) Cilium nft tables"
if command -v nft >/dev/null 2>&1; then
  tables=$(nft list tables 2>/dev/null | grep -i cilium || true)
  if [ -z "${tables}" ]; then
    echo "    none present"
  else
    while read -r fam name; do
      [ -n "${name:-}" ] || continue
      if nft delete table "${fam}" "${name}" 2>/dev/null; then
        echo "    deleted nft table ${fam} ${name}"
      else
        echo "    WARN: could not delete nft table ${fam} ${name}" >&2
      fi
    done <<< "${tables}"
  fi
else
  echo "    WARN: nft binary unavailable - skipping nft purge" >&2
fi

# --- (c) Cilium cgroup eBPF attachments ----------------------------------------
# bpftool is the only reliable way to detach the socket-LB programs; it ships in
# linux-tools-common / linux-tools-$(uname -r) (provisioned outside this script).
CGROOTS="/sys/fs/cgroup"
[ -d /run/cilium/cgroupv2 ] && CGROOTS="${CGROOTS} /run/cilium/cgroupv2"

if ! command -v bpftool >/dev/null 2>&1; then
  echo "WARN: bpftool unavailable - cgroup eBPF programs may persist until reboot." >&2
  echo "      Provision with: sudo apt-get install -y linux-tools-common \"linux-tools-\$(uname -r)\"" >&2
  echo "      Continuing with (a), (b), (d)."
else
  echo "==> (c) Cilium cgroup eBPF attachments"
  found_any=0
  for root in ${CGROOTS}; do
    # One JSON object per line, then keep only cilium-named programs.
    progs=$(bpftool cgroup tree -j "${root}" 2>/dev/null \
            | sed 's/},{/}\n{/g' | grep '"name":"cilium' || true)
    while IFS= read -r obj; do
      [ -n "${obj}" ] || continue
      found_any=1
      id=$(sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' <<<"${obj}")
      atype=$(sed -n 's/.*"attach_type":"\([^"]*\)".*/\1/p' <<<"${obj}")
      cgp=$(sed -n 's/.*"cgroup_path":"\([^"]*\)".*/\1/p' <<<"${obj}" | sed 's|\\/|/|g')
      pname=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' <<<"${obj}")
      case "${cgp}" in
        "/") target="${root}" ;;
        /*)  target="${root}${cgp}" ;;
        *)   target="${root}/${cgp}" ;;
      esac
      detached=0
      # bpftool releases differ on how the attach type token is spelled on the
      # command line (cgroup/sock_create vs sock_create vs cgroup_sock_create);
      # try all three before declaring failure.
      for cand in "${atype}" "${atype#cgroup/}" "${atype//\//_}"; do
        [ -n "${cand}" ] || continue
        if bpftool cgroup detach "${target}" "${cand}" "${id}" >/dev/null 2>&1; then
          echo "    detached ${pname} (id ${id}, ${atype}) from ${target}"
          detached=1
          break
        fi
      done
      [ "${detached}" -eq 1 ] \
        || echo "    WARN: could not detach ${pname} (id ${id}, ${atype}) from ${target}" >&2
    done <<< "${progs}"
  done
  [ "${found_any}" -eq 1 ] || echo "    none present"
fi

# --- (d) leftover Cilium links (best-effort, failures are inert) ---------------
echo "==> (d) Leftover Cilium links (best-effort)"
links_seen=0
for link in cilium_net cilium_host cilium_vxlan; do
  if ip link show "${link}" >/dev/null 2>&1; then
    links_seen=1
    ip link set "${link}" down 2>/dev/null || true
    if ip link delete "${link}" 2>/dev/null; then
      echo "    deleted link ${link}"
    else
      echo "    note: link ${link} busy - left in place (inert once rules/eBPF are gone)"
    fi
  fi
done
[ "${links_seen}" -eq 1 ] || echo "    none present"

# --- self-check -----------------------------------------------------------------
echo "==> Self-check"
left_rules=$(ip -o rule show 2>/dev/null | grep -Ec 'fwmark 0x200/0xf00|lookup 2004' || true)
left_rules=${left_rules:-0}
left_nft=0
if command -v nft >/dev/null 2>&1; then
  left_nft=$(nft list tables 2>/dev/null | grep -ci cilium || true)
  left_nft=${left_nft:-0}
fi
left_ebpf=-1   # -1 = UNKNOWN (bpftool unavailable, cannot verify)
if command -v bpftool >/dev/null 2>&1; then
  left_ebpf=0
  for root in ${CGROOTS}; do
    n=$(bpftool cgroup tree -j "${root}" 2>/dev/null \
        | sed 's/},{/}\n{/g' | grep -c '"name":"cilium' || true)
    left_ebpf=$((left_ebpf + ${n:-0}))
  done
fi

if [ "${left_rules}" -eq 0 ] && [ "${left_nft}" -eq 0 ] && [ "${left_ebpf}" -eq 0 ]; then
  echo "PASS: all Cilium host-networking state removed - plain network path restored."
elif [ "${left_rules}" -eq 0 ] && [ "${left_nft}" -eq 0 ] && [ "${left_ebpf}" -lt 0 ]; then
  echo "PARTIAL: ip rules + nft purged; cgroup eBPF state UNKNOWN (no bpftool)."
  echo "         If web access via the LB VIP still black-holes, install bpftool or reboot."
else
  echo "PARTIAL: residual state remains (rules=${left_rules} nft=${left_nft} ebpf=${left_ebpf}; ebpf=-1 means unverified)."
  echo "         Hint: a reboot restores full plain-network operation (this script never reboots)."
fi

exit 0

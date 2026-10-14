# compute-lsis-2 host tooling

Host-level (outside git's ArgoCD reach) configuration for `compute-lsis-2`, the
amd64 control-plane node. Cluster-side resources are GitOps-managed; **udev
rules, fstab, and kernel power settings cannot be** — they live here as the
source of truth the operator applies by hand.

## USB autosuspend — `99-usb-never-autosuspend.rules`

The `/mnt/hdd` disk enclosure is USB-attached and hosts the garage backup-tier
static Local PVs. USB runtime autosuspend must never spin it down mid-write
(LMDB corruption risk — see the header comment in the rule file for the
2026-10-14 rationale). Install from this file:

```
sudo cp 99-usb-never-autosuspend.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Runtime (non-persistent) equivalent used on 2026-10-14, before the rule
existed — disables autosuspend on every currently-attached USB device:

```
for d in /sys/bus/usb/devices/*/power/control; do echo on > "$d"; done
```

## /mnt/hdd mount (fstab)

Observed fstab entry backing the enclosure (UUID-based, survives replug/rename):

```
UUID=8f32b18d-4db6-4e25-af75-2ab58a79f8c9 /mnt/hdd ext4 defaults 0 0
```

**Dependency:** the `kubernetes/garage-storage/` PVs (`garage-meta-hdd`,
`garage-data-hdd`, SC `local-path-hdd`) point into `/mnt/hdd/k3s-storage/garage/…`
and carry `nodeAffinity: compute-lsis-2`. Local PVs perform no mount sanity
check — if this fstab mount does not survive (bad UUID, enclosure replugged to
a different port with stale power settings, disk removed), the garage pods
would write into an empty `/mnt/hdd` directory tree on the root filesystem
instead of the enclosure. Keep this mount healthy and the udev rule installed.

Related platform lessons are recorded in the repo-root `AGENTS.md`
("Troubleshooting Patterns": garage storage relocation, 2026-10-14).

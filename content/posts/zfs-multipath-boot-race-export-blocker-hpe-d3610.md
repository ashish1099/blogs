---
title: "ZFS + multipath on HPE D3610: boot race, a silent export blocker, and syncoid divergence"
date: 2026-06-16
tags: [zfs, multipath, sanoid, syncoid, hpe, storage, linux]
draft: false
---

We run a pair of ZFS storage nodes (storage-a and storage-b) backed by HPE D3610 JBODs — 24 × 18 TB SAS HDDs each,
dual-pathed through dm-multipath, in two 11-wide raidz3 vdevs. Replication is handled by
[sanoid/syncoid](https://github.com/jimsalterjrs/sanoid) in pull mode (storage-b pulls from storage-a).

A routine check revealed syncoid had been failing silently for three weeks. What followed was a
day of debugging that surfaced three non-obvious problems. This post documents each one.

---

## The silent failure

The systemd units were configured to tolerate a non-zero exit (`SuccessExitStatus=2`), which meant
`systemctl status syncoid-replication@slow` looked like this:

```
Exited (with status 2)
```

...and the last line of the journal log was the innocuous `Nothing to do`. The real error —
a `CRITICAL ERROR` several lines above — scrolled past the truncated `systemctl status` view
and was never surfaced in any alert.

**Lesson:** `SuccessExitStatus=2` on a replication unit masks divergence for as long as the unit
runs. Add explicit monitoring on syncoid's log output for `CRITICAL ERROR`, or use
`ExecStartPost=/usr/bin/grep -qv "CRITICAL ERROR" /path/to/syncoid.log` as a canary.

---

## Problem 1: ZFS pool imported on raw `sd*` instead of multipath

`zpool status slow` on the backup node showed all member devices as `sdy`, `sdag`, `sdbt`, … —
raw single paths — instead of `dm-name-mpatha`, `dm-name-mpathb`, …

This means no path-failover HA. If one SAS cable or path fails, the pool sees missing devices
and can go faulted.

### Root cause: a race on boot

On boot, `zfs-import-cache.service` runs before `multipathd.service` claims the raw block
devices. The ZFS import finds the disks first and grabs them directly.

### Fix: re-import the pool on `/dev/mapper`

```sh
# maintenance window — stop replication and anything holding the pool
systemctl stop 'syncoid-replication@*' cron
pkill -f inventory-agent       # see Problem 2

zpool export slow
systemctl restart multipathd   # multipathd now claims the freed disks
zpool import -d /dev/mapper slow   # MUST specify -d /dev/mapper
zpool status slow              # members now read dm-name-mpath*
```

### Make it survive the next reboot

```sh
mkdir -p /etc/systemd/system/zfs-import-cache.service.d
printf '[Unit]\nWants=multipathd.service\nAfter=multipathd.service\n' \
  > /etc/systemd/system/zfs-import-cache.service.d/multipath.conf
systemctl daemon-reload
```

Without this drop-in, `zpool import` on the next reboot races multipathd again and you're back
to raw `sd*`. With it, the import is deferred until multipathd has finished.

**After the next reboot:** always verify with `zpool status slow | grep -E 'mpath|sd[a-z]+'`
to confirm devices stayed on the multipath names.

---

## Problem 2: an inventory agent blocking `zpool export`

After stopping replication, `zpool export slow` still failed:

```
cannot unmount '/slow': pool or dataset is busy
```

`fuser -vm /slow` pointed to a single PID. `ps faux | grep <PID>` showed:

```
/opt/vendor/inventory-agent -w /opt/vendor/  (D state, 848 CPU-hours)
```

The agent is a software-inventory scanner. It had been crawling the `/slow` mountpoint, nearly
200 TB of data, for days, accumulating CPU time and holding the pool open, completely stuck in D
(uninterruptible sleep) because of the I/O depth. That's why the CPU spike was never noticed
as abnormal: a D-state process doesn't show in `top` as a runaway.

### The non-obvious part

The agent here is launched from **cron**, not from a systemd unit. `systemctl status` finds
nothing to report. You can't stop it with `systemctl stop`. `systemctl stop cron` to prevent
re-launch, then `pkill -f inventory-agent` to kill the in-flight scan.

### Permanent fix

Exclude the ZFS data mountpoints in the agent's scan configuration.
Never let an inventory scanner crawl a multi-TB data pool — the scan will take longer than
its own cron interval, stack up, and eventually hold the pool open indefinitely.

Verify after the next scheduled scan time: `fuser -m /slow` should return empty.

---

## Problem 3: syncoid `--force-delete` is `zfs destroy -r` — never use it on a parent

The replication failure was caused by snapshot divergence: the source and target had no common
snapshot, so syncoid refused to proceed. The fix depends on _what the dataset actually is_:

| Dataset type | `usedds` | Has children? | Safe fix |
|---|---|---|---|
| Empty container (just a namespace root) | ~0 | yes | `syncoid --skip-parent` — skips the root, keeps syncing children |
| Leaf dataset | any | no | `syncoid --force-delete` — destroys target, full re-send |
| Data-bearing root (holds real data + has children) | large | yes | Rename-swap re-seed — see below |

**`syncoid --force-delete` = `zfs destroy -r <target>` followed by a full send.** If the target
has children, `zfs destroy -r` removes the entire subtree. We had 121 TB of children under
`slow` — `--force-delete` on the root would have wiped all of it.

### How to classify

```sh
# usedds = space used by THIS dataset only, excluding children
zfs list -o name,used,usedds slow

# zero snapshots on target = no common base exists
zfs list -t snapshot -d1 -H -o guid,name slow | wc -l
```

An empty container root shows `usedds` ≈ 0 (a few hundred KB at most). A data-bearing root
shows `usedds` in the tens or hundreds of GB — that's real data, and blowing it up with
`--force-delete` would lose it.

### Data-bearing root with no common snapshots: rename-swap re-seed

When the root holds real data AND has no common snapshot with the source (impossible to
do an incremental), the safest path is:

```sh
systemctl stop 'syncoid-replication@*'
zfs rename slow slow_old              # children follow: slow_old/child1, ...
syncoid --no-sync-snap root@source:slow slow   # full-seed the root only

# move children back under the new root:
for child in $(zfs list -H -d1 -o name slow_old | tail -n +2); do
    zfs rename "$child" "slow/${child#slow_old/}"
done

# verify, then after full verification only:
# zfs destroy -r slow_old
```

⚠️ Keep `slow_old` alive until you've fully verified the new root. The rename causes transient
mountpoint disruption — do this in a maintenance window on a non-serving replica.

---

## Disk count pitfall: model-filtered counts miss mixed-drive pools

A `grep 'HPE,MB018000JXLAU' /proc/scsi/scsi | wc -l` returned 23, not 24. Panic.

The 24th drive was a 20 TB Seagate in bay 1E:1:8. Model-filtered counts
and size-filtered counts (`lsblk | awk '$1=="16.4T"'`) both skipped it. The true count:

```sh
multipath -ll | grep -cE '^mpath'
```

Don't count by model or size in mixed-drive pools. Count multipath maps.

---

## Which controller manages which disks?

On HPE D3610 JBOD setups with a Smart Array HBA, the disk controllers are separate:

- **HPE Smart Array P408e-p** (ssacli) — manages the D3610 JBOD HDDs
- **Broadcom/LSI** (storcli64 /c0) — manages on-board SSDs or a separate RAID card

Using `storcli64` to query the D3610 disks returns completely wrong results (it'll show you
the SSD pool, not the HDDs). Install `ssacli` from the HPE MCP SDR repo:

```sh
# /etc/apt/sources.list.d/hpe-mcp.list
deb https://downloads.linux.hpe.com/SDR/repo/mcp jammy/current non-free

# GPG — ALL THREE keys required:
curl -fsSL https://downloads.linux.hpe.com/SDR/hpePublicKey1024.pub | apt-key add -
curl -fsSL https://downloads.linux.hpe.com/SDR/hpePublicKey2048.pub | apt-key add -
curl -fsSL https://downloads.linux.hpe.com/SDR/hpePublicKey2048_key2.pub | apt-key add -

apt-get update && apt-get install ssacli
```

Missing `hpePublicKey2048_key2.pub` causes `NO_PUBKEY E3FE26E774C3A4A2` on `apt update`.

Then:

```sh
ssacli ctrl all show               # confirm slot number
ssacli ctrl slot=14 pd all show status  # all 24 drives + bay labels for LED lighting
ssacli ctrl slot=14 pd 1E:1:8 modify led=on   # light a drive for the DC
```

---

## Summary

| Problem | Root cause | Fix |
|---|---|---|
| ZFS pool on raw `sd*` | `zfs-import-cache` races `multipathd` on boot | `zpool import -d /dev/mapper` + systemd drop-in |
| `zpool export` hangs | an inventory agent (cron, D-state) scanning the data pool | `pkill` + a scan exclusion in its config |
| syncoid fails silently | `SuccessExitStatus=2` masks `CRITICAL ERROR` | Log grep monitoring on replication units |
| syncoid divergence | No common snapshot — fix depends on dataset type | `--skip-parent` / `--force-delete` (leaf only) / rename-swap |

# Future: mirror `/srv/docker-data` with a spare SSD

**Not yet done** — confirmed against the live box (2026-08-11): `sdb` is still
a lone, unmirrored SSD. This is a distinct thing from the restic-level "array
mirror" in [storage-and-backup.md](storage-and-backup.md#the-tradeoff-in-putting-the-repo-on-sdb),
which already exists — that's a second *backup copy*; this is RAID-mirroring
the live disk itself.

## Goal

A RAID mirror is not a backup — it protects against a disk dying, not against
you dropping a table. What it does do is make "swap a disk, keep working" the
recovery path for routine disk failure, instead of falling back to the real
backups (local `restic-repo`, the `md0` mirror, B2, and the
[Pi target](pi-backup.md)) for something a mirror should have absorbed.

## Current state

- `sdb` → `/srv/docker-data`, 238.5G. Re-check usage with `df -h` before
  starting — this is a light lift only if usage is still small.
- No partition table on `sdb` — `/dev/sdb` mounts directly, matching the
  whole-disk convention already used for the `md0` HDDs.

## Pre-flight

1. Confirm a recent clean backup (local + B2):
   ```bash
   sudo systemctl start homelab-backup.service
   journalctl -u homelab-backup.service -f
   ```
2. Physically install the spare SSD, then identify it:
   ```bash
   lsblk
   ```
   Confirm it's the *new* device (not `sdb`, not `nvme0n1`, not the `md0`
   members) — call it `<NEW_DEV>` below. Size must be ≥ 238.5G; RAID1
   truncates to the smaller member.

## Steps

**1. Stop the stack.**
```bash
cd /opt/homelab && docker compose down
```

**2. Stage the existing data off `sdb`:**
```bash
sudo mkdir -p /root/docker-data-staging
sudo rsync -aHAX /srv/docker-data/ /root/docker-data-staging/
```
`-H` preserves hardlinks, `-A`/`-X` preserve ACLs/xattrs — matters for
Postgres/Traefik file permissions.

**3. Unmount and wipe both members** — both need to be signature-free before
`mdadm --create`:
```bash
sudo umount /srv/docker-data
sudo wipefs -a /dev/sdb
sudo wipefs -a <NEW_DEV>
```

**4. Build the array.**
```bash
sudo apt install -y mdadm
sudo mdadm --create /dev/md1 --level=1 --raid-devices=2 /dev/sdb <NEW_DEV>
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
sudo update-initramfs -u
sudo mkfs.ext4 /dev/md1
```

**5. Restore the data onto the array.**
```bash
sudo mkdir -p /mnt/md1-tmp
sudo mount /dev/md1 /mnt/md1-tmp
sudo rsync -aHAX /root/docker-data-staging/ /mnt/md1-tmp/
diff -rq /root/docker-data-staging /mnt/md1-tmp   # should print nothing
sudo umount /mnt/md1-tmp
```

**6. Point `/srv/docker-data` at the array.**
```bash
sudo blkid /dev/md1
sudo nano /etc/fstab
```
Replace the existing `sdb` UUID line for `/srv/docker-data` with `md1`'s UUID,
same `nofail` pattern as the rest of `/etc/fstab`:
```
UUID=<md1-uuid>  /srv/docker-data  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```
```bash
sudo systemctl daemon-reload
sudo mount -a
df -h /srv/docker-data      # should show ~238G, same used size as before
```

**7. Bring the stack back up and verify.**
```bash
cd /opt/homelab && docker compose up -d
docker compose ps
```
All containers healthy, apps reachable as before — same files, same path, new
block device underneath.

**8. Watch the initial resync finish before trusting the mirror.**
```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md1
```
Wait for `[UU]` — until then it's effectively running on one disk, same
caveat as any fresh RAID1 build.

**9. Clean up staging once confirmed.**
```bash
sudo rm -rf /root/docker-data-staging
```

## Future member failure

Same drill as `md0` (see
[storage-and-backup.md](storage-and-backup.md#replacing-a-failed-raid1-member)),
just on `md1`:
```bash
sudo mdadm --detail /dev/md1                    # identify the failed member
sudo mdadm --manage /dev/md1 --remove <DEV>
#  power down, swap the disk, boot
sudo mdadm --manage /dev/md1 --add <NEW_DEV>
cat /proc/mdstat                                # watch the rebuild
```

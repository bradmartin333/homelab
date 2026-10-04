# Storage layout & backup

How the disks are laid out and what gets backed up where. Setting the backup
up on a fresh box is [systemd/README.md](../systemd/README.md); getting data
back out is [restore.md](restore.md).

## Layout

| Mount                           | Disk  | Holds                                          | Backed up             |
| -------------------------------- | ----- | ----------------------------------------------- | ---------------------- |
| `/`                               | nvme  | OS, docker images                                | no — rebuildable       |
| `/opt/homelab`                    | nvme  | this repo, decrypted `.env` files                | restic + B2            |
| `/srv/docker-data`                | `sdb` | postgres PGDATA, immich PGDATA, vikunja files    | restic + B2, partial   |
| `/srv/docker-data/gickup`         | `sdb` | GitHub repo mirrors — see [github-mirrors.md](github-mirrors.md) | restic + B2  |
| `/srv/docker-data/restic-repo`    | `sdb` | the local restic repository                      | is the backup          |
| `/srv/media/immich`               | `md0` | Immich media library (`$UPLOAD_LOCATION`)        | rPi replica — see [`pi-backup.md`](pi-backup.md) |
| `/srv/media/restic-mirror`        | `md0` | mirror of the local restic repo                  | is a backup copy       |

`/srv/media` is a **RAID1 mirror — redundant storage, not a backup.** It
protects against a single disk failure, not against `rm -rf`, corruption, a bad
upgrade, or the house burning down; the mirror replicates all of those to both
disks instantly. (It was previously mounted at `/mnt/backup`, which described
neither what it held nor what it was for — if you see that path referenced
anywhere else, it's describing the general pattern, not this box's current
state.)

The actual backup is the restic repo on `sdb`, its mirror on `/srv/media`, and
its offsite copy in B2. See [restore.md](restore.md) for which to use when.

Three things are deliberately excluded from restic:

- **Live PGDATA** (`/srv/docker-data/postgres`, `/srv/docker-data/immich/postgres`).
  A hot copy of a running cluster's data directory is inconsistent and won't
  restore. `scripts/backup.sh` dumps both clusters with `pg_dumpall` into
  `/var/lib/homelab-backup-staging` instead, and *those* get backed up.
- **The restic repo itself** (`/srv/docker-data/restic-repo`). `sdb` is a
  single volume mounted at `/srv/docker-data`, so there's nowhere on that disk
  that isn't inside the tree being backed up. Without the exclude, restic
  feeds its own output back into itself.
- **The Immich media library** (`/srv/media`). Too large for B2 at a sane
  cost, and already mirrored. A Raspberry Pi replica is the second copy for
  it — see [pi-backup.md](pi-backup.md) for current status.

### The tradeoff in putting the repo on sdb

The local repo shares a disk with the live data it backs up. If `sdb` dies you
lose both at once, and recovery becomes a restore from the array mirror or B2
rather than "the disk right next to it." That's survivable — the mirror and B2
both have full history — but it's a real reduction in redundancy versus
keeping the repo somewhere else entirely.

It also means **a runaway repo can fill the disk postgres is writing to.**
`healthcheck.sh`'s disk-usage check warns at 85%; treat that warning on
`/srv/docker-data` as urgent, and trim `LOCAL_KEEP` in `backup.sh` if it fires.

## How the two postgres clusters get backed up

Two entirely separate postgres containers, neither backed up by copying its
files.

| Cluster        | Container         | Data dir                           | Contains                                           |
| -------------- | ------------------ | ----------------------------------- | --------------------------------------------------- |
| app cluster    | `postgres`         | `/srv/docker-data/postgres`         | the `vikunja` database, and anything added later    |
| Immich cluster | `immich-postgres`  | `/srv/docker-data/immich/postgres`  | Immich's photo metadata, albums, faces, embeddings  |

Separate because Immich pins its own postgres image (14, with `vectorchord`/
`pgvectors` compiled in) while the app cluster runs stock postgres 18 — they
can't share a server.

**Why not just back up the data directories?** A running cluster writes to
them constantly. Copying `PGDATA` out from under a live postgres gives you a
torn snapshot — pages half-written, WAL inconsistent with the heap. It
restores into a cluster that refuses to start, or worse, one that starts and
is subtly corrupt. Both directories are excluded in `scripts/backup.sh`.

**What happens instead, each night, per cluster:**

1. `pg_dumpall --clean --if-exists` runs *inside* the container via `docker
   exec` — a consistent logical snapshot straight from postgres itself, safe
   on a live database. `--clean --if-exists` drops each object before
   recreating it, so a restore lands cleanly on a non-empty cluster.
2. Output goes to `/var/lib/homelab-backup-staging/<name>.sql.tmp`. If the
   dump dies halfway, last night's good file is untouched.
3. The temp file is checked for pg_dumpall's completion trailer and a minimum
   size before being promoted over the real file.
4. `restic backup` picks up the whole staging directory as one of its
   `SOURCES`.

`pg_dumpall` (not `pg_dump`) captures cluster-wide state too — roles,
passwords, grants — so a restore brings back the `vikunja` login role, not
just its tables.

**The dumps are stored uncompressed, deliberately.** restic already chunks,
dedupes, and compresses. Tonight's dump differs from last night's only in the
changed rows, so restic stores just the delta — pre-gzipping destroys that,
since two gzip streams of near-identical input share almost no bytes.

## Physical layout

| Device          | Size    | Type    | Mount              |
| ---------------- | ------- | -------- | ------------------- |
| `nvme0n1p1`       | 1G      | NVMe     | `/boot/efi`          |
| `nvme0n1p2`       | 237.4G  | NVMe     | `/`                  |
| `sdb`             | 238.5G  | SSD      | `/srv/docker-data`   |
| `sda1` + `sdc1`   | 931.5G  | → `md0`  | `/srv/media`         |

`/srv/media` is **RAID1** (`md0`, 931.4G usable) across `sda`/`sdc`.
`/srv/docker-data` is a single unmirrored SSD mounted as a whole raw device —
no partition table, which is unusual but harmless; `blkid /dev/sdb` still
gives a filesystem UUID for fstab.

Verify before changing anything:

```bash
mountpoint -q /srv/docker-data && mountpoint -q /srv/media && echo "mounts ok"
cat /proc/mdstat          # md0 should read [UU], not [U_]
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
```

`/etc/fstab` entries (`nofail` keeps the box booting when a disk is absent —
`backup.sh`/`healthcheck.sh` both assert `mountpoint -q` themselves, since
without `nofail` a missing disk turns the mount into an ordinary directory on
`/` and the stack writes to the OS disk without complaint):

```
UUID=<uuid>  /srv/media        ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
UUID=<uuid>  /srv/docker-data  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

`/etc/mdadm/mdadm.conf` registers `md0` so it assembles under the same name on
every boot instead of drifting to `/dev/md127`. Regenerate it against
whatever array is actually present rather than copying a UUID from
elsewhere — this file is not portable across hardware:

```bash
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
sudo update-initramfs -u
```

## Backblaze B2

Private bucket, application key scoped to just that bucket with read+write.
In the bucket's lifecycle settings: **"Keep only the last version of the
file"** — restic manages its own history, and without this every file restic
deletes lingers as a hidden version still counting against the 10 GB.

Credentials live at `/root/.restic-b2.env`, outside the git repo, same as
`/root/.restic-password`:

```bash
install -m 600 /dev/null /root/.restic-b2.env
cat > /root/.restic-b2.env <<'EOF'
B2_ACCOUNT_ID=<keyID>
B2_ACCOUNT_KEY=<applicationKey>
RESTIC_B2_REPO=b2:<bucket-name>:homelab
EOF
```

Initializing a repo — local, mirror, or B2 — always uses
`--copy-chunker-params` against whichever repo is the source of truth, which
is what keeps `restic copy` deduplicating instead of re-uploading everything
every night:

```bash
set -a; . /root/.restic-b2.env; set +a
restic -r "$RESTIC_B2_REPO" --password-file /root/.restic-password init \
  --copy-chunker-params \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password
```

All repos share `/root/.restic-password` — `restic copy` has to unlock source
and destination, and one password is one fewer thing to lose.

## The Pi target

The fourth repo, and the only one that includes the Immich library. Reached
over Tailscale rather than the public internet, so it has its own credentials
file rather than reusing B2's shape — and unlike B2, auth is via
`RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` rather than embedded in the URL:

```bash
install -m 600 /dev/null /root/.restic-pi.env
cat > /root/.restic-pi.env <<'EOF'
PI_REPO=rest:http://<PI_TS_IP>:8000/homelab-backup/
RESTIC_REST_USERNAME=homelab-backup
RESTIC_REST_PASSWORD=<htpasswd-password>
EOF
```
The trailing `/homelab-backup/` path segment is required — the server's
`--private-repos` flag only grants access under a path matching the htpasswd
username.

`backup.sh` sources this file with `set -a`, so all three variables end up
exported and restic picks up the REST credentials automatically — no
`--password`-style flag needed for them. The file is treated as optional:
absent means the Pi leg is skipped with a warning rather than failing the
whole nightly run, which is what lets the script-side wiring land before the
physical Pi setup is finished. See [pi-backup.md](pi-backup.md) for the full
setup and current status.

## Staying inside the B2 free tier

**10 GB stored**, free egress up to **3x stored per month**. Uploads and
deletions are free; *downloads* are what can generate a bill.

| restic operation      | What it does on B2                  | Free-tier impact       |
| ----------------------- | ------------------------------------- | ------------------------ |
| `copy` (nightly)         | uploads new chunks                     | free                     |
| `forget` (nightly)       | deletes snapshot files                 | free                     |
| `prune` (1st of month)   | downloads and repacks partial packs    | small egress             |
| `check` (1st of month)   | downloads indexes only                 | tiny egress              |
| `check --read-data`      | downloads **the entire repo**          | avoid — see below        |
| a real restore           | downloads what you restore             | ~1x storage, well under  |

Three knobs, in the order to reach for them:

1. The Immich library is excluded — it's the only genuinely large thing here.
2. Dumps are uncompressed so restic dedupes them (see above) — the difference
   between one delta per night and one full dump per night.
3. `B2_KEEP` in `backup.sh`, currently matching `LOCAL_KEEP` since usage sits
   around 1%. A shorter offsite history is a cheaper concession than a bill,
   if this ever needs trimming.

`healthcheck.sh` reports the B2 repo size every run and warns at 8 GB. The one
thing that grows on its own is Immich's CLIP-embedding database — if the B2
warning ever fires, that's almost certainly why.

Never run `restic check --read-data` against B2 — it downloads roughly 1x your
storage in one go. Use `--read-data-subset=5%` instead, or run full data
verification against the local array where reads are free.

## Adding or replacing a disk

### Replacing a failed RAID1 member

`healthcheck.sh` reports `md0 degraded`, or `/proc/mdstat` shows `[U_]`.
Identify the failed member by serial (`lsblk -o NAME,SIZE,SERIAL`):

```bash
mdadm --detail /dev/md0                  # confirm which member is faulty
mdadm --manage /dev/md0 --remove /dev/sdX1
# physically swap the disk, then partition the replacement to match
sfdisk -d /dev/sda | sfdisk /dev/sdX     # copy the surviving disk's layout
mdadm --manage /dev/md0 --add /dev/sdX1
watch cat /proc/mdstat                   # resync; hours for 1TB
```

The array stays readable and writable throughout. Don't run a `prune` against
the repo while it's resyncing — let it finish first.

### Building a fresh data disk

> Destroys everything on the device. Confirm by size, model, and **serial** —
> never by the `/dev/sdX` name, which can change across reboots.

```bash
wipefs -a /dev/sdX
parted -s /dev/sdX mklabel gpt
parted -s /dev/sdX mkpart primary ext4 0% 100%
mkfs.ext4 -L homelab-data /dev/sdX1
blkid -s UUID -o value /dev/sdX1         # for the fstab line
```

Add the fstab entry (with `nofail`, as above), `systemctl daemon-reload`,
`mount -a`, confirm with `mountpoint -q`.

To move `/srv/docker-data` onto it, stop the stack first so nothing is
writing:

```bash
systemctl stop homelab-backup.timer
docker compose -f /opt/homelab/docker-compose.yml down
rsync -aHAX --info=progress2 /srv/docker-data/ /mnt/newdisk/
```

Swap the fstab entries, remount, bring the stack back up, and only remove the
old copy once `healthcheck.sh` is fully green.

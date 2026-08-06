# Storage layout & backup runbook

How the homelab's disks are laid out, what gets backed up where, and how to add
the Backblaze B2 offsite copy. Run everything as root on the homelab box.

Getting data back out is a separate doc: [restore.md](restore.md). Container and
docker-daemon changes are in
[architecture-migration.md](architecture-migration.md).

## Target layout

| Mount                        | Disk    | Holds                                         | Backed up            |
| ---------------------------- | ------- | --------------------------------------------- | -------------------- |
| `/`                          | nvme    | OS, docker images                             | no — rebuildable     |
| `/opt/homelab`               | nvme    | this repo, decrypted `.env` files             | restic + B2          |
| `/srv/docker-data`           | `sdb`   | postgres PGDATA, immich PGDATA, vikunja files | restic + B2, partial |
| `/srv/docker-data/restic-repo` | `sdb` | the local restic repository                   | is the backup        |
| `/srv/media/immich`          | `md0`   | Immich media library (`$UPLOAD_LOCATION`)     | rPi replica only     |

The naming matters here. `/srv/media` is a **RAID1 mirror — redundant storage,
not a backup.** It exists so a single disk failure isn't a data loss event for
irreplaceable photos. It does not protect against `rm -rf`, corruption, a bad
Immich upgrade, or the house burning down; the mirror replicates all of those to
both disks instantly. It was previously mounted at `/mnt/backup`, which
described neither what it held nor what it was for.

The actual backup is the restic repo on `sdb`, plus its offsite copy in B2.

Three things are deliberately excluded from restic:

- **Live PGDATA** (`/srv/docker-data/postgres`, `/srv/docker-data/immich/postgres`).
  A hot copy of a running cluster's data directory is inconsistent and will not
  restore. `scripts/backup.sh` dumps both clusters with `pg_dumpall` into
  `/var/lib/homelab-backup-staging` instead, and *those* get backed up.
- **The restic repo itself** (`/srv/docker-data/restic-repo`). `sdb` is a single
  volume mounted at `/srv/docker-data`, so there is nowhere on that disk that
  isn't inside the tree being backed up. Without the exclude, restic feeds its
  own output back into itself.
- **The Immich media library** (`/srv/media`). Too large to push to B2 at a sane
  cost, and already mirrored. The remote rPi replica is the offsite plan for it.
  Everything needed to rebuild Immich *around* a restored library — its
  database, config, and this repo — is in restic.

Immich's derived data (thumbnails, encoded video) lives under `$UPLOAD_LOCATION`
too and so is also excluded; Immich regenerates it from the originals on demand.

### The tradeoff in putting the repo on sdb

The local repo shares a disk with the live data it backs up. If `sdb` dies you
lose both at once, and recovery becomes a network restore from B2 rather than a
local one. That is survivable — B2 has the databases and config, and the photos
are on the mirror — but it is a real reduction in redundancy compared to keeping
the repo on `md0`.

It also means **a runaway repo can fill the disk postgres is writing to.** The
disk-usage check in `healthcheck.sh` warns at 85%; treat that warning on
`/srv/docker-data` as urgent rather than informational, and trim `LOCAL_KEEP` in
`backup.sh` if it fires.

## How the two postgres clusters get backed up

There are two entirely separate postgres containers, and neither is backed up by
copying its files.

| Cluster            | Container          | Data dir                            | Contains                                          |
| ------------------ | ------------------ | ----------------------------------- | ------------------------------------------------- |
| app cluster        | `postgres`         | `/srv/docker-data/postgres`         | the `vikunja` database, and anything added later   |
| Immich cluster     | `immich-postgres`  | `/srv/docker-data/immich/postgres`  | Immich's photo metadata, albums, faces, embeddings |

They are separate because Immich pins its own postgres image — version 14 with
the `vectorchord` and `pgvectors` extensions compiled in — while the app cluster
runs stock postgres 18. They can't share a server.

**Why not just back up the data directories?** Because a running cluster is
writing to them constantly. Copying `PGDATA` out from under a live postgres
gives you a torn snapshot: pages half-written, WAL inconsistent with the heap.
It restores into a cluster that refuses to start, or worse, one that starts and
is subtly corrupt. Both directories are therefore in `EXCLUDES` in
`scripts/backup.sh`.

**What happens instead**, each night, for each cluster:

1. `pg_dumpall --clean --if-exists` runs *inside* the container via `docker exec`.
   This asks postgres itself for a consistent logical snapshot, so it's safe on
   a live database. `--clean --if-exists` makes the output drop each object
   before recreating it, so a restore lands cleanly on a non-empty cluster
   instead of erroring on every `CREATE`.
2. Output goes to `/var/lib/homelab-backup-staging/<name>.sql.tmp`. Writing to a
   temp name matters: if the dump dies halfway, last night's good file is still
   sitting there untouched.
3. The temp file is checked for pg_dumpall's completion trailer
   (`-- PostgreSQL database cluster dump complete`), which it only writes as its
   very last act, and for a minimum size. Both must pass.
4. Only then is it renamed over the real file.
5. `restic backup` picks up the whole staging directory as one of its `SOURCES`.

`pg_dumpall` (rather than `pg_dump`) captures cluster-wide state too — roles,
passwords, grants — so a restore brings back the `vikunja` login role, not just
its tables.

**The dumps are stored uncompressed, deliberately.** restic already chunks,
dedupes, and compresses. Tonight's plain-SQL dump differs from last night's only
in the rows that changed, so restic stores just the delta. Pre-gzipping destroys
that — two gzip streams of near-identical input share almost no bytes, so every
night would upload a full copy. On a 10 GB budget that's the difference between
months of history and a few weeks.

## Physical layout

As of 2026-08-05:

| Device            | Size    | Type       | Mount              |
| ----------------- | ------- | ---------- | ------------------ |
| `nvme0n1p1`       | 1G      | NVMe       | `/boot/efi`        |
| `nvme0n1p2`       | 237.4G  | NVMe       | `/`                |
| `sdb`             | 238.5G  | SSD        | `/srv/docker-data` |
| `sda1` + `sdc1`   | 931.5G  | → `md0`    | `/srv/media`       |

`/srv/media` is a **RAID1 mirror** (`md0`, 931.4G usable) across `sda` and
`sdc`. `/srv/docker-data` is a single unmirrored SSD, mounted as a whole raw
device — there is no `sdb1` partition table, which is unusual but harmless;
`blkid /dev/sdb` still gives you a filesystem UUID for fstab.

Verify the layout before changing anything:

```bash
mountpoint -q /srv/docker-data && mountpoint -q /srv/media && echo "mounts ok"
cat /proc/mdstat          # md0 should read [UU], not [U_]
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
```

Confirm both entries in `/etc/fstab` carry `nofail`:

```
UUID=<uuid>  /srv/docker-data  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
UUID=<uuid>  /srv/media        ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

`nofail` keeps the box booting when a disk is absent — which is exactly why
`backup.sh` and `healthcheck.sh` both assert `mountpoint -q` themselves. Without
that assert, a missing disk turns the mount into an ordinary directory on `/`
and the stack writes to the OS disk without complaint. See "Adding or replacing
a disk" at the end if you ever need to build one of these from scratch.

## Migrating to this layout

The array was previously mounted at `/mnt/backup` and held both the Immich
library and the restic repo. This moves the array to an honest mount point and
relocates the repo onto `sdb`.

Remounting the array is free — the filesystem is unchanged, only where it
attaches. Moving the repo is a real copy across disks.

### 1. Pre-flight: does the repo fit on sdb?

Measured 2026-08-05: the repo is **123M**, and `/srv/docker-data` was using 531M
of 234G with 222G free. The move is a rounding error on that disk and the rsync
takes seconds. The photos are the only large thing here (64G) and they aren't
going to `sdb`.

Re-check anyway before you start, since this is the one thing that would make
the migration a bad idea:

```bash
df -h /srv/docker-data /mnt/backup
sudo du -sh /mnt/backup/restic-repo     # sudo required — the repo is mode 700
```

If the repo somehow doesn't fit, trim it before moving rather than after:

```bash
restic -r /mnt/backup/restic-repo --password-file /root/.restic-password \
  forget --tag nightly --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
```

Note what these numbers are telling you: a 123M repo against a 10G free tier is
about 1% utilization. Staying inside Backblaze's free tier requires no ongoing
effort — it only becomes a question if something changes shape, and the section
below covers what to do then.

### 2. Stop everything that writes

```bash
systemctl stop homelab-backup.timer
docker compose -f /opt/homelab/docker-compose.yml down
```

### 3. Remount the array at /srv/media

Edit `/etc/fstab` to change the array's mount point from `/mnt/backup` to
`/srv/media`, then:

```bash
umount /mnt/backup
mkdir -p /srv/media
systemctl daemon-reload
mount -a
mountpoint -q /srv/media && ls /srv/media
```

The Immich library and the old repo are both now under `/srv/media` — nothing
was copied, the mount simply attaches elsewhere.

The library was at `/mnt/backup/media/immich`, so it is now at
`/srv/media/media/immich` — a redundant level, since the mount point already
says "media". Flatten it. This is a rename inside one filesystem, so it's
instant regardless of how many photos are involved:

```bash
ls /srv/media/media/          # see what else is in there before moving anything
mv /srv/media/media/* /srv/media/
rmdir /srv/media/media
ls /srv/media/                # expect: immich/, restic-repo/
```

If `media/` turns out to hold more than `immich/`, the `mv` still does the right
thing — everything moves up one level together.

### 4. Move the repo onto sdb

```bash
rsync -aHAX --info=progress2 /srv/media/restic-repo/ /srv/docker-data/restic-repo/
restic -r /srv/docker-data/restic-repo --password-file /root/.restic-password check
```

**Only after `check` passes**, reclaim the space on the array:

```bash
rm -rf /srv/media/restic-repo
```

### 5. Point Immich at the new library path

`UPLOAD_LOCATION` in `immich/.env` still reads `/mnt/backup/media/immich`.
Change it to match where the library actually is now:

```
UPLOAD_LOCATION=/srv/media/immich
```

Then re-encrypt. The plaintext `.env` is gitignored; only `.env.enc` is
committed, and `homelab-secrets.sh commit` re-encrypts before committing:

```bash
$EDITOR /opt/homelab/immich/.env
/opt/homelab/scripts/homelab-secrets.sh commit "move immich library to /srv/media"
```

Getting this wrong is recoverable but alarming: Immich starts with an empty
library and begins writing to a fresh directory. It doesn't delete anything —
fix the path and restart. Don't let it run a scan in that state.

### 6. Bring the stack back up

```bash
docker compose -f /opt/homelab/docker-compose.yml up -d
sudo /opt/homelab/scripts/healthcheck.sh
```

Confirm in the Immich UI that existing photos still load — that is the real test
that `UPLOAD_LOCATION` is right. If thumbnails are missing but originals open,
let Immich regenerate them rather than assuming the move failed.

**Leave the backup timer stopped for now.** `backup.sh` sources
`/root/.restic-b2.env` and exits non-zero if it isn't there, so a nightly run
before B2 is configured will fail and trip the dead man's switch. Set up B2
next, then re-enable the timer.

## Backblaze B2

Create a **private** bucket in the B2 console, then an application key scoped to
just that bucket with read and write access. Note the `keyID` and
`applicationKey` — the key is shown once.

In the bucket's lifecycle settings choose **"Keep only the last version of the
file."** restic manages its own history; without this, every file restic deletes
lingers as a hidden version that still counts against your 10 GB.

Write the credentials to `/root/.restic-b2.env` — outside the git repo, same as
`/root/.restic-password`:

```bash
install -m 600 /dev/null /root/.restic-b2.env
cat > /root/.restic-b2.env <<'EOF'
B2_ACCOUNT_ID=<keyID>
B2_ACCOUNT_KEY=<applicationKey>
RESTIC_B2_REPO=b2:<bucket-name>:homelab
EOF
```

Initialize the B2 repo. `--copy-chunker-params` makes it chunk data identically
to the local repo, which is what keeps `restic copy` deduplicating instead of
re-uploading everything each night:

```bash
set -a; . /root/.restic-b2.env; set +a
restic -r "$RESTIC_B2_REPO" --password-file /root/.restic-password init \
  --copy-chunker-params \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password
```

Both repos intentionally share `/root/.restic-password`. `restic copy` has to
unlock source and destination, and one password is one fewer thing to lose.

Seed the first offsite copy by hand. At 123M this is a few minutes, not the
overnight haul a first restic upload usually is:

```bash
restic -r "$RESTIC_B2_REPO" --password-file /root/.restic-password copy \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password
```

## Resume nightly backups

```bash
systemctl start homelab-backup.timer
systemctl start homelab-backup.service   # run once now
journalctl -u homelab-backup.service -f
sudo /opt/homelab/scripts/healthcheck.sh
```

The `BACKUPS` section of healthcheck should show both dumps fresh and both
repos with a snapshot newer than two days.

### What changed in the scripts

- Dumps are taken with `--clean --if-exists` so a restore drops existing objects
  first, and are verified for pg_dumpall's completion trailer plus a minimum
  size before replacing the previous night's file. They stay uncompressed so
  restic can dedupe them.
- `/srv/docker-data` is backed up wholesale with explicit excludes, rather than
  listing `vikunja/files` alone — a service added later is covered by default
  instead of silently missing until the day it matters.
- The run is wrapped in `flock`, so a slow B2 copy can't overlap the next night.
- Failures ping `hc-ping.com/<uuid>/fail` immediately instead of waiting for the
  check to time out.
- Retention is a pair of tunables (`LOCAL_KEEP`, `B2_KEEP`, currently equal), and
  B2 `prune` runs on the 1st only — see below.
- `LOCAL_REPO` moved to `/srv/docker-data/restic-repo`, with an explicit
  `--exclude` of the repo itself so restic doesn't back up its own output, and
  the mount assertion moved from `/mnt/backup` to `/srv/docker-data`.

## Staying inside the B2 free tier

The free tier is **10 GB stored**, with free egress up to **3x your stored
amount per month**. Uploads and deletions cost nothing; *downloads* are the
thing that can generate a bill. The setup is built around that:

| restic operation                | What it does on B2                    | Free-tier impact       |
| ------------------------------- | ------------------------------------- | ---------------------- |
| `copy` (nightly)                | uploads new chunks                    | free                   |
| `forget` (nightly)              | deletes snapshot files                | free                   |
| `prune` (1st of month)          | downloads and repacks partial packs   | small egress           |
| `check` (1st of month)          | downloads indexes only                | tiny egress            |
| `check --read-data`             | downloads **the entire repo**         | avoid — see below      |
| a real restore                  | downloads what you restore            | 1x storage, well under |

Three knobs keep storage down, in the order you should reach for them:

1. The Immich library is excluded — it's the only genuinely large thing here.
2. Dumps are uncompressed so restic dedupes them (see above). This is worth more
   than it sounds: it's the difference between storing one delta per night and
   one full dump per night.
3. `B2_KEEP` in `backup.sh`, which currently matches `LOCAL_KEEP` because at
   ~1% utilization there's no reason to keep less offsite than locally. This is
   the knob to reach for if that ever stops being true — a shorter offsite
   history is a cheaper concession than a bill.

`healthcheck.sh` reports the B2 repo size on every run and warns at 8 GB, so you
get notice while there's still room to act.

The one thing to watch is the Immich database. It stores CLIP embeddings for
smart search, and that grows with your photo count — it's the only part of this
backup with real growth in it. If the B2 warning ever fires, that's almost
certainly what grew.

Never run `restic check --read-data` against B2: it downloads every byte in the
repo, which is roughly 1x your storage in one go. Use
`--read-data-subset=5%` instead, or run full data verification against the local
array where reads are free.

## Adding or replacing a disk

Not needed for the current layout — this is here for the day a disk dies or you
outgrow `/srv/docker-data`.

### Replacing a failed RAID1 member

`healthcheck.sh` reports `md0 degraded`, or `/proc/mdstat` shows `[U_]`. Identify
the failed member by serial (`lsblk -o NAME,SIZE,SERIAL`), then:

```bash
mdadm --detail /dev/md0                  # confirm which member is faulty
mdadm --manage /dev/md0 --remove /dev/sdX1
# physically swap the disk, then partition the replacement to match
sfdisk -d /dev/sda | sfdisk /dev/sdX     # copy the surviving disk's layout
mdadm --manage /dev/md0 --add /dev/sdX1
watch cat /proc/mdstat                   # resync; hours for 1TB
```

The array stays readable and writable throughout. Do not run a `prune` against
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

Then add the fstab entry (with `nofail`, as above), `systemctl daemon-reload`,
`mount -a`, and confirm with `mountpoint -q`.

To move `/srv/docker-data` onto it, stop the stack first so nothing is writing:

```bash
systemctl stop homelab-backup.timer
docker compose -f /opt/homelab/docker-compose.yml down
rsync -aHAX --info=progress2 /srv/docker-data/ /mnt/newdisk/
```

Swap the fstab entries, remount, bring the stack back up, and only remove the
old copy once `healthcheck.sh` is fully green.

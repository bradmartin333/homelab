# Restoring

How to get data back out of the backups. For how they're produced and how the
disks are laid out, see [storage-and-backup.md](storage-and-backup.md).

There are three repos, all sharing `/root/.restic-password`, all
interchangeable as a restore source:

| Repo         | Path                            | Use when            |
| ------------- | --------------------------------- | ---------------------- |
| local         | `/srv/docker-data/restic-repo`    | default — fastest      |
| array mirror  | `/srv/media/restic-mirror`        | `sdb` died              |
| offsite       | `$RESTIC_B2_REPO`                 | the box died            |

Everything below reads from the local repo on `sdb`. To read from either of
the others, change one thing — the repo. For B2, load the credentials first:

```bash
set -a; . /root/.restic-b2.env; set +a
REPO="$RESTIC_B2_REPO"        # instead of REPO=/srv/docker-data/restic-repo
```

The commands are otherwise identical; restic hides the difference. What
actually differs is covered in "Restoring from B2" at the end.

All examples assume:

```bash
REPO=/srv/docker-data/restic-repo
PASS=/root/.restic-password
```

## Find what you're looking for

```bash
restic -r "$REPO" --password-file "$PASS" snapshots            # list snapshots
restic -r "$REPO" --password-file "$PASS" ls latest            # browse the newest
restic -r "$REPO" --password-file "$PASS" find '*vikunja*'     # find a path
```

Anywhere below that says `latest`, substitute a snapshot ID from that first
command to go back further.

## Restore a postgres cluster

Both clusters restore the same way: stream the dump out of restic straight
into `psql` inside the running container. `pg_dumpall` output is plain SQL,
taken with `--clean --if-exists`, so it drops each object before recreating
it — it lands cleanly on a cluster that already has data.

**App cluster (vikunja):**

```bash
docker stop vikunja        # don't let it write mid-restore
restic -r "$REPO" --password-file "$PASS" \
  dump latest /var/lib/homelab-backup-staging/pg_dumpall.sql \
  | docker exec -i postgres psql -U postgres
docker start vikunja
```

**Immich cluster:**

```bash
docker stop immich-server immich-machine-learning
restic -r "$REPO" --password-file "$PASS" \
  dump latest /var/lib/homelab-backup-staging/immich_pg_dumpall.sql \
  | docker exec -i immich-postgres psql -U immich -d postgres
docker start immich-server immich-machine-learning
```

Note `-d postgres` for Immich: the dump drops and recreates the `immich`
database, which it can't do while you're connected *to* that database.
Connect to the default `postgres` database instead.

`psql` keeps going after a failed statement by default — add
`-v ON_ERROR_STOP=1` to make it stop at the first problem instead.

**Sanity check afterwards:**

```bash
docker exec postgres psql -U postgres -c '\l'
docker exec postgres psql -U vikunja -d vikunja -c 'select count(*) from tasks;'
```

## Restore files

Never restore straight over live data — put it somewhere scratch and move it
into place yourself:

```bash
restic -r "$REPO" --password-file "$PASS" restore latest \
  --target /srv/media/restore-scratch \
  --include /srv/docker-data/vikunja/files
```

Scratch space goes on `/srv/media` deliberately — the 931G array. Don't stage
a restore on `/srv/docker-data`: it's the small SSD, and it already holds both
the databases and the repo you're restoring from.

The restored tree appears under the target with its full original path, i.e.
`/srv/media/restore-scratch/srv/docker-data/vikunja/files`.

**A single file**, straight to stdout:

```bash
restic -r "$REPO" --password-file "$PASS" \
  dump latest /opt/homelab/immich/.env > ./recovered.env
```

**Browsing before committing** — mount the repo read-only:

```bash
mkdir -p /mnt/restic-browse
restic -r "$REPO" --password-file "$PASS" mount /mnt/restic-browse
# snapshots appear under /mnt/restic-browse/snapshots/ ; ctrl-c to unmount
```

Mounting over B2 works but reads on demand over the network — slow, and every
browse is egress. Prefer the local repo.

## Full rebuild from nothing

Order matters:

1. Provision the OS, install docker, restic, sops, age.
2. Restore the age key from wherever it's kept offsite. **Without it the
   `.env.enc` files in git are unreadable** — this is the one secret not in
   any backup, by design.
3. `git clone` this repo to `/opt/homelab`, then
   `scripts/homelab-secrets.sh decrypt`.
4. Mount `sdb` at `/srv/docker-data`. If `sdb` is what died, the local repo
   died with it — point `REPO` at the array mirror or B2 and restore over the
   network instead.
5. Assemble and mount the `md0` array at `/srv/media` — `mdadm --assemble
   --scan`, then check `/proc/mdstat`. If the photos survived, they're here
   and don't need restoring at all.
6. Restore `/srv/docker-data` from restic to a scratch path, then move it
   into place. The two `PGDATA` directories are *not* in there — that's
   expected, the containers recreate them empty on first start.
7. Recreate the external docker networks — nothing in the stack does this on
   its own, and `docker compose up` fails outright without them:
   ```bash
   sudo cp /opt/homelab/docker/daemon.json /etc/docker/daemon.json
   sudo systemctl restart docker
   /opt/homelab/scripts/create-networks.sh
   ```
   **The `proxy` subnet is not optional** — see `create-networks.sh` for why.
8. Install the ssh hardening, unattended-upgrades, and systemd backup timer
   configs — see the READMEs in `ssh/`, `apt/`, and `systemd/`.
9. `docker compose up -d` and let both clusters initialize from scratch.
10. Load both dumps, per the sections above.
11. Only if the array was lost too: restore the Immich media library from the
    rPi replica (once built — see `homelab-runbook`'s `pi-offsite-backup.md`)
    into `$UPLOAD_LOCATION`, then have Immich rescan. Thumbnails and encoded
    video regenerate on their own.

## Restoring from B2

Same commands, `REPO="$RESTIC_B2_REPO"`. What's different in practice:

- **Speed.** Everything is a network read — a full restore is bounded by your
  download link, not the disk.
- **Egress.** A one-time full restore pulls roughly 1x your stored data,
  comfortably inside the free 3x-of-storage monthly allowance. Restoring
  repeatedly in one month is what would push past it.
- **Same history as local.** `B2_KEEP` matches `LOCAL_KEEP`, so anything
  restorable locally is restorable from B2 — check `backup.sh` before
  assuming that still holds if the repo ever outgrows the free tier.
- **No Immich library**, same as local — that lives only on the rPi, once
  built.
- **You need three things**, none of them on the box: the B2 key, the restic
  password, and the age key. Keep them somewhere that survives the house — a
  password manager, or paper in another building. A backup you can't decrypt
  isn't a backup.

Restoring to a machine that isn't the homelab box works fine — install
restic, export `B2_ACCOUNT_ID`/`B2_ACCOUNT_KEY`, point `-r` at the repo.

## Verify it actually works

A backup you've never restored is a hypothesis. Twice a year:

1. Restore `pg_dumpall.sql` from **B2**, not local, into a throwaway postgres
   container and confirm the vikunja tables have your data:
   ```bash
   docker run -d --name pgtest -e POSTGRES_PASSWORD=x postgres:18
   restic -r "$RESTIC_B2_REPO" --password-file "$PASS" \
     dump latest /var/lib/homelab-backup-staging/pg_dumpall.sql \
     | docker exec -i pgtest psql -U postgres
   docker exec pgtest psql -U postgres -d vikunja -c 'select count(*) from tasks;'
   docker rm -f pgtest
   ```
2. `restic -r "$RESTIC_B2_REPO" --password-file "$PASS" check --read-data-subset=5%`
   — verifies the offsite data itself rather than just the index, at 5% of
   the egress of a full `--read-data`.
3. Confirm you can still decrypt `.env.enc` with the archived copy of the age
   key, not the one already on the box.
4. Run `scripts/sanitycheck.sh` — confirms the local, array-mirror, and B2
   repos all hold the identical nightly snapshot, not just that each is
   independently recent.

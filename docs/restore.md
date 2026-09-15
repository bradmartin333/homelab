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

## Two paths to the `.env` files

Application secrets exist in two independent places, which matters because
they fail independently:

| Path | Source | Needs | Fails if |
| ----- | ------- | ------ | --------- |
| sops | `<app>/.env.enc` in git | the **age key** | age key lost or not the one the files were encrypted to |
| restic | `/opt/homelab` in any repo | the **restic password** | restic password lost |

`backup.sh` backs up `/opt/homelab` wholesale with no `.env` exclusion, so
**the plaintext `.env` files are inside every restic snapshot.** Git only ever
holds the encrypted `.enc` copies. That redundancy is deliberate: losing one
key still leaves a route to the secrets.

To recover them without sops:

```bash
restic -r "$REPO" --password-file "$PASS" \
  restore latest --target /tmp/env-recover --include /opt/homelab
ls /tmp/env-recover/opt/homelab/*/.env
```

> ⚠️ **Verify the age key round-trips before relying on the sops path.** The
> recipient in `.sops.yaml` (and recorded inside every `.enc` file) must match
> the public key of the private key you hold. Check them against each other:
>
> ```bash
> grep age .sops.yaml                                    # expected recipient
> grep -o 'public key: .*' ~/.config/sops/age/keys.txt   # key you actually have
> sops -d --input-type dotenv --output-type dotenv postgres/.env.enc >/dev/null \
>   && echo "sops path OK" || echo "sops path BROKEN — use the restic path"
> ```
>
> A mismatch is silent until the day you need it — nothing warns you, because
> the running stack reads the already-decrypted plaintext `.env` files and
> never touches sops. Re-encrypt to a key you hold with
> `./homelab-secrets.sh encrypt` after fixing `.sops.yaml`.

The restic password has no such fallback. Lose it and all three repositories
are permanently unreadable — see the ⛔ in
[operations.md](operations.md#quick-reference).

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
2. **Firewall, before anything is network-reachable:**
   ```bash
   sudo apt install -y ufw
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow from <your LAN subnet> to any port 22 proto tcp
   ```
   ⛔ Verify the SSH rule actually landed before enabling — a malformed
   subnet silently drops the rule instead of erroring, and `default deny
   incoming` on top of that locks SSH out completely with no console access
   assumed:
   ```bash
   sudo ufw show added | grep 22   # must show the rule above
   sudo ufw enable
   ```
   The Tailscale rule (`sudo ufw allow in on tailscale0 to any port 22 proto
   tcp`) comes later, once Tailscale itself is up — see the Tailscale step
   below.
3. Restore the age key from wherever it's kept offsite. **Without it the
   `.env.enc` files in git are unreadable** — this is the one secret not in
   any backup, by design. See
   [Two paths to the `.env` files](#two-paths-to-the-env-files) below: if the
   key is unavailable, restic still has the plaintext copies, so this is a
   convenience path rather than the only one.
4. `git clone` this repo to `/opt/homelab`, then
   `./homelab-secrets.sh decrypt`. This restores every `<app>/.env`
   from its `.env.enc` — but **not** the root `/opt/homelab/.env`, which
   `homelab-secrets.sh` deliberately doesn't touch (glob is `*/.env`, one
   level deep only). The root `.env` interpolates `${TRAEFIK_BIND_IP}`,
   `${ACME_EMAIL}`, `${IMMICH_DOMAIN}`, `${VIKUNJA_DOMAIN}`,
   `${TALKOMATIC_DOMAIN}`, `${MEALS_DOMAIN}`, `${TALKOMATIC_BRANCH}`,
   `${MEALS_BRANCH}` directly into the compose files — none of it is
   secret (a domain name is public in DNS regardless), so it's a plain
   template rather than sops-encrypted:
   ```bash
   cp /opt/homelab/.env.example /opt/homelab/.env
   $EDITOR /opt/homelab/.env      # fill in your real domain/IP/email
   ```
5. Mount `sdb` at `/srv/docker-data`. If `sdb` is what died, the local repo
   died with it — point `REPO` at the array mirror or B2 and restore over the
   network instead.
6. Assemble and mount the `md0` array at `/srv/media` — `mdadm --assemble
   --scan`, then check `/proc/mdstat`. If the photos survived, they're here
   and don't need restoring at all.
7. Restore `/srv/docker-data` from restic to a scratch path, then move it
   into place. The two `PGDATA` directories are *not* in there — that's
   expected, the containers recreate them empty on first start.
8. Recreate the external docker networks — nothing in the stack does this on
   its own, and `docker compose up` fails outright without them:
   ```bash
   sudo cp /opt/homelab/docker/daemon.json /etc/docker/daemon.json
   sudo systemctl restart docker
   /opt/homelab/scripts/create-networks.sh
   ```
   **The `proxy` subnet is not optional** — see `create-networks.sh` for why.
9. Install the ssh hardening, unattended-upgrades, and systemd backup timer
   configs — see the READMEs in `ssh/`, `apt/`, and `systemd/`.
10. **Rejoin Tailscale** — needed for remote access, and `immich/docker-compose.yml`
    binds to `$TAILSCALE_IP`:
    ```bash
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up
    sudo tailscale set --auto-update
    sudo tailscale set --ssh
    tailscale ip -4
    ```
    `tailscale up` prints a URL — open it and approve the machine. In the
    [admin console](https://login.tailscale.com/admin/machines), disable key
    expiry on this machine again (`⋯` → *Disable key expiry* — node keys
    otherwise expire in 180 days and recovery needs an interactive login *at
    the machine*, which is the whole problem on a headless rebuild) and enable
    MagicDNS. Allow SSH over the tailnet:
    ```bash
    sudo ufw allow in on tailscale0 to any port 22 proto tcp
    ```
    Update `TAILSCALE_IP` in `immich/.env` to the new address, then
    `./homelab-secrets.sh commit`.
11. **Create a new Cloudflare Tunnel** — tunnel credentials are deliberately
    not in any backup, so this is always a fresh tunnel on a rebuild, not a
    restore:
    ```bash
    sudo mkdir -p /srv/docker-data/cloudflared
    sudo chown -R 65532:65532 /srv/docker-data/cloudflared
    docker run --rm -it -v /srv/docker-data/cloudflared:/home/nonroot/.cloudflared \
      cloudflare/cloudflared:latest tunnel login       # opens a URL, authorize the domain
    docker run --rm -it -v /srv/docker-data/cloudflared:/home/nonroot/.cloudflared \
      cloudflare/cloudflared:latest tunnel create homelab
    ```
    Prints a `<TUNNEL_UUID>` and writes `<TUNNEL_UUID>.json` next to
    `cert.pem` — record the UUID somewhere durable, same reasoning as the age
    key. Write `/srv/docker-data/cloudflared/config.yml`:
    ```yaml
    tunnel: <TUNNEL_UUID>
    credentials-file: /home/nonroot/.cloudflared/<TUNNEL_UUID>.json
    ingress:
      - hostname: "*.<your domain>"
        service: https://traefik:443
        originRequest:
          noTLSVerify: true
      - hostname: "<your domain>"
        service: https://traefik:443
        originRequest:
          noTLSVerify: true
      - service: http_status:404
    ```
    ```bash
    sudo chown 65532:65532 /srv/docker-data/cloudflared/config.yml
    ```
    In the Cloudflare dashboard, update both DNS CNAMEs (`*` and `@`) to
    `<TUNNEL_UUID>.cfargotunnel.com` (proxied), then delete the old tunnel.
12. `docker compose up -d` and let both clusters initialize from scratch.
    Check `docker compose logs -f cloudflared` for `Registered tunnel
    connection` (usually four) before assuming the tunnel step above worked.
13. Load both dumps, per the sections above.
14. Only if the array was lost too: restore the Immich media library from the
    Pi replica (see [`pi-backup.md`](pi-backup.md) for current status) into
    `$UPLOAD_LOCATION`:
    ```bash
    sudo bash -c 'set -a; . /root/.restic-pi.env; set +a; \
      restic -r "$PI_REPO" --password-file /root/.restic-password \
      restore latest --target / --include "$UPLOAD_LOCATION"'
    ```
    then have Immich rescan. Thumbnails and encoded video regenerate on their
    own.

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
- **No Immich library**, same as local — that lives only on the Pi target
  (see [pi-backup.md](pi-backup.md)).
- **You need three things**, none of them on the box: the B2 key, the restic
  password, and the age key. Keep them somewhere that survives the house — a
  password manager, or paper in another building. A backup you can't decrypt
  isn't a backup.

Restoring to a machine that isn't the homelab box works fine — install
restic, export `B2_ACCOUNT_ID`/`B2_ACCOUNT_KEY`, point `-r` at the repo.

## Verify it actually works

A backup you've never restored is a hypothesis. Twice a year:

1. Restore `pg_dumpall.sql` from **B2**, not local, into a throwaway postgres
   container and confirm the vikunja tables have your data.

   Only the restic step needs root (it reads `/root/.restic-b2.env` and
   `/root/.restic-password`); everything else runs as your normal user via the
   `docker` group, so scope `sudo` to that one command rather than the whole
   drill:

   ```bash
   docker rm -f pgtest 2>/dev/null || true   # clear any stale container first
   docker run -d --name pgtest -e POSTGRES_PASSWORD=x postgres:18

   # docker run -d returns before postgres accepts connections, so wait — but
   # bail out if the container died rather than looping forever. A bare
   # `until docker exec ... pg_isready` spins silently against a dead
   # container, and the usual cause (missing POSTGRES_PASSWORD, name clash)
   # is only visible in its logs.
   for _ in $(seq 30); do
     docker exec pgtest pg_isready -q 2>/dev/null && break
     docker ps -q -f name=pgtest -f status=running | grep -q . || {
       echo "pgtest exited before becoming ready:"; docker logs pgtest --tail 20; break; }
     sleep 1
   done

   sudo bash -c 'set -a; . /root/.restic-b2.env; set +a
     restic -r "$RESTIC_B2_REPO" --password-file /root/.restic-password \
       dump latest /var/lib/homelab-backup-staging/pg_dumpall.sql' \
     | docker exec -i pgtest psql -U postgres > /tmp/restore.log 2>&1

   # psql continues past failed statements and still exits 0, so check the log
   # rather than the exit code — otherwise a half-failed restore looks fine.
   # The two role errors below are unavoidable and expected; see the note.
   grep '^ERROR' /tmp/restore.log \
     | grep -vE 'current user cannot be dropped|role "postgres" already exists' \
     || echo "no unexpected errors ✓"

   docker exec pgtest psql -U postgres -d vikunja -c 'select count(*) from tasks;'
   docker rm -f pgtest
   ```

   ⚠️ **Do not add `-v ON_ERROR_STOP=1` here.** `pg_dumpall --clean` always
   emits `DROP ROLE IF EXISTS postgres;`, and restoring *as* postgres makes
   that fail with `current user cannot be dropped` every single time — which
   in turn leaves the role in place, so the following `CREATE ROLE postgres`
   fails with `role "postgres" already exists`. Both are unavoidable and
   harmless (the subsequent `ALTER ROLE` sets the real attributes). With
   `ON_ERROR_STOP=1` psql halts at the first one — before `CREATE DATABASE
   vikunja` — and the drill fails without restoring anything at all.

   These are also expected and harmless:
   `NOTICE: database "vikunja" does not exist, skipping` (a fresh cluster has
   nothing to drop) and a bare `DROP DATABASE`. Filtering the log for
   unexpected `ERROR` lines gives the same protection without the false
   failure.

   **A passing drill looks like:** `no unexpected errors ✓`, a task count
   matching live, and ~37 tables in `vikunja`. Recorded 2026-08-11: 70 tasks
   restored from B2, 70 live — exact match.
2. `restic -r "$RESTIC_B2_REPO" --password-file "$PASS" check --read-data-subset=5%`
   — verifies the offsite data itself rather than just the index, at 5% of
   the egress of a full `--read-data`.
3. Confirm you can still decrypt `.env.enc` with the archived copy of the age
   key, not the one already on the box — see
   [Two paths to the `.env` files](#two-paths-to-the-env-files). This is the
   check most likely to have quietly broken, because nothing in normal
   operation exercises it.
4. Run `scripts/sanitycheck.sh` — confirms the local, array-mirror, and B2
   repos all hold the identical nightly snapshot, not just that each is
   independently recent. The Pi leg is reported alongside them but isn't held
   to the same identical-snapshot bar, since it's a separate `restic backup`
   run with a wider source set (it includes the Immich library), not a
   `copy` of the other three.
5. **Pi/Immich leg** — see [pi-backup.md](pi-backup.md#verification) for the
   day-to-day check (`scripts/pi-verify.sh`). Twice a year, also do an actual
   restore:
   ```bash
   sudo bash -c 'set -a; . /root/.restic-pi.env; set +a; \
     restic -r "$PI_REPO" --password-file /root/.restic-password \
     restore latest --target /tmp/pi-restore-test --include "$UPLOAD_LOCATION"; \
     diff -rq "/tmp/pi-restore-test$UPLOAD_LOCATION" "$UPLOAD_LOCATION"; \
     rm -rf /tmp/pi-restore-test'
   ```
   A passing drill is `diff` printing nothing — every file the restore
   produced matches what's actually live on `/srv/media`.

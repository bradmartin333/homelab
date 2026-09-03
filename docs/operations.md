# Operations

Running this thing over time. Storage design is in
[storage-and-backup.md](storage-and-backup.md); getting data back is
[restore.md](restore.md); compose-level rationale is in
[architecture-notes.md](architecture-notes.md).

The failure mode for an unattended homelab is not a dramatic crash — it's
**silent drift**. Backups stop succeeding in March and you find out in June.
Everything below exists to make that visible on a schedule.

## Alerting

Two external services, both free, both deliberately *external* — self-hosted
monitoring dies alongside the thing it monitors and then reports perfect
uptime forever.

**Dead man's switch (healthchecks.io).** `scripts/backup.sh` pings
`hc-ping.com/$HC_UUID` on success and `.../fail` immediately on failure. In
the healthchecks.io dashboard the check is set to a **1 day period with a few
hours' grace**, so:

- ping arrives → last night worked
- explicit `/fail` ping → it ran and broke, look at
  `journalctl -u homelab-backup`
- *silence* → the job never ran at all, or the box is off. This is the case
  a status-file check on the box can never catch, because a dead box can't
  report that it's dead.

Confirm email (or SMS) notification is actually enabled on that check — the
switch is worthless if nothing is listening. This is the single most
important alert in the build: it is the difference between finding out
tonight and finding out in June.

**Uptime monitoring.** A free [UptimeRobot](https://uptimerobot.com) monitor
on each public hostname (`$VIKUNJA_DOMAIN`, `$IMMICH_DOMAIN`,
`$TALKOMATIC_DOMAIN`) so you hear about an outage by email rather than from
whoever was using it.

**Grafana** (Tailscale-only, `monitoring/`) is the "what is it doing right
now" view — dashboards for traefik, postgres, immich, cadvisor, node-exporter,
watchtower, and the cloudflare tunnel. It is not an alerting layer; it runs on
the same box, so it goes down with everything else.

**Watchtower email.** A custom `WATCHTOWER_NOTIFICATION_TEMPLATE` (guarded on
`.Updated`/`.Failed`/`.Restarted`) means an email only goes out when a scan
actually updates, fails, or restarts a container — silent on a normal night.
`WATCHTOWER_NOTIFICATION_REPORT` alone does not do this; it only supplies the
structured report data the template renders from. Reuses Vikunja's Gmail SMTP
creds; recipient(s) are configured via `toAddresses` in
`WATCHTOWER_NOTIFICATION_URL`.

## Cadence

**Nightly, automatic**

| Time  | Job                                                                    |
| ------ | ------------------------------------------------------------------------ |
| 03:00 | Backup: dump both clusters → local repo → array mirror → B2 → Pi (if configured, see [pi-backup.md](pi-backup.md)) → ping (`homelab-backup.timer`, ±5m jitter) |
| 04:30 | Reboot window, if patches require one (`apt/50unattended-upgrades`)      |
| 05:00 | Watchtower patch updates (`WATCHTOWER_SCHEDULE`)                         |

The ordering is deliberate and the three must not overlap — a reboot landing
mid-backup kills it partway through. If you change any of these, change them
together.

Also continuous: security patches, certificate renewal, tunnel reconnection,
Tailscale updates.

**Weekly — two minutes**

```bash
sudo /opt/homelab/scripts/healthcheck.sh
```

All green means done. Add every new container to `CONTAINERS` in that script
when you add an app — a service missing from the list is a service whose
death reports as all-green.

**Monthly — fifteen minutes**

1. **Confirm all three backup copies agree:**
   ```bash
   sudo /opt/homelab/scripts/sanitycheck.sh
   ```
   This is a different question from "is each repo recent" — it proves local,
   array mirror, and B2 all hold the *same* nightly snapshot, which catches a
   B2 leg that has been quietly failing while the local legs look fine.
2. **Verify the Pi target**, once configured:
   ```bash
   sudo /opt/homelab/scripts/pi-verify.sh
   ```
   Checks the Immich library itself, not just repo reachability — see
   [pi-backup.md](pi-backup.md#verification).
3. **Restore test** — a backup you have never restored is a hypothesis. See
   [restore.md](restore.md#verify-it-actually-works).
4. **Deep-verify the local repository.** The nightly `check` validates
   structure only; this reads a sample of actual data and catches a silently
   failing disk:
   ```bash
   sudo restic -r /srv/docker-data/restic-repo \
     --password-file /root/.restic-password check --read-data-subset=5%
   ```
5. `sudo ufw status verbose` — still the expected rules, nothing new.
6. `docker system df` — reclaim space if images have crept up.
7. Check **B2 usage** against the 10 GB free tier (`healthcheck.sh` reports it
   and warns at 8 GB).
8. `tailscale status` — remove devices you no longer own.

**Quarterly — thirty minutes**

1. **Restore from B2**, not the local repo — proves the offsite copy and the
   credentials to reach it both still work.
2. **Pull Postgres minor releases.** Watchtower deliberately excludes both
   postgres containers, so security fixes within the current major only land
   when you do this:
   ```bash
   cd /opt/homelab && docker compose pull postgres && docker compose up -d postgres
   ```
3. Bump pinned minor versions for apps and Traefik deliberately, after reading
   release notes.
4. Ubuntu point release: `sudo apt update && sudo apt full-upgrade && sudo reboot`.
5. Re-read the secrets inventory below and confirm each is in your password
   manager.
6. **Prove the sops age key still decrypts the repo.** Nothing in normal
   operation touches sops — the stack reads the already-decrypted plaintext
   `.env` files — so a key mismatch stays invisible until a rebuild:
   ```bash
   cd /opt/homelab && sops -d --input-type dotenv --output-type dotenv \
     postgres/.env.enc >/dev/null && echo OK || echo BROKEN
   ```
   If this fails, see
   [Two paths to the `.env` files](restore.md#two-paths-to-the-env-files) —
   restic still holds plaintext copies, so it is recoverable, but fix the key
   before you need it.

**Annually — an hour**

1. **Rotate credentials**: Cloudflare API token, app database passwords.
   Rotating proves you still know how, and finds the places you forgot
   something was hardcoded.
2. Confirm **Tailscale key expiry is still disabled** on this machine.
3. Check **domain auto-renew**.
4. **Drive health in detail**: `sudo smartctl -a /dev/<device>` per drive —
   the weekly script only watches overall SMART status. Watch reallocated
   sectors and power-on hours; 24/7 drives are consumables, and `sdb` is
   unmirrored (see [future-drive-mirror.md](future-drive-mirror.md)).
5. Confirm the BIOS **Restore on AC Power Loss** setting survived — it is
   lost when a CMOS battery dies, and without it one outage leaves the box
   off until someone visits.
6. Plan the next **Ubuntu LTS** upgrade for a visit. Do it with hands on the
   machine, not over SSH.

## Update policy

| Component            | Policy                              | Why                                          |
| --------------------- | ------------------------------------ | --------------------------------------------- |
| OS security patches   | Automatic                            | Low risk, high value                          |
| OS point releases     | Quarterly, manual                    | Occasionally touches kernel or networking     |
| OS LTS major          | On a visit, years apart              | Too much can go wrong blind                   |
| App containers        | Automatic patches via Watchtower     | Minor-pinned tags cap the blast radius        |
| App minor/major       | Quarterly, manual, deliberate        | You choose when to read release notes         |
| Traefik               | Quarterly, minor only                | Config format has changed across majors       |
| Postgres major        | Deliberately, with a verified backup | See below                                     |
| Tailscale             | Automatic                            | Network-facing; you want it current           |
| cloudflared           | Manual — **not** on watchtower       | `:latest` could cross a major unattended; see [architecture-notes.md](architecture-notes.md#cloudflared-is-not-on-watchtower) |

**Postgres major upgrades.** Never automatic.

1. Run a manual backup and verify it restores into a scratch container.
2. Read the release notes.
3. PG18+ stores each major in its own subdirectory under
   `/var/lib/postgresql`, so a new-major container mounting the same volume
   creates a fresh cluster *beside* the old one rather than migrating it.
   Restore your dump into the new one, verify, then remove the old directory.

## Warning signs

| Symptom                                   | Likely cause                        | Where to look                                                            |
| ------------------------------------------ | ------------------------------------ | -------------------------------------------------------------------------- |
| Disk climbing with no new data             | Unrotated container logs             | `docker/daemon.json` applied? then recreate containers                    |
| `/srv/docker-data` filling up              | restic repo never pruning            | `journalctl -u homelab-backup`; it shares the disk postgres writes to     |
| Backups slower every night                 | Repository never pruning             | `journalctl -u homelab-backup`                                            |
| No backup pings                            | Disk unmounted, or B2 unreachable    | `df -h /srv/docker-data /srv/media`; `journalctl -u homelab-backup`       |
| Backup ran but B2 is stale                 | B2 leg failing after local succeeded | `scripts/sanitycheck.sh`                                                   |
| App occasionally 502s                      | Container OOM-killed                 | `docker inspect <c> --format '{{.State.OOMKilled}}'`; add a memory limit  |
| Certificate expiry warnings                | DNS-01 renewal failing               | `docker logs traefik \| grep -i acme`; usually an expired Cloudflare token |
| Every client shows the same IP in logs     | `proxy` subnet drifted from traefik's `trustedIPs` | `scripts/create-networks.sh` — fails silently, nothing errors |
| Tailscale drops after months               | Key expiry got re-enabled            | Tailscale admin console                                                    |
| Site down, Tailscale fine                  | Tunnel disconnected                  | `docker logs cloudflared --tail 50`                                       |
| SSH refused after a firewall change        | ufw active with no port 22 rule      | Console only: `sudo ufw status verbose`, then re-add the rule             |
| App broke overnight                        | Watchtower pulled a bad patch        | `docker logs watchtower`; pin the previous tag                            |
| Array shows `[U_]` instead of `[UU]`       | A mirror member dropped or failed    | `cat /proc/mdstat`, then [replace it](storage-and-backup.md#replacing-a-failed-raid1-member) |
| B2 usage climbing fast                     | Bucket lifecycle keeping old versions | B2 console → bucket → Lifecycle → "keep only the last version"           |
| Pi repo approaching the SSD's capacity     | Immich library growth, or retention never pruning | `sudo scripts/healthcheck.sh` reports it (85% of `PI_DISK_BYTES` in `/root/.restic-pi.env`) — trim retention in `backup.sh` or grow the drive |
| Immich DB growing steadily                 | CLIP embeddings scale with photo count | Expected; it's the only part of the backup with real growth in it       |
| Machine stays off after an outage          | BIOS AC-restore lost (dead CMOS battery) | Reset it in BIOS on the next visit                                    |
| Containers exited after an auto-reboot     | Bound to the tailnet IP before tailscaled had assigned it | `journalctl -u homelab-boot-reconcile -b` |
| Backup service "never ran" but timer fired | `RemainAfterExit=yes` on the oneshot | Must stay absent — see [`../systemd/`](../systemd/homelab-backup.service) |
| Pi leg missing from `healthcheck.sh`       | `/root/.restic-pi.env` not present yet | Expected until [pi-backup.md](pi-backup.md) setup is finished |
| Pi backup green in `healthcheck.sh` but Immich restore comes up short | Snapshot is fresh but scoped wrong (bad path/exclude) | `sudo scripts/pi-verify.sh` — checks file count/size, not just reachability |

## Adding an app

1. Create `<appname>/docker-compose.yml` and `<appname>/.env`, following an
   existing app as the template. No `ports:` mapping on a public app —
   traefik labels only, and it joins the `proxy` network.
2. Add `- <appname>/docker-compose.yml` to the `include:` list in the root
   `docker-compose.yml`.
3. **Add its container name to `CONTAINERS` in `scripts/healthcheck.sh`.**
   This is the step everyone forgets — the app runs fine and the health check
   stays green forever whether or not it is actually up.
4. If it stores data outside `/srv/docker-data`, add that path to `SOURCES` in
   `scripts/backup.sh`. Anything *inside* `/srv/docker-data` is already
   covered — it's backed up wholesale precisely so a new app is protected by
   default rather than silently missing until the day it matters.
5. Add a scrape target in `monitoring/prometheus/prometheus.yml` if it exposes
   metrics.
6. Encrypt and commit: `./homelab-secrets.sh commit "add <appname>"`.
7. `scripts/redeploy.sh`, then check `docker logs traefik` for the certificate.

No DNS, router, or tunnel changes are needed — the wildcard CNAME and wildcard
tunnel ingress hand every hostname to traefik automatically.

## Quick reference

| Path                                | Contents                                                        |
| ------------------------------------ | ----------------------------------------------------------------- |
| `/opt/homelab/<app>/`                 | Compose files + `.env` — in Git, encrypted as `.env.enc`         |
| `/opt/homelab/.env`                   | Non-secret compose interpolation (domains, bind IP, ACME email)  |
| `/srv/docker-data/<app>/`             | Persistent app state — backed up with exclusions                 |
| `/srv/docker-data/restic-repo`        | Local restic repository                                          |
| `/srv/media/restic-mirror`            | Mirror of the local repo, on the array                           |
| `/srv/media/immich`                   | Immich library — mirrored, and backed up to the Pi target only   |
| `$RESTIC_B2_REPO`                     | Offsite repository — the copy that survives the house            |
| `$PI_REPO`                            | Pi target — the only repo with Immich in it — see [pi-backup.md](pi-backup.md) |
| `/srv/docker-data/cloudflared`        | Tunnel credentials — not backed up, recreate on restore          |
| `/var/lib/homelab-backup-staging`     | Nightly SQL dumps + `last-run-status`                            |
| `/root/.restic-password`              | Backup encryption key — guards **all four** repos                |
| `/root/.restic-b2.env`                | B2 key ID, application key, repo URL                             |
| `/root/.restic-pi.env`                | Pi target repo URL (optional — absent skips the Pi leg)          |

| Secret                    | Generate with                | Stored in                                          |
| -------------------------- | ----------------------------- | --------------------------------------------------- |
| Postgres superuser         | `openssl rand -hex 24`        | `postgres/.env`                                     |
| App DB passwords           | `openssl rand -hex 24`        | `<app>/.env`                                        |
| Vikunja service secret     | `openssl rand -hex 32`        | `vikunja/.env`                                      |
| Grafana admin password     | `openssl rand -hex 24`        | `monitoring/.env`                                   |
| restic repo key            | `openssl rand -hex 32`        | `/root/.restic-password`                            |
| Backblaze application key  | B2 console, scoped to one bucket | `/root/.restic-b2.env`                           |
| Pi REST-server password    | `htpasswd -B -c /mnt/offsite/.htpasswd homelab-backup` (on the Pi) | `/root/.restic-pi.env` |
| Cloudflare API token       | Cloudflare dashboard          | `traefik/.env`                                      |
| Tunnel UUID + credentials  | `cloudflared tunnel create`   | `/srv/docker-data/cloudflared/`                     |
| sops age key               | `age-keygen`                  | `~/.config/sops/age/keys.txt` — unlocks every `.enc` |

⛔ **The age key, the restic password, and the B2 key must exist somewhere
that is not this machine.** The age key unlocks every `.env.enc` in this repo;
the restic password decrypts all three backup repositories. Losing the restic
password means every backup you have is permanently unreadable — the data is
there and no one can read it. Password manager, or paper in another building.

| Task                     | Command                                                                 |
| ------------------------- | ------------------------------------------------------------------------- |
| Shell from anywhere       | `ssh brad@homelab` (Tailscale on)                                        |
| **Is everything OK?**     | `sudo /opt/homelab/scripts/healthcheck.sh`                               |
| Are backups in sync?      | `sudo /opt/homelab/scripts/sanitycheck.sh`                               |
| Check the mesh            | `tailscale status`                                                       |
| Mirror health             | `cat /proc/mdstat` — `[UU]` healthy, `[U_]` degraded                     |
| Tunnel status             | `docker logs cloudflared --tail 20`                                      |
| Database shell            | `docker exec -it postgres psql -U postgres`                              |
| Manual backup             | `sudo systemctl start homelab-backup.service`                            |
| Backup log                | `journalctl -u homelab-backup.service -n 100`                            |
| Next scheduled backup     | `systemctl list-timers \| grep homelab`                                   |
| Whole stack up / status   | `cd /opt/homelab && docker compose up -d` / `docker compose ps`          |
| Rebuild + restart changed | `/opt/homelab/scripts/redeploy.sh`                                       |
| Local snapshots           | `sudo restic -r /srv/docker-data/restic-repo --password-file /root/.restic-password snapshots` |
| Commit config             | `./homelab-secrets.sh commit "message"`                            |

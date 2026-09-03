# Pi backup target (second copy)

**Done and deployed** (2026-09-03) — SSD wiped/mounted, `restic-rest-server`
running, repo initialized, `backup.sh` wired in and confirmed against a real
nightly run (67.7GiB, including the Immich library), and `pi-verify.sh`
confirms exact file-count/size matches. The [Setup](#setup) steps below are
kept as a reference for rebuilding the Pi from scratch, not a to-do list.

## Goal

A third restic target — Raspberry Pi + external SSD, reachable over
Tailscale — that finally covers what B2 can't: the Immich photo library,
currently excluded from `backup.sh`'s `SOURCES` because it blows past the
10GB B2 free tier. Everything else already going to B2 goes here too, for a
second independent copy.

**Scope: back up everything, not just photos.** Configs, Postgres dumps,
Vikunja files, and the photo library all go to the Pi.

**Relocation in progress.** This branch merges with the Pi still physically
in the same house as the tower; moving it to a second location (a relative's
house, per the original plan) happens right after, as a separate physical
step — functionally nothing but a new Tailscale IP, no script or doc changes
needed once it's there. The docs no longer hedge this as "same-house, not
offsite" since the move is imminent and deliberate, not an open-ended TODO —
but until the Pi actually leaves the house, treat "offsite" as aspirational:
it still protects against `sdb`/`md0` failing or B2 becoming unreachable, not
against fire, theft, or the house itself.

## Current state

- **Pi:** hostname `pi-backup`, Debian 13 (Trixie) aarch64, imaged and joined
  to the tailnet already. Reachable as `brad@pi-backup` (Tailscale MagicDNS)
  or by IP — check `tailscale status` on the tower if the hostname doesn't
  resolve; re-auth can change the IP.
- **SSD:** 500GB (not the 2TB originally planned — that's a someday upgrade),
  mounted at `/mnt/offsite` as `ext4`. At current usage (~68GB Immich library
  + a few hundred MB of everything else), 500GB has plenty of headroom for
  history via restic's retention/pruning. `healthcheck.sh` warns at ~85% of
  the drive (`PI_WARN_BYTES`) so this doesn't have to be tracked by hand —
  **but that threshold is hardcoded to today's 500GB drive** and needs
  updating in `healthcheck.sh` if the drive is ever swapped for a bigger one.
- **sudo on the Pi requires a password**, same as the tower — none of the
  steps below can be run unattended from a laptop. Run them at the Pi's
  terminal or over `ssh brad@pi-backup` with the password in hand.

## Setup

Steps actually run against the live Pi/tower on 2026-09-03, kept here for
rebuilding the Pi from scratch (new SD card, replacement SSD, etc.) — not a
pending to-do list.

**1. Wipe and mount the SSD.**
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,SERIAL   # confirm it's sda — the 500G WD drive, not mmcblk0
sudo wipefs -a /dev/sda
sudo mkfs.ext4 /dev/sda
sudo mkdir -p /mnt/offsite
sudo blkid /dev/sda
sudo nano /etc/fstab
```
```
UUID=<sda-uuid>  /mnt/offsite  ext4  defaults,nofail  0  2
```
```bash
sudo mount -a && df -h /mnt/offsite
```
No partition table, matching the whole-disk convention `sdb`/`md0` already
use on the tower — `sda` mounts directly rather than `sda1`.

**2. Install and run `restic-rest-server`.**
REST server over raw HTTP: gives restic-native auth (`htpasswd`) and doesn't
need the Pi's SSH exposed for backup traffic.

The release archive extracts to a single version-named directory containing
the binary directly (not two levels deep) — resolve the actual latest tag
rather than hardcoding a version, since this doc will go stale otherwise:
```bash
LATEST=$(curl -fsSL https://api.github.com/repos/restic/rest-server/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
curl -fsSL -o rest-server.tar.gz \
  "https://github.com/restic/rest-server/releases/download/${LATEST}/rest-server_${LATEST#v}_linux_arm64.tar.gz"
tar xzf rest-server.tar.gz
sudo install -m 755 rest-server_*/rest-server /usr/local/bin/rest-server
rm -rf rest-server_* rest-server.tar.gz
rest-server --version   # confirm it runs before wiring up the service below
sudo apt install -y apache2-utils   # for htpasswd
sudo mkdir -p /mnt/offsite/restic
sudo htpasswd -B -c /mnt/offsite/.htpasswd homelab-backup   # -B: bcrypt — rest-server's
                                                             # htpasswd parser rejects the
                                                             # apr1-MD5 format htpasswd
                                                             # defaults to, with only
                                                             # "Invalid htpasswd entry" in
                                                             # the log to go on
# The service below runs as User=brad, not root — without this, repo
# creation fails with a 500 and "permission denied" in the journal, since
# sudo mkdir above left the directory root-owned.
sudo chown -R brad:brad /mnt/offsite/restic
```

`/etc/systemd/system/restic-rest-server.service`:
```ini
[Unit]
Description=restic REST server (Pi backup target)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/rest-server \
  --path /mnt/offsite/restic \
  --htpasswd-file /mnt/offsite/.htpasswd \
  --listen <PI_TS_IP>:8000 \
  --private-repos
Restart=on-failure
User=brad

[Install]
WantedBy=multi-user.target
```
Binding to `<PI_TS_IP>` specifically (not `0.0.0.0`) means it's reachable
only over Tailscale, never on the house LAN. Get `<PI_TS_IP>` from
`tailscale ip -4` run on the Pi itself.
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now restic-rest-server
sudo systemctl status restic-rest-server
```

**3. Initialize the repo from the tower**, reusing the tower's restic
password so `restic copy`/dedup logic works the same way it does for the
array mirror and B2. `--private-repos` on the server means the URL path must
be the htpasswd username (`homelab-backup`), not `/` — a bare `/` or any
other path is denied.

Auth goes through `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` rather than
embedding `user:pass@` in the URL — restic supports both, but the env-var
form matches how B2's credentials are already structured here and sidesteps
having to URL-escape whatever's in the password:
```bash
export RESTIC_REST_USERNAME=homelab-backup
export RESTIC_REST_PASSWORD=<htpasswd-password>
sudo -E restic -r rest:http://<PI_TS_IP>:8000/homelab-backup/ \
  --password-file /root/.restic-password init \
  --copy-chunker-params \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password
```
`sudo -E` matters — plain `sudo` drops your exported env vars and the
request comes back `401 Unauthorized` with no other clue why.

**4. Drop the Pi's credentials on the tower**, outside the git repo like
`/root/.restic-b2.env`:
```bash
install -m 600 /dev/null /root/.restic-pi.env
cat > /root/.restic-pi.env <<'EOF'
PI_REPO=rest:http://<PI_TS_IP>:8000/homelab-backup/
RESTIC_REST_USERNAME=homelab-backup
RESTIC_REST_PASSWORD=<htpasswd-password>
EOF
```
`scripts/backup.sh` looks for this file and skips the Pi leg cleanly if it's
absent — the block was added ahead of the physical setup on purpose, so
wiring it into the script and actually finishing the Pi don't have to land in
the same step. Once this file exists, the Pi leg switches on the next nightly
run with no other change needed.

**5. Confirm the wiring.**
```bash
sudo systemctl start homelab-backup.service
journalctl -u homelab-backup.service -f
sudo /opt/homelab/scripts/healthcheck.sh    # BACKUPS section should show the Pi repo now
```

**6. Verify it actually backed up what you think it did** — see
[Verification](#verification) below, and run it now rather than trusting the
first green healthcheck.

## Verification

Reachability and snapshot age (what `healthcheck.sh` checks) prove the Pi
*ran*, not that the Immich library actually landed on it intact — a truncated
`EXCLUDES`/`SOURCES_PI` mistake would still show a fresh, green snapshot.
`scripts/pi-verify.sh` checks the thing that actually matters:

```bash
sudo /opt/homelab/scripts/pi-verify.sh
```

- Confirms the Pi repo is reachable and the latest snapshot is recent.
- Compares the **live file count and size** under `$UPLOAD_LOCATION`
  (Immich's actual library on `/srv/media`) against what restic recorded in
  that snapshot — catches a scoping mistake (wrong `SOURCES_PI` path, an
  exclude that's too broad, a partial/truncated backup) that a fresh-snapshot
  check alone would miss.

  This needs `restic ls latest --recursive <dir>` with the directory as a
  positional argument, not `--path` — `--path` on `ls`/`stats` only selects
  *which snapshot* to use (by one of its recorded top-level source paths),
  it does not restrict what gets listed or counted. `stats` in particular has
  no way to scope to a subtree at all, so the size comparison is computed by
  summing `"size"` across the same `--json` listing rather than using
  `stats --mode restore-size`. Both mistakes looked plausible on the first
  real run — the snapshot count came back *higher* than live because plain
  `ls` counts directories as well as files, and Immich's per-asset directory
  layout means there are nearly as many directories as files.
- Runs `restic check --read-data-subset=5%` against the Pi repo — same
  sampling B2 uses, done here mainly to catch a *degrading SSD* rather than
  to save egress, since Tailscale-LAN reads aren't metered the way B2's are.

Run it monthly alongside `sanitycheck.sh` (see
[operations.md](operations.md#cadence)), and always right after step 6 above
before trusting the Pi leg is really done.

**Twice a year**, do the actual restore drill — see
[restore.md](restore.md#verify-it-actually-works), which extends the
existing B2 drill with a Pi/Immich restore step.

## Security notes

- `--listen <PI_TS_IP>:8000` keeps the REST server off the house LAN
  entirely — Tailscale is the only path in, same as `immich-server` and the
  other tailnet-bound services on the tower.
- Consider `--append-only` on the systemd unit as a ransomware/accidental-
  `forget` guard, dropping it only when actually running `prune` (monthly) —
  trades a little manual friction for "even a compromised tower credential
  can't delete existing snapshots."
- The Pi itself is now something that needs occasional `apt upgrade`
  attention, same as the tower — a second machine to keep patched, not a
  fire-and-forget appliance. It isn't in `healthcheck.sh`'s `CONTAINERS` or
  update-tracking (it runs no containers), so its own package updates are on
  you to remember — there's no automated nudge for this today.

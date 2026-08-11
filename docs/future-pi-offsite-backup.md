# Future: offsite Pi backup (second location)

**Not yet done** — confirmed against the live box (2026-08-11): `tailscale
status` shows only `homelab` and one laptop in the tailnet, and `backup.sh`
has no third repo target.

## Goal

A third restic target — Raspberry Pi + 2TB external SSD, physically at a
different house, reachable over Tailscale — that finally covers what B2
can't: the Immich photo library, currently excluded from `backup.sh`'s
`SOURCES` because it blows past the 10GB B2 free tier. Everything else
already going to B2 goes here too, for a second independent offsite copy.

**Scope: back up everything, not just photos.** The whole point of 2TB of
headroom is that there's no reason to special-case anything — configs,
Postgres dumps, Vikunja files, and the photo library all go to the Pi.

## Prerequisites

- Raspberry Pi 4 or 5 (USB3 matters — it's the bottleneck to the external
  SSD, not the network, since Tailscale traffic is upload-bandwidth-bound
  anyway)
- 2TB external SSD in a USB3 enclosure
- Raspberry Pi Imager, on a machine that can pre-configure hostname/SSH
  key/Wi-Fi before first boot
- The same tailnet `homelab` is already on (`tailscale ip -4` on the tower)

## Steps

**1. Image the Pi.**
Raspberry Pi Imager → Raspberry Pi OS Lite (64-bit) → gear icon (advanced
options) to set hostname (e.g. `pi-backup`), enable SSH with your public key,
and Wi-Fi/ethernet credentials, so it's headless-ready on first boot. Do this
before shipping it to the second location, or over that location's LAN once
it's there.

**2. First boot, update, join Tailscale.**
```bash
ssh brad@pi-backup.local          # or its DHCP IP, before Tailscale is up
sudo apt update && sudo apt full-upgrade -y
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```
Authenticate via the link it prints. Confirm it lands in the same tailnet as
`homelab`, then note its Tailscale IP (`tailscale ip -4`) — that's
`<PI_TS_IP>` for the rest of this doc.

From the tower, confirm reachability before going further:
```bash
tailscale ping <PI_TS_IP>
ssh brad@<PI_TS_IP>
```

**3. Format and mount the external SSD.**
```bash
lsblk                              # identify it, e.g. /dev/sda — confirm size ~2TB before wiping anything
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

**4. Install and run `restic-rest-server`.**
REST server over raw SFTP: gives restic-native auth (`htpasswd`) and doesn't
need the Pi's SSH exposed for backup traffic.
```bash
curl -fsSL -o rest-server.tar.gz \
  https://github.com/restic/rest-server/releases/latest/download/rest-server_linux_arm64.tar.gz
tar xzf rest-server.tar.gz --strip-components=2 -C /usr/local/bin '*/rest-server'
sudo apt install -y apache2-utils   # for htpasswd
sudo mkdir -p /mnt/offsite/restic
htpasswd -c /mnt/offsite/.htpasswd homelab-backup   # same restic password idea — one set of creds
```

`/etc/systemd/system/restic-rest-server.service`:
```ini
[Unit]
Description=restic REST server (offsite backup target)
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
only over Tailscale — never on the second house's own LAN.
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now restic-rest-server
sudo systemctl status restic-rest-server
```

**5. Initialize the repo from the tower.**
Reuse the same restic password as the local/B2 repos:
```bash
sudo restic -r rest:http://homelab-backup:<htpasswd-password>@<PI_TS_IP>:8000/ \
  --password-file /root/.restic-password init
```

**6. Add a third block to `/opt/homelab/scripts/backup.sh`.**
Photos need to reach the Pi but not B2, so this needs a second sources list
rather than reusing `SOURCES` as-is:
```bash
PI_REPO=rest:http://homelab-backup:<htpasswd-password>@<PI_TS_IP>:8000/

SOURCES_PI=(
  "${SOURCES[@]}"
  /srv/media/immich
)

# ---- second offsite (Pi) ----
restic -r "$PI_REPO" --password-file "$PASSFILE" backup --tag nightly "${SOURCES_PI[@]}"
restic -r "$PI_REPO" --password-file "$PASSFILE" forget --tag nightly \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12
[ "$(date +%d)" = "01" ] && restic -r "$PI_REPO" --password-file "$PASSFILE" prune
[ "$(date +%u)" = "7" ] && restic -r "$PI_REPO" --password-file "$PASSFILE" check
```

**7. Add the Pi target to `healthcheck.sh` and `sanitycheck.sh`**, mirroring
how the B2 check and the 3-way sync check already work.

**8. Test a restore drill**, same shape as the existing restore verification
in [restore.md](restore.md#verify-it-actually-works), pointed at the Pi repo:
```bash
sudo restic -r "$PI_REPO" --password-file /root/.restic-password restore latest --target /tmp/pi-restore-test
```

## Security notes

- `--listen <PI_TS_IP>:8000` keeps the REST server off the second house's LAN
  entirely — Tailscale is the only path in.
- Consider `--append-only` on the systemd unit as a ransomware/accidental-
  `forget` guard, dropping it only when actually running `prune` (monthly) —
  trades a little manual friction for "even a compromised tower credential
  can't delete existing snapshots."
- The Pi itself is now something that needs occasional `apt upgrade`
  attention, same as the tower — a second machine to keep patched, not a
  fire-and-forget appliance.

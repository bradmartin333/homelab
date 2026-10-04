# Backup setup

One-time setup for the nightly backup on a fresh box, or on a rebuild once
`/srv/docker-data` and `/srv/media` are mounted. What gets backed up and why
is in [storage-and-backup.md](../docs/storage-and-backup.md). Getting data
back out is in [restore.md](../docs/restore.md).

The unit files here are the canonical copies. `install.sh` symlinks them into
`/etc/systemd/system`, so a `git pull` changes them in place. Run
`./systemd/install.sh` again after pulling a unit change.

| Unit                             | What it does                                                    |
| -------------------------------- | --------------------------------------------------------------- |
| `homelab-backup.timer`           | Starts the backup nightly, 03:00–03:05                          |
| `homelab-backup.service`         | Runs `scripts/backup.sh`. No `[Install]`: only the timer starts it |
| `homelab-boot-reconcile.service` | At boot, starts any container that failed to come up            |

## 1. Restic password

One key unlocks every repo: local, array, B2 and Pi.

```bash
sudo apt install -y restic
sudo install -m 600 /dev/null /root/.restic-password
openssl rand -hex 32 | sudo tee /root/.restic-password >/dev/null
```

⛔ Copy it somewhere off this machine **now**. Without it, every repo is
unreadable. See the secrets table in
[operations.md](../docs/operations.md#quick-reference).

On a rebuild, put the existing password back in place instead of making a
new one.

## 2. Local repo and its array mirror

Skip this on a rebuild if the repos survived.

```bash
sudo restic -r /srv/docker-data/restic-repo --password-file /root/.restic-password init
sudo restic -r /srv/media/restic-mirror --password-file /root/.restic-password init \
  --copy-chunker-params \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password
```

`--copy-chunker-params` keeps the nightly `restic copy` deduplicating instead
of rewriting everything.

## 3. B2 offsite

Bucket, lifecycle rule, `/root/.restic-b2.env` and `init`: follow
[storage-and-backup.md → Backblaze B2](../docs/storage-and-backup.md#backblaze-b2).
`backup.sh` fails without this file.

## 4. Dead man's switch

In healthchecks.io, create a check with a **1 day period and a few hours'
grace**, and make sure email notification is turned on. Then save its UUID:

```bash
sudo install -m 600 /dev/null /root/.homelab-hc-uuid
echo '<uuid>' | sudo tee /root/.homelab-hc-uuid >/dev/null
```

Without it, backups still run, but nothing tells you when they stop. See
[operations.md → Alerting](../docs/operations.md#alerting).

## 5. Install the timer

```bash
cd /opt/homelab && ./systemd/install.sh
```

The output should list `homelab-backup.timer` with a next run time. If the
next run shows `n/a`, see `install.sh`'s comments. Running it again is the fix.

## 6. First run and check

```bash
sudo systemctl start homelab-backup.service   # blocks until done
journalctl -u homelab-backup -n 50 --no-pager
sudo ./scripts/healthcheck.sh
```

The check should show a fresh snapshot in the local, array and B2 repos, and
healthchecks.io should have received a ping.

To check that the timer schedules the *next* run as well, which a manual
start doesn't prove, use `sudo ./scripts/backup-timer-test.sh arm`, then
`status`, then `revert`.

## Optional extras

- **Pi target** (the only copy that includes the Immich library):
  [pi-backup.md](../docs/pi-backup.md). Skipped cleanly until
  `/root/.restic-pi.env` exists.
- **GitHub mirrors**: [github-mirrors.md](../docs/github-mirrors.md). These
  are a container, not a systemd unit. They land in `/srv/docker-data`, so
  the steps above already cover them.

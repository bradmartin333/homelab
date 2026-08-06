# Architecture migration

A set of container and daemon changes that are independent of the storage move
in [storage-and-backup.md](storage-and-backup.md), but land well alongside it —
several want the stack down anyway.

Run everything as root on the homelab box. Steps are ordered so the stack is
down once, not repeatedly. If you're doing the storage migration too, do that
first; step 4 here depends on `/srv/media` existing.

| # | Change | Needs downtime |
| - | ------------------------------ | -------------- |
| 1 | Cap container log growth       | daemon restart |
| 2 | Pin the `proxy` network subnet | only if wrong  |
| 3 | Boot ordering healthchecks     | recreate       |
| 4 | Restic mirror onto the array   | no             |
| 5 | Tailscale IP to a variable     | recreate       |
| 6 | cloudflared off watchtower     | no             |

## 1. Cap container log growth

Docker's `json-file` driver has **no size limit by default**, and traefik runs
with `accessLog: {}` enabled — so every HTTP request to every public service
accumulates on the root filesystem indefinitely. Nothing rotates it.

See how much has already built up:

```bash
sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -h | tail
```

Apply the cap at the daemon level so containers added later inherit it:

```bash
sudo cp /opt/homelab/docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

Restarting the daemon restarts every container — this is the one step that
interrupts service on its own. Existing oversized log files are not truncated
retroactively; the cap takes effect as they rotate. To reclaim that space now,
`docker compose up -d --force-recreate <service>` for the worst offenders.

## 2. Pin the proxy network subnet

`traefik/traefik.yml` trusts forwarded headers from `172.20.0.0/16`. Nothing
guarantees the `proxy` network actually uses that range — it's `external: true`,
created by hand at some point in the past. If they disagree, traefik stops
trusting forwarded headers and every service sees the proxy's address instead of
the real client address. **Nothing errors when this is wrong**; the rate-limit
middleware just silently keys on one IP for all traffic.

```bash
/opt/homelab/scripts/create-networks.sh
```

The script is idempotent and creates whatever is missing with the right subnet.
If the network already exists with a *different* subnet it warns rather than
acting, since fixing it means disconnecting every attached container:

```bash
docker compose -f /opt/homelab/docker-compose.yml down
docker network rm proxy
/opt/homelab/scripts/create-networks.sh
docker compose -f /opt/homelab/docker-compose.yml up -d
```

This script is also the missing prerequisite for a rebuild from scratch — see
the full-rebuild section of [restore.md](restore.md).

## 3. Boot ordering

`vikunja` had no `depends_on` at all, so on boot it raced postgres and
crash-looped until it happened to win. `immich-server` had a plain `depends_on`,
which orders container *start* but says nothing about readiness.

Already changed in the compose files:

- `immich-postgres` gained a healthcheck matching the one `postgres` already had.
- `vikunja` waits on `postgres` with `condition: service_healthy`.
- `immich-server` waits on `immich-postgres` with `condition: service_healthy`,
  and on `immich-redis` with `condition: service_started`.

Redis is deliberately the weaker condition — valkey's CLI binary name varies
between image builds, so a healthcheck there is more fragile than the problem it
solves, and Immich retries its redis connection anyway.

Apply with a recreate:

```bash
docker compose -f /opt/homelab/docker-compose.yml up -d
docker compose -f /opt/homelab/docker-compose.yml ps
```

Expect `immich-postgres` and `postgres` to show `(healthy)`. If
`immich-postgres` reports unhealthy, check that `DB_USERNAME` and
`DB_DATABASE_NAME` in `immich/.env` match what the container actually
initialized with — the healthcheck reads `$POSTGRES_USER`/`$POSTGRES_DB` inside
the container:

```bash
docker exec immich-postgres pg_isready -U "$(docker exec immich-postgres printenv POSTGRES_USER)"
```

## 4. Restic mirror onto the array

Moving the repo onto `sdb` put it on the same unmirrored disk as the data it
protects. A ~123M second copy on the array buys that redundancy back: a dead
`sdb` becomes a local restore instead of a B2 download.

`--copy-chunker-params` is what makes the mirror dedupe against the source
instead of storing everything twice over:

```bash
restic -r /srv/media/restic-mirror --password-file /root/.restic-password init \
  --copy-chunker-params \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password

restic -r /srv/media/restic-mirror --password-file /root/.restic-password copy \
  --from-repo /srv/docker-data/restic-repo \
  --from-password-file /root/.restic-password
```

`backup.sh` now refuses to run if `/srv/media/restic-mirror` is missing, rather
than skipping the mirror quietly — do this before re-enabling the timer.

All three repos share `/root/.restic-password`.

Restoring from the mirror is identical to any other repo; set
`REPO=/srv/media/restic-mirror` and follow [restore.md](restore.md).

## 5. Tailscale IP to a variable

`immich/docker-compose.yml` bound port 2283 to a hardcoded `100.115.137.14`. If
a Tailscale re-auth ever changes that address the container fails outright with
`cannot assign requested address`. It now reads `${TAILSCALE_IP}`.

Add it to `immich/.env` — the same file as `UPLOAD_LOCATION`, which is where
that compose file's interpolation resolves from:

```bash
docker exec immich-server tailscale ip -4 2>/dev/null || tailscale ip -4
$EDITOR /opt/homelab/immich/.env      # TAILSCALE_IP=100.115.137.14
/opt/homelab/scripts/homelab-secrets.sh commit "parameterize tailscale bind IP"
```

A plain `${TAILSCALE_IP}` would interpolate to empty when unset and bind
`":2283:2283"` — every interface on the box, exposing Immich on your LAN. The
compose file uses `${TAILSCALE_IP:?...}` so that case is a hard error at
`up` time instead of a silent exposure. Verify anyway:

```bash
docker port immich-server 2283     # expect 100.115.137.14:2283, not 0.0.0.0:2283
```

## 6. cloudflared off watchtower

Watchtower runs in label-enable mode, so it only touches containers carrying
`com.centurylinklabs.watchtower.enable=true`. Of those, `immich-server` and
`immich-machine-learning` are pinned to `v3.1.0` and `vikunja` to `2.5` — the
first two can only move on a digest re-push, and vikunja picks up 2.5.x patch
releases, which is the point of running watchtower at all.

`cloudflared:latest` was the exception: it could cross a major version
unattended at 05:00 with no notification and no rollback. Its watchtower label
is now removed. It updates when you ask it to:

```bash
docker compose -f /opt/homelab/docker-compose.yml pull cloudflared
docker compose -f /opt/homelab/docker-compose.yml up -d cloudflared
```

To go further and pin it, take the digest of whatever is currently running and
put that in the compose file — this pins to a known-good image rather than a
version number guessed from release notes:

```bash
docker inspect --format='{{index .RepoDigests 0}}' cloudflared
# → cloudflare/cloudflared@sha256:...  paste into cloudflared/docker-compose.yml
```

## Verify

```bash
sudo /opt/homelab/scripts/healthcheck.sh
```

Expect, beyond the usual: both postgres containers healthy, `local repo (sdb)`
and `array mirror (md0)` each reporting a recent snapshot, and all mounts real.

Then confirm the log cap actually took:

```bash
docker inspect traefik -f '{{.HostConfig.LogConfig}}'   # expect max-size:10m
```

## What was deliberately not changed

- **The networks stayed `external: true`.** Declaring them in the top-level
  compose file would be tidier, but `include:` requires every included file to
  be valid standalone, so each would still need its own declaration — meaning
  the subnet duplicated across four files. One idempotent script is the better
  trade.
- **Watchtower stayed.** With cloudflared off it, its remaining job is vikunja
  patch releases on the rolling `2.5` tag — the only automatic security patching
  in the stack for a public-facing app.
- **No redis healthcheck**, per step 3.

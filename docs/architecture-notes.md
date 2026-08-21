# Architecture notes

Rationale for a few non-obvious decisions in the compose files that aren't
explained anywhere else. Storage/backup design is in
[storage-and-backup.md](storage-and-backup.md); container log caps and
`live-restore` are in [`../docker/README.md`](../docker/README.md); the
`proxy` network's pinned subnet is in
[`../scripts/create-networks.sh`](../scripts/create-networks.sh).

## Boot ordering

`vikunja` originally had no `depends_on` at all, so on boot it raced postgres
and crash-looped until it happened to win. `immich-server` had a plain
`depends_on`, which orders container *start* but says nothing about
readiness.

- `immich-postgres` has a healthcheck matching the one `postgres` already had.
- `vikunja` waits on `postgres` with `condition: service_healthy`.
- `immich-server` waits on `immich-postgres` with `condition: service_healthy`,
  and on `immich-redis` with `condition: service_started`.

Redis is deliberately the weaker condition — valkey's CLI binary name varies
between image builds, so a healthcheck there is more fragile than the problem
it solves, and Immich retries its redis connection anyway.

If `immich-postgres` reports unhealthy after a change, check that
`DB_USERNAME`/`DB_DATABASE_NAME` in `immich/.env` match what the container
actually initialized with — the healthcheck reads `$POSTGRES_USER`/
`$POSTGRES_DB` inside the container:

```bash
docker exec immich-postgres pg_isready -U "$(docker exec immich-postgres printenv POSTGRES_USER)"
```

## Tailscale IP is a variable, not a literal

`immich/docker-compose.yml` binds port 2283 to `${TAILSCALE_IP}` rather than a
hardcoded address — a re-auth that changes the tailnet IP used to fail the
container outright with `cannot assign requested address`.

Set in `immich/.env` (same file as `UPLOAD_LOCATION`):

```bash
docker exec immich-server tailscale ip -4 2>/dev/null || tailscale ip -4
$EDITOR /opt/homelab/immich/.env      # TAILSCALE_IP=<the ip above>
/opt/homelab/homelab-secrets.sh commit "update tailscale bind ip"
```

The compose file uses `${TAILSCALE_IP:?...}` rather than a bare `${TAILSCALE_IP}`
so an unset variable is a hard error at `up` time instead of silently
interpolating to empty and binding `:2283:2283` on every interface — exposing
Immich on the LAN. Verify after any change anyway:

```bash
docker port immich-server 2283     # expect <ip>:2283, not 0.0.0.0:2283
```

`cannot assign requested address` has a second, unrelated cause: at boot,
dockerd restores containers before tailscaled has put the address on
`tailscale0`, so every service binding `${TAILSCALE_IP}` — vikunja,
immich-server, grafana, prometheus — fails to start. On the 2026-08-20
auto-reboot dockerd lost that race by 1.5 seconds and all four stayed down
until someone noticed, because a restart policy does not retry a container
that failed to *start* during daemon restore. `homelab-boot-reconcile.service`
now waits for the address and brings them up; if this symptom appears after a
reboot, read `journalctl -u homelab-boot-reconcile -b` before touching any
`.env`.

## cloudflared is not on watchtower

Watchtower runs in label-enable mode — only containers carrying
`com.centurylinklabs.watchtower.enable=true` are touched. `immich-server`/
`immich-machine-learning` are pinned to a specific version (only move on a
digest re-push) and `vikunja` tracks a minor tag, which is the actual point of
running watchtower.

`cloudflared:latest` was the exception: it could cross a major version
unattended with no notification and no rollback. It has no watchtower label
and updates only when asked:

```bash
docker compose -f /opt/homelab/docker-compose.yml pull cloudflared
docker compose -f /opt/homelab/docker-compose.yml up -d cloudflared
```

To pin it instead of tracking `latest`, take the digest of whatever's
currently running and put that in the compose file:

```bash
docker inspect --format='{{index .RepoDigests 0}}' cloudflared
# → cloudflare/cloudflared@sha256:...  paste into cloudflared/docker-compose.yml
```

## What was deliberately not changed

- **The networks stayed `external: true`.** Declaring them in the top-level
  compose file would be tidier, but `include:` requires every included file
  to be valid standalone, so each would still need its own declaration —
  meaning the subnet duplicated across four files. One idempotent script
  (`create-networks.sh`) is the better trade.
- **Watchtower stayed.** With cloudflared off it, its remaining job is
  vikunja's patch releases — the only automatic security patching in the
  stack for a public-facing app.
- **No redis healthcheck**, per the boot-ordering section above.

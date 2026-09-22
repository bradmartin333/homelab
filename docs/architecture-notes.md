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

## Which `.env` a variable goes in

Compose fills in `${VAR}` from two kinds of `.env`. The root
`/opt/homelab/.env` applies to every included compose file. An app's own
`<app>/.env` applies only to that app's compose file — and any service with
`env_file: .env` (most of them) also gets everything in it as container
environment.

When both set the same variable, the root wins, silently (a variable exported
in the shell beats both). Checked on compose v5.5.1 with a throwaway
`include:` project:

```
set in <app>/.env only     → <app>/.env value
set in root and <app>/.env → root value
also exported in shell     → shell value
```

So each variable gets exactly one home:

- **Root `.env`** — non-secret settings read at build or routing time, and
  anything several apps share: domains, the `TRAEFIK_BIND_IP` and
  `TAILSCALE_IP` bind addresses, `ACME_EMAIL`, and the `*_BRANCH` build refs.
  A plain file copied from `.env.example`, not in git.
- **`<app>/.env`** — secrets and settings only that app uses
  (`VIKUNJA_DB_PASSWORD`, `MEALS_DB_PASSWORD`, `UPLOAD_LOCATION`).
  sops-encrypted to `.env.enc` and committed. This holds even for a
  low-stakes secret, like a metrics scrape token on an internal network.
  Never write one as a literal in a compose file or `prometheus.yml`: those
  are plaintext in git, and a leaked value stays in the history after it's
  removed.

A `*_BRANCH` variable once ended up in an app's own `.env` instead of the
root. It worked only because the root `.env` didn't set it — rebuilding the
root from `.env.example` would have made the app-level copy a silent no-op —
and it leaked into that container's environment. `MEALS_BRANCH` is the one
left that can go wrong this way. To see what compose actually resolved rather
than trusting either file:

```bash
docker compose -f /opt/homelab/docker-compose.yml config | grep 'context:.*#'
```

## Tailscale IP is a variable, not a literal

Four services bind a host port to `${TAILSCALE_IP}` rather than a hardcoded
address: vikunja (3456), immich-server (2283), grafana (3000) and prometheus
(9090). A re-auth that changes the tailnet IP used to fail them outright
with `cannot assign requested address`.

It is set once, in the root `.env`, so a re-IP is one edit. The root `.env`
isn't in git, so there is nothing to commit:

```bash
tailscale ip -4
$EDITOR /opt/homelab/.env      # TAILSCALE_IP=<the ip above>
docker compose -f /opt/homelab/docker-compose.yml up -d
```

Each compose file uses `${TAILSCALE_IP:?...}` rather than a bare
`${TAILSCALE_IP}`, so an unset variable is a hard error at `up` time instead
of silently interpolating to empty and binding the port on every interface —
exposing the service on the LAN. Verify after any change anyway:

```bash
docker port vikunja 3456           # expect <ip>:3456, not 0.0.0.0:3456
docker port immich-server 2283
docker port grafana 3000
docker port prometheus 9090
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

It recreates them rather than restarting them. After the 2026-09-15 reboot,
all four failed containers had lost their internal network (vikunja lost
`db_internal`, grafana had no network left at all). Restarting reuses those
same containers, so vikunja crash-looped on `lookup postgres` and
immich-server looped too. The reconcile then checked once, a second later,
and reported success. It now waits 30s and fails the unit if any restart
count moved.

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

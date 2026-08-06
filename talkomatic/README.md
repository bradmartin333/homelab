# Talkomatic (private chat for friends)

Self-hosted fork of [talkomatic-classic](https://github.com/mohdmahmodi/talkomatic-classic),
a nickname-based chat room - no user accounts or database, state is JSON files
on disk. Access control for "who gets in" is handled at the Cloudflare edge
instead of inside the app; see below.

## Build

`docker-compose.yml` builds straight from the upstream git repo (`build.context`
is a git URL) rather than vendoring the source or pulling a registry image -
upstream doesn't publish one. That has one consequence: **watchtower can't
update this service**, since there's no image tag for it to poll
(`watchtower.enable=false` is set accordingly). To pick up new upstream
commits:

```bash
docker compose build --pull --no-cache talkomatic
docker compose up -d talkomatic
```

To pin to a known-good point instead of always tracking `main`, change the
`#main` ref in `docker-compose.yml`'s `build.context` to a commit SHA or tag.

## Setup

1. Create `talkomatic/.env` (gitignored, encrypt with `homelab-secrets.sh encrypt`
   like the other services) with:

   ```
   SESSION_SECRET=<openssl rand -hex 32>
   ```

   `DEV_KEY_HASH` is optional - only needed if you want an owner/mod key for
   the moderation dashboard (see upstream's `.env.example` for how to generate
   the hash).

2. Add `TALKOMATIC_DOMAIN` to the root `.env` (see `.env.example`).

3. Add a public hostname for `TALKOMATIC_DOMAIN` to the cloudflared tunnel
   config on the host (`/srv/docker-data/cloudflared/config.yml`, not tracked
   in this repo) - mirror whatever ingress rule the existing domains
   (`IMMICH_DOMAIN`, `VIKUNJA_DOMAIN`) use to reach traefik.

4. From the repo root (so `include:` picks up this file):

   ```bash
   docker compose build talkomatic
   docker compose up -d talkomatic
   ```

Runtime state (rooms, bans, identity, audit log) persists to
`/srv/docker-data/talkomatic` on the host - back it up alongside the other
services' data dirs.

## Gating access with Cloudflare Access

Talkomatic has no login of its own - anyone who loads the page can type any
nickname and start chatting. Cloudflare Access sits in front of the hostname
at Cloudflare's edge and requires a login *before* the request ever reaches
the tunnel, which is what stands in for "accounts" here: each friend's email
on an allowlist, not a password they set inside the app.

In the Zero Trust dashboard (`one.dash.cloudflare.com` → your account → Access
→ Applications):

1. **Add an application → Self-hosted.**
2. **Application domain**: the value of `TALKOMATIC_DOMAIN`.
3. **Policy**: action `Allow`, include rule `Emails` listing each friend's
   address (or an existing Access group, if you keep one).
4. **Login method**: leave `One-time PIN` on - friends verify with a code
   emailed to them, no password or third-party signup required. Adding a
   friend later just means adding their email to the policy.
5. **Session duration**: pick something long enough friends aren't
   re-verifying every visit (e.g. 24h or a week).
6. Save, then load the domain - Cloudflare's login page should appear before
   Talkomatic does.

No changes are needed on the traefik or app side: Access enforcement happens
entirely at Cloudflare's edge, ahead of the tunnel.

**Caveat**: Access gates the door, not identity inside the room. Once past
login, chat nicknames are still free-typed and unlinked to the Access
identity - useful for "only my friends can reach this at all," not for
knowing which friend said what inside the app. Cloudflare does forward a
`Cf-Access-Authenticated-User-Email` header on every authenticated request,
which `server/identity.js` could be taught to trust for that - not implemented
here.

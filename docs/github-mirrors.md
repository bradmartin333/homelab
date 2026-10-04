# GitHub mirrors

A nightly copy of a whitelisted set of my GitHub repos, wikis included, in
case GitHub loses them or goes away. It's a backup, not a place to work from.

## How it works

- The `gickup` container ([`../gickup/`](../gickup/)) runs at 02:30 and makes
  or updates a bare `--mirror` clone of each repo under
  `/srv/docker-data/gickup/github.com/bradmartin333/<repo>.git`. Wikis sit
  next to their repo as `<repo>.wiki.git`.
- The 03:00 restic backup already covers all of `/srv/docker-data`, so the
  mirrors go to the local repo, the array copy and B2 without any change to
  `backup.sh`. See [storage-and-backup.md](storage-and-backup.md).
- gickup keeps only the latest state of each repo. Restic snapshots keep the
  history, so a force-push, a deleted branch or a deleted repo can be
  recovered from an older snapshot until it ages out of `LOCAL_KEEP` /
  `B2_KEEP`.
- A repo deleted on GitHub stays in the mirror directory. gickup never
  removes anything.

Issues, PRs and releases are **not** mirrored, only git data.

## Choosing repos

Only repos named under `include:` in [`../gickup/conf.yml`](../gickup/conf.yml)
are mirrored. That list is the source of truth for what's backed up. A fork
goes on it the same way as any other repo, under my fork's name. Git packs
barely compress further, so each repo added grows B2 by roughly its GitHub
size, against the 10 GB free tier. To find a repo's size:
`gh api repos/bradmartin333/<repo> --jq .size` (in KB).

Taking a repo off the list stops future updates but leaves its existing
mirror on disk. Delete the `.git` directory by hand to get it out of future
snapshots. B2 frees the space after the next monthly prune.

## Setup

1. Create a fine-grained token at
   <https://github.com/settings/personal-access-tokens/new>. Resource owner:
   `bradmartin333`. Repository access: All repositories. Permissions:
   Contents read-only. "All repositories" keeps the whitelist in
   `conf.yml` the only list to edit. A fine-grained token also only sees
   repos its owner owns, so `include:`, which matches on name alone, can't
   pick up someone else's repo with the same name.
2. On the box: `cd /opt/homelab && git pull`, then
   `cp gickup/.env.example gickup/.env` and set `GITHUB_TOKEN`.
3. `./homelab-secrets.sh commit "add gickup"`.
4. Start gickup, then reload prometheus so it picks up the new scrape job.
   `up -d` alone won't: prometheus.yml is bind-mounted, so its container
   isn't recreated, and prometheus only reads the file at startup or on
   reload. `scripts/redeploy.sh` does the same reload.

   ```bash
   docker compose up -d gickup
   docker compose exec -T prometheus wget -qO- --post-data='' http://localhost:9090/-/reload
   ```
5. Do the first run now instead of waiting for 02:30:

   ```bash
   docker exec gickup sh -c \
     "sed '/^cron:/d' /gickup/conf.yml > /tmp/once.yml && /gickup/gickup /tmp/once.yml"
   ```

   Without `cron:`, gickup runs once and exits. The token file it reads was
   already written when the container started.
6. Check:
   - `docker logs gickup` shows no errors.
   - `sudo ls /srv/docker-data/gickup/github.com/bradmartin333` lists each
     whitelisted repo, plus a `.wiki.git` for each one that has a wiki.
   - `sudo git -C /srv/docker-data/gickup/github.com/bradmartin333/<repo>.git log -1`
     shows the latest commit.

## Checks

- `sudo ./scripts/healthcheck.sh`, **GITHUB MIRRORS** section: each repo on
  the whitelist has a valid mirror on disk, and gickup's log shows a
  completed, error-free run in the last 26h. The log resets when the
  container is recreated, so right after a redeploy or a watchtower update
  this shows a warning until the next 02:30 run, not a failure. A manual
  first run (step 5) goes to your terminal, not the container log, so it
  doesn't count either.
- `sudo ./scripts/sanitycheck.sh`: each whitelisted mirror is inside the
  latest nightly snapshot, which the same script already checks is identical
  in the local, array and B2 repos. A repo added to the whitelist fails this
  until the 03:00 backup after its first mirror run.

## Token expiry

Fine-grained tokens expire. When the token runs out, the nightly run fails
and every repo stops updating, while the container keeps running.
`healthcheck.sh` reports it as a run with errors. You'll also see
`gickup_repo_success == 0` in Prometheus and an auth error in
`docker logs gickup`. Rotate it by editing
`gickup/.env`, then run `./homelab-secrets.sh commit "rotate gickup token"`
and `docker compose up -d gickup`.

## Restoring a repo

```bash
# from the live mirror
git clone /srv/docker-data/gickup/github.com/bradmartin333/<repo>.git

# or push it all back to a fresh, empty GitHub repo
git -C /srv/docker-data/gickup/github.com/bradmartin333/<repo>.git \
  push --mirror git@github.com:bradmartin333/<repo>.git
```

If the box itself is gone, restore `/srv/docker-data/gickup` from B2 first.
The steps are in [restore.md](restore.md).

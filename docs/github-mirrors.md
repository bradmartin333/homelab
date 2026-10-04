# GitHub mirrors

A nightly copy of every GitHub repo I own, forks and wikis included, in case
GitHub loses them or goes away. It's a backup, not a place to work from.

## How it works

- The `gickup` container ([`../gickup/`](../gickup/)) runs at 02:00 and makes
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

## Size and B2

The full set was about 2.4 GB on GitHub (2026-10), and git packs barely
compress further, so this is the biggest thing in B2 after the database
dumps. To skip a repo, add its name to `exclude:` in
[`../gickup/conf.yml`](../gickup/conf.yml). Excluding a repo stops future
updates but leaves its existing mirror on disk. Delete the `.git` directory
by hand to get it out of future snapshots. B2 frees the space after the
next monthly prune.

## Setup

1. Create a fine-grained token at
   <https://github.com/settings/personal-access-tokens/new>. Resource owner:
   `bradmartin333`. Repository access: All repositories. Permissions:
   Contents read-only. A fine-grained token only sees repos its owner owns,
   which keeps collaborator and org repos out.
2. On the box: `cd /opt/homelab && git pull`, then
   `cp gickup/.env.example gickup/.env` and set `GITHUB_TOKEN`.
3. `./homelab-secrets.sh commit "add gickup"`.
4. `docker compose up -d gickup prometheus` (prometheus picks up the new
   scrape job).
5. Do the first run now instead of waiting for 02:00:

   ```bash
   docker exec gickup sh -c \
     "sed '/^cron:/d' /gickup/conf.yml > /tmp/once.yml && /gickup/gickup /tmp/once.yml"
   ```

   Without `cron:`, gickup runs once and exits. The token file it reads was
   already written when the container started.
6. Check:
   - `docker logs gickup` shows no errors.
   - `sudo ls /srv/docker-data/gickup/github.com/bradmartin333 | wc -l`
     matches the repo count, plus one for each wiki.
   - `sudo git -C /srv/docker-data/gickup/github.com/bradmartin333/homelab.git log -1`
     shows the latest commit.

## Token expiry

Fine-grained tokens expire. When the token runs out, the nightly run fails
and every repo stops updating, while the container keeps running and
`healthcheck.sh` stays green. The signal is `gickup_repo_success == 0` in
Prometheus, or an auth error in `docker logs gickup`. Rotate it by editing
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

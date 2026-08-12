# Bot profiles

Drop-in personality files for talkomatic-bot. Everything else (Talkomatic
URL/room, API keys, cooldown timings) is static per-container config in
`../.env` — these files hold only the five params that define a bot's
personality:

```
BOT_USERNAME=
BOT_PERSONA=
REPLY_PERSONA=
BOT_TRIGGER_WORDS=
CLAUDE_MODEL=
```

Any key you omit falls back to the container's `.env` / built-in default.
Blank lines and `#` comments are ignored.

## Using a profile

From the homelab box:

```
scripts/bot-ctl.sh list                          # available profiles
scripts/bot-ctl.sh status <container>            # which profile a container is running
scripts/bot-ctl.sh load <container> <profile>    # hot-swap a running container onto a profile
```

`load` copies `bots/<profile>.env` to `bots/active/<container>.env` and sends
the container SIGHUP. The app re-reads that file live — persona/model/trigger
changes apply on the next message, and a username change makes it drop and
rejoin the lobby under the new name. No rebuild, no restart.

## `bots/active/`

Per-container state (which profile is currently loaded), one file per
container name, git-ignored — regenerate with `bot-ctl.sh load`.

## Wiring up a new container

Any container running the talkomatic-bot image can use this. Mount the repo's
`bots/` dir read-only and point `BOT_CONFIG_PATH` at that container's active
file (named after the container):

```
-v $(pwd)/bots:/config/bots:ro
-e BOT_CONFIG_PATH=/config/bots/active/<container-name>.env
```

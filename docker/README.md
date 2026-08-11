# Docker daemon config

`daemon.json` is the canonical copy of `/etc/docker/daemon.json`. It is kept here
so the setting is version-controlled and survives a rebuild; nothing reads it
from this directory at runtime.

It caps container logs at 10MB × 3 files each. Docker's `json-file` driver has
**no size limit by default**, and traefik runs with `accessLog: {}` enabled — so
every HTTP request to every public service accumulates on the root filesystem
forever. Setting it at the daemon level rather than per-service means any
container added later inherits the cap without anyone remembering to add it.

To apply:

```bash
sudo cp /opt/homelab/docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

Restarting the daemon restarts every container. Existing log files are not
truncated retroactively — the cap applies as they rotate. To reclaim space from
logs that already grew, recreate the container (`docker compose up -d --force-recreate <service>`)
or truncate the file under `/var/lib/docker/containers/<id>/`.

`live-restore: true` keeps containers running while the Docker daemon itself restarts (e.g.
for a Docker engine upgrade) instead of stopping everything with it — one less interruption
on a machine nobody is watching. This only affects containers created *after* the daemon
restart; existing ones need `docker compose up -d --force-recreate` to pick it up.

Check current usage with:

```bash
sudo du -sh /var/lib/docker/containers/*/*-json.log | sort -h | tail
```

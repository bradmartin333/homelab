# SSH hardening

`00-hardening.conf` is the canonical copy of `/etc/ssh/sshd_config.d/00-hardening.conf`. It
is kept here so key-only, no-root access is version-controlled and survives a rebuild;
nothing reads it from this directory at runtime.

Ubuntu reads `/etc/ssh/sshd_config.d/*.conf` before the main config, first value wins, and
the installer leaves a `50-cloud-init.conf` that re-enables password auth. A `00-` prefix
sorts ahead of it and always wins — editing `sshd_config` directly, or a drop-in with a
higher sort order, can silently do nothing.

To apply:

```bash
sudo cp /opt/homelab/ssh/00-hardening.conf /etc/ssh/sshd_config.d/00-hardening.conf
sudo sshd -t && sudo systemctl restart ssh
```

⛔ **Stop and verify before closing your session.** Open a **second** terminal and confirm
key login still works before closing the one you have — if key auth isn't already set up
(`ssh-copy-id`) for every account that needs in, this locks it out with no password
fallback. If the second session fails, fix it from the session you still have.

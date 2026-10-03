# Unattended upgrades

`52homelab-reboot` is the canonical copy of `/etc/apt/apt.conf.d/52homelab-reboot`. It is
kept here so the auto-reboot policy is version-controlled and survives a rebuild; nothing
reads it from this directory at runtime.

Kernel and library security patches need a reboot to actually take effect, and nobody is
physically at the machine to do it. This sets the three reboot directives; everything else
about unattended upgrades — most importantly `Unattended-Upgrade::Allowed-Origins`, which
decides what gets installed at all — stays in the `50unattended-upgrades` that
`dpkg-reconfigure --priority=low unattended-upgrades` generates.

⛔ **Never copy this over `50unattended-upgrades`.** apt reads every file in `apt.conf.d`
in name order and later assignments win, which is why a separate `52` file works. Replacing
the generated `50` file with these few lines deletes its `Allowed-Origins` block, and with
no allowed origins `unattended-upgrades` installs nothing — while still running nightly,
still logging, and still rebooting. Nothing errors; patches just stop. That is the failure
this directory exists to prevent, so it is worth the extra file.

`07:30` comes after the patches it exists to apply. `unattended-upgrade` runs from the
stock `apt-daily-upgrade.timer` (06:00 plus up to 60 minutes of random delay) and schedules
the reboot for the *next* occurrence of this time — so any time before 07:00, including the
old 04:30, delayed every patch reboot by a day. It also clears `homelab-backup.timer`
(nightly ~03:00, longest on the 1st) and watchtower (05:00). A reboot landing mid-backup
would kill it partway through.

To apply:

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
sudo cp /opt/homelab/apt/52homelab-reboot /etc/apt/apt.conf.d/52homelab-reboot
```

The filename has no extension, which is one of the two forms apt reads (the other is
`.conf`) — renaming it to something with a dot in it makes apt ignore the file silently.

Verify both halves are in effect:

```bash
apt-config dump | grep -iE 'Allowed-Origins|Automatic-Reboot'
```

That reads the merged configuration, so it answers the question the two files answer
together rather than either one alone.

No service restart needed — `unattended-upgrades` reads this fresh on its next scheduled
run.

## If the directives are already in `50unattended-upgrades`

They were, on this box, until 2026-09-22: set in place inside the generated file rather
than dropped in beside it. Leaving them there is harmless — same values, and `52` wins
either way — but they are not version-controlled and a future `dpkg-reconfigure` can
rewrite them. Comment them out in `50unattended-upgrades` once this drop-in is installed
and verified, so there is one place the policy lives.

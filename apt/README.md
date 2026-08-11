# Unattended upgrades

`50unattended-upgrades` is the canonical copy of `/etc/apt/apt.conf.d/50unattended-upgrades`.
It is kept here so the auto-reboot policy is version-controlled and survives a rebuild;
nothing reads it from this directory at runtime.

Kernel and library security patches need a reboot to actually take effect, and nobody is
physically at the machine to do it. This appends the reboot directives onto the file
`dpkg-reconfigure --priority=low unattended-upgrades` generates — it does not replace the
package's own defaults above them.

`04:30` is deliberately clear of every other scheduled job — see `homelab-backup.timer`
(nightly ~03:00) and the stock Ubuntu `apt-daily-upgrade.timer`/`fstrim.timer` windows. A
reboot landing mid-backup would kill it partway through.

To apply:

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
sudo cp /opt/homelab/apt/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
```

No service restart needed — `unattended-upgrades` reads this file fresh on its next
scheduled run.

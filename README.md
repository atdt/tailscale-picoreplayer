# Tailscale for piCorePlayer

Packages and installs the current release of Tailscale as a piCore extension.
Run it as `tc` on your piCorePlayer:

```sh
wget https://raw.githubusercontent.com/atdt/tailscale-picoreplayer/main/mktailscale.tcz.sh
chmod +x mktailscale.tcz.sh
./mktailscale.tcz.sh
```

On a fresh install, load the extension and authenticate:

```sh
tce-load -i tailscale
sudo tailscale up
```

To upgrade later, re-run the script and then `sudo reboot`.

## What it does

* Downloads and SHA256-verifies the current stable release for your
  architecture.
* Builds `tailscale.tcz` and sets it to load at boot.
* Starts `tailscaled` when the extension loads.
* Keeps the node identity on the pCP data partition, so it survives reboots.

The daemon runs `--tun=tailscale0`, so the tunnel is a real interface and the
node can act as a subnet router or exit node.

## Migrating from an earlier setup

The build script carries an existing node identity over on first run, from
either `tailscale_state` on the data partition (where mll's script kept it) or
`/var/lib/tailscale` (where the forum recipe did), so you keep the same tailnet
IP without re-authenticating. This also gets your node's private key out of the
`.tcz`, where the forum recipe left it alongside a state file the daemon could
never write.

The extension starts itself, so remove whatever used to start it or the daemon
will run twice: the pCP user commands under Tweaks &rarr; User commands, and any
`tailscaled` lines in `/opt/bootlocal.sh`. Then run `pcp bu`.

## Acknowledgements

This started from the [piCorePlayer forum thread][thread]. Checksum verification
and keeping state out of the pCP backup are taken from mll's
[`install_update_Tailscale.sh`][mll]; wetenschaap proposed `--tun=tailscale0` in
place of userspace networking; and paul- of piCorePlayer explained the tun
driver behaviour and how third-party binaries ought to be packaged.

[thread]: https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer
[mll]: https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer/page4

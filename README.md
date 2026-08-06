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

The extension carries a copy of the script as `tailscale-installer`, so upgrading
later needs nothing kept or fetched:

```sh
tailscale-installer
sudo reboot
```

That copy is frozen at the version that built the extension. Re-download the
script from here to pick up any changes since.

The current stable release is the default. To build a different one, or if the
script can no longer work out which that is, name it:

```sh
TAILSCALE_VERSION=1.102.1 ./mktailscale.tcz.sh
```

<https://pkgs.tailscale.com/stable/> lists the current version, and serves
`tailscale_latest_<arch>.tgz` as a redirect to it.

## What it does

* Downloads the current stable release for your architecture.
* Builds `tailscale.tcz` and sets it to load at boot.
* Puts a copy of itself in the extension, as `tailscale-installer`.
* Starts `tailscaled` when the extension loads.
* Keeps the node identity on the pCP data partition, so it survives reboots.
* Can act as a subnet router or exit node.
* Survives pCP in-situ upgrades, including kernel changes.

## Coming from a manual install

Several recipes for installing Tailscale circulated on the piCorePlayer forum
before this package existed. If you followed one of them, the script picks your
node identity up from wherever that recipe left it, so you keep the same tailnet
IP without re-authenticating.

The extension starts itself, so remove whatever used to start it or the daemon
will run twice: the pCP user commands under Tweaks &rarr; User commands, and any
`tailscaled` lines in `/opt/bootlocal.sh`. Then run `pcp bu`.

## Packaging the script as an extension

The build script can itself be shipped as an extension, so that loading it from a
repository puts `tailscale-installer` on the system and nobody has to download a
script by hand. `mktailscale-installer.tcz.sh` builds that, writing
`tailscale-installer.tcz` alongside the `.info`, `.list` and `.md5.txt` a piCore
repository expects. Run it as `tc` on a piCorePlayer:

```sh
./mktailscale-installer.tcz.sh
```

## Acknowledgements

This started from the [piCorePlayer forum thread][thread]. Checksum verification
and keeping state out of the pCP backup are taken from mll's
[`install_update_Tailscale.sh`][mll]. Using `--tun=tailscale0` in place of
userspace networking was wetenschaap's suggestion. The tun driver behaviour and
how third-party binaries ought to be packaged were explained by paul- of
piCorePlayer.

[thread]: https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer
[mll]: https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer/page4

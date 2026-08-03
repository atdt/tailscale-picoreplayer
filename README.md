# Tailscale for piCorePlayer

Builds an up-to-date Tailscale `.tcz` extension on the device and installs it.

```sh
./mktailscale.tcz.sh
```

Run it as `tc`, not with `sudo` — `tce-load` refuses to run as root, and the few
steps that need privilege call `sudo` themselves.

On a new node, load the extension and authenticate. No reboot needed, and
nothing prompts you for this — the daemon starts unauthenticated and sits idle
until you run:

```sh
tce-load -i tailscale
sudo tailscale up
```

Re-run the script any time to upgrade. Upgrades do need a `sudo reboot`, since a
mounted extension cannot be replaced in place.

## What it does

* Downloads the current stable release for the detected architecture and
  verifies the SHA256 published by Tailscale before installing anything.
* Packages `tailscale`, `tailscaled` and an init script into `tailscale.tcz`,
  with `.dep`, `.md5.txt`, `.list` and `.info` sidecars, and adds it to
  `onboot.lst`.
* Starts itself through `/usr/local/tce.installed/tailscale`, the standard Tiny
  Core hook that runs as root when the extension mounts. Nothing needs to be
  added to `bootlocal.sh` or to pCP's user commands.
* Keeps state in `tailscale` on the pCP data partition, symlinked to
  `/var/lib/tailscale`. `tailscaled` writes it directly, so the node identity
  survives a reboot whether or not you have run `pcp bu`.

Everything the script writes lives on the data partition, so no pCP backup is
needed for any of it to persist.

## Why this approach

Compared with the original recipe in the [forum thread][thread] and mll's
`install_update_Tailscale.sh` [posted later in it][mll]:

* **State never goes inside the package.** The recipe builds
  `var/lib/tailscale` into the extension, which leaves `tailscaled.state` a
  read-only symlink into the squashfs: the daemon cannot persist changes, and
  the node's private key ends up in a file meant to be copied around.
* **The package starts itself.** Both alternatives need something outside it —
  pCP user commands, or lines appended to `bootlocal.sh`. `tce.installed` is the
  Tiny Core hook meant for this, so there is no user-side configuration to get
  wrong, and nothing to undo if you remove the extension.
* **The netfilter dependency is declared.** Kernel mode needs modules that ship
  as a kernel-versioned extension; `.dep` loads it automatically, and the init
  script degrades to userspace if a kernel update ever breaks the pin.
* **It follows piCore packaging conventions** — 4k blocks, `-no-xattrs`,
  root-owned contents, a `/usr/local` prefix and the full sidecar set, which is
  what the repo expects if the package is ever hosted there.
* **It changes no configuration.** Nothing is written to `bootlocal.sh`,
  `pcp.cfg` or the backup, so there is nothing to undo and no `pcp bu` to
  remember.

Verifying the checksum and keeping state out of the backup are both good ideas
taken from mll's script. wetenschaap first proposed `--tun=tailscale0` in place
of userspace networking, and paul- of piCorePlayer explained the tun driver
behaviour and how third-party binaries ought to be packaged.

## Kernel networking

The daemon runs `--tun=tailscale0` so the tunnel is a real interface and the
node can act as a subnet router or exit node. `tailscaled` programs netfilter
over netlink, so it needs the kernel modules but no `iptables` or `iproute2`
userland; `tailscale.tcz.dep` pulls in `ipv6-netfilter-<kernel>.tcz` alone.

Because that dependency is pinned to the running kernel, a pCP update that
changes the kernel will leave it unresolvable. The init script checks for `tun`
and `nf_tables` at start and falls back to `--tun=userspace-networking` rather
than failing to come up, so an update degrades connectivity instead of removing
it. Re-run the build script after a kernel update to repin the dependency.

One non-obvious detail: `ipv6` is a module, and `tailscaled` only loads it later
via its own netfilter setup. The init script modprobes it before setting
`net.ipv6.conf.all.forwarding`, which otherwise silently stays off and Tailscale
reports "Subnet routing is enabled, but IP forwarding is disabled".

## Migrating from an earlier setup

The build script carries an existing node identity over on first run, from
either `tailscale_state` on the data partition (where mll's script kept it) or
`/var/lib/tailscale` (where the forum recipe did), so you keep the same tailnet
IP without re-authenticating. It copies rather than moves, leaving the old
directory alone.

The extension starts itself now, so remove whatever used to start it or the
daemon will run twice: the pCP user commands under Tweaks &rarr; User commands,
and any `tailscaled` lines in `/opt/bootlocal.sh`. Both live in the pCP backup,
so run `pcp bu` afterwards.

[thread]: https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer
[mll]: https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer/page4

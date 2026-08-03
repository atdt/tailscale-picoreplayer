# Tailscale for piCorePlayer

Builds an up-to-date Tailscale `.tcz` extension on the device and installs it.
Re-run it any time to upgrade.

```sh
./mktailscale.tcz.sh
sudo reboot
```

Run it as `tc`, not with `sudo` — `tce-load` refuses to run as root, and the few
steps that need privilege call `sudo` themselves.

On a new node, authenticate once after the reboot:

```sh
sudo tailscale up
```

## What it does

* Downloads the current stable release for the detected architecture and
  verifies the SHA256 published by Tailscale before installing anything.
* Packages `tailscale`, `tailscaled` and an init script into `tailscale.tcz`,
  with `.dep`, `.md5.txt`, `.list` and `.info` sidecars, and adds it to
  `onboot.lst`.
* Starts itself through `/usr/local/tce.installed/tailscale`, the standard Tiny
  Core hook that runs as root when the extension mounts. Nothing needs to be
  added to `bootlocal.sh` or to pCP's user commands.
* Keeps state in `tailscale_state` on the pCP data partition, symlinked to
  `/var/lib/tailscale`. `tailscaled` writes it directly, so the node identity
  survives a reboot whether or not you have run `pcp bu`.

Everything the script writes lives on the data partition, so no pCP backup is
needed for any of it to persist.

## Licensing

Tailscale is BSD-3-Clause, which requires binary redistributions to reproduce
the copyright notice and disclaimer. The official tarball ships no license file,
so the build script fetches it from the matching release tag and installs it to
`/usr/local/share/tailscale/LICENSE`. That matters if the package is ever shared
rather than just built locally. For the statically linked Go dependencies, run
`tailscale licenses`.

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

## Migrating from the forum recipe

If you previously followed the [forum
thread](https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer),
the build script copies your existing node identity out of `/var/lib/tailscale`
the first time it runs, so you keep the same tailnet IP and do not have to
re-authenticate. That recipe created the state directory *inside* the package,
which left `tailscaled.state` as a read-only symlink into the squashfs and put
the node's private key in a shareable file. The rebuilt package contains only
the binaries and scripts.

The extension now starts itself, so remove whatever used to start it or the
daemon will run twice:

* pCP user commands — Tweaks &rarr; User commands in the web UI, blanking the
  `tailscaled` and `modprobe tun` entries.
* Any `tailscaled` lines added to `/opt/bootlocal.sh`. Note that anything below
  the `#pCPstop------` marker never ran anyway: `pcp_startup.sh` pipes into
  `tee`, the daemons it spawns hold the pipe open, and the pipeline never
  returns.

Both live in the pCP backup, so run `pcp bu` afterwards.

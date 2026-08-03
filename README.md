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

Tailscale is BSD-3-Clause, whose second clause requires binary redistributions
to reproduce the copyright notice and disclaimer. The official tarball ships no
license file, so the build script fetches it from the matching release tag and
installs it to `/usr/local/share/tailscale/LICENSE`. That matters if the package
is ever shared rather than just built locally.

The binaries statically link a large number of third-party Go packages. Run
`tailscale licenses`, or see <https://tailscale.com/licenses/tailscale>.

## Kernel networking

The daemon runs `--tun=tailscale0` so the tunnel is a real interface and the
node can act as a subnet router or exit node. That needs netfilter, which on
piCore lives in a kernel-versioned extension, so `tailscale.tcz.dep` pulls in:

```
ipv6-netfilter-<kernel>.tcz
iptables.tcz
iproute2.tcz
```

Because that dependency is pinned to the running kernel, a pCP update that
changes the kernel will leave it unresolvable. The init script checks for `tun`
and `ip_tables` at start and falls back to `--tun=userspace-networking` rather
than failing to come up, so an update degrades connectivity instead of removing
it. Re-run the build script after a kernel update to repin the dependency.

Two things that are easy to get wrong here:

* `iptables` and `ip` install to `/usr/local/sbin`, which piCore leaves out of
  the default `PATH`. `tailscaled` execs them, so the init script sets `PATH`
  explicitly. Without it the daemon comes up with no firewall rules and peers
  are unreachable.
* `ipv6` is a module, and `tailscaled` only loads it later via
  `ip6table_mangle`. The init script modprobes it before setting
  `net.ipv6.conf.all.forwarding`, which otherwise silently stays off and
  Tailscale reports "Subnet routing is enabled, but IP forwarding is disabled".

## Migrating from the forum recipe

If you previously followed the [forum
thread](https://forums.lyrion.org/forum/user-forums/linux-unix/1722251-tailscale-on-picoreplayer),
the build script copies your existing node identity out of `/var/lib/tailscale`
the first time it runs, so you keep the same tailnet IP and do not have to
re-authenticate. That earlier recipe created the state directory *inside* the
package, which left `tailscaled.state` as a read-only symlink into the squashfs
and put your node's private key in a shareable file — the rebuilt package
contains only the binaries and scripts.

The script deliberately does not touch your configuration. Clean up the old
startup path yourself, or the daemon will be started twice:

```sh
# 1. Clear the pCP user commands that started tailscaled.
#    Web UI: Tweaks -> User commands, blank the tailscaled and 'modprobe tun'
#    entries. Or edit /usr/local/etc/pcp/pcp.cfg directly.

# 2. Remove any tailscaled lines you added to /opt/bootlocal.sh.
#    Note that anything below the #pCPstop------ marker never runs anyway:
#    pcp_startup.sh pipes into tee, the daemons it spawns keep the pipe open,
#    and the pipeline never returns.

# 3. The daemon runs as root now, so an earlier dedicated user is unused.
sudo deluser tailscale
sudo delgroup tailscale

# 4. Those all live in the pCP backup, so persist the changes.
pcp bu
```

The migration copies the identity rather than moving it, so the original is left
untouched under `/var/lib/tailscale` until the next reboot replaces it. Confirm
the node still works before clearing out any older copies of your own.

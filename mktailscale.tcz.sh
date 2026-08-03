#!/bin/sh
# Build and install a Tailscale .tcz extension for piCorePlayer.
# Re-run at any time to upgrade to the current stable release.
#
#   ./mktailscale.tcz.sh && sudo reboot
#
# Run as tc, not with sudo: tce-load refuses to run as root. The few steps that
# need privilege call sudo themselves.
set -e

[ "$(id -u)" != 0 ] || { echo "run as tc, not root: tce-load refuses to run as root" >&2; exit 1; }

INITD=$(dirname "$0")/tailscaled
[ -f "$INITD" ] || { echo "missing init script: $INITD" >&2; exit 1; }

case "$(uname -m)" in
    aarch64)       ARCH=arm64 ;;
    armv7l|armv6l) ARCH=arm   ;;
    x86_64)        ARCH=amd64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

TCEDIR=$(readlink -f /etc/sysconfig/tcedir)
P2=$(dirname "$TCEDIR")
STATEDIR=$P2/tailscale_state
KERNEL=$(uname -r)
# $P2 itself is root-owned; the tce directory below it belongs to tc.
WORK=$TCEDIR/tailscale-build

# The state used to be baked into the .tcz by the original forum recipe, which
# left tailscaled.state as a read-only symlink into the squashfs. Copy it out
# (dereferencing) before the old extension is replaced, or the node identity is
# lost and you have to re-authenticate.
# These paths are root-owned and mode 0700, so test them through sudo: as tc the
# checks would come back false and clobber good state with a stale copy.
if ! sudo test -f "$STATEDIR/tailscaled.state" && sudo test -e /var/lib/tailscale/tailscaled.state; then
    echo "Migrating existing node identity out of /var/lib/tailscale"
    sudo install -d -m 0700 "$STATEDIR"
    sudo cp -rL /var/lib/tailscale/. "$STATEDIR/"
fi

# -l loads without adding to onboot.lst; squashfs-tools is only needed to build.
command -v mksquashfs >/dev/null || tce-load -wil squashfs-tools

TGZ=$(wget -qO- 'https://pkgs.tailscale.com/stable/?mode=json' |
      grep -o "tailscale_[0-9.]*_$ARCH\.tgz" | head -n1)
[ -n "$TGZ" ] || { echo "could not determine the latest version" >&2; exit 1; }
VERSION=${TGZ#tailscale_}
VERSION=${VERSION%_$ARCH.tgz}
echo "Building Tailscale $VERSION ($ARCH)"

rm -rf "$WORK"
mkdir -p "$WORK/pkg/usr/local/bin" "$WORK/pkg/usr/local/etc/init.d" \
         "$WORK/pkg/usr/local/tce.installed" "$WORK/pkg/usr/local/share/tailscale"
cd "$WORK"

wget -q "https://pkgs.tailscale.com/stable/$TGZ"
wget -q "https://pkgs.tailscale.com/stable/$TGZ.sha256"
# Tailscale publishes a bare hash, not the "hash  filename" sha256sum -c expects.
echo "$(cat "$TGZ.sha256")  $TGZ" | sha256sum -c -

tar xzf "$TGZ"
cp "tailscale_${VERSION}_${ARCH}/tailscale" \
   "tailscale_${VERSION}_${ARCH}/tailscaled" pkg/usr/local/bin/
install -m 0755 "$INITD" pkg/usr/local/etc/init.d/tailscaled

# BSD-3-Clause clause 2 requires binary redistributions to reproduce the
# copyright notice and disclaimer. Tailscale's own tarball omits it, which is
# their prerogative as the copyright holder but not ours as a repackager. Pin it
# to the release tag so the text always matches the binaries beside it.
wget -q -O pkg/usr/local/share/tailscale/LICENSE \
    "https://raw.githubusercontent.com/tailscale/tailscale/v$VERSION/LICENSE"
[ -s pkg/usr/local/share/tailscale/LICENSE ] || { echo "could not fetch LICENSE" >&2; exit 1; }

# tce-load runs this as root the moment the extension mounts, so the package
# starts itself with no user-side configuration. This is the documented Tiny Core
# hook; bootlocal.sh and pCP user commands are the user's to control, not ours.
cat > pkg/usr/local/tce.installed/tailscale <<'EOF'
#!/bin/sh
/usr/local/etc/init.d/tailscaled start
EOF
chmod 0775 pkg/usr/local/tce.installed/tailscale

# -b 4k -no-xattrs matches what the stock piCore extensions are built with.
# -all-root keeps the packaged files root-owned even though tc runs the build.
mksquashfs pkg tailscale.tcz -b 4k -no-xattrs -all-root -noappend >/dev/null

install -m 0644 tailscale.tcz "$TCEDIR/optional/tailscale.tcz"
md5sum tailscale.tcz > "$TCEDIR/optional/tailscale.tcz.md5.txt"
( cd pkg && find usr -not -type d ) > "$TCEDIR/optional/tailscale.tcz.list"

cat > "$TCEDIR/optional/tailscale.tcz.info" <<EOF
Title:          tailscale.tcz
Description:    Tailscale mesh VPN (WireGuard-based)
Version:        $VERSION
Author:         Tailscale Inc.
Original-site:  https://tailscale.com/
Copying-policy: BSD-3-Clause
Size:           $(du -h tailscale.tcz | cut -f1)
Extension_by:   built on-device by mktailscale.tcz.sh
Tags:           vpn network wireguard mesh
Comments:       Repackaged from the official static binaries.

                License: /usr/local/share/tailscale/LICENSE
                The binaries statically link many third-party Go packages;
                see https://tailscale.com/licenses/tailscale for that list,
                or run 'tailscale licenses'.

                Starts itself via /usr/local/tce.installed/tailscale.
                State is kept in tailscale_state on the pCP data partition so
                the node identity survives a reboot without a pCP backup.

                Run 'tailscale up' once to authenticate the node.
Change-log:     ----
Current:        $(date +%Y/%m/%d) Built for kernel $KERNEL
EOF

# Kernel mode needs the netfilter modules built for this exact kernel.
cat > "$TCEDIR/optional/tailscale.tcz.dep" <<EOF
ipv6-netfilter-$KERNEL.tcz
iptables.tcz
iproute2.tcz
EOF
# Fetch them now so the first boot after this does not need the network. -w only
# downloads; tce-load pulls them in from the .dep file at boot.
tce-load -w "ipv6-netfilter-$KERNEL" iptables iproute2 >/dev/null

ONBOOT=$TCEDIR/onboot.lst
grep -qx 'tailscale.tcz' "$ONBOOT" || echo 'tailscale.tcz' >> "$ONBOOT"

cd /
rm -rf "$WORK"

# Everything written above lives on the pCP data partition, so no pcp backup is
# needed for any of it to survive a reboot.
echo "Installed Tailscale $VERSION. Reboot to apply: sudo reboot"
if ! sudo test -f "$STATEDIR/tailscaled.state"; then
    echo "No node identity yet. After the reboot, run: sudo tailscale up"
fi

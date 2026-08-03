#!/bin/sh
# Build and install a Tailscale .tcz extension for piCorePlayer.
# Re-run to upgrade. Run as tc: tce-load refuses to run as root.
#
#   ./mktailscale.tcz.sh && sudo reboot
set -e

[ "$(id -u)" != 0 ] || { echo "run as tc, not root" >&2; exit 1; }

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
STATEDIR=$P2/tailscale
KERNEL=$(uname -r)
WORK=$TCEDIR/tailscale-build   # the partition root is root-owned; this is not

# Earlier layouts to carry an identity over from, live copy first: mll's
# maintenance script used tailscale_state, and the forum recipe kept state
# inside the .tcz, where tailscaled.state is a read-only symlink into the
# squashfs that goes away with the old package. Tested through sudo because as
# tc these checks come back false and would overwrite good state.
if ! sudo test -f "$STATEDIR/tailscaled.state"; then
    for old in "$P2/tailscale_state" /var/lib/tailscale; do
        sudo test -e "$old/tailscaled.state" || continue
        echo "Migrating existing node identity out of $old"
        sudo install -d -m 0700 "$STATEDIR"
        sudo cp -rL "$old/." "$STATEDIR/"
        break
    done
fi

# -l loads without adding to onboot.lst; this is only needed to build.
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

# BSD-3-Clause requires binary redistributions to carry the notice; the upstream
# tarball has no license file. Pinned to the tag so it matches these binaries.
wget -q -O pkg/usr/local/share/tailscale/LICENSE \
    "https://raw.githubusercontent.com/tailscale/tailscale/v$VERSION/LICENSE"

# tce-load runs this as root when the extension mounts.
cat > pkg/usr/local/tce.installed/tailscale <<'EOF'
#!/bin/sh
/usr/local/etc/init.d/tailscaled start
EOF
chmod 0775 pkg/usr/local/tce.installed/tailscale

# Matches how the stock piCore extensions are built; -all-root because tc builds.
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
                Starts itself via /usr/local/tce.installed/tailscale.
                Run 'tailscale up' once to authenticate the node.

                License: /usr/local/share/tailscale/LICENSE
                Third-party licenses: 'tailscale licenses'
Current:        $(date +%Y/%m/%d) Built for kernel $KERNEL
EOF

# tailscaled programs netfilter over netlink, so it needs the kernel modules but
# no iptables or iproute2 userland. These are tied to the running kernel.
echo "ipv6-netfilter-$KERNEL.tcz" > "$TCEDIR/optional/tailscale.tcz.dep"
tce-load -w "ipv6-netfilter-$KERNEL" >/dev/null

ONBOOT=$TCEDIR/onboot.lst
grep -qx 'tailscale.tcz' "$ONBOOT" || echo 'tailscale.tcz' >> "$ONBOOT"

cd /
rm -rf "$WORK"

echo "Installed Tailscale $VERSION. Reboot to apply: sudo reboot"
if ! sudo test -f "$STATEDIR/tailscaled.state"; then
    echo "No node identity yet. After the reboot, run: sudo tailscale up"
fi

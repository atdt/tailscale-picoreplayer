#!/bin/sh
# Build and install a Tailscale .tcz extension for piCorePlayer.
# Re-run to upgrade, or --force to reinstall the current version.
set -e

[ "$(id -u)" != 0 ] || { echo "run as tc, not root" >&2; exit 1; }

case "$(uname -m)" in
    aarch64)       ARCH=arm64 ;;
    armv7l|armv6l) ARCH=arm   ;;
    x86_64)        ARCH=amd64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

SELF=$(readlink -f "$0")
TCEDIR=$(readlink -f /etc/sysconfig/tcedir)
P2=$(dirname "$TCEDIR")
STATEDIR=$P2/tailscale
WORK=$TCEDIR/tailscale-build   # the partition root is root-owned; this is not

# If we find Tailscale state in a legacy location, migrate it so the node
# retains its identity.
if ! sudo test -f "$STATEDIR/tailscaled.state"; then
    for old in "$P2/tailscale_state" /var/lib/tailscale; do
        sudo test -e "$old/tailscaled.state" || continue
        echo "Migrating existing node identity out of $old"
        sudo install -d -m 0700 "$STATEDIR"
        sudo cp -rL "$old/." "$STATEDIR/"
        break
    done
fi

# Set TAILSCALE_VERSION to build a particular release, which also gets you past
# a change to how the current one is published.
VERSION=$TAILSCALE_VERSION
if [ -z "$VERSION" ]; then
    VERSION=$(wget -qO- 'https://pkgs.tailscale.com/stable/?mode=json' |
              sed -n "s/.*tailscale_\([0-9.]*\)_$ARCH\.tgz.*/\1/p" | head -n1)
    [ -n "$VERSION" ] || { echo "could not determine the latest version" >&2; exit 1; }
    # Nested, so that naming a version builds it whether or not it is installed.
    if [ "$1" != --force ] && [ "$(tailscale version 2>/dev/null | head -n1)" = "$VERSION" ]; then
        echo "Tailscale $VERSION is already the latest. Re-run with --force to reinstall."
        exit 0
    fi
fi
TGZ=tailscale_${VERSION}_$ARCH.tgz
echo "Building Tailscale $VERSION ($ARCH)"

# Only needed for the build, so -l loads it without adding to onboot.lst.
command -v mksquashfs >/dev/null || tce-load -wil squashfs-tools

rm -rf "$WORK"
mkdir -p "$WORK/pkg/usr/local/bin" "$WORK/pkg/usr/local/etc/init.d" \
         "$WORK/pkg/usr/local/tce.installed" "$WORK/pkg/usr/local/share/tailscale"
cd "$WORK"

wget -q "https://pkgs.tailscale.com/stable/$TGZ"
wget -q "https://pkgs.tailscale.com/stable/$TGZ.sha256"
# Tailscale publishes a bare hash, not the "hash  filename" sha256sum -c expects.
echo "$(awk '{print $1}' "$TGZ.sha256")  $TGZ" | sha256sum -c -

tar xzf "$TGZ"
cp "tailscale_${VERSION}_${ARCH}/tailscale" \
   "tailscale_${VERSION}_${ARCH}/tailscaled" pkg/usr/local/bin/

# Upgrades need this script, and /home/tc does not survive a reboot.
install -m 0755 "$SELF" pkg/usr/local/bin/tailscale-installer

# BSD-3-Clause requires binary redistributions to carry the notice, but the
# upstream tarball has no license file.
wget -q -O pkg/usr/local/share/tailscale/LICENSE \
    "https://raw.githubusercontent.com/tailscale/tailscale/v$VERSION/LICENSE"

cat > pkg/usr/local/etc/init.d/tailscaled <<'INIT'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          tailscaled
# Required-Start:    $local_fs $network $syslog
# Required-Stop:     $local_fs $network $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: tailscaled daemon
# Description:       tailscaled daemon
### END INIT INFO

DAEMON=/usr/local/bin/tailscaled
PIDFILE=/var/run/tailscaled.pid

# State on the data partition, so the node identity survives a reboot whether or
# not a pCP backup has been taken.
STATEDIR=$(dirname "$(readlink -f /etc/sysconfig/tcedir)")/tailscale

test -x "$DAEMON" || exit 0

case "$1" in
  start)
    echo "Starting tailscaled"
    install -d -m 0700 "$STATEDIR"
    [ -e /var/lib/tailscale ] || ln -s "$STATEDIR" /var/lib/tailscale

    # The netfilter modules come from a separate extension that has to match the
    # running kernel. Degrade to userspace rather than fail to come up.
    if modprobe tun 2>/dev/null && modprobe nf_tables 2>/dev/null; then
        TUN=tailscale0
        # tailscaled pulls in ipv6 itself, but too late for this sysctl.
        modprobe ipv6 2>/dev/null
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    else
        TUN=userspace-networking
        echo "tun/netfilter unavailable, using userspace networking"
    fi

    start-stop-daemon --start --background --pidfile "$PIDFILE" --make-pidfile \
        --startas "$DAEMON" -- \
        --statedir="$STATEDIR" --tun="$TUN" --no-logs-no-support
    ;;
  stop)
    echo "Stopping tailscaled"
    start-stop-daemon --stop --pidfile "$PIDFILE" --retry 10 &&
        rm -f "$PIDFILE"
    ;;
  restart)
    "$0" stop
    sleep 2
    "$0" start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac
exit 0
INIT
chmod 0755 pkg/usr/local/etc/init.d/tailscaled

# tce-load runs this as root when the extension mounts.
cat > pkg/usr/local/tce.installed/tailscale <<'EOF'
#!/bin/sh
/usr/local/etc/init.d/tailscaled start
EOF
chmod 0755 pkg/usr/local/tce.installed/tailscale

# Matches how the stock piCore extensions are built; -all-root because the
# build runs as tc rather than root.
mksquashfs pkg tailscale.tcz -b 4k -no-xattrs -all-root -noappend >/dev/null

# The loaded extension is loop-mounted from this file, so it cannot be replaced
# in place. tce-setup moves anything staged in optional/upgrade into optional/
# early on the next boot.
if [ -f /usr/local/tce.installed/tailscale ]; then
    DEST=$TCEDIR/optional/upgrade
    mkdir -p "$DEST"
else
    DEST=$TCEDIR/optional
fi

install -m 0644 tailscale.tcz "$DEST/tailscale.tcz"
md5sum tailscale.tcz > "$DEST/tailscale.tcz.md5.txt"
( cd pkg && find usr -not -type d ) > "$DEST/tailscale.tcz.list"

cat > "$DEST/tailscale.tcz.info" <<EOF
Title:          tailscale.tcz
Description:    Tailscale mesh VPN (WireGuard-based)
Version:        $VERSION
Author:         Tailscale Inc.
Original-site:  https://tailscale.com/
Copying-policy: BSD-3-Clause
Size:           $(du -h tailscale.tcz | cut -f1)
Extension_by:   atdt
Tags:           VPN NETWORK SECURITY CLI
Comments:       Repackaged from the official static binaries.
                Starts itself via /usr/local/tce.installed/tailscale.
                Run 'tailscale up' once to authenticate the node.
                Run 'tailscale-installer' to upgrade.

                License: /usr/local/share/tailscale/LICENSE
                Third-party licenses: 'tailscale licenses'
Current:        $(date +%Y/%m/%d) Tailscale $VERSION
EOF

# tce-load expands KERNEL to the running version.
echo 'ipv6-netfilter-KERNEL.tcz' > "$DEST/tailscale.tcz.dep"
tce-load -w ipv6-netfilter-KERNEL.tcz >/dev/null

ONBOOT=$TCEDIR/onboot.lst
grep -qx 'tailscale.tcz' "$ONBOOT" || echo 'tailscale.tcz' >> "$ONBOOT"

cd /
rm -rf "$WORK"

echo "Installed Tailscale $VERSION."
if [ "$DEST" = "$TCEDIR/optional" ]; then
    echo
    echo "Load it and authenticate the node:"
    echo "    tce-load -i tailscale"
    echo "    sudo tailscale up"
    echo
    echo "To upgrade later, run tailscale-installer."
else
    echo
    echo "Reboot to apply it:"
    echo "    sudo reboot"
fi

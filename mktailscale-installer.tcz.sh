#!/bin/sh
# Build tailscale-installer.tcz, the extension that carries the build script.
# Run as tc on a piCorePlayer. The .tcz and its metadata land in the current
# directory.
set -e

[ "$(id -u)" != 0 ] || { echo "run as tc, not root" >&2; exit 1; }

VERSION=1.0
NAME=tailscale-installer
SRC=$(dirname "$(readlink -f "$0")")/mktailscale.tcz.sh
OUT=$PWD

# Only needed for the build, so -l loads it without adding to onboot.lst.
command -v mksquashfs >/dev/null || tce-load -wil squashfs-tools

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

install -D -m 0755 "$SRC" "$WORK/pkg/usr/local/bin/$NAME"

# This extension installs a script, not Tailscale. Print the remaining steps
# where the web interface will show them.
install -D -m 0755 /dev/stdin "$WORK/pkg/usr/local/tce.installed/$NAME" <<'EOF'
#!/bin/sh
[ -f /etc/sysconfig/tcedir/optional/tailscale.tcz ] && exit 0

echo "To install Tailscale, run:"
echo "    tailscale-installer"
echo "    tce-load -i tailscale"
echo "    sudo tailscale up"
EOF

cd "$WORK"
# Matches how the stock piCore extensions are built; -all-root because the
# build runs as tc rather than root.
mksquashfs pkg "$NAME.tcz" -b 4k -no-xattrs -all-root -noappend >/dev/null

install -m 0644 "$NAME.tcz" "$OUT/$NAME.tcz"
md5sum "$NAME.tcz" > "$OUT/$NAME.tcz.md5.txt"
( cd pkg && find usr -not -type d ) > "$OUT/$NAME.tcz.list"

cat > "$OUT/$NAME.tcz.info" <<EOF
Title:          $NAME.tcz
Description:    Builds and installs Tailscale as a piCore extension.
Version:        $VERSION
Author:         Ori Livneh
Original-site:  https://github.com/atdt/tailscale-picoreplayer
Copying-policy: BSD-3-Clause
Size:           $(du -h "$NAME.tcz" | cut -f1)
Extension_by:   atdt
Tags:           VPN NETWORK SECURITY CLI tailscale installer
Comments:       Tailscale is a mesh VPN built on WireGuard. This extension
                downloads the current stable release for this machine's
                architecture and packages it as tailscale.tcz.

                Run it as tc, not root:
                  tailscale-installer
                  tce-load -i tailscale
                  sudo tailscale up

                Re-run tailscale-installer to upgrade, then reboot. A mounted
                extension cannot be swapped in place.

                The node identity is kept on the data partition, outside the
                pCP backup, so it survives reboots whether or not a backup has
                been taken, and survives in-situ pCP updates. An identity from
                an earlier hand-rolled setup is carried over on first run.

                tailscaled starts itself when tailscale.tcz loads. Clear
                anything that used to start it, under Tweaks or in
                /opt/bootlocal.sh, or the daemon runs twice.
Change-log:     $(date +%Y/%m/%d) Original
Current:        $(date +%Y/%m/%d) Original
EOF

echo "Built $OUT/$NAME.tcz"

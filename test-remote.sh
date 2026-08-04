#!/bin/sh
# Smoke-test the extensions on a remote piCorePlayer.
#
# Usage: ./test-remote.sh [--run-installer | --reinstall [--yes]] [user@host]
# The host defaults to tc@picoreplayer.local.
#
# Modes:
#   - default: build and open tailscale-installer.tcz.
#   - --run-installer: run it and check the resulting Tailscale binary.
#   - --reinstall: remove Tailscale and reboot to test a clean install.
#
# The reinstall test preserves node identity and requires a LAN address. It asks
# for confirmation unless --yes is set and leaves recovery files on failure.
set -u

DEFAULT_HOST=tc@picoreplayer.local
SCRIPT_DIR=$(CDPATH='' cd -P "$(dirname "$0")" && pwd) || exit 1

usage() {
    STATUS=${1-2}
    if [ "$STATUS" -eq 0 ]; then
        echo "usage: $0 [--run-installer | --reinstall [--yes]] [user@host]"
    else
        echo "usage: $0 [--run-installer | --reinstall [--yes]] [user@host]" >&2
    fi
    exit "$STATUS"
}

ok() {
    echo "[OK] $1"
}

fail() {
    echo "[FAIL] $1" >&2
}

watch_phase() {
    PHASE=$1
    trap 'LAST_STATUS=$?; if [ "$LAST_STATUS" -ne 0 ]; then fail "$PHASE failed (exit $LAST_STATUS)."; fi' EXIT
}

remote_tests() {
    RUN_INSTALLER=$1
    watch_phase "Remote package test"
    set -e

    cd "$SCRIPT_DIR" || exit 1

    echo "Building the installer extension..."
    ./mktailscale-installer.tcz.sh
    mkdir installer-root
    unsquashfs -d installer-root -no-progress tailscale-installer.tcz >/dev/null
    test -x installer-root/usr/local/bin/tailscale-installer
    ok "Installer extension builds and opens."

    if [ "$RUN_INSTALLER" = yes ]; then
        echo "Running the packaged installer..."
        installer-root/usr/local/bin/tailscale-installer

        TCEDIR=$(readlink -f /etc/sysconfig/tcedir)
        if [ -f /usr/local/tce.installed/tailscale ]; then
            PACKAGE=$TCEDIR/optional/upgrade/tailscale.tcz
        else
            PACKAGE=$TCEDIR/optional/tailscale.tcz
        fi

        mkdir tailscale-root
        unsquashfs -d tailscale-root -no-progress "$PACKAGE" >/dev/null
        tailscale-root/usr/local/bin/tailscale version
        ok "Tailscale package builds and its binary runs."
    fi
}

reinstall_prepare() {
    watch_phase "Reinstall preparation"
    set -e
    cd "$SCRIPT_DIR" || exit 1

    echo "Building the installer extension..."
    ./mktailscale-installer.tcz.sh

    TCEDIR=$(readlink -f /etc/sysconfig/tcedir)
    mkdir removed-tailscale
    for LOCATION in optional optional/upgrade; do
        DIR=$TCEDIR/$LOCATION
        LABEL=$(echo "$LOCATION" | tr / -)
        for SUFFIX in '' .dep .info .list .md5.txt; do
            if [ -e "$DIR/tailscale.tcz$SUFFIX" ]; then
                mv "$DIR/tailscale.tcz$SUFFIX" \
                    "removed-tailscale/$LABEL-tailscale.tcz$SUFFIX"
            fi
        done
    done
    cp "$TCEDIR/onboot.lst" removed-tailscale/onboot.lst
    sed '/^tailscale\.tcz$/d' "$TCEDIR/onboot.lst" >onboot.lst
    mv onboot.lst "$TCEDIR/onboot.lst"
    ok "Removed the Tailscale extension; node identity was preserved."
}

reinstall() {
    watch_phase "Clean installation"
    set -e
    cd "$SCRIPT_DIR" || exit 1
    TCEDIR=$(readlink -f /etc/sysconfig/tcedir)

    test ! -e /usr/local/bin/tailscale
    test ! -e "$TCEDIR/optional/tailscale.tcz"

    echo "Loading the installer extension..."
    MESSAGE=$(tce-load -ils "$PWD/tailscale-installer.tcz" 2>&1)
    echo "$MESSAGE"
    echo "$MESSAGE" | grep -q 'To install Tailscale, run:'

    echo "Running its packaged installer..."
    tailscale-installer
    test -s "$TCEDIR/optional/tailscale.tcz"

    MESSAGE=$(/usr/local/tce.installed/tailscale-installer)
    test -z "$MESSAGE"
    ok "The installer prompt appeared before installation and not afterward."

    echo "Loading Tailscale..."
    tce-load -is tailscale
    tailscale version
    wait_for_tailscale
    ok "Tailscale installed and connected."
}

reinstall_verify() {
    watch_phase "Post-reboot verification"
    set -e
    command -v tailscale >/dev/null
    wait_for_tailscale
    ok "Tailscale started and connected after reboot."
}

wait_for_tailscale() {
    ATTEMPTS=0
    while [ "$ATTEMPTS" -lt 30 ]; do
        if sudo tailscale status >/dev/null 2>&1; then
            return
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 2
    done
    fail "Timed out waiting for Tailscale to connect."
    return 1
}

if [ "${1-}" = --remote ]; then
    remote_tests "${2-no}"
    exit
fi
if [ "${1-}" = --reinstall-prepare ]; then
    reinstall_prepare
    exit
fi
if [ "${1-}" = --reinstall-remote ]; then
    reinstall
    exit
fi
if [ "${1-}" = --reinstall-verify ]; then
    reinstall_verify
    exit
fi

RUN_INSTALLER=no
REINSTALL=no
ASSUME_YES=no
HOST=$DEFAULT_HOST
HOST_SET=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run-installer) RUN_INSTALLER=yes ;;
        --reinstall) REINSTALL=yes ;;
        --yes) ASSUME_YES=yes ;;
        -h|--help) usage 0 ;;
        -*) usage ;;
        *)
            [ "$HOST_SET" = no ] || usage
            HOST=$1
            HOST_SET=yes
            ;;
    esac
    shift
done

[ "$RUN_INSTALLER" = no ] || [ "$REINSTALL" = no ] || usage
[ "$ASSUME_YES" = no ] || [ "$REINSTALL" = yes ] || usage

echo "Using $HOST (override with a user@host argument)."

reboot_player() {
    OLD_BOOT_ID=$(ssh "$HOST" cat /proc/sys/kernel/random/boot_id) || return 1
    echo "Rebooting $HOST..."
    ssh "$HOST" sudo reboot >/dev/null 2>&1 || true
    echo "Waiting for $HOST to come back..."

    ATTEMPTS=0
    while [ "$ATTEMPTS" -lt 90 ]; do
        NEW_BOOT_ID=$(ssh -o BatchMode=yes -o ConnectTimeout=2 "$HOST" \
            cat /proc/sys/kernel/random/boot_id 2>/dev/null) || NEW_BOOT_ID=
        if [ -n "$NEW_BOOT_ID" ] && [ "$NEW_BOOT_ID" != "$OLD_BOOT_ID" ]; then
            ok "$HOST rebooted."
            return 0
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 2
    done
    fail "Timed out waiting for $HOST to reboot."
    return 1
}

if [ "$REINSTALL" = yes ]; then
    if [ "$ASSUME_YES" = no ]; then
        if [ ! -t 0 ]; then
            fail "--reinstall requires confirmation; use --yes for a non-interactive run."
            exit 2
        fi
        echo "This will remove Tailscale from $HOST and reboot it twice."
        echo "The player must remain reachable at this SSH address without Tailscale."
        printf "Continue? [y/N] "
        read -r ANSWER
        case "$ANSWER" in
            y|Y|yes|YES) ;;
            *) echo "Cancelled."; exit 1 ;;
        esac
    fi

    REMOTE_TCEDIR=$(ssh "$HOST" readlink -f /etc/sysconfig/tcedir) || exit 1
    case "$REMOTE_TCEDIR" in
        /*) ;;
        *) fail "Refusing unexpected remote TCEDIR: $REMOTE_TCEDIR"; exit 1 ;;
    esac
    ssh "$HOST" mkdir -p "$REMOTE_TCEDIR/tailscale-test" || exit 1
    REMOTE_DIR=$(ssh "$HOST" mktemp -d \
        "$REMOTE_TCEDIR/tailscale-test/run.XXXXXX") || exit 1
    case "$REMOTE_DIR" in
        "$REMOTE_TCEDIR"/tailscale-test/run.*) ;;
        *) fail "Refusing unexpected remote work path: $REMOTE_DIR"; exit 1 ;;
    esac

    REINSTALL_SUCCESS=no
    reinstall_cleanup() {
        if [ "$REINSTALL_SUCCESS" = yes ]; then
            ssh "$HOST" rm -rf "$REMOTE_DIR"
        else
            fail "Reinstall failed; recovery files remain at $HOST:$REMOTE_DIR"
        fi
    }
    trap reinstall_cleanup EXIT
    trap 'exit 130' HUP INT TERM

    scp -q "$SCRIPT_DIR/test-remote.sh" "$SCRIPT_DIR/mktailscale.tcz.sh" \
        "$SCRIPT_DIR/mktailscale-installer.tcz.sh" \
        "$HOST:$REMOTE_DIR/" || exit 1

    echo "Removing Tailscale from $HOST and performing a clean reinstall."
    ssh "$HOST" "$REMOTE_DIR/test-remote.sh" --reinstall-prepare || exit 1
    reboot_player || exit 1
    ssh "$HOST" "$REMOTE_DIR/test-remote.sh" --reinstall-remote || exit 1
    reboot_player || exit 1
    ssh "$HOST" "$REMOTE_DIR/test-remote.sh" --reinstall-verify || exit 1

    REINSTALL_SUCCESS=yes
    trap - EXIT HUP INT TERM
    reinstall_cleanup
    exit
fi

REMOTE_DIR=$(ssh "$HOST" mktemp -d) || exit 1
case "$REMOTE_DIR" in
    /tmp/*) ;;
    *) fail "Refusing unexpected remote temporary path: $REMOTE_DIR"; exit 1 ;;
esac

cleanup() {
    ssh "$HOST" rm -rf "$REMOTE_DIR"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

scp -q "$SCRIPT_DIR/test-remote.sh" "$SCRIPT_DIR/mktailscale.tcz.sh" \
    "$SCRIPT_DIR/mktailscale-installer.tcz.sh" \
    "$HOST:$REMOTE_DIR/" || exit 1

STATUS=0
ssh "$HOST" "$REMOTE_DIR/test-remote.sh" --remote "$RUN_INSTALLER" || STATUS=$?
trap - EXIT HUP INT TERM
cleanup
exit "$STATUS"

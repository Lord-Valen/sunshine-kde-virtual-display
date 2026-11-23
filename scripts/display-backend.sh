#!/bin/bash
# Virtual-display backend for KDE Plasma 6 / Wayland (KWin).
#
# KWin has no command to spawn a headless output on demand, so display
# creation is done with krfb-virtualmonitor, which creates a virtual output at
# the *compositor* level. Userspace only, no kernel module. Sunshine must
# capture it with `capture = kwin` (the kms backend can't see compositor-level
# outputs).
#
# Public interface (consumed by sunshine-connect.sh / sunshine-disconnect.sh):
#   create_virtual_display <WxH> <name-hint>  -> creates the output
#   get_virtual_display_name                  -> echoes the name KWin assigned
#   destroy_virtual_display                   -> tears it down
#
# This file must sit next to the hook scripts that source it; they locate it
# via BASH_SOURCE, so the whole set works from any directory.
LOG="${LOG:-$HOME/.local/share/sunshine-headless.log}"
VDISPLAY_PIDFILE="$HOME/.local/share/sunshine-vdisplay.pid"
VDISPLAY_NAMEFILE="$HOME/.local/share/sunshine-vdisplay.name"

log() { echo "$(date -Iseconds) $*" >> "$LOG"; }

# --- dbus session discovery --------------------------------------------------
# Sunshine runs as a systemd daemon (user or system service), so the global_prep_cmd
# hooks inherit an environment WITHOUT the desktop's dbus session. kscreen-doctor
# and krfb-virtualmonitor talk to KWin over it, so recover it from the dbus daemon
# KDE started for this user (launched with `--abstract-socket /tmp/dbus-XXXXXXX`).
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    _dbus_sock="$(pgrep -u "$(id -u)" -a dbus 2>/dev/null | grep -Eo '/tmp/dbus-[^ ]+' | head -n1)"
    [ -n "$_dbus_sock" ] && export DBUS_SESSION_BUS_ADDRESS="unix:abstract=$_dbus_sock"
    log "dbus: recovered DBUS_SESSION_BUS_ADDRESS from running dbus daemon"
fi

# --- helpers ----------------------------------------------------------------

# All current output names, one per line.
_kscreen_output_names() {
    kscreen-doctor -j 2>/dev/null \
        | python3 -c "import sys,json; [print(o['name']) for o in json.load(sys.stdin).get('outputs',[])]"
}

# ===========================================================================
# krfb backend
# ===========================================================================

create_virtual_display() {
    local res="$1" name_hint="$2"
    # Snapshot existing outputs so we can identify the *new* one afterwards —
    # the assigned name isn't predictable, so diffing the output list is the
    # robust way to discover it.
    local before after new
    before="$(_kscreen_output_names | sort)"

    # --desktopfile NONE keeps it headless (no tray entry); the VNC port is
    # incidental (localhost) — we only want the virtual output it spawns.
    krfb-virtualmonitor --resolution "$res" --name "$name_hint" \
        --password "" --desktopfile NONE --scale 1 --port 5921 \
        >> "$LOG" 2>&1 &
    echo $! > "$VDISPLAY_PIDFILE"

    # Wait for KWin to register the new output (poll up to ~4s).
    for _ in $(seq 1 20); do
        sleep 0.2
        after="$(_kscreen_output_names | sort)"
        new="$(comm -13 <(echo "$before") <(echo "$after") | head -n1)"
        [ -n "$new" ] && break
    done

    if [ -z "$new" ]; then
        log "ERROR: krfb-virtualmonitor did not produce a new output"
        return 1
    fi
    echo "$new" > "$VDISPLAY_NAMEFILE"
    log "created virtual output: $new (${res})"
}

get_virtual_display_name() {
    [ -f "$VDISPLAY_NAMEFILE" ] && cat "$VDISPLAY_NAMEFILE"
}

destroy_virtual_display() {
    [ -f "$VDISPLAY_PIDFILE" ] && kill "$(cat "$VDISPLAY_PIDFILE")" 2>/dev/null
    rm -f "$VDISPLAY_PIDFILE" "$VDISPLAY_NAMEFILE"
}

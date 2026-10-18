# capture — the screen-capture leak (option capture).
#
# The OLED panel service (eplmanager, which measures on-screen luminance for
# pixel care) asks captureservice for a 640x360 grab of the UI plane every
# ~3 s and writes it to /tmp/capture.rgb, world-readable, and /tmp is shared
# into every app sandbox. Rather than stop the panel service, we bind a
# root-only 0600 file (on tmpfs, so no flash wear) over that path: the writer
# keeps writing, but nothing unprivileged can read it, and the mountpoint
# cannot be unlinked and recreated with looser permissions. The jails see the
# original file under the bind, so it is emptied and made 0600 first.
# vtCaptureTestSuite, a vendor command-line tool that dumps the video plane
# (nothing on the TV launches it), is bound to /dev/null as well.
#
# The root-only files live in /run/own-your-glass: /run is root's own tmpfs,
# which no app sandbox can write (the /var/run some jails get is
# /tmp/var/run on webOS). Since /tmp is shared with every sandbox, nothing
# found there is trusted: a link, or anything but a plain file, at a shielded
# path is left alone and reported. 1.5.5 and older kept the files in
# /tmp/.own-your-glass; a shield bound from there is made again from /run.
#
# The panel service keeps its samples (C5 firmware): eplmanager and
# captureservice both run as root, and captureservice writes with
# fopen/fwrite (it imports no rename or unlink), so every grab lands in the
# bound file. eplmanager's PixelExtension uses them to dim static on-screen
# elements, which is why status checks that the file keeps being written.
# Where pixel care takes no samples, status says nothing about them: LCD sets
# whose image ships eplmanager never run it (LG starts it on OLED panels
# only), and before webOS 10 eplmanager does not sample the screen.

CAP_FILE=/tmp/capture.rgb
CAP_DIR=/run/own-your-glass
VTCAP=/usr/bin/vtCaptureTestSuite
EPL_BIN=/usr/sbin/eplmanager
EPL_SAMPLES=/tmp/capture.rgb                            # named in a pixel care that samples the screen
EPL_OSD_OFF=/mnt/lg/cmn_data/pnwash/osdCaptureDisable   # LG's test-menu switch: no samples
EPL_STALE=300   # seconds without a sample before status says so

# shield_file <path>: bind a root-only file (on tmpfs) over <path>, made
# first if its writer has not made it yet. 0 = shielded now, 2 = already,
# 1 = left alone.
shield_file() {
    _sh=$CAP_DIR/${1##*/}
    if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then
        warn "$1 is not a plain file: left alone"; return 1
    fi
    if is_mounted "$1"; then
        [ "$(kv_get "shadow.${1##*/}")" = "$_sh" ] && return 2
        # bound by 1.5.5 or older, from /tmp: made again from $CAP_DIR
        state_has mounts "$1" && unbind "$1"
        is_mounted "$1" && { warn "$1 is bound by something else: left alone"; return 1; }
    fi
    if [ "$OYG_DRYRUN" != 1 ]; then
        { [ -d "$CAP_DIR" ] && [ ! -L "$CAP_DIR" ]; } || mkdir -m 700 "$CAP_DIR" || { warn "could not make $CAP_DIR"; return 1; }
        chmod 700 "$CAP_DIR"
        [ -f "$_sh" ] || touch "$_sh"; chmod 600 "$_sh"
        [ -e "$1" ] || { touch "$1" 2>/dev/null && mark_created "$1"; }
    fi
    # App jails see the file under the bind, not the bind: empty it and
    # make it root-only first, or they keep the last frame, readable.
    set_mode "$1" 600
    run "empty $1" sh -c ": > $1"
    bind_file "$_sh" "$1" && kv_set "shadow.${1##*/}" "$_sh"
}
# the file seen at <path>, through our bind, is ours and 0600
shield_ok() { [ "$(stat -c '%u %a' "$1" 2>/dev/null)" = "$(id -u) 600" ]; }
# shield_status <module> <path> <name>: one status line for a shielded file
# (nothing when the file is absent and nothing is bound)
shield_status() {
    if [ -L "$2" ]; then st "$1" WARN "$3 is a link (left alone)"; return 1; fi
    if is_mounted "$2"; then
        shield_ok "$2" && { st "$1" OK "$3 root-only"; return 0; }
        st "$1" WARN "$3 shielded by a file that is not root-only (apply again)"; return 1
    fi
    [ -e "$2" ] || return 0
    st "$1" WARN "$3 readable ($(mode_of "$2"))"; return 1
}

hook_capture_apply() {
    shield_file "$CAP_FILE"
    case $? in 0) ok "capture file shielded (root-only)" ;; 2) ok "capture file already shielded" ;; esac
    [ -e "$VTCAP" ] && bind_null "$VTCAP" && ok "video-plane grabber blocked"
    return 0
}
hook_capture_restore() { :; }   # generic restore unbinds first: the mode belongs to the file underneath
hook_capture_status() {
    _r=0
    if [ -e "$CAP_FILE" ] || [ -L "$CAP_FILE" ]; then shield_status "$1" "$CAP_FILE" "capture file" || _r=1
    else st "$1" OK "no capture file present"; fi
    if [ -e "$VTCAP" ]; then is_mounted "$VTCAP" && st "$1" OK "video grabber blocked" || { st "$1" WARN "video grabber available"; _r=1; }; fi
    capture_oled_status "$1" || _r=1
    return $_r
}
# OLED care still gets its screen samples, where it takes any: the panel
# service runs and the shielded file keeps being written. Nothing is written
# while the screen is off or the screen saver is up, so a stale file says so.
capture_oled_status() {
    [ -e "$EPL_BIN" ] && running eplmanager || return 0   # not an OLED panel
    [ -e "$EPL_OSD_OFF" ] && { st "$1" OK "OLED care takes no screen samples here (switched off in LG's test menu)"; return 0; }
    # (the binary's strings one per line: an older grep stops at a NUL byte)
    tr '\0' '\n' < "$EPL_BIN" 2>/dev/null | grep -qF "$EPL_SAMPLES" || return 0   # this pixel care samples nothing
    _sz=$(stat -c %s "$CAP_FILE" 2>/dev/null || echo 0)
    _age=$(( $(date +%s) - $(stat -c %Y "$CAP_FILE" 2>/dev/null || echo 0) ))
    if [ "$_age" -le "$EPL_STALE" ]; then
        if [ "$_sz" -gt 0 ]; then st "$1" OK "OLED care is getting its screen samples"
        else st "$1" OK "OLED care: waiting for its first screen sample"; fi
        return 0
    fi
    st "$1" WARN "OLED care has had no screen sample for over $((EPL_STALE / 60)) minutes (normal while the screen is off or the screen saver is up)"
    return 1
}

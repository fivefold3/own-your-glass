# capture — the screen-capture leak.
#
# A panel-maintenance service asks captureservice for a 640x360 grab of the
# UI plane every ~3 s and writes it to /tmp/capture.rgb, world-readable, and
# /tmp is shared into every app sandbox. Rather than stop the panel service,
# we bind a root-only 0600 file (on tmpfs, so no flash wear) over that path:
# the writer keeps writing, but nothing unprivileged can read it, and the
# mountpoint cannot be unlinked and recreated with looser permissions.
# The vendor's video-plane grabber (vtCaptureTestSuite) is bound to
# /dev/null as well.
MOD_CAPTURE_DESC="Screen-capture file readable by every app, video-plane grabber"
MOD_CAPTURE_DEFAULT=on

CAP_FILE=/tmp/capture.rgb
CAP_SHADOW=/tmp/.own-your-glass/capture.rgb
VTCAP=/usr/bin/vtCaptureTestSuite

mod_capture_apply() {
    if [ "$OYG_DRYRUN" != 1 ]; then
        mkdir -p "$(dirname "$CAP_SHADOW")" && chmod 700 "$(dirname "$CAP_SHADOW")"
        [ -e "$CAP_SHADOW" ] || : > "$CAP_SHADOW"; chmod 600 "$CAP_SHADOW"
        [ -e "$CAP_FILE" ] || { : > "$CAP_FILE"; mark_created "$CAP_FILE"; }
    fi
    if is_mounted "$CAP_FILE"; then ok "capture file already shielded"
    else bind_file "$CAP_SHADOW" "$CAP_FILE" && ok "capture file shielded (root-only)"; fi
    [ -e "$VTCAP" ] && bind_null "$VTCAP" && ok "video-plane grabber blocked"
    kv_set applied 1
    return 0
}
mod_capture_restore() { generic_restore; }
mod_capture_status() {
    _r=0
    if is_mounted "$CAP_FILE"; then st CAPTURE OK "capture file root-only"
    elif [ -e "$CAP_FILE" ]; then st CAPTURE WARN "capture file readable ($(mode_of "$CAP_FILE"))"; _r=1
    else st CAPTURE OK "no capture file present"; fi
    if [ -e "$VTCAP" ]; then is_mounted "$VTCAP" && st CAPTURE OK "video grabber blocked" || { st CAPTURE WARN "video grabber available"; _r=1; }; fi
    return $_r
}

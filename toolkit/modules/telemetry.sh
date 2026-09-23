# telemetry — the daemons whose only job is to ship data off the TV.
#
#   uploadd        log/diagnostic uploader (LS2 Type=dynamic: ls-hubd re-execs
#                  it on the next call, which is why the binary is bound, not
#                  just stopped)
#   rdxd           remote diagnostics: crash dumps and device logs to LG
#   rdx_reporter   its reporting helper
#   remotelogger   ships system logs to LG on request
#   nudge          promotional "nudge" notifications from LG
MOD_TELEMETRY_DESC="Log uploaders, remote diagnostics, promotional nudges"
MOD_TELEMETRY_DEFAULT=on

TELEMETRY_SPEC='
uploadd|uploadd.service|?|uploadd|
rdxd|rdxd.service|?|rdxd|
rdx_reporter||?|rdx_reporter|
remotelogger|remotelogger.service|?|remotelogger|
nudge|nudge.service|?|nudge|
'

mod_telemetry_apply() {
    printf '%s\n' "$TELEMETRY_SPEC" | svc_apply
    # damage limitation: the plaintext log files that were leaking utterances
    for f in /tmp/var/log/messages /tmp/app.voice.log; do [ -f "$f" ] && run "truncate $f" sh -c ": > $f"; done
    return 0
}
mod_telemetry_restore() { generic_restore; }
mod_telemetry_status()  { printf '%s\n' "$TELEMETRY_SPEC" | svc_status TELEMETRY; }

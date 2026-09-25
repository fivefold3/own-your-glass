# telemetry — the daemons that collect usage and diagnostics and send them
# to LG.
#
#   uploadd        sends the crash and analytics reports (LS2 Type=dynamic:
#                  ls-hubd re-execs it on the next call, which is why the
#                  binary is bound, not just stopped)
#   rdxd           builds crash and analytics reports and hands them to uploadd
#   rdx_reporter   command-line tool that makes one rdx report
#   remotelogger   crash backtrace helper (no network code; its dumps are what
#                  uploadd sends)
#   nudge          "AI Recommendation" tips picked from your app and channel
#                  usage
#   service-logger runs LG's usage-logging rules (first use of each app, HDMI
#                  device brands, game inputs, volume, picture mode) and
#                  fetches updated rules from LG; how its records leave the
#                  TV was not traced
#   user-context-manager
#                  records app and channel watch start/end times and sends them
#                  with the user number through sdx (nudge_log_secure); also
#                  ranks recent apps for the Home screen
#   ocpservice     OLED Care: keeps a journal of panel hours and pushes it to
#                  ocp.lgtviot.com directly, not through sdx
#   sdp-server-notice  LG server notices and "alarm nudge" popups
#   ftms           Bluetooth LE fitness-machine (FTMS) detector; fetches the
#                  list of apps it may pop up over from LG
MOD_TELEMETRY_DESC="Log uploaders, usage and panel analytics, remote diagnostics, LG notices and nudges"
MOD_TELEMETRY_DEFAULT=on

TELEMETRY_SPEC='
uploadd|uploadd.service|?|uploadd|
rdxd|rdxd.service|?|rdxd|
rdx_reporter||?|rdx_reporter|
remotelogger|remotelogger.service|?|remotelogger|
nudge|nudge.service|?|nudge|
service-logger|service-logger.service|?|service-logger|
user-context-manager|user-context-manager.service|?|user-context-manager|
ocpservice|ocp.service|?|ocpservice|
sdp-server-notice||?|sdp-server-notice|
ftms|ftms.service|?|ftms|
'

mod_telemetry_apply() {
    printf '%s\n' "$TELEMETRY_SPEC" | svc_apply
    # damage limitation: the plaintext log files that were leaking utterances
    for f in /tmp/var/log/messages /tmp/app.voice.log; do [ -f "$f" ] && run "truncate $f" sh -c ": > $f"; done
    return 0
}
mod_telemetry_restore() { generic_restore; }
mod_telemetry_status()  { printf '%s\n' "$TELEMETRY_SPEC" | svc_status TELEMETRY; }

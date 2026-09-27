# nag — the "User Agreements" prompt and the LG account terms prompt (option terms).
#
# How the prompt works on webOS 10 (verified on a 2025 LG OLED):
#   eula-service (LS2 dynamic, /usr/sbin/eula-service) is started by an
#   activity once LG's SDX platform has authenticated the TV. Its
#   UpdateManager fetches new terms versions and, when it finds one, sets the
#   system setting launchEulaByHome=true. The Home app watches that setting
#   (checkLaunchEulaByHome) and raises the agreements wall. Its
#   MarketingEulaToastObserver raises the periodic "allow marketing" toast.
#
# The LG *account* terms prompt is a different flow and is not handled
# here: a stored LG account signs itself in at every boot, accountmanager
# then checks the account's terms and launches com.webos.app.membership.
# The way to stop it is to remove the account from the TV (option account;
# the app says "LG Account signed in" while one is), not to close LG's
# screen behind the owner's back.
#
# This module:
#   1. keeps launchEulaByHome=false and runs a small watcher that flips it
#      back within a second if anything sets it;
#   2. clears every "updated":true flag of the consent list, through
#      settingsservice (lib/eula.sh), as LG's own agreements screen does.
# eula-service itself is left running. Neutralising it also made SDX's
# getEulaDownloadStatus fail, which accountmanager consults after the LG
# account auto-login at boot — and that re-raised the LG *account* terms
# prompt on every boot. The mandatory terms (S_SVC terms of use, S_PRG
# privacy policy) are left ACCEPTED — declining those is what forces the
# wall on every launch.

NAG_WATCH="$OYG_ROOT/nag-watch.sh"
NAG_PID="$OYG_ROOT/nag-watch.pid"
NAG_OFF='{"category":"general","settings":{"launchEulaByHome":false}}'

nag_watch_running() { _p=$(cat "$NAG_PID" 2>/dev/null); [ -n "$_p" ] && [ -d "/proc/$_p" ] && grep -q nag-watch "/proc/$_p/cmdline" 2>/dev/null; }
nag_watch_start() {
    [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) start launchEulaByHome watcher"; return 0; }
    nag_watch_running && nag_watch_stop   # always restart: the script may have changed
    cat > "$NAG_WATCH" <<'W'
#!/bin/sh
# own-your-glass nag watcher (see hooks/nag.sh)
LOG=${NAG_LOG:-/var/lib/own-your-glass/nag-watch.log}
note() { echo "$(date '+%F %T') $*" >> "$LOG"; }
# 1. the TV agreements wall: keep launchEulaByHome=false
( while :; do
    luna-send -i -f luna://com.webos.settingsservice/getSystemSettings \
        '{"category":"general","keys":["launchEulaByHome"],"subscribe":true}' </dev/null 2>/dev/null \
    | while read -r line; do
        case $line in *launchEulaByHome*true*)
            luna-send -n 1 -f luna://com.webos.settingsservice/setSystemSettings \
                '{"category":"general","settings":{"launchEulaByHome":false}}' </dev/null >/dev/null 2>&1
            note "launchEulaByHome was set to true: reset to false" ;;
        esac
      done
    [ -n "${NAG_ONCE:-}" ] && break
    sleep 5
  done ) &
wait
W
    chmod 755 "$NAG_WATCH"
    nohup setsid sh "$NAG_WATCH" >/dev/null 2>&1 </dev/null &
    printf '%s' "$!" > "$NAG_PID"
    _t=0; while [ $_t -lt 10 ] && ! nag_watch_running; do sleep 0.1; _t=$((_t+1)); done
    nag_watch_running && ok "launchEulaByHome watcher running (pid $(cat "$NAG_PID"))" || warn "watcher did not start"
}
nag_watch_stop() {
    _p=$(cat "$NAG_PID" 2>/dev/null)
    ps_snapshot
    # its own process group, plus what an earlier version's watcher left
    # behind, orphaned to init: never a live shell someone has on the file
    # (a command-line match once took an editor open on nag-watch.sh)
    _orph="$(orphans_of_arg 'applicationManager/getForegroundAppInfo') $(orphans_of_arg nag-watch.sh) $(orphans_of_arg 'keys":["launchEulaByHome"]')"
    [ -n "$_p" ] && kill_pids nag-watch "$_p" $(pgrp_pids "$_p") $_orph
    rm -f "$NAG_PID" "$NAG_WATCH"
}

hook_nag_apply() {
    if command -v luna-send >/dev/null 2>&1; then
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) setSystemSettings launchEulaByHome=false"
        else luna_ok luna://com.webos.settingsservice/setSystemSettings "$NAG_OFF" && ok "launchEulaByHome off"; fi
    fi
    eula_update_pending && eula_apply updated
    nag_watch_start
    return 0
}
hook_nag_restore() { nag_watch_stop; }   # the engine undoes the recorded flag changes
hook_nag_status() {
    _r=0
    if nag_watch_running; then st "$1" OK "launch-flag watcher running"; else st "$1" WARN "launch-flag watcher not running"; _r=1; fi
    eula_update_pending && { st "$1" WARN "a terms update is flagged for display"; _r=1; }
    return $_r
}

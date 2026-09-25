# nag — the "User Agreements" prompt and the marketing re-consent toast.
#
# How the prompt works on webOS 10 (verified on a 2025 LG OLED):
#   eula-service (LS2 dynamic, /usr/sbin/eula-service) is started by an
#   activity once LG's SDX platform has authenticated the TV. Its
#   UpdateManager fetches new terms versions and, when it finds one, sets the
#   system setting launchEulaByHome=true. The Home app watches that setting
#   (checkLaunchEulaByHome) and raises the agreements wall. Its
#   MarketingEulaToastObserver raises the periodic "allow marketing" toast.
#
# The LG *account* terms prompt is a different flow: after the account
# auto-login at boot, accountmanager compares the account's agreed term ids
# with LG's latest and, if they differ, launches com.webos.app.membership
# (SAM logs it as NL_APP_LAUNCH_BEGIN with caller_id
# com.webos.service.accountmanager.req). There is no local state to satisfy
# that check without agreeing, so the watcher follows the system log and
# closes the membership app only when accountmanager launched it. Opening
# LG Account from Settings (a different caller) is left alone.
#
# This module:
#   1. keeps launchEulaByHome=false and runs a small watcher that flips it
#      back within a second if anything sets it;
#   2. closes the account terms prompt whenever accountmanager raises it;
#   3. clears every "updated":true flag in /var/luna/preferences/eula.
# eula-service itself is left running. Neutralising it also made SDX's
# getEulaDownloadStatus fail, which accountmanager consults after the LG
# account auto-login at boot — and that re-raised the LG *account* terms
# prompt on every boot. The mandatory terms (S_SVC terms of use, S_PRG
# privacy policy) are left ACCEPTED — declining those is what forces the
# wall on every launch.
MOD_NAG_DESC="Stop the terms & conditions prompts (TV agreements and LG account) from being raised"
MOD_NAG_DEFAULT=on

NAG_EULA=/var/luna/preferences/eula
NAG_WATCH="$OYG_ROOT/nag-watch.sh"
NAG_PID="$OYG_ROOT/nag-watch.pid"
NAG_OFF='{"category":"general","settings":{"launchEulaByHome":false}}'

nag_watch_running() { _p=$(cat "$NAG_PID" 2>/dev/null); [ -n "$_p" ] && [ -d "/proc/$_p" ] && grep -q nag-watch "/proc/$_p/cmdline" 2>/dev/null; }
nag_watch_start() {
    [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) start launchEulaByHome watcher"; return 0; }
    nag_watch_running && nag_watch_stop   # always restart: the script may have changed
    cat > "$NAG_WATCH" <<'W'
#!/bin/sh
# own-your-glass nag watcher (see modules/nag.sh)
LOG=/var/lib/own-your-glass/nag-watch.log
MEMBERSHIP=com.webos.app.membership
note() { echo "$(date '+%F %T') $*" >> "$LOG"; }
close_membership() {
    luna-send -n 1 -f luna://com.webos.applicationManager/closeByAppId "{\"id\":\"$MEMBERSHIP\"}" </dev/null >/dev/null 2>&1
    note "closed $MEMBERSHIP: $1"
}
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
    sleep 5
  done ) &
# 2. the LG account terms prompt: close it when accountmanager raises it.
#    SAM logs every launch with the caller and the uptime in brackets; the
#    log lives on a RAM disk and rotates every couple of minutes, so poll it
#    instead of following it. A prompt already up when we start (raised
#    before the hook ran, or restored as the last app at boot) is closed too.
luna-send -n 1 -f luna://com.webos.applicationManager/running '{}' </dev/null 2>/dev/null | grep -q "\"$MEMBERSHIP\"" && close_membership "was running at start"
last=""
while :; do
    t=$(grep -a "NL_APP_LAUNCH_BEGIN.*\"$MEMBERSHIP\".*accountmanager" /var/log/messages 2>/dev/null | tail -n 1 | sed -n 's/.*\[ *\([0-9]*\)\.[0-9]*\].*/\1/p')
    if [ -n "$t" ] && [ "$t" != "$last" ]; then
        now=$(cut -d. -f1 /proc/uptime)
        if [ $((now - t)) -lt 60 ]; then
            last=$t; sleep 1
            luna-send -n 1 -f luna://com.webos.applicationManager/running '{}' </dev/null 2>/dev/null | grep -q "\"$MEMBERSHIP\"" && close_membership "launched by accountmanager at uptime ${t}s"
        else last=$t; fi
    fi
    sleep 2
done
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
    [ -n "$_p" ] && kill_pids nag-watch "$_p" $(pids_of_arg nag-watch.sh) $(pids_of_arg 'keys":["launchEulaByHome"]')
    rm -f "$NAG_PID" "$NAG_WATCH"
}

mod_nag_apply() {
    if command -v luna-send >/dev/null 2>&1; then
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) setSystemSettings launchEulaByHome=false"
        else luna_ok luna://com.webos.settingsservice/setSystemSettings "$NAG_OFF" && ok "launchEulaByHome off"; fi
    fi
    if [ -f "$NAG_EULA" ] && grep -q '"updated": *true' "$NAG_EULA"; then
        backup_once "$NAG_EULA"
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) clear updated flags in $NAG_EULA"
        else sed 's/"updated": *true/"updated":false/g' "$NAG_EULA" | write_atomic "$NAG_EULA" && ok "pending terms-update flags cleared"; fi
    fi
    nag_watch_start
    kv_set applied 1
}
mod_nag_restore() { nag_watch_stop; generic_restore; }
mod_nag_status() {
    _r=0
    if nag_watch_running; then st NAG OK "launch-flag watcher running"; else [ "$(kv_get applied)" = 1 ] && { st NAG WARN "launch-flag watcher not running"; _r=1; }; fi
    [ -f "$NAG_EULA" ] && grep -q '"updated": *true' "$NAG_EULA" && { st NAG WARN "a terms update is flagged for display"; _r=1; }
    return $_r
}

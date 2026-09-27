# remote — the doors a rooted TV leaves open (option remote-support; the
# RemoteOne daemon itself is in the option's service spec).
#
#   telnet            Homebrew Channel starts an unauthenticated root shell
#                     on :23 unless webosbrew_telnet_disabled exists. Its
#                     failsafe boot path starts telnetd regardless of the flag.
#   hbchannel tree    ships 0777 (service.js, bin/, certs/), and so do the
#                     /media/developer directories above every homebrew app:
#                     any sandboxed app could rewrite a root service.
#   role paths        a few LS2 roles LG ships for test binaries grant bus
#                     rights to whatever runs from /tmp or /mnt/lg/cmn_data
#                     (0777, not sticky). An empty, root-owned, immutable
#                     file takes each path so nothing can be planted there.
#   test automation   /var/luna/preferences/tas_<app>_enabled turns on a
#                     Flutter app's remote-control hook (webOS 11).

REMOTE_GATE=/mnt/lg/cmn_data/remoteDebug
TELNET_FLAG=/var/luna/preferences/webosbrew_telnet_disabled
FAILSAFE_FLAG=/var/luna/preferences/webosbrew_failsafe
HBC_SVC=/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service
DEV_DIRS="/media/developer /media/developer/apps /media/developer/apps/usr /media/developer/apps/usr/palm /media/developer/apps/usr/palm/applications /media/developer/apps/usr/palm/services"
ROLE_DIRS="/usr/share/luna-service2/roles.d"

# exeName paths of shipped roles that sit in world-writable places
remote_role_paths() {
    for _d in $ROLE_DIRS; do [ -d "$_d" ] && cat "$_d"/*.json 2>/dev/null; done \
        | grep -oE '"exeName"[[:space:]]*:[[:space:]]*"(/tmp|/var/tmp|/mnt/lg/cmn_data)/[^"]*"' \
        | sed 's/.*"\(\/[^"]*\)"$/\1/' | sort -u
}
# telnet listening on :23 (0017), IPv4 or IPv6
remote_telnet_listening() { awk 'NR > 1 && $4 == "0A" { split($2, a, ":"); if (a[2] == "0017") f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; }

hook_remote_apply() {
    [ -e "$REMOTE_GATE" ] && warn "$REMOTE_GATE exists: remote support has been provisioned on this TV (left in place, inspect it)"
    if [ ! -e "$TELNET_FLAG" ]; then
        run "touch $TELNET_FLAG" touch "$TELNET_FLAG" && mark_created "$TELNET_FLAG"
        kill_procs telnetd
        ok "telnet root shell disabled (takes effect now and at boot)"
    fi
    if [ -d "$HBC_SVC" ]; then
        # the whole tree: bin/ and certs/ ship 0777 too, and an update of
        # Homebrew Channel puts service.js back to 0666. Executables keep
        # their x bit, everything else becomes 0644.
        find "$HBC_SVC" -type d | while read -r d; do set_mode "$d" 755; done
        find "$HBC_SVC" -type f | while read -r f; do
            if [ -x "$f" ]; then set_mode "$f" 755; else set_mode "$f" 644; fi
        done
        ok "homebrew channel service tree is no longer world-writable"
    fi
    _dd=0; for d in $DEV_DIRS; do [ -d "$d" ] && set_mode "$d" 755 && _dd=$((_dd+1)); done
    [ $_dd = 0 ] || ok "homebrew app directories are no longer world-writable"
    for p in $(remote_role_paths); do
        [ -e "$p" ] && continue          # status reports what is there
        [ -d "${p%/*}" ] || continue
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) occupy role path $p"; continue; fi
        : > "$p" && chmod 000 "$p" && mark_created "$p" || { warn "could not occupy $p"; continue; }
        chattr +i "$p" 2>/dev/null && state_add immutable "$p"
        ok "role path $p occupied"
    done
    return 0
}
# all recorded: generic restore clears the immutable flags first. Undoing
# is faithful, so it re-opens what the option had closed: the owner is told,
# since a root shell with no password is not something to give back quietly
hook_remote_restore() {
    _back=""
    state_has created "$TELNET_FLAG" && _back="Homebrew Channel's telnet root shell (port 23, no password) is allowed again"
    [ -s "$(_sf modes)" ] && _back="$_back${_back:+; }Homebrew Channel's files are world-writable again"
    [ -n "$_back" ] || return 0
    warn "root hygiene undone: $_back"
    [ "$OYG_DRYRUN" = 1 ] || toast_always "Own Your Glass: root hygiene undone. Telnet root shell may be back on: check Homebrew Channel's settings"
    return 0
}
hook_remote_status() {
    _r=0; _m=$1
    [ -e "$REMOTE_GATE" ] && { st "$_m" FAIL "remote-debug gate present ($REMOTE_GATE)"; _r=1; }
    if running telnetd || remote_telnet_listening; then st "$_m" FAIL "a telnet root shell is listening"; _r=1
    elif [ -e "$FAILSAFE_FLAG" ]; then st "$_m" FAIL "Homebrew Channel's failsafe mode is armed: it starts telnet at boot whatever the flag"; _r=1
    elif [ -e "$TELNET_FLAG" ]; then st "$_m" OK "telnet disabled"
    else st "$_m" WARN "telnet flag not set"; _r=1; fi
    if [ -d "$HBC_SVC" ]; then
        _ww=$(find "$HBC_SVC" $DEV_DIRS -maxdepth 0 -perm -002 ! -type l 2>/dev/null | head -1)
        [ -n "$_ww" ] || _ww=$(find "$HBC_SVC" -perm -002 ! -type l 2>/dev/null | head -1)
        if [ -n "$_ww" ]; then st "$_m" WARN "world-writable homebrew path: $_ww"; _r=1; else st "$_m" OK "homebrew root service and app directories locked"; fi
    fi
    for p in $(remote_role_paths); do
        [ -e "$p" ] || continue
        if [ -s "$p" ] || [ "$(stat -c %u "$p" 2>/dev/null)" != 0 ]; then st "$_m" FAIL "something was planted at role path $p"; _r=1; fi
    done
    for f in /var/luna/preferences/tas_*_enabled; do [ -e "$f" ] && { st "$_m" FAIL "test automation enabled: $f"; _r=1; }; done
    return $_r
}

# apps — hide the system apps the enabled options list from the launcher.
#
# The launcher honours a vendor file listing system apps to hide:
#   /var/preferences/com.webos.applicationManager/blockedSystemAppList/<REGION>.json
#   {"blocked_system_applist":["id", ...]}
# Hiding is all this does (nothing is deleted). Entries already in the file
# are kept; curated ids not present on this TV are skipped. The system app
# manager then refuses to launch them, which is the real effect: most are
# already invisible.
# LG's own entries are always read from the live file minus the ids OYG
# added last time (kv "added"), never from the first-apply backup: a
# firmware update that changes LG's list would otherwise be overwritten at
# the next apply and again on restore. (The backup stays as a fallback for
# records from before 1.4.59.)

APPS_DIR=/var/preferences/com.webos.applicationManager/blockedSystemAppList
APPS_IDS=${APPS_IDS:-}   # the enabled options' apps (etc/options.sh), set by the engine

apps_file() {
    for f in "$APPS_DIR"/*.json; do [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done
    _r=$(json_str /var/luna/preferences/localeInfo country); [ -z "$_r" ] && _r=$(sed -n 's/.*"country" *: *"\([A-Z]*\)".*/\1/p' /var/luna/preferences/localeInfo 2>/dev/null | head -1)
    printf '%s/%s.json\n' "$APPS_DIR" "${_r:-XXX}"
}
# system apps live on the rootfs, the separately updated app partitions
# (otncabi holds com.webos.app.adapp, the full-screen ad app) and /media
app_exists() {
    for _r in /usr/palm/applications /mnt/otncabi/usr/palm/applications /mnt/otycabi/usr/palm/applications /media/system/apps/usr/palm/applications /media/cryptofs/apps/usr/palm/applications; do
        [ -d "$_r/$1" ] && return 0
    done
    return 1
}
apps_current() { [ -f "$1" ] || return 0; tr ',' '\n' < "$1" | grep -o '"[a-zA-Z0-9_.-]*"' | tr -d '"' | grep -v '^blocked_system_applist$'; }

# The app manager reads the hidden list only when it starts, so an app shown
# again comes back after the TV restarts (C5: LG Channels, the account page).
APPS_BACK="Apps that were hidden come back"
res_apps_apply() {
    f=$(apps_file)
    _was=$( [ -f "$f" ] && apps_current "$f" )
    if [ -f "$f" ]; then backup_once "$f"; else mark_created "$f"; fi
    kv_set file "$f"
    _add=""; _skip=0
    for id in $APPS_IDS; do app_exists "$id" && _add="$_add $id" || _skip=$((_skip+1)); done
    # LG's own entries: the live file minus what OYG added last time, so an
    # app of an option turned off since is shown again and LG's changes stay
    _mine=$(oyg_tmp apps.mine); printf '%s\n' $(kv_get added) | grep -v '^$' > "$_mine"
    all=$( { apps_current "$f" | minus_file "$_mine"; printf '%s\n' $_add; } | grep -v '^$' | sort -u)
    [ -z "$all" ] && { info "nothing to hide on this TV"; kv_set applied 1; return 0; }
    printf '{"blocked_system_applist":[%s]}\n' "$(printf '%s\n' $all | sed 's/.*/"&"/' | paste -sd, -)" | write_atomic "$f"
    kv_set added "$(printf '%s\n' $_add | grep -v '^$' | tr '\n' ' ')"
    ok "$(printf '%s\n' $_add | grep -c .) apps hidden ($_skip not on this TV) via $(basename "$f")"
    # hidden before and not now: shown again once the TV restarts
    _keep=$(oyg_tmp apps.keep); printf '%s\n' $all > "$_keep"
    if printf '%s\n' "$_was" | grep -v '^$' | grep -qvxF -f "$_keep"; then need_restart "$APPS_BACK" >/dev/null; fi
    kv_set applied 1
}
res_apps_restore() {
    [ -n "$(state_list files)$(state_list created)" ] && [ "$OYG_DRYRUN" != 1 ] && need_restart "$APPS_BACK" >/dev/null
    # a file LG had: take OYG's ids out of the live one and keep the rest as
    # LG has it now, rather than copying the first-apply backup back
    f=$(kv_get file)
    if [ -n "$f" ] && [ -f "$f" ] && state_has files "$f" && [ -n "$(kv_get added)" ] && [ "$OYG_DRYRUN" != 1 ]; then
        _mine=$(oyg_tmp apps.mine); printf '%s\n' $(kv_get added) | grep -v '^$' > "$_mine"
        _keep=$(apps_current "$f" | minus_file "$_mine" | sed 's/.*/"&"/' | paste -sd, -)
        printf '{"blocked_system_applist":[%s]}\n' "$_keep" | write_atomic "$f"
        rm -f "$(backup_path "$f")"; state_del files "$f"
    fi
    generic_restore
}
res_apps_status() {
    f=$(kv_get file); [ -z "$f" ] && f=$(apps_file)
    [ -f "$f" ] || { st "$1" WARN "no hidden-app list"; return 1; }
    _want=0; _have=0
    for id in $APPS_IDS; do app_exists "$id" || continue; _want=$((_want+1)); grep -q "\"$id\"" "$f" && _have=$((_have+1)); done
    [ $_want = 0 ] && { st "$1" NA "none of the targeted apps are on this TV"; return 0; }
    [ $_have = $_want ] && { st "$1" OK "$_have unwanted apps hidden"; return 0; }
    st "$1" WARN "$_have of $_want unwanted apps hidden"; return 1
}

# apps — hide the ad, ACR, remote-support and demo apps from the launcher.
#
# The launcher honours a vendor file listing system apps to hide:
#   /var/preferences/com.webos.applicationManager/blockedSystemAppList/<REGION>.json
#   {"blocked_system_applist":["id", ...]}
# Hiding is all this does (nothing is deleted). Entries already in the file
# are kept; curated ids not present on this TV are skipped. The overlay
# containers (com.webos.app.overlaycontainer*) are deliberately NOT hidden:
# they host the quick-settings panel, not the ads.
MOD_APPS_DESC="Hide ad, ACR, remote-support and demo apps from the launcher"
MOD_APPS_DEFAULT=on

APPS_DIR=/var/preferences/com.webos.applicationManager/blockedSystemAppList
APPS_IDS='
com.webos.app.acrcomponent com.webos.app.acrhdmi1 com.webos.app.acrhdmi2 com.webos.app.acrhdmi3
com.webos.app.acrhdmi4 com.webos.app.acroverlay com.webos.app.adoverlay com.webos.app.adoverlayex
com.webos.app.adhdmi1 com.webos.app.adhdmi2 com.webos.app.adhdmi3 com.webos.app.adhdmi4
com.webos.app.fooddelivery com.webos.app.fooddeliveryex com.webos.app.fooddeliveryhdmi1
com.webos.app.fooddeliveryhdmi2 com.webos.app.fooddeliveryhdmi3 com.webos.app.fooddeliveryhdmi4
com.webos.app.overlaymembership com.webos.app.videoads com.webos.app.cmp-client com.webos.app.newandhot
com.webos.app.remoteservice com.webos.app.svcdiagnostics
com.webos.app.store-demo com.webos.app.sync-demo com.webos.app.factorywin com.webos.app.quickrecovery
com.webos.exampleapp.enyoapp.epg com.webos.exampleapp.groupowner com.webos.exampleapp.nav
com.webos.exampleapp.qmlapp.client.negative.one com.webos.exampleapp.qmlapp.client.negative.two
com.webos.exampleapp.qmlapp.client.positive.one com.webos.exampleapp.qmlapp.client.positive.two
com.webos.exampleapp.qmlapp.discover com.webos.exampleapp.qmlapp.epg com.webos.exampleapp.qmlapp.hbbtv
com.webos.exampleapp.qmlapp.livetv com.webos.exampleapp.qmlapp.search com.webos.exampleapp.systemui
'

apps_file() {
    for f in "$APPS_DIR"/*.json; do [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done
    _r=$(json_str /var/luna/preferences/localeInfo country); [ -z "$_r" ] && _r=$(sed -n 's/.*"country" *: *"\([A-Z]*\)".*/\1/p' /var/luna/preferences/localeInfo 2>/dev/null | head -1)
    printf '%s/%s.json\n' "$APPS_DIR" "${_r:-XXX}"
}
app_exists() { [ -d "/usr/palm/applications/$1" ] || [ -d "/media/system/apps/usr/palm/applications/$1" ] || [ -d "/media/cryptofs/apps/usr/palm/applications/$1" ]; }
apps_current() { tr ',' '\n' < "$1" 2>/dev/null | grep -o '"[a-zA-Z0-9_.-]*"' | tr -d '"' | grep -v '^blocked_system_applist$'; }

mod_apps_apply() {
    f=$(apps_file)
    if [ -f "$f" ]; then backup_once "$f"; else mark_created "$f"; fi
    kv_set file "$f"
    _add=""; _skip=0
    for id in $APPS_IDS; do app_exists "$id" && _add="$_add $id" || _skip=$((_skip+1)); done
    all=$( { apps_current "$f"; printf '%s\n' $_add; } | grep -v '^$' | sort -u)
    [ -z "$all" ] && { info "nothing to hide on this TV"; kv_set applied 1; return 0; }
    printf '{"blocked_system_applist":[%s]}\n' "$(printf '%s\n' $all | sed 's/.*/"&"/' | paste -sd, -)" | write_atomic "$f"
    ok "$(printf '%s\n' $_add | grep -c .) apps hidden ($_skip not on this TV) via $(basename "$f")"
    kv_set applied 1
}
mod_apps_restore() { generic_restore; }
mod_apps_status() {
    f=$(kv_get file); [ -z "$f" ] && f=$(apps_file)
    [ -f "$f" ] || { st APPS WARN "no hidden-app list"; return 1; }
    _want=0; _have=0
    for id in $APPS_IDS; do app_exists "$id" || continue; _want=$((_want+1)); grep -q "\"$id\"" "$f" && _have=$((_have+1)); done
    [ $_want = 0 ] && { st APPS NA "none of the targeted apps are on this TV"; return 0; }
    [ $_have = $_want ] && { st APPS OK "$_have unwanted apps hidden"; return 0; }
    st APPS WARN "$_have of $_want unwanted apps hidden"; return 1
}

# blocklist.sh — LG's own launch block list, used as a second lock.
#
# ls-hubd starts every on-demand (Type=dynamic) Luna service through
# /usr/bin/run-service (webOS 10 and later). That script exits 1, before the
# jailer and before the binary, when the service's first LS2 name is listed
# in /var/preferences/servicemanager/blocked-services.json. LG uses it for
# the sign-language avatar. It reaches what a bind on /usr cannot:
#   - jailed services, whose /usr overlay does not see our binds when the
#     jail is set up after apply (performer, lg.thinqai.adapter, Alexa);
#   - services installed on /media/system (the Chromecast receiver);
#   - JS services loaded into the unified server (run-js-service -u), which
#     no kill can reach once loaded.
# It cannot stop static services (ls-hubd never launches those) or anything
# already running, and servicemanager rewrites the file from systemprofile
# early at boot, so our list is bound read-only over it. LG's own entries are
# kept. Each module records the names of its entries (state list "ls2"); the
# file is the union, rebuilt after every apply and restore.

BL_FILE=/var/preferences/servicemanager/blocked-services.json
BL_GEN="$OYG_ROOT/blocked-services.json"
BL_LG="$OYG_ROOT/blocked-services.lg"
LS2_DIRS="/usr/share/luna-service2/services.d /var/luna-service2/services.d /var/luna-service2-dev/services.d /usr/share/dbus-1/system-services /usr/share/dbus-1/services"
LS2_INDEX="$OYG_ROOT/ls2.index"

blocklist_supported() { grep -q blocked-services /usr/bin/run-service 2>/dev/null; }

# Names that must never be blocked: the bus itself and what Settings, Home,
# the terms state and the app need, whatever a spec says. Blocking a
# service its callers wait on makes them hang (the voiceconductor lesson).
ls2_denied() {
    case $1 in
        com.palm.uploadd) return 1 ;;   # the crash/analytics uploader, the one com.palm.* we block
        org.webosbrew.*|org.ownyourglass.*|com.palm.*|com.webos.service.jsserver|com.webos.service.secondscreen.gateway|com.webos.service.settingsui|com.webos.service.sdx|com.webos.service.voiceconductor|com.webos.service.voiceinput|com.webos.service.ics|com.webos.service.ics.*|com.webos.service.eulaservice|com.webos.service.accountmanager|com.webos.service.capture|com.webos.service.servicemanager|com.webos.service.systemprofile|com.webos.settingsservice|com.webos.service.settings|com.webos.applicationManager|com.webos.service.applicationmanager|com.webos.bootManager|com.webos.notification) return 0 ;;
    esac
    return 1
}

# name<TAB>type<TAB>exec<TAB>first for every LS2 name this TV registers
# (first = 1 for the first name of its file, the only one run-service
# checks). Built at apply (it reads ~600 files) and cached for status.
ls2_index_build() {
    _o=${1:-$LS2_INDEX}
    _f=""; for _d in $LS2_DIRS; do [ -d "$_d" ] && _f="$_f $_d/*.service"; done
    [ -n "$_f" ] || { : > "$_o"; return 0; }
    # shellcheck disable=SC2086
    awk '
        function flush(  k, i, a) { if (n != "") { k = split(n, a, ";"); for (i = 1; i <= k; i++) if (a[i] != "") print a[i] "\t" (ty == "" ? "dynamic" : ty) "\t" e "\t" (i == 1) }; n = e = ty = "" }
        FNR == 1 { flush() }
        { sub(/\r$/, "") }   # some legacy registry files are CRLF
        /^Name=/ { n = substr($0, 6) }
        /^Exec=/ { e = substr($0, 6) }
        /^Type=/ { ty = substr($0, 6) }
        END { flush() }' $_f 2>/dev/null | sort -u > "$_o.t" && mv "$_o.t" "$_o"
}
_ls2_idx() {
    if [ -s "$LS2_INDEX" ]; then printf '%s' "$LS2_INDEX"
    else _t=$(oyg_tmp ls2.index); [ -s "$_t" ] || ls2_index_build "$_t"; printf '%s' "$_t"; fi
}
ls2_known() { awk -F'\t' -v n="$1" '$1 == n { f = 1; exit } END { exit !f }' "$(_ls2_idx)"; }
ls2_type()  { awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$(_ls2_idx)"; }
ls2_blockable() {  # dynamic, first name of its registry file, not denied
    ! ls2_denied "$1" && awk -F'\t' -v n="$1" '$1 == n && $2 == "dynamic" && $4 == 1 { f = 1; exit } END { exit !f }' "$(_ls2_idx)"
}

blocklist_names() { { cat "$OYG_STATE"/ls2.* 2>/dev/null; [ "$OYG_DRYRUN" = 1 ] && cat "$(oyg_tmp dry.ls2)" 2>/dev/null; } | grep -v '^$' | sort -u; }
# LG's list (file, may be missing) ∪ our names, in LG's format
blocklist_json() {  # blocklist_json <LG's file> <name>...
    _f=$1; shift
    _l=$( { [ -f "$_f" ] && grep -o '"[^"]*"' "$_f" | tr -d '"' | grep -vx blockedServices; printf '%s\n' "$@"; } | grep -v '^$' | sort -u)
    printf '{"blockedServices":[%s]}' "$(printf '%s\n' $_l | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)"
}
blocklist_listed() { is_mounted "$BL_FILE" && grep -q "\"$1\"" "$BL_FILE" 2>/dev/null; }

blocklist_sync() {
    blocklist_supported || return 0
    _om=$OYG_MOD; OYG_MOD=blocklist
    _names=$(blocklist_names)
    if [ -z "$_names" ]; then
        if [ -n "$(state_list mounts)$(state_list created)" ]; then
            restore_mounts; unbind_src "$BL_GEN"; restore_created
            [ "$OYG_DRYRUN" = 1 ] || rm -f "$BL_GEN" "$BL_LG"
            ok "launch block list: LG's own list back in place"
        fi
        OYG_MOD=$_om; return 0
    fi
    # LG's own list: the live file while it is not ours, else the saved copy
    if [ "$OYG_DRYRUN" != 1 ] && [ -f "$BL_FILE" ] && ! is_mounted "$BL_FILE"; then cp -p "$BL_FILE" "$BL_LG" 2>/dev/null; fi
    _json=$(blocklist_json "$BL_LG" $_names)
    _all=$(printf '%s' "$_json" | grep -o '"[^"]*"' | grep -vxc '"blockedServices"')
    if is_mounted "$BL_FILE" && state_has mounts "$BL_FILE" && [ "$(cat "$BL_GEN" 2>/dev/null)" = "$_json" ] && ro_ok "$BL_GEN"; then
        OYG_MOD=$_om; return 0
    fi
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) bind launch block list ($_all names) over $BL_FILE"; OYG_MOD=$_om; return 0; fi
    printf '%s\n' "$_json" > "$BL_GEN.t" && mv "$BL_GEN.t" "$BL_GEN"
    if [ ! -f "$BL_FILE" ]; then
        # nothing to cover yet: an empty list of LG's shape, removed on restore
        mkdir -p "$(dirname "$BL_FILE")" && printf '{"blockedServices":[]}\n' > "$BL_FILE" && mark_created "$BL_FILE"
    fi
    if bind_file_ro "$BL_GEN" "$BL_FILE"; then ok "launch block list: $(printf '%s\n' $_names | grep -c .) services cannot be started by the bus"
    else warn "launch block list could not be made read-only"; fi
    OYG_MOD=$_om
}

# META line for oyg status: state (none|ok|missing|rw|unsupported) and count
blocklist_meta() {
    blocklist_supported || { printf 'META|blocklist|unsupported|0\n'; return 0; }
    _n=$(blocklist_names | grep -c .)
    if [ "$_n" = 0 ]; then _s=none
    elif ! is_mounted "$BL_FILE"; then _s=missing
    else _om=$OYG_MOD; OYG_MOD=blocklist; [ -n "$(rw_peers "$BL_GEN")" ] && _s=rw || _s=ok; OYG_MOD=$_om; fi
    printf 'META|blocklist|%s|%s\n' "$_s" "$_n"
}

# sdx — cut LG's network gateway off from its logging and marketing endpoints.
#
# /usr/sbin/sdx is the HTTP client most of the TV uses to reach LG. A caller
# asks luna://com.webos.service.sdx/send for a serviceName (sdp_logging,
# nudge_log_secure, tlamp_secure, ...) and sdx looks up that name's host in
# its routing table, server_addr_version.conf, which LG's server refreshes.
# Every request carries the device ID (derived from the MAC), the fck key,
# model, firmware, locale and consent state. PmLogDaemon and the LG Channels
# engine (dmost) log through it, and neither can be stopped.
#
# sdx itself must keep running: Settings, the terms state and the LG account
# prompt depend on it. So this module rewrites the table instead. Each
# blocked serviceName points at <prefix>.oyg.invalid, which never resolves
# (.invalid is reserved, RFC 6761). The kept ones hold their LG hosts: sign-in
# and the clock (sdp_auth, sdp_init, sdp_common; the TV's first time source
# is "sdp"), the Content Store (sdp_apps, sdp_apps_resource, cpauth_secure,
# wise_account), AirPlay provisioning (sdp_airplay) and the address list
# Settings uses (ibis_secure).
#
# The rewritten table is bound read-only over the live one, so a server push
# cannot put the entries back. sdx is an on-demand Luna service (ls-hubd
# starts it on the next call) that reads the table when it starts, so apply
# and restore end the process.
MOD_SDX_DESC="Cut LG's network gateway (sdx) off from its logging, beacon, nudge, shop and recommendation endpoints"
MOD_SDX_DEFAULT=on
MOD_SDX_BREAKS="Home screen recommendations and promo cards, LG Channels online guide, LG shop, sports alerts, Home Hub and Gallery cloud features. The services the Content Store, AirPlay, Settings, sign-in and the clock use keep their LG hosts"

SDX_TABLE=/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf
SDX_GEN="$OYG_ROOT/sdx-routes.conf"
SDX_ORIG="$OYG_ROOT/sdx-routes.orig"   # LG's table as it was at apply; the network module reads it
SDX_SINK=oyg.invalid
SDX_BIN=/usr/sbin/sdx

# serviceNames sent nowhere. Anything not listed keeps its LG host.
SDX_BLOCK="
sdp_logging rdx_secure rdxdev_secure ibis_stat_secure
nudge_secure nudge_log_secure homeprv_secure recommend_secure tlamp_secure
web_browser_rcmd qcard sdp_nais sdp_onnow
cdpbeacon_secure cdp_service_secure cpv_secure
lgshop_secure lgshoplog_secure
iot iot_push_secure iot_sports_secure voice_proxy_secure buddy
"
# serviceNames whose host the prefix lookup reads (never blocked)
SDX_PROBE_DEFAULT=sdp_apps
SDX_PROBE_RIC=wise_account

# Rewrite the "domain" of every entry whose serviceName is in BLOCK. The table
# is one line of JSON; entries are the innermost {...} objects.
SDX_AWK='
BEGIN { n = split(BLOCK, b, " "); for (i = 1; i <= n; i++) blk[b[i]] = 1 }
{
    s = $0; out = ""
    while (match(s, /\{[^{}]*\}/)) {
        st = RSTART; ln = RLENGTH; o = substr(s, st, ln)
        if (match(o, /"serviceName"[ ]*:[ ]*"[^"]*"/)) {
            sn = substr(o, RSTART, RLENGTH); sub(/.*:[ ]*"/, "", sn); sub(/"$/, "", sn)
            if (sn in blk) sub(/"domain"[ ]*:[ ]*"[^"]*"/, "\"domain\": \"" SINK "\"", o)
        }
        out = out substr(s, 1, st - 1) o; s = substr(s, st + ln)
    }
    print out s
}'

sdx_block_list() { printf '%s\n' $SDX_BLOCK; }
# serviceName|domainType|domain for every entry of a table
sdx_entries() {
    { cat "$1"; echo; } | tr '{' '\n' | sed -n 's/.*"domainType"[ ]*:[ ]*"\([^"]*\)".*"domain"[ ]*:[ ]*"\([^"]*\)".*"serviceName"[ ]*:[ ]*"\([^"]*\)".*/\3|\1|\2/p'
}
sdx_url() {  # sdx_url <serviceName> → the baseUrl sdx uses now
    luna luna://com.webos.service.sdx/getServerUrl "{\"serviceName\":\"$1\"}" \
        | sed -n 's/.*"baseUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}
sdx_restart() {  # ls-hubd starts sdx again on the next call; make that call
    # At boot, accountmanager checks the terms status through sdx, and a
    # failed check raises the LG account prompt: never restart it mid-boot.
    [ "$OYG_DRYRUN" = 1 ] || boot_done || { info "waiting for boot to finish before restarting sdx"; wait_boot_done; }
    kill_pids sdx $(pids_of_exe "$SDX_BIN") $(pids_of sdx)
    [ "$OYG_DRYRUN" = 1 ] && return 0
    _i=0; while [ $_i -lt 10 ]; do [ -n "$(sdx_url sdp_common)" ] && return 0; sleep 1; _i=$((_i+1)); done
    warn "sdx did not answer after restart"
}

# Hostnames that only blocked serviceNames use, built from LG's own table and
# the prefixes sdx puts in front of it (a country code for "default" domains,
# a regional code for "ric" ones). The network module sinkholes these.
sdx_blocked_hosts() {
    _t=$SDX_ORIG; [ -f "$_t" ] || _t=$SDX_TABLE; [ -f "$_t" ] || return 0
    _pd=$(sdx_prefix default); _pr=$(sdx_prefix ric)
    sdx_entries "$_t" | awk -F'|' -v BLOCK="$SDX_BLOCK" -v pd="$_pd" -v pr="$_pr" '
        BEGIN { n = split(BLOCK, b, " "); for (i = 1; i <= n; i++) blk[b[i]] = 1 }
        { p = ($2 == "default") ? pd : pr; if (p == "") next
          h = p "." $3; if ($1 in blk) bh[h] = 1; else kh[h] = 1 }
        END { for (h in bh) if (!(h in kh)) print h }' | sort
}
# The prefix sdx puts in front of a domain type's hosts, read from the URL it
# reports for a service that is never blocked. Cached by the sdx module.
sdx_prefix_live() {  # sdx_prefix_live default|ric
    case $1 in default) _sn=$SDX_PROBE_DEFAULT;; *) _sn=$SDX_PROBE_RIC;; esac
    _dom=$(sdx_entries "$SDX_TABLE" | awk -F'|' -v s="$_sn" '$1==s{print $3; exit}')
    _host=$(sdx_url "$_sn" | sed 's#^[a-z]*://##; s#/.*##')
    case $_host in *".$_dom") printf '%s' "${_host%.$_dom}";; esac
}
sdx_prefix() {
    _c=$(sed -n "s/^prefix_$1=//p" "$OYG_STATE/kv.sdx" 2>/dev/null | head -1)
    if [ -n "$_c" ]; then printf '%s' "$_c"; else sdx_prefix_live "$1"; fi
}
sdx_learn_prefixes() {
    for _ty in default ric; do
        _p=$(sdx_prefix_live "$_ty")
        if [ -n "$_p" ]; then kv_set "prefix_$_ty" "$_p"; else warn "could not learn the sdx $_ty host prefix"; fi
    done
}

mod_sdx_apply() {
    [ -f "$SDX_TABLE" ] || { info "sdx routing table not on this TV"; return 0; }
    # the prefixes come from services that are never blocked, so the running
    # sdx reports them whatever table it has; learn them while it is up
    sdx_learn_prefixes
    # start from LG's current table: drop our previous layer first (sdx is
    # restarted once, below, after the new layer is in place)
    if is_mounted "$SDX_TABLE" && state_has mounts "$SDX_TABLE"; then unbind "$SDX_TABLE"; fi
    _all=$(sdx_entries "$SDX_TABLE" | wc -l | tr -d ' ')
    [ "$_all" -gt 0 ] || { fail "sdx routing table not understood"; return 1; }
    if [ "$OYG_DRYRUN" = 1 ]; then
        info "(dry-run) route $(sdx_entries "$SDX_TABLE" | cut -d'|' -f1 | grep -cxF "$(sdx_block_list)") of $_all sdx services to $SDX_SINK"
        return 0
    fi
    cp "$SDX_TABLE" "$SDX_ORIG"
    awk -v BLOCK="$SDX_BLOCK" -v SINK="$SDX_SINK" "$SDX_AWK" "$SDX_TABLE" > "$SDX_GEN.tmp"
    # the rewrite must keep every entry and change only domains
    if [ "$(sdx_entries "$SDX_GEN.tmp" | wc -l | tr -d ' ')" != "$_all" ] || ! grep -q "\"$SDX_SINK\"" "$SDX_GEN.tmp"; then
        rm -f "$SDX_GEN.tmp"; fail "rewritten sdx table failed its check; left LG's table in place"; return 1
    fi
    mv "$SDX_GEN.tmp" "$SDX_GEN"
    bind_file "$SDX_GEN" "$SDX_TABLE" || { fail "could not bind the sdx table"; return 1; }
    run "remount $SDX_TABLE read-only" mount -o remount,bind,ro "$SDX_TABLE"
    sdx_restart
    case $(sdx_url sdp_logging) in
        *"$SDX_SINK"*) ok "$(grep -o "\"$SDX_SINK\"" "$SDX_GEN" | wc -l | tr -d ' ') of $_all sdx services routed to nowhere" ;;
        *) warn "sdx still reports its old route for sdp_logging" ;;
    esac
    kv_set applied 1
}
mod_sdx_restore() {
    _was=0; is_mounted "$SDX_TABLE" && state_has mounts "$SDX_TABLE" && _was=1
    generic_restore
    rm -f "$SDX_GEN" "$SDX_ORIG"
    [ $_was = 1 ] && sdx_restart
    return 0
}
mod_sdx_status() {
    [ -f "$SDX_TABLE" ] || { st SDX NA "no sdx routing table on this TV"; return 0; }
    if ! is_mounted "$SDX_TABLE" || ! grep -q "\"$SDX_SINK\"" "$SDX_TABLE" 2>/dev/null; then
        st SDX WARN "routing table not rewritten"; return 1
    fi
    case $(sdx_url sdp_logging) in
        *"$SDX_SINK"*) st SDX OK "$(grep -o "\"$SDX_SINK\"" "$SDX_TABLE" | wc -l | tr -d ' ') LG endpoints routed to nowhere" ;;
        *) st SDX WARN "table rewritten but sdx still uses its old routes"; return 1 ;;
    esac
}

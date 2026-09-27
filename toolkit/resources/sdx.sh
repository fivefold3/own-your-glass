# sdx — cut LG's network gateway off from the endpoints the enabled options name.
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
# Settings uses (ibis_secure). On webOS 11 nearly every name shares one host
# (<CC>/<RIC>.tv.wiselg.com) with sign-in and the clock, so this per-name
# rewrite is the only way to separate LG's telemetry from what the TV needs.
#
# The table is JSON: {"version":…,"severDomain":{"<group>":[{entry},…]}}
# with one group on webOS 10 ("10.0.0") and two on webOS 11 ("default" and
# the China group "C01"). LG's factory copy is pretty-printed, its server
# push is one line, and key order varies; the parser below reads any of them.
#
# The rewritten table is bound read-only over the live one, on every mount
# the file shows up under (/mnt/lg/{cmn_data,cache,flash/data,user}), so a
# server push cannot put the entries back. sdx is an on-demand Luna service
# (ls-hubd starts it on the next call) that reads the table when it starts,
# so apply and restore end the process, but only when the table changed:
# every sdx start stacks another tmpfs on its pkgs directory.

SDX_TABLE=/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf
SDX_GEN="$OYG_ROOT/sdx-routes.conf"
SDX_ORIG="$OYG_ROOT/sdx-routes.orig"   # LG's table as it was at apply; the network module reads it
SDX_SINK=$OYG_SINK
SDX_BIN=/usr/sbin/sdx
SDX_OKF=/tmp/.own-your-glass.sdx-ok   # sdx pid last seen routing to the sink (status cache)
# the host prefixes sdx uses on this TV (country, region) and its table
# group: facts about the TV, not changes, so a restore keeps them for the
# sinkhole (1.2.x kept them in kv.sdx, still read as a fallback)
SDX_PREFIXES="$OYG_ROOT/sdx.prefixes"

# serviceNames sent nowhere: the union of the enabled options' gateway names
# (etc/options.sh), set by the engine before it calls res_sdx_apply. Anything
# not listed keeps its LG host.
SDX_BLOCK=${SDX_BLOCK:-}
# serviceNames never blocked, preferred for learning the host prefix sdx puts
# in front of each domain type (the country code, the regional code)
SDX_PROBE_default="sdp_common sdp_init sdp_auth"
SDX_PROBE_ric="service_setting_secure wise_account cpauth_secure"

# group|serviceName|domainType|domain for every entry of a flattened table,
# whatever the key order and whitespace.
SDX_PARSE='
function val(o, k,   m) {
    if (match(o, "\"" k "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
        m = substr(o, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*"/, "", m); sub(/"$/, "", m); return m
    }
    return ""
}
{
    s = $0
    while (1) {
        g = match(s, /"[^"]*"[[:space:]]*:[[:space:]]*\[/); gs = RSTART; gl = RLENGTH
        o = match(s, /\{[^{}]*\}/); os = RSTART; ol = RLENGTH
        if (!g && !o) break
        if (g && (!o || gs < os)) { grp = substr(s, gs + 1); sub(/".*/, "", grp); s = substr(s, gs + gl); continue }
        e = substr(s, os, ol); s = substr(s, os + ol); sn = val(e, "serviceName")
        if (sn != "") print grp "|" sn "|" val(e, "domainType") "|" val(e, "domain")
    }
}'
# Rewrite the "domain" of every entry whose serviceName is in BLOCK; entries
# are the innermost {...} objects of the flattened table.
SDX_AWK='
BEGIN { n = split(BLOCK, b, " "); for (i = 1; i <= n; i++) blk[b[i]] = 1 }
{
    s = $0; out = ""
    while (match(s, /\{[^{}]*\}/)) {
        st = RSTART; ln = RLENGTH; o = substr(s, st, ln)
        if (match(o, /"serviceName"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
            sn = substr(o, RSTART, RLENGTH); sub(/.*:[[:space:]]*"/, "", sn); sub(/"$/, "", sn)
            if (sn in blk) sub(/"domain"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"domain\": \"" SINK "\"", o)
        }
        out = out substr(s, 1, st - 1) o; s = substr(s, st + ln)
    }
    print out s
}'

sdx_block_list() { printf '%s\n' $SDX_BLOCK; }
sdx_blocked() { case " $(printf '%s' "$SDX_BLOCK" | tr '\n' ' ') " in *" $1 "*) return 0;; esac; return 1; }
sdx_entries() { tr -d '\r\n' < "$1" | awk "$SDX_PARSE"; }
sdx_url() {  # sdx_url <serviceName> → the baseUrl sdx uses now (its reply escapes "/")
    luna luna://com.webos.service.sdx/getServerUrl "{\"serviceName\":\"$1\"}" \
        | sed -n 's/.*"baseUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | sed 's#\\/#/#g'
}
sdx_pid() { pids_of_exe "$SDX_BIN" | awk '{print $1}'; }
# ls-hubd starts sdx again on the next call; make that call
sdx_restart() {
    kill_pids sdx $(pids_of_exe "$SDX_BIN")
    [ "$OYG_DRYRUN" = 1 ] && return 0
    _i=0; while [ $_i -lt 10 ]; do [ -n "$(sdx_url sdp_common)" ] && return 0; sleep 1; _i=$((_i+1)); done
    warn "sdx did not answer after restart"
}

# A never-blocked serviceName of a domain type, present in the table.
sdx_probe() {  # sdx_probe default|ric
    _e=$(sdx_entries "$SDX_TABLE")
    for _s in $(eval "printf '%s ' \$SDX_PROBE_$1") $(printf '%s\n' "$_e" | awk -F'|' -v t="$1" '$3 == t { print $2 }'); do
        sdx_blocked "$_s" && continue
        printf '%s\n' "$_e" | awk -F'|' -v s="$_s" -v t="$1" '$2 == s && $3 == t { f = 1 } END { exit !f }' && { printf '%s' "$_s"; return 0; }
    done
    return 1
}
# "<prefix> <group>": the prefix sdx puts in front of a domain type's hosts,
# read from the URL it reports for a never-blocked name, and the table group
# whose domain that URL ends with (webOS 11 also carries the China group)
sdx_prefix_live() {  # sdx_prefix_live default|ric
    _sn=$(sdx_probe "$1") || return 1
    # a just-restarted sdx can answer empty for a moment
    _i=0; _host=""
    while [ $_i -lt 5 ] && [ -z "$_host" ]; do
        _host=$(sdx_url "$_sn" | sed 's#^[a-z]*://##; s#/.*##; s#:.*##')
        [ -n "$_host" ] || { [ "$OYG_DRYRUN" = 1 ] && break; sleep 1; }; _i=$((_i+1))
    done
    [ -n "$_host" ] || return 1
    sdx_entries "$SDX_TABLE" | awk -F'|' -v s="$_sn" -v h="$_host" '
        $2 == s { d = "." $4; if (length(h) > length(d) && substr(h, length(h) - length(d) + 1) == d) { print substr(h, 1, length(h) - length(d)), $1; exit } }'
}
sdx_known() {  # sdx_known default|ric|group
    _v=$(sed -n "s/^$1=//p" "$SDX_PREFIXES" 2>/dev/null | head -1)
    if [ -z "$_v" ]; then
        case $1 in group) _k=group ;; *) _k=prefix_$1 ;; esac
        _v=$(sed -n "s/^$_k=//p" "$OYG_STATE/kv.sdx" 2>/dev/null | head -1)
    fi
    printf '%s' "$_v"
}
sdx_prefix() { sdx_known "$1"; }
sdx_learn_prefixes() {
    _pf=""; _g=""
    for _ty in default ric; do
        set -- $(sdx_prefix_live "$_ty")
        if [ -n "${1:-}" ]; then _pf="$_pf$_ty=$1
"; [ -n "${2:-}" ] && _g=$2
        else warn "could not learn the sdx $_ty host prefix"; _p=$(sdx_known "$_ty"); [ -n "$_p" ] && _pf="$_pf$_ty=$_p
"; fi
    done
    _g=${_g:-$(sdx_known group)}; [ -n "$_g" ] && _pf="${_pf}group=$_g
"
    [ "$OYG_DRYRUN" = 1 ] || [ -z "$_pf" ] || printf '%s' "$_pf" > "$SDX_PREFIXES"
}

# Hostnames that only blocked serviceNames use, in the group this TV uses,
# with the prefixes sdx puts in front of them. The network module sinkholes
# these. Never the shared gateway hosts: sign-in and the clock live there.
sdx_blocked_hosts() {
    _t=$SDX_ORIG; [ -f "$_t" ] || _t=$SDX_TABLE; [ -f "$_t" ] || return 0
    # a prefix sdx has not told yet: every code LG uses (resources/network.sh)
    _pd=$(sdx_known default); _pr=$(sdx_known ric); _g=$(sdx_known group)
    [ -n "$_pd" ] || _pd=$(lg_countries | tr '\n' ' ')
    [ -n "$_pr" ] || _pr=$OYG_RICS
    sdx_entries "$_t" | awk -F'|' -v BLOCK="$SDX_BLOCK" -v pd="$_pd" -v pr="$_pr" -v g="$_g" '
        BEGIN { n = split(BLOCK, b, " "); for (i = 1; i <= n; i++) blk[b[i]] = 1; nd = split(pd, d, " "); nr = split(pr, r, " ") }
        g != "" && $1 != g { next }
        { if ($3 == "default") { m = nd; for (i = 1; i <= m; i++) p[i] = d[i] } else { m = nr; for (i = 1; i <= m; i++) p[i] = r[i] }
          for (i = 1; i <= m; i++) { h = p[i] "." $4; if ($2 in blk) bh[h] = 1; else kh[h] = 1 } }
        END { for (h in bh) if (!(h in kh)) print h }' \
    | grep -viE '^([^.]+\.)?(tv\.wiselg\.(com|cn)|nextlgsdp\.com|lgtvsdp\.com)$|^lgtvonline\.lge\.com$|ngfts\.lge\.com$' | sort
}

# The rewrite must keep every entry, change only the domains of blocked names
# and still be JSON.
sdx_validate() {  # sdx_validate <LG's table> <rewritten>
    _a=$(oyg_tmp sdx.a); _b=$(oyg_tmp sdx.b)
    sdx_entries "$1" > "$_a"; sdx_entries "$2" > "$_b"
    [ -s "$_a" ] && [ "$(wc -l < "$_a")" = "$(wc -l < "$_b")" ] || return 1
    grep -q "\"$SDX_SINK\"" "$2" || return 1
    paste -d'#' "$_a" "$_b" | awk -F'#' -v BLOCK="$SDX_BLOCK" -v SINK="$SDX_SINK" '
        BEGIN { n = split(BLOCK, b, " "); for (i = 1; i <= n; i++) blk[b[i]] = 1 }
        { split($1, x, "|"); split($2, y, "|")
          if (x[1] != y[1] || x[2] != y[2] || x[3] != y[3]) bad = 1
          else if (x[2] in blk) { if (y[4] != SINK) bad = 1 }
          else if (x[4] != y[4]) bad = 1 }
        END { exit bad }' || return 1
    if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$2" 2>/dev/null || return 1; fi
    return 0
}

res_sdx_apply() {
    [ -f "$SDX_TABLE" ] || { info "sdx routing table not on this TV"; return 0; }
    # the prefixes come from services that are never blocked, so the running
    # sdx reports them whatever table it has; learn them while it is up
    sdx_learn_prefixes
    # LG's table: the live file, or the copy taken when we first bound it
    _bound=0; is_mounted "$SDX_TABLE" && state_has mounts "$SDX_TABLE" && [ -f "$SDX_ORIG" ] && _bound=1
    if [ $_bound = 1 ]; then _src=$SDX_ORIG; else _src=$SDX_TABLE; fi
    _all=$(sdx_entries "$_src" | wc -l | tr -d ' ')
    [ "$_all" -gt 0 ] || { fail "sdx routing table not understood"; return 1; }
    _nb=0; [ -n "$(printf '%s' "$SDX_BLOCK" | tr -d ' \n')" ] && _nb=$(sdx_entries "$_src" | cut -d'|' -f2 | grep -cxF "$(sdx_block_list)")
    if [ "$_nb" = 0 ]; then
        info "none of the enabled options' gateway names are in this TV's table"
        [ $_bound = 1 ] && res_sdx_restore
        return 0
    fi
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) route $_nb of $_all sdx services to $SDX_SINK"; return 0; fi
    [ $_bound = 1 ] || cp "$SDX_TABLE" "$SDX_ORIG"
    tr -d '\r\n' < "$SDX_ORIG" | awk -v BLOCK="$SDX_BLOCK" -v SINK="$SDX_SINK" "$SDX_AWK" > "$SDX_GEN.new"
    if ! sdx_validate "$SDX_ORIG" "$SDX_GEN.new"; then
        rm -f "$SDX_GEN.new"; fail "rewritten sdx table failed its check; left LG's table in place"; return 1
    fi
    _changed=1
    if [ $_bound = 1 ] && [ "$(md5sum < "$SDX_GEN.new")" = "$(md5sum < "$SDX_GEN" 2>/dev/null)" ] && [ "$(md5sum < "$SDX_TABLE" | cut -d' ' -f1)" = "$(kv_get gen_md5)" ]; then
        _changed=0; rm -f "$SDX_GEN.new"
        ro_ok "$SDX_GEN" || bind_file_ro "$SDX_GEN" "$SDX_TABLE"
    else
        mv "$SDX_GEN.new" "$SDX_GEN"
        bind_file_ro "$SDX_GEN" "$SDX_TABLE" || { is_mounted "$SDX_TABLE" || { fail "could not bind the sdx table"; return 1; }; }
        kv_set gen_md5 "$(md5sum < "$SDX_GEN" | cut -d' ' -f1)"
    fi
    kv_set check "$(sdx_entries "$SDX_GEN" | awk -F'|' -v s="$SDX_SINK" '$4 == s { print $2; exit }')"
    kv_set applied 1
    # sdx reads the table when it starts. At boot, accountmanager checks the
    # terms status through sdx and a failed check raises the LG account
    # prompt, so the restart waits for the boot to finish, in the background.
    if [ $_changed = 0 ] && sdx_routes_ok; then ok "$_nb of $_all sdx services already routed to nowhere"; return 0; fi
    if [ "${OYG_BOOT:-0}" = 1 ] && ! boot_done; then
        ( oyg_detach_env sdx; wait_boot_done; sdx_restart; sdx_routes_ok || log "  warn  sdx still reports its old routes" ) </dev/null >/dev/null 2>&1 &
        ok "$_nb of $_all sdx services routed to nowhere (sdx restarts once the boot is done)"
        return 0
    fi
    sdx_restart
    if sdx_routes_ok; then ok "$_nb of $_all sdx services routed to nowhere"; else warn "sdx still reports its old route for $(kv_get check)"; fi
}
# a blocked name sdx should now route to the sink (recorded at apply; state
# from 1.2.x has none)
sdx_routes_ok() { _c=$(kv_get check); case $(sdx_url "${_c:-sdp_logging}") in *"$SDX_SINK"*) true;; *) false;; esac; }

res_sdx_restore() {
    _was=0; is_mounted "$SDX_TABLE" && state_has mounts "$SDX_TABLE" && _was=1
    generic_restore
    unbind_src "$SDX_GEN"
    [ "$OYG_DRYRUN" = 1 ] || rm -f "$SDX_GEN" "$SDX_ORIG" "$SDX_OKF"
    [ $_was = 1 ] && sdx_restart
    # web apps that reached the placeholder hosts are on record in WAM's profile
    forget_origins; forget_files "$WAM_ORIGINS"
    return 0
}
res_sdx_status() {
    [ -f "$SDX_TABLE" ] || { st "$1" NA "no sdx routing table on this TV"; return 0; }
    if ! is_mounted "$SDX_TABLE" || ! grep -q "\"$SDX_SINK\"" "$SDX_TABLE" 2>/dev/null; then
        st "$1" WARN "routing table not rewritten"; return 1
    fi
    _r=0; _nb=$(grep -o "\"$SDX_SINK\"" "$SDX_TABLE" | wc -l | tr -d ' ')
    _gm=$(kv_get gen_md5)
    if [ -n "$_gm" ] && [ "$(md5sum < "$SDX_TABLE" | cut -d' ' -f1)" != "$_gm" ]; then st "$1" FAIL "LG rewrote the routing table under the bind (apply again)"; _r=1; fi
    _rw=$(rw_peers "$SDX_GEN" | head -1)
    [ -n "$_rw" ] && { st "$1" FAIL "routing table is writable at $_rw"; _r=1; }
    # ask sdx only when it restarted since the last good answer (a call
    # starts it when it is not running, so an idle sdx is left alone)
    _p=$(sdx_pid)
    if [ -z "$_p" ] || [ "$_p" = "$(cat "$SDX_OKF" 2>/dev/null)" ]; then st "$1" OK "$_nb LG endpoints routed to nowhere"
    elif sdx_routes_ok; then st "$1" OK "$_nb LG endpoints routed to nowhere"; [ "$OYG_DRYRUN" = 1 ] || printf '%s' "$_p" > "$SDX_OKF" 2>/dev/null
    else st "$1" WARN "table rewritten but sdx still uses its old routes"; _r=1; fi
    return $_r
}

# svc.sh — the one service-neutralising engine every module shares.
#
# A spec is a list of lines:   id|unit|binary|comm|argmatch|ls2|flags
#   unit      systemd unit (may be empty for luna-launched services)
#   binary    absolute path, or "?" = discover by comm name in the usual bin
#             dirs or from the unit's ExecStart, or empty = none
#   comm      process name to kill (kernel comm, first 15 chars). Never a
#             name many daemons share: every com.webos.service.* binary is
#             "com.webos.servi"
#   argmatch  substring of the cmdline to kill (JS scripts), optional
#   ls2       the service's first LS2 name, for LG's launch block list
#             (lib/blocklist.sh); only used when it is a dynamic service
#   flags     comma-separated:
#               u        loaded into the unified JS server (ss.gateway):
#                        nothing can kill it once loaded, only the block
#                        list keeps it from loading again
#               j=<id>   its jail, when the jail's name does not end with
#                        the binary's name
#               m        installed on /media/system: block by name, never
#                        bind (LG's package updates replace it)
#               L=<how>  the launch model the knowledge base expects
#                        (dynamic|static|unified|jailed)
# Lines with only the first five fields still parse.
#
# For each entry that exists on this TV: bind /dev/null over the binary and
# its jailed copies so nothing (systemd, ls-hubd, an activity) can exec it
# again, record its LS2 name for the block list, stop its unit (remembering
# whether it was active), and kill what is running. Entries that do not
# exist are skipped: the same spec runs unchanged across models.

svc_flags() {  # svc_flags <flags>: sets _fu _fm _fj _fL (no fork: status runs it per entry)
    _fu=""; _fm=""; _fj=""; _fL=""; _rest="$1,"
    while [ -n "$_rest" ]; do
        _f=${_rest%%,*}; _rest=${_rest#*,}
        case $_f in u) _fu=1 ;; m) _fm=1 ;; j=*) _fj=${_f#j=} ;; L=*) _fL=${_f#L=} ;; esac
    done
}

svc_resolve_bin() {  # svc_resolve_bin <unit> <binary> <comm>
    case $2 in
        "?") _b=""; [ -n "$3" ] && _b=$(find_bin "$3")
             if [ -z "$_b" ] && [ -n "$1" ]; then
                 _b=$(unit_exec "$1"); [ -n "$_b" ] && _b=$(canon "$_b")
                 bind_denied "$_b" && _b=""; case $_b in *.sh) _b="";; esac
             fi
             printf '%s' "$_b" ;;
        "")  ;;
        *)   if [ -e "$2" ]; then canon "$2"; else printf '%s' "$2"; fi ;;
    esac
}

# Some daemons run chrooted in /var/palm/jail/<id>, whose /usr is an overlay
# of the pristine /usr set up when the jail is: they exec their own copy of
# the binary, which a bind on /usr/... never reaches. The copy that matters
# is the one in the service's own jail, whose name ends with the binary's
# name (lg.thinqai.adapter, com.webos.service.voice.performer) unless the
# spec names it (j=). A jail set up after apply is not covered by a bind;
# for dynamic services the block list is what stops it.
svc_jail_bins() {  # svc_jail_bins <binary> [<jail id>] → the jailed copies to bind
    [ -d /var/palm/jail ] || return 0
    if [ -n "${2:-}" ]; then [ -e "/var/palm/jail/$2$1" ] && printf '%s\n' "/var/palm/jail/$2$1"; return 0; fi
    _b=${1##*/}; _n=$(printf '%s' "$_b" | tr '-' '.')   # amazon-alexa-adapter → jail amazon.alexa.adapter
    for _j in /var/palm/jail/*; do
        case ${_j##*/} in *"$_n"|*"$_b") [ -e "$_j$1" ] && printf '%s\n' "$_j$1";; esac
    done
}

# One awk over (resolved spec, process snapshot): "id pid" for every running
# process an entry matches, by executable (or its jailed copy), comm or
# command line. Replaces an awk per entry and lookup.
svc_match() {  # svc_match <resolved spec: id|bin|comm|arg>
    [ -s "$1" ] || return 0
    [ -s "$OYG_PSF" ] || ps_snapshot
    awk -v self="$$" '
        FNR == NR { split($0, s, "|"); n++; id[n] = s[1]; b[n] = s[2]; c[n] = substr(s[3], 1, 15); a[n] = s[4]; next }
        { split($0, f, "\t"); if (f[1] == self) next
          x = f[3]; j = x; sub(/^\/var\/palm\/jail\/[^\/]+/, "", j)
          if (x == "") { x = f[4]; sub(/ .*/, "", x) }
          for (i = 1; i <= n; i++)
              if ((b[i] != "" && (x == b[i] || j == b[i])) || (c[i] != "" && f[2] == c[i]) || (a[i] != "" && index(f[4], a[i])))
                  print id[i], f[1] }' "$1" "$OYG_PSF"
}

# The unified JS server: a shell wrapper running run-unified-service-server
# (its node child is "ss.gateway"). At apply we ask it which services it has
# loaded; while its pid is unchanged, those stay resident.
unified_pid() { _ps | awk -F'\t' 'index($4, "run-unified-service-server") { print $1; exit }'; }
unified_loaded() {  # the service directories the unified server has loaded now
    luna luna://com.webos.service.jsserver/infoServices '{}' | sed 's#\\/#/#g' | sed -n 's#.*"filename"[[:space:]]*:[[:space:]]*"\(.*\)/[^/]*".*#\1#p' | sort -u
}

# A daemon that crashed on the way down leaves a crash trigger in librdx
# (named <program>__…) that rdxd would upload once telemetry runs again.
svc_drop_triggers() {  # svc_drop_triggers <names file> [<newer-than file>]
    [ "$OYG_DRYRUN" = 1 ] && return 0
    [ -s "$1" ] || return 0
    for _d in /var/log/reports/librdx /tmp/var/log/reports/librdx; do
        [ -d "$_d" ] || continue
        if [ -n "${2:-}" ]; then find "$_d" -type f -newer "$2" 2>/dev/null; else find "$_d" -type f 2>/dev/null; fi | while read -r _f; do
            _c=${_f##*/}; _c=${_c%%__*}
            grep -qxF -- "$_c" "$1" && rm -f "$_f" && info "dropped crash report trigger ${_f##*/}"
        done
    done
}

# On a webOS generation the knowledge base has not seen (OYG_STRICT=1), an
# entry is applied only when it is recognisably the same thing: found by its
# own name rather than through a unit, and registered with the launch model
# the knowledge base expects. Prints why an entry is left alone.
svc_strict_why() {  # svc_strict_why <unit> <binary field> <comm> <ls2> <expected launch model>
    if [ "$2" = "?" ] && [ -n "$3" ] && [ -n "$1" ] && ! find_bin "$3" >/dev/null && have_unit "$1"; then echo "found only through its unit"; return; fi
    [ -n "$4" ] && [ -n "$5" ] && ls2_known "$4" || return 0
    awk -F'\t' -v n="$4" -v want="$5" '$1 == n {
        m = ($3 ~ /jailer/) ? "jailed" : ($3 ~ /run-js-service/ && $3 ~ / -u( |$)/) ? "unified" : ($2 == "static") ? "static" : "dynamic"
        if (m != want) print "registered as " m ", expected " want; exit }' "$(_ls2_idx)"
}

svc_apply() {  # spec on stdin
    _n=0; _res=$(oyg_tmp svc.res); _units=$(oyg_tmp svc.units); _names=$(oyg_tmp svc.names); _stamp=$(oyg_tmp svc.stamp); _jsl=""
    _dyn=$(oyg_tmp svc.dyn)
    : > "$_res"; : > "$_units"; : > "$_names"; : > "$_stamp"; : > "$_dyn"
    ps_snapshot
    [ "$OYG_DRYRUN" = 1 ] || ls2_index_build
    # 1. bind and record, entry by entry
    while IFS='|' read -r id unit bin comm arg ls2 flags; do
        [ -n "$id" ] || continue; case $id in \#*) continue;; esac
        svc_flags "$flags"; _u=$_fu; _m=$_fm
        if [ "${OYG_STRICT:-0}" = 1 ]; then
            _why=$(svc_strict_why "$unit" "$bin" "$comm" "$ls2" "$_fL")
            if [ -n "$_why" ]; then info "$id: left alone on unrecognised firmware ($_why)"; continue; fi
        fi
        # a static service is one other daemons call and wait for (a stopped
        # nudge held its callers 15 s, a bound voiceconductor for ever): on a
        # release Own Your Glass has only seen as firmware, it is left running
        if static_skipped "$_fL"; then info "$id: a static service, left running on a webOS release Own Your Glass has not run on (Untested protections includes it)"; continue; fi
        bin=$(svc_resolve_bin "$unit" "$bin" "$comm")
        present=0
        if [ -n "$unit" ] && have_unit "$unit"; then present=1; printf '%s\n' "$unit" >> "$_units"; fi
        _refused=0
        if [ -n "$bin" ] && [ -e "$bin" ]; then
            present=1
            if [ -z "$_m" ]; then
                if ! bind_null "$bin"; then
                    if bind_denied "$bin" || bind_denied "$(canon "$bin")"; then _refused=1; fi
                fi
                for _jb in $(svc_jail_bins "$bin" "$_fj"); do bind_null "$_jb"; done
            fi
        fi
        if [ -n "$ls2" ] && ls2_known "$ls2"; then
            present=1
            if ls2_blockable "$ls2"; then state_add ls2 "$ls2"; [ "$OYG_DRYRUN" = 1 ] && printf '%s\n' "$ls2" >> "$(oyg_tmp dry.ls2)"; fi
        fi
        # a unified service is never killed by command line: the one process
        # that could match is the server hosting SSAP and Settings' services
        [ -n "$_u" ] && arg=""
        printf '%s|%s|%s|%s\n' "$id" "$bin" "$comm" "$arg" >> "$_res"
        [ -n "$ls2" ] && [ "$_fL" = dynamic ] && printf '%s %s\n' "$id" "$ls2" >> "$_dyn"
        { [ -n "$comm" ] && printf '%s\n' "$comm"; [ -n "$bin" ] && printf '%s\n' "${bin##*/}"; } >> "$_names"
        if [ $_refused = 1 ]; then warn "$id: left running (on the never-touch list outside Lockdown)"
        elif [ $present = 1 ]; then ok "$id neutralised${bin:+ ($bin)}"; _n=$((_n+1)); else info "$id: not on this TV"; fi
        # a unified service that is loaded now stays loaded until the server
        # restarts: remember that (and the server's pid) for status
        if [ -n "$_u" ] && [ $present = 1 ]; then
            [ -n "$_jsl" ] || _jsl=$(unified_loaded; echo .)
            kv_set unified_pid "$(unified_pid)"
            if [ -n "$bin" ] && printf '%s\n' "$_jsl" | grep -qxF "${bin%/*}"; then kv_set "resident.$id" 1; warn "$id is loaded in the shared JS server: blocked for new loads, it stays until the TV restarts"
            else kv_set "resident.$id" ""; fi
        fi
    done
    # 2. units: one is-active for all of them, one stop for the active ones.
    #    --no-block: a unit that ignores SIGTERM would otherwise hold us for
    #    its stop timeout (90 s); we kill the process ourselves right after.
    if [ -s "$_units" ]; then
        _ul=$(sort -u "$_units" | tr '\n' ' ')
        # shellcheck disable=SC2086
        _act=$(systemctl is-active $_ul 2>/dev/null | tr '\n' ' ')
        _stop=""; set -- $_ul
        for _a in $_act; do
            [ $# -gt 0 ] || break
            [ "$_a" = active ] && { state_add units "$1"; _stop="$_stop $1"; }
            mask_unit "$1"; shift
        done
        [ -n "$_stop" ] && run "systemctl stop$_stop" systemctl --no-block stop $_stop
    fi
    # 3. one kill pass for the whole spec: TERM everything, wait once, KILL survivors
    _hits=$(svc_match "$_res")
    [ -n "$_hits" ] && printf '%s\n' "$_hits" | svc_hit_units
    # an on-demand service we stop was running for a reason: restore calls it
    # once so the bus starts it again (nothing else may, C5: iconnectivity)
    [ -n "$_hits" ] && printf '%s\n' "$_hits" | while read -r _hi _hp; do
        awk -v i="$_hi" '$1 == i { print $2 }' "$_dyn"; done | sort -u | while read -r _dn; do state_add relaunch "$_dn"; done
    if [ -n "$_hits" ]; then
        kill_pids "$(printf '%s\n' "$_hits" | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')" $(printf '%s\n' "$_hits" | awk '{print $2}')
    fi
    # 4. a stopped unit whose process we killed is left "failed"
    _su=$(state_list units | tr '\n' ' ')
    [ -n "$_su" ] && [ "$OYG_DRYRUN" != 1 ] && systemctl reset-failed $_su >/dev/null 2>&1
    svc_drop_triggers "$_names" "$_stamp"
    daemon_reload_if_needed
    kv_set applied 1
    kv_set count "$_n"
}

# svc_hit_units — a process systemd runs under a unit the spec does not name
# would stay dead after restore (we kill it; systemd does not start it
# again): record that unit, so restore starts it, when the unit's ExecStart
# is the process's own executable.
svc_hit_units() {  # "id pid" lines on stdin
    while read -r _hi _hp; do
        _hu=$(sed -n 's#.*/\([^/]*\.service\)$#\1#p' "$OYG_PROC/$_hp/cgroup" 2>/dev/null | head -1)
        [ -n "$_hu" ] && ! state_has units "$_hu" || continue
        _he=$(awk -F'\t' -v p="$_hp" '$1 == p { print $3; exit }' "$OYG_PSF")
        _hx=$(unit_exec "$_hu")
        [ -n "$_hx" ] && [ -n "$_he" ] && [ "$(canon "$_hx")" = "$(canon "$_he")" ] && state_add units "$_hu"
    done
    return 0
}

# svc_restore — generic_restore, first dropping any pending crash triggers of
# the daemons we had stopped, so rdxd does not upload our teardown.
svc_restore() {  # spec on stdin
    _names=$(oyg_tmp svc.names); : > "$_names"
    while IFS='|' read -r id unit bin comm arg ls2 flags; do
        [ -n "$id" ] || continue; case $id in \#*) continue;; esac
        [ -n "$comm" ] && printf '%s\n' "$comm" >> "$_names"
        case $bin in /*) printf '%s\n' "${bin##*/}" >> "$_names";; esac
    done
    svc_drop_triggers "$_names"
    # off the launch block list before any daemon starts again: a daemon we
    # restart may call its services at once (Cast's provisioning starts its
    # receiver on start-up and gives up when the bus refuses)
    if [ -n "$(state_list ls2)" ]; then state_drop ls2; blocklist_sync; fi
    generic_restore
}

# svc_release — undo what an earlier version did to entries the spec no
# longer has (spec lines as they were): unbind their binaries and jailed
# copies wherever they were recorded, drop their LS2 names and start their
# units again if we had stopped them.
svc_release() {  # old spec lines on stdin
    _rl=$(oyg_tmp svc.release); : > "$_rl"; _rdrop=""
    while IFS='|' read -r id unit bin comm arg ls2 flags; do
        [ -n "$id" ] || continue; case $id in \#*) continue;; esac
        # an explicit path is matched exactly (index.js is not unique); a
        # discovered one by its name, jailed copies included
        case $bin in /*) _re="^\(/var/palm/jail/[^/]*\)\{0,1\}$bin\$" ;; *) [ -n "$comm" ] && _re="/$comm\$" || _re="^$" ;; esac
        _hit=""
        for _p in $(state_list mounts | grep -e "$_re"); do unbind "$_p"; _hit=1; done
        [ -n "$ls2" ] && state_has ls2 "$ls2" && { state_del ls2 "$ls2"; _hit=1; _rdrop=1; }
        if [ -n "$unit" ] && state_has units "$unit"; then printf '%s\n' "$unit" >> "$_rl"; _hit=1; fi
        [ -n "$_hit" ] && ok "$id released (no longer blocked)"
    done
    # the names leave the block list before their daemons start again
    [ -n "$_rdrop" ] && blocklist_sync
    while read -r _ru; do
        run "systemctl start $_ru" systemctl start "$_ru"; state_del units "$_ru"
    done < "$_rl"
    return 0
}

# status never calls systemctl or luna: it checks binds, the block list and
# the process table. Levels: OK blocked, NA not on this TV, FAIL running,
# WARN stopped but startable, RESIDENT loaded into the unified JS server
# before apply (it stays until the TV restarts; nothing new can load),
# SKIP a static service left running on a release not yet run on a TV.
svc_status() {  # svc_status <MODULE> ; spec on stdin
    _m=$1; _bad=0; _res=$(oyg_tmp st.res); _inf=$(oyg_tmp st.info); : > "$_res"; : > "$_inf"
    [ -s "$OYG_PSF" ] || ps_snapshot
    _upid=$(unified_pid); _apid=$(kv_get unified_pid)
    while IFS='|' read -r id unit bin comm arg ls2 flags; do
        [ -n "$id" ] || continue; case $id in \#*) continue;; esac
        case $bin in
            "?") _c=$comm; bin=$(state_list mounts | grep -v '^/var/palm/jail/' | grep "/$_c\$" | head -1)
                 [ -z "$bin" ] && [ -n "$comm" ] && bin=$(find_bin "$comm")
                 [ -z "$bin" ] && [ -n "$unit" ] && bin=$(unit_exec "$unit") ;;
            /*)  [ -e "$bin" ] && bin=$(canon "$bin") ;;
        esac
        [ -n "$bin" ] && [ ! -e "$bin" ] && bin=""
        svc_flags "$flags"; _u=$_fu; _mf=$_fm
        if static_skipped "$_fL"; then printf '%s|skip|0|0|\n' "$id" >> "$_inf"; continue; fi
        [ -n "$_u" ] && arg=""
        _listed=0; [ -n "$ls2" ] && blocklist_listed "$ls2" && _listed=1
        present=0; [ -n "$bin" ] && present=1
        [ -n "$ls2" ] && [ $present = 0 ] && ls2_known "$ls2" && present=1
        [ -n "$unit" ] && [ $present = 0 ] && have_unit "$unit" && present=1
        # bound = every copy that can be exec'd is covered by a bind or by name
        bound=0
        if [ $_listed = 1 ]; then bound=1
        elif [ -n "$bin" ] && [ -z "$_mf" ] && is_mounted "$bin"; then
            bound=1; for _jb in $(svc_jail_bins "$bin" "$_fj"); do is_mounted "$_jb" || bound=0; done
        fi
        printf '%s|%s|%s|%s\n' "$id" "$bin" "$comm" "$arg" >> "$_res"
        printf '%s|%s|%s|%s|%s\n' "$id" "$present" "$bound" "${_u:-0}" "$bin" >> "$_inf"
    done
    _alive=$(svc_match "$_res" | awk '{print $1}' | sort -u)
    while IFS='|' read -r id present bound uni bin; do
        if printf '%s\n' "$_alive" | grep -qxF -- "$id"; then st "$_m" FAIL "$id is running"; _bad=1
        elif [ "$present" = skip ]; then st "$_m" SKIP "$id left running: Own Your Glass has not run on this webOS release (Untested protections includes it)"
        elif [ "$present" = 0 ]; then st "$_m" NA "$id not on this TV"
        elif [ "$uni" = 1 ] && [ -n "$_apid" ] && [ "$_upid" = "$_apid" ] && [ "$(kv_get "resident.$id")" = 1 ]; then st "$_m" RESIDENT "$id loaded before Own Your Glass ran: blocked for new loads, it stays until the TV restarts"
        elif [ "$bound" = 0 ]; then st "$_m" WARN "$id stopped but not blocked${bin:+ ($bin or a jailed copy)}"
        else st "$_m" OK "$id blocked"; fi
    done < "$_inf"
    return $_bad
}

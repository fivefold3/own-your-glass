# svc.sh — the one service-neutralising engine every module shares.
#
# A spec is a list of lines:   id|unit|binary|comm|argmatch
#   unit      systemd unit (may be empty for luna-launched services)
#   binary    absolute path, or "?" = discover from the unit's ExecStart or
#             from the usual bin dirs by comm name, or empty = none
#   comm      process name to kill (kernel comm, first 15 chars)
#   argmatch  substring of the cmdline to kill (node/iotjs scripts), optional
#
# For each entry that exists on this TV:  stop the unit (remembering whether
# it was active), mask it (opt-in), bind /dev/null over the binary so nothing
# — systemd, ls-hubd or an activity — can start it again, and kill what is
# running. Entries that do not exist are skipped silently: the same spec runs
# unchanged across models: whatever is not there is skipped.

svc_resolve_bin() {  # svc_resolve_bin <unit> <binary> <comm>
    case $2 in
        "?") _b=""; [ -n "$3" ] && _b=$(find_bin "$3")
             if [ -z "$_b" ] && [ -n "$1" ]; then _b=$(unit_exec "$1"); bind_denied "$_b" && _b=""; case $_b in *.sh) _b="";; esac; fi
             printf '%s' "$_b" ;;
        *)   printf '%s' "$2" ;;
    esac
}

svc_apply() {  # spec on stdin
    _n=0; _pids=""; _ids=""
    ps_snapshot
    while IFS='|' read -r id unit bin comm arg; do
        [ -n "$id" ] || continue; case $id in \#*) continue;; esac
        bin=$(svc_resolve_bin "$unit" "$bin" "$comm")
        present=0
        if [ -n "$unit" ] && have_unit "$unit"; then
            present=1; stop_unit "$unit"; mask_unit "$unit"
        fi
        if [ -n "$bin" ] && [ -e "$bin" ]; then present=1; bind_null "$bin"; fi
        _p="$( [ -n "$bin" ] && pids_of_exe "$bin") $( [ -n "$comm" ] && pids_of "$comm") $( [ -n "$arg" ] && pids_of_arg "$arg")"
        if [ -n "$(printf '%s' "$_p" | tr -d ' ')" ]; then _pids="$_pids $_p"; _ids="$_ids $id"; fi
        if [ $present = 1 ]; then ok "$id neutralised${bin:+ ($bin)}"; _n=$((_n+1)); else info "$id: not on this TV"; fi
    done
    # one kill pass for the whole spec: TERM everything, wait once, KILL survivors
    kill_pids "$(printf '%s' "$_ids" | sed 's/^ //')" $_pids
    daemon_reload_if_needed
    kv_set applied 1
    kv_set count "$_n"
}

# status never calls systemctl: it checks the binds and the process table.
svc_status() {  # svc_status <MODULE> ; spec on stdin
    _m=$1; _bad=0; _seen=0; _off=0
    while IFS='|' read -r id unit bin comm arg; do
        [ -n "$id" ] || continue; case $id in \#*) continue;; esac
        case $bin in "?") bin=$(state_list mounts | grep "/$comm\$" | head -1); [ -z "$bin" ] && [ -n "$comm" ] && bin=$(find_bin "$comm");; esac
        [ -n "$bin" ] && [ ! -e "$bin" ] && bin=""
        alive=0
        [ -n "$bin" ] && running_exe "$bin" && alive=1
        [ -n "$comm" ] && running "$comm" && alive=1
        [ -n "$arg" ] && [ -n "$(pids_of_arg "$arg" | tr -d ' ')" ] && alive=1
        bound=0; [ -n "$bin" ] && is_mounted "$bin" && bound=1
        if [ -z "$bin" ] && [ $alive = 0 ]; then continue; fi   # not on this TV
        _seen=$((_seen+1))
        if [ $alive = 1 ]; then st "$_m" FAIL "$id is running"; _bad=1
        elif [ -n "$bin" ] && [ $bound = 0 ]; then st "$_m" WARN "$id stopped but not blocked ($bin)"; _off=$((_off+1))
        else st "$_m" OK "$id blocked"; fi
    done
    [ $_seen = 0 ] && st "$_m" NA "nothing matching on this TV"
    return $_bad
}

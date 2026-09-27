# options.sh — the option engine.
#
# What the owner selects is a preset (Recommended, Strict, Lockdown) or their
# one Custom set; etc/options.sh (generated from the knowledge base) says what
# each option contains. An option is also a state scope (OYG_MOD): every
# change it makes is recorded under its name, so restoring it needs nothing
# but the records. Its contents:
#   spec       services (lib/svc.sh), and released = what it no longer blocks
#   settings   system settings (lib/settings.sh)
#   hook       code for what is not declarative (hooks/<name>.sh)
#   sdx hosts apps   contributions to the shared resources below
# The resources are built from the union of the applied options' contributions
# and have their own scopes: blocklist (LG's launch block list), sdx (the
# gateway table), network (/etc/hosts), apps (the hidden-app list).
# Entries not yet verified on a TV (the _t lists) are left out unless
# $OYG_ROOT/untested exists or OYG_UNTESTED=1.

OYG_RESOURCES="blocklist sdx network apps"
PRESET_FILE="$OYG_ROOT/preset"
CUSTOM_FILE="$OYG_ROOT/custom"
UNTESTED_FILE="$OYG_ROOT/untested"

_ovar() { printf '%s' "$1" | tr '-' '_'; }
ov() { eval "printf '%s' \"\${OPT_$(_ovar "$1")_$2:-}\""; }      # ov <option> <field>
pv() { eval "printf '%s' \"\${PRESET_$1${2:+_$2}:-}\""; }         # pv <preset> [field]
is_option() { case " $OYG_OPTIONS " in *" $1 "*) return 0 ;; esac; return 1; }
is_preset() { case " $OYG_PRESETS " in *" $1 "*) return 0 ;; esac; return 1; }
untested_on() { [ -f "$UNTESTED_FILE" ] || [ "${OYG_UNTESTED:-0}" = 1 ]; }
# an option's content of one kind, with the untested entries while testing
oc() { ov "$1" "$2"; if untested_on; then printf '\n'; ov "$1" "${2}_t"; fi; }
_blank() { [ -z "$(printf '%s' "$1" | tr -d ' \n')" ]; }
uc() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }

# ------------------------------------------------------------- selection --
current_preset() {
    _p=$(cat "$PRESET_FILE" 2>/dev/null)
    if is_preset "$_p" || [ "$_p" = custom ]; then printf '%s' "$_p"; else printf recommended; fi
}
custom_base() { _b=$(sed -n 's/^base=//p' "$CUSTOM_FILE" 2>/dev/null | head -1); is_preset "$_b" && printf '%s' "$_b" || printf recommended; }
# the options on now, in catalogue order. Custom holds explicit choices over
# a base preset, so an option a later version adds follows that preset.
selected_options() {
    _p=$(current_preset)
    if [ "$_p" = custom ]; then
        _bl=" $(pv "$(custom_base)") "
        for _o in $OYG_OPTIONS; do
            case $(sed -n "s/^$_o=//p" "$CUSTOM_FILE" 2>/dev/null | head -1) in
                on) printf '%s\n' "$_o" ;;
                off) ;;
                *) case $_bl in *" $_o "*) printf '%s\n' "$_o" ;; esac ;;
            esac
        done
    else
        _bl=" $(pv "$_p") "
        for _o in $OYG_OPTIONS; do case $_bl in *" $_o "*) printf '%s\n' "$_o" ;; esac; done
    fi
}
opt_applied() { [ "$(sed -n 's/^applied=//p' "$OYG_STATE/kv.$1" 2>/dev/null | head -1)" = 1 ]; }
applied_options() { for _o in $OYG_OPTIONS; do opt_applied "$_o" && printf '%s\n' "$_o"; done; }
has_state() { for _x in "$OYG_STATE"/*."$1"; do [ -e "$_x" ] && return 0; done; return 1; }
# scopes with records: options, resources, and anything left by older versions
state_scopes() { ls "$OYG_STATE" 2>/dev/null | sed -n 's/^[a-z0-9]*\.//p' | sort -u; }
orphan_scopes() {
    for _s in $(state_scopes); do
        is_option "$_s" && continue
        case " $OYG_RESOURCES core " in *" $_s "*) continue ;; esac
        printf '%s\n' "$_s"
    done
}

# ------------------------------------------------------------ one option --
opt_settings_apply() {  # leaves OPT_SETTINGS_CHANGED: the keys it changed, for the hook
    OPT_SETTINGS_CHANGED=""
    _l=$(oc "$1" settings | grep '|')
    [ -n "$_l" ] || return 0
    for _c in $(printf '%s\n' "$_l" | cut -d'|' -f1 | sort -u); do
        _j=$(printf '%s\n' "$_l" | awk -F'|' -v c="$_c" '$1 == c { v = substr($0, length($1) + length($2) + 3); o = o (o == "" ? "" : ",") "\"" $2 "\":" v } END { print "{" o "}" }')
        SETTINGS_PAIRS=$(printf '%s\n' "$_l" | awk -F'|' -v c="$_c" '$1 == c { print substr($0, length($1) + 2) }')   # key|value, for the no-python path
        settings_apply "$_c" "$_j"
        OPT_SETTINGS_CHANGED="$OPT_SETTINGS_CHANGED $SETTINGS_CHANGED"
    done
}
opt_settings_restore() {
    for _c in $(sed -n 's/^settings\.\([^=]*\)=.*/\1/p' "$OYG_STATE/kv.$1" 2>/dev/null); do settings_restore "$_c"; done
}
opt_apply() {
    OYG_MOD=$1; oyg_init_dirs
    # soft-never paths only for an option that no preset but Lockdown carries
    case " $(ov "$1" presets) " in *" recommended "*|*" strict "*|"  ") OYG_SOFT_OK=0 ;; *) OYG_SOFT_OK=1 ;; esac
    head_ "$(ov "$1" name)"
    _s=$(oc "$1" spec)
    # The option's services changed since the last apply (untested entries
    # turned off, or a newer version dropped one): take its binds, launch
    # names and stopped units off first, so nothing it no longer lists stays
    # blocked. They are put back at once for what it still lists.
    _sig=$(printf '%s' "$_s" | md5sum | cut -d' ' -f1); _old=$(kv_get spec_md5)
    if [ -n "$_old" ] && [ "$_old" != "$_sig" ]; then
        info "this option's services changed: re-applying them"
        restore_mounts; restore_units; state_drop ls2
    fi
    _blank "$_s" || printf '%s\n' "$_s" | svc_apply
    kv_set spec_md5 "$_sig"
    _s=$(ov "$1" released); _blank "$_s" || printf '%s\n' "$_s" | svc_release
    opt_settings_apply "$1"
    _h=$(ov "$1" hook); [ -n "$_h" ] && "hook_${_h}_apply"
    kv_set applied 1
    OYG_MOD=core; OYG_SOFT_OK=0
}
# From the records alone: a scope no longer in the catalogue (an option a
# newer version renamed or dropped, a 1.4 module) is restored the same way.
opt_restore() {
    OYG_MOD=$1
    if is_option "$1"; then
        head_ "$(ov "$1" name): restoring"
        _h=$(ov "$1" hook); [ -n "$_h" ] && "hook_${_h}_restore"
        _s=$(oc "$1" spec)
    else head_ "$1: restoring (left by an earlier version)"; _s=""; fi
    opt_settings_restore "$1"
    eula_restore
    printf '%s\n' "$_s" | svc_restore
    OYG_MOD=core
}

# ------------------------------------------------------------- resources --
# a dry run applies nothing, so its preview follows the selection
_union_opts() { if [ "$OYG_DRYRUN" = 1 ]; then selected_options; else applied_options; fi; }
union() { for _o in $(_union_opts); do oc "$_o" "$1"; printf '\n'; done | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '; }
resources_sync() {
    _rom=$OYG_MOD
    blocklist_sync
    OYG_MOD=sdx; SDX_BLOCK=$(union sdx)
    if _blank "$SDX_BLOCK"; then [ -n "$(state_list mounts)" ] && res_sdx_restore; else res_sdx_apply; fi
    OYG_MOD=network; NET_HOSTS=$(union hosts); res_network_apply
    OYG_MOD=apps; APPS_IDS=$(union apps)
    if _blank "$APPS_IDS"; then [ -n "$(state_list files)$(state_list created)" ] && res_apps_restore; else res_apps_apply; fi
    OYG_MOD=$_rom
}

# Bring the TV to the selection: restore what is applied but no longer
# selected (and scopes older versions left), apply what is selected, then
# rebuild the shared resources.
# trials (oyg try): options applied without being selected, so the next
# apply, or the next boot, undoes them: the way out when a test breaks
TRIAL_FILE="$OYG_ROOT/trial"
trial_options() { [ -f "$TRIAL_FILE" ] && grep -v '^$' "$TRIAL_FILE"; return 0; }
trial_undo() {  # restore every trial that is not also selected
    for _to in $(trial_options); do selected_options | grep -qx "$_to" || opt_restore "$_to"; done
    [ "$OYG_DRYRUN" = 1 ] || rm -f "$TRIAL_FILE"
}
sync_selection() {
    _sel=" $(selected_options | tr '\n' ' ') "
    # every scope with records that is not selected: options turned off,
    # options that received 1.4 records, scopes older versions left
    for _s in $(state_scopes); do
        case " $OYG_RESOURCES core " in *" $_s "*) continue ;; esac
        case $_sel in *" $_s "*) ;; *) opt_restore "$_s" ;; esac
    done
    for _o in $_sel; do opt_apply "$_o"; done
    resources_sync
}

# ---------------------------------------------------------------- status --
# per option: its services and hook, then what it contributes to the shared
# resources, as far as those are in place
opt_status() {
    _U=$(uc "$1"); OYG_MOD=$1; _rc=0
    _s=$(oc "$1" spec); _blank "$_s" || { printf '%s\n' "$_s" | svc_status "$_U" || _rc=1; }
    _h=$(ov "$1" hook); [ -n "$_h" ] && { "hook_${_h}_status" "$_U" || _rc=1; }
    # gateway names count only when this TV's table has them
    _n=0
    if [ -f "$SDX_TABLE" ] && ! _blank "$(oc "$1" sdx)"; then
        _tn=$(oyg_tmp sdx.names); [ -s "$_tn" ] || { _t=$SDX_ORIG; [ -f "$_t" ] || _t=$SDX_TABLE; sdx_entries "$_t" | cut -d'|' -f2 | sort -u > "$_tn"; }
        _n=$(oc "$1" sdx | tr ' ' '\n' | grep -v '^$' | grep -cxF -f "$_tn")
    fi
    if [ "$_n" -gt 0 ]; then
        if is_mounted "$SDX_TABLE" && grep -q "\"$SDX_SINK\"" "$SDX_TABLE" 2>/dev/null; then st "$_U" OK "LG gateway routes cut ($_n names)"
        else st "$_U" WARN "LG gateway routes not cut"; _rc=1; fi
    fi
    _n=$(oc "$1" hosts | wc -w | tr -d ' ')
    if [ "$_n" -gt 0 ]; then
        if grep -q "^$HOSTS_MARK" /etc/hosts 2>/dev/null; then st "$_U" OK "hostnames sinkholed"; else st "$_U" WARN "hostnames not sinkholed"; _rc=1; fi
    fi
    _n=0; _h=0
    _af=$(sed -n 's/^file=//p' "$OYG_STATE/kv.apps" 2>/dev/null | head -1)
    for _a in $(oc "$1" apps); do app_exists "$_a" || continue; _n=$((_n+1)); grep -q "\"$_a\"" "$_af" 2>/dev/null && _h=$((_h+1)); done
    if [ $_n -gt 0 ]; then [ $_h = $_n ] && st "$_U" OK "$_n apps hidden" || { st "$_U" WARN "$_h of $_n apps hidden"; _rc=1; }; fi
    _sfail=$(sed -n 's/^settings_failed\.\([^=]*\)=1$/\1/p' "$OYG_STATE/kv.$1" 2>/dev/null | paste -sd, -)
    if [ -n "$_sfail" ]; then st "$_U" WARN "privacy settings could not be set ($_sfail): apply again"; _rc=1
    elif [ -n "$(sed -n 's/^settings\./&/p' "$OYG_STATE/kv.$1" 2>/dev/null)" ]; then st "$_U" OK "privacy settings set"; fi
    OYG_MOD=core
    return $_rc
}

# the catalogue the app shows (static; read once)
do_catalog() {
    for _c in $OYG_CATEGORIES; do
        printf 'CAT|%s|%s|%s\n' "$_c" "$(eval "printf '%s' \"\$CAT_$(_ovar "$_c")_title\"")" "$(eval "printf '%s' \"\$CAT_$(_ovar "$_c")_blurb\"")"
    done
    for _p in $OYG_PRESETS; do
        printf 'PRESET|%s|%s|%s|%s|%s\n' "$_p" "$(pv "$_p" name)" "$(pv "$_p" summary)" "$(pv "$_p" warning)" "$(pv "$_p")"
    done
    for _o in $OYG_OPTIONS; do
        printf 'OPT|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_o" "$(ov "$_o" category)" "$(ov "$_o" name)" "$(ov "$_o" what)" "$(ov "$_o" breaks)" "$(ov "$_o" presets)" "$(ov "$_o" warning)" "$(ov "$_o" untested)"
    done
}

# --------------------------------------------------- unknown firmware --
# On a webOS generation the knowledge base has not seen, apply only what is
# recognised: entries whose launch model and executable match (lib/svc.sh).
known_generation() { case " $OYG_KB_GENS " in *" $(webos_generation) "*) return 0 ;; esac; return 1; }
# a generation Own Your Glass has been run on (kb/services.toml run_on): only
# there are static services stopped (lib/svc.sh)
run_generation() { case " ${OYG_KB_RUN:-} " in *" $(webos_generation) "*) return 0 ;; esac; return 1; }
# a static entry is left alone on a release not run on, unless the owner
# turned Untested protections on (oyg untested on): then they are the first
# to try it, and the boot breaker is the net
static_skipped() { [ "${1:-}" = static ] && ! run_generation && ! untested_on; }

# ------------------------------------------------- migration from 1.4 --
# 1.4 kept its records per module (acr, telemetry, cloud…). Each record goes
# to the option that owns its path, unit, LS2 name or setting (etc/owners.txt
# from the knowledge base); what no option owns goes to "legacy", which the
# next sync restores (1.4 blocked it, the options do not). Nothing is undone
# and re-done on the way: flipping consents back even briefly could make
# eula-service report an acceptance to LG.
LEGACY_MODULES="nag acr telemetry remote voice mic capture consent apps cloud sdx network"
_owners_file() {
    if [ -f "$OYG_TK/etc/owners.txt" ]; then printf '%s' "$OYG_TK/etc/owners.txt"
    else _t=$(oyg_tmp owners); printf '%s\n' "${OWNERS_INLINE:-}" > "$_t"; printf '%s' "$_t"; fi
}
_owner_of() { awk -F'|' -v k="$1" -v n="$2" '$1 == k && $2 == n { print $3; exit }' "$_OWN"; }
migrate_owner() {  # migrate_owner <kind> <record> → option or resource
    _r=$2
    case $1 in
        mounts)
            case $_r in
                */sdp/sdx/server_addr_version.conf) echo sdx; return ;;
                /etc/hosts) echo network; return ;;
                */servicemanager/blocked-services.json) echo blocklist; return ;;
                /dev/snd/*|/var/palm/jail/*/dev/snd/*) echo mic; return ;;
                /tmp/capture.rgb|/usr/bin/vtCaptureTestSuite) echo capture; return ;;
            esac
            _q=$(printf '%s' "$_r" | sed 's#^/var/palm/jail/[^/]*##')
            _w=$(_owner_of bin "$_q"); [ -n "$_w" ] || _w=$(_owner_of comm "${_q##*/}")
            echo "${_w:-legacy}" ;;
        units) _w=$(_owner_of unit "$_r"); echo "${_w:-legacy}" ;;
        ls2) _w=$(_owner_of ls2 "$_r"); echo "${_w:-legacy}" ;;
        modes)
            case $_r in /dev/snd/*) echo mic ;; /tmp/capture.rgb*) echo capture ;; /media/developer*) echo remote-support ;; *) echo legacy ;; esac ;;
        files)
            case $_r in */blockedSystemAppList/*) echo apps ;; */eula-service/*) echo consents ;; /var/palm/jail/*/etc/hosts) echo network ;; *) echo legacy ;; esac ;;
        created)
            case $_r in */webosbrew_telnet_disabled) echo remote-support ;; /tmp/capture.rgb) echo capture ;; */blockedSystemAppList/*) echo apps ;; */servicemanager/*) echo blocklist ;; *) echo legacy ;; esac ;;
        moved) case $_r in *marketingAllowedDate*) echo consents ;; *) echo legacy ;; esac ;;
        *) echo legacy ;;
    esac
}
_kv_to() { _om=$OYG_MOD; OYG_MOD=$1; kv_set "$2" "$3"; OYG_MOD=$_om; }
migrate_kv() {  # migrate_kv <scope> <file>
    while IFS='=' read -r _k _v; do
        [ -n "$_k" ] || continue
        case $_k in
            settings.*)
                _c=${_k#settings.}
                if command -v python3 >/dev/null 2>&1; then
                    for _line in $(python3 -c 'import json,sys
d = json.loads(sys.argv[2]); own = {}
for l in open(sys.argv[3]):
    p = l.rstrip("\n").split("|")
    if len(p) == 3 and p[0] == "set" and p[1].startswith(sys.argv[1] + "."): own[p[1][len(sys.argv[1]) + 1:]] = p[2]
out = {}
for k, v in d.items(): out.setdefault(own.get(k, "legacy"), {})[k] = v
for o, v in out.items(): print(o + "=" + json.dumps(v, separators=(",", ":")))' "$_c" "$_v" "$_OWN" 2>/dev/null); do
                        _kv_to "${_line%%=*}" "$_k" "${_line#*=}"
                    done
                else
                    _first=$(printf '%s' "$_v" | sed -n 's/^{"\([^"]*\)".*/\1/p'); _w=$(_owner_of set "$_c.$_first")
                    _kv_to "${_w:-legacy}" "$_k" "$_v"
                fi ;;
            eula.flipped) case $1 in consent) _kv_to consents "$_k" "$_v" ;; nag) _kv_to terms "$_k" "$_v" ;; esac ;;
            resident.*) _w=$(_owner_of id "${_k#resident.}"); [ -n "$_w" ] && _kv_to "$_w" "$_k" "$_v" ;;
            unified_pid) for _w in thinq buddy-sports phone; do _kv_to "$_w" "$_k" "$_v"; done ;;
            applied|count) ;;
            *) case " $OYG_RESOURCES " in *" $1 "*) _kv_to "$1" "$_k" "$_v" ;; esac ;;
        esac
    done < "$2"
}
oyg_migrate_modules() {
    [ -f "$OYG_ROOT/enabled" ] && [ ! -f "$PRESET_FILE" ] || return 0
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) move the 1.4 module records to options"; return 0; fi
    head_ "moving the 1.4 module records to options"
    _OWN=$(_owners_file)
    _tmp=$(oyg_tmp migrate); mkdir -p "$_tmp"
    # (_mf, not _f: kv_set uses _f)
    for _mf in "$OYG_STATE"/*.*; do
        [ -f "$_mf" ] || continue
        _n=${_mf##*/}; _kind=${_n%%.*}; _scope=${_n#*.}
        case " $LEGACY_MODULES " in *" $_scope "*) ;; *) continue ;; esac
        if [ "$_kind" = kv ]; then
            # a resource keeps its own key/values (prefixes, peers, md5)
            case " $OYG_RESOURCES " in *" $_scope "*) continue ;; esac
            migrate_kv "$_scope" "$_mf"; rm -f "$_mf"; continue
        fi
        while IFS= read -r _line; do
            [ -n "$_line" ] || continue
            case $_kind in modes) _key=${_line% *} ;; moved) _key=${_line%%|*} ;; *) _key=$_line ;; esac
            printf '%s\n' "$_line" >> "$_tmp/$_kind.$(migrate_owner "$_kind" "$_key")"
        done < "$_mf"
        rm -f "$_mf"
    done
    for _mf in "$_tmp"/*; do
        [ -f "$_mf" ] || continue
        cat "$_mf" >> "$OYG_STATE/${_mf##*/}"
        awk '!s[$0]++' "$OYG_STATE/${_mf##*/}" > "$_mf.u" && mv "$_mf.u" "$OYG_STATE/${_mf##*/}"
    done
    # the 1.4 selection: all modules on (the default) becomes Recommended
    printf 'recommended\n' > "$PRESET_FILE"
    mv "$OYG_ROOT/enabled" "$OYG_ROOT/enabled.1.4"
    ok "records moved; selection: Recommended (the 1.4 module list is kept in enabled.1.4)"
}

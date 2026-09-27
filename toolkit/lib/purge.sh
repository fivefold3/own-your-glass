# purge.sh — delete what the advertising and diagnostics machinery has
# already collected, and reset the advertising identifier.
#
# This is an action, not a module: nothing here is re-applied at boot and
# nothing is restored on uninstall (deleting collected data is the point).
# The old advertising ID is not kept anywhere (1.4 kept a copy, which undid
# the unlinking the reset is for) and no part of either ID is logged.
#
# Paths verified on a 2025 LG OLED (webOS 10.3.1) and in the webOS 11.2
# image; missing ones are skipped.

PURGE_VOICE_LOGS="/tmp/app.voice.log /tmp/var/log/messages"
PURGE_AD_DIRS="/mnt/lg/cmn_data/admanager/cache /mnt/lg/cmn_data/admanager/tmpData /mnt/lg/cmn_data/admanager/cookie /mnt/lg/cmn_data/admanager/homePromotion /mnt/lg/cmn_data/adlogservice/data"
PURGE_AD_FILES="/mnt/lg/cmn_data/admanager/fck/fckInfo.txt"
PURGE_UPLOAD_DIRS="/var/spool/uploadd/pending /var/spool/uploadd/uploaded /var/spool/rdxd /var/spool/faultmanager"
# request dumps and caches the voice, AI and ad stacks leave behind; the Home
# Hub's cached LG account token (webOS 10); LG Channels' ad-URL cache
PURGE_MISC_DIRS="/tmp/thinqai /tmp/voiceinput /tmp/livepickplus /tmp/nlpmanager /tmp/iflytek /mnt/lg/cmn_data/.lgchannelurl /mnt/lg/cmn_data/iotframework"
PURGE_MISC_FILES="/tmp/saa.pcm /var/firstUseAppInfo.json /mnt/lg/cmn_data/homeconnect/tv.json /mnt/lg/cmn_data/homeconnect/repo.json /mnt/lg/cmn_data/universalcontrolmanager/cec_usage_normal_log.json"
# only with --forget: Matter/Homey pairing keys (you would pair devices again)
PURGE_FORGET_DIRS="/mnt/lg/cmn_data/.homeymatter"
# analytics cookies by name, whatever site set them
PURGE_COOKIE_NAMES="_ga _gid _gat _fbp _gcl_au"
IFA_FILE=/var/lib/secretagent/IFA.txt
WAM_COOKIES="/var/lib/wam/Default/Cookies"

_purge_dir() {  # empty a directory, keep the directory
    [ -d "$1" ] || return 0
    _c=$(find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
    [ "$_c" = 0 ] && return 0
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) empty $1 ($_c entries)"; return 0; fi
    find "$1" -mindepth 1 -exec rm -rf {} + 2>/dev/null; ok "emptied $1 ($_c entries)"
}
_new_uuid() {
    if command -v python3 >/dev/null 2>&1; then python3 -c 'import uuid; print(uuid.uuid4())'
    elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
    else od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'; fi
}

do_purge() {
    need_root; oyg_init_dirs
    head_ "purge: collected advertising, diagnostics and voice data"
    for f in $PURGE_VOICE_LOGS; do
        [ -f "$f" ] || continue
        _n=$(grep -a -c -E 'user_utterance|NL_RESULT_DATA|NL_SEARCH_ITEM' "$f" 2>/dev/null)
        run "truncate $f" sh -c ": > $f" && [ "$OYG_DRYRUN" != 1 ] && ok "cleared $f (${_n:-0} transcript lines)"
    done
    for d in $PURGE_AD_DIRS; do _purge_dir "$d"; done
    for f in $PURGE_AD_FILES; do [ -f "$f" ] && run "rm $f" rm -f "$f" && [ "$OYG_DRYRUN" != 1 ] && ok "removed $f"; done
    for d in $PURGE_UPLOAD_DIRS $PURGE_MISC_DIRS; do _purge_dir "$d"; done
    for f in $PURGE_MISC_FILES; do [ -f "$f" ] && run "rm $f" rm -f "$f" && [ "$OYG_DRYRUN" != 1 ] && ok "removed $f"; done
    for f in /tmp/var/log/messages.*; do [ -f "$f" ] && run "rm $f" rm -f "$f"; done
    case " $* " in *" --forget "*) for d in $PURGE_FORGET_DIRS; do _purge_dir "$d"; done ;; esac
    if is_mounted "$IFA_FILE"; then
        info "advertising ID is held at zero by the Opt-out advertising ID option: left alone"
    elif [ -f "$IFA_FILE" ]; then
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) reset advertising ID in $IFA_FILE"
        else
            rm -f "$OYG_BACKUP/IFA.txt.before-reset"   # 1.4 kept the old ID there
            _new=$(_new_uuid)
            if [ -n "$_new" ] && printf '%s' "$_new" > "$IFA_FILE"; then ok "advertising ID reset to a new random one"; else warn "could not rewrite $IFA_FILE"; fi
        fi
    else info "no advertising ID file on this TV"; fi
    # tracker cookies in the web-app profile: rows whose host is a sinkholed
    # name of any option, or whose name is an analytics cookie, are deleted
    # with sqlite3 (present on webOS); the whole store is only wiped on
    # request, because that signs web apps out
    if [ -f "$WAM_COOKIES" ] && command -v sqlite3 >/dev/null 2>&1; then
        _where=$( { for o in $OYG_OPTIONS; do ov "$o" hosts; printf '\n'; ov "$o" hosts_t; printf '\n'; done | hosts_expand | hosts_never_filter; } | sort -u \
            | awk '{ printf "%shost_key LIKE \"%%%s\"", (n++ ? " OR " : ""), $1 }')
        # by prefix, not LIKE: its _ matches any character (LIKE "_ga%" took agadget)
        for _c in $PURGE_COOKIE_NAMES; do _where="$_where${_where:+ OR }substr(name,1,${#_c})=\"$_c\""; done
        _n=$(sqlite3 "$WAM_COOKIES" "SELECT count(*) FROM cookies WHERE $_where" 2>/dev/null)
        if [ "${_n:-0}" -gt 0 ]; then
            if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) delete $_n tracker cookies"
            else sqlite3 "$WAM_COOKIES" "PRAGMA busy_timeout=3000; DELETE FROM cookies WHERE $_where" 2>/dev/null && ok "deleted $_n tracker cookies from the web-app profile" || warn "could not delete tracker cookies (store busy)"; fi
        else info "no tracker cookies in the web-app profile"; fi
    fi
    case " $* " in *" --web-cookies "*) _wc=1 ;; *) _wc=0 ;; esac
    if [ $_wc = 1 ] && [ -f "$WAM_COOKIES" ]; then
        run "rm web-app cookie store" rm -f "$WAM_COOKIES" "$WAM_COOKIES-journal" && ok "web-app cookie store removed (web apps will ask you to sign in again)"
    fi
    head_ "purge done"
    if is_mounted "$IFA_FILE"; then toast "Own Your Glass: collected data cleared"; else toast "Own Your Glass: collected data cleared, advertising ID reset"; fi
}

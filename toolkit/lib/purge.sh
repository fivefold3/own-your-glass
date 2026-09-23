# purge.sh — delete what the advertising and diagnostics machinery has
# already collected, and reset the advertising identifier.
#
# This is an action, not a module: nothing here is re-applied at boot and
# nothing is restored on uninstall (deleting collected data is the point).
# The old advertising ID is kept as a plain copy in the backup directory in
# case it is ever wanted; it is not put back by restore.
#
# Paths verified on a 2025 LG OLED (webOS 10.3.1); missing ones are skipped.

PURGE_VOICE_LOGS="/tmp/app.voice.log /tmp/var/log/messages"
PURGE_AD_DIRS="/mnt/lg/cmn_data/admanager/cache /mnt/lg/cmn_data/admanager/tmpData /mnt/lg/cmn_data/admanager/cookie /mnt/lg/cmn_data/admanager/homePromotion /mnt/lg/cmn_data/adlogservice/data/backup"
PURGE_AD_FILES="/mnt/lg/cmn_data/admanager/fck/fckInfo.txt /mnt/lg/cmn_data/adlogservice/data/adlogservice.enc"
PURGE_UPLOAD_DIRS="/var/spool/uploadd/pending /var/spool/uploadd/uploaded /var/spool/rdxd /var/spool/faultmanager"
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
    for d in $PURGE_UPLOAD_DIRS; do _purge_dir "$d"; done
    if [ -f "$IFA_FILE" ]; then
        _old=$(cat "$IFA_FILE")
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) reset advertising ID in $IFA_FILE"
        else
            [ -f "$OYG_BACKUP/IFA.txt.before-reset" ] || cp -p "$IFA_FILE" "$OYG_BACKUP/IFA.txt.before-reset" 2>/dev/null
            _new=$(_new_uuid)
            if [ -n "$_new" ] && printf '%s' "$_new" > "$IFA_FILE"; then ok "advertising ID reset ($(printf '%s' "$_old" | cut -c1-4)… -> $(printf '%s' "$_new" | cut -c1-4)…)"; else warn "could not rewrite $IFA_FILE"; fi
        fi
    else info "no advertising ID file on this TV"; fi
    # tracker cookies in the web-app profile: rows whose host matches a
    # blocklist domain are deleted with sqlite3 (present on webOS); the whole
    # store is only wiped on request, because that signs web apps out
    if [ -f "$WAM_COOKIES" ] && command -v sqlite3 >/dev/null 2>&1; then
        _bl="$OYG_TK/etc/blocklist.txt"; [ -f "$_bl" ] || _bl="$OYG_ROOT/toolkit/etc/blocklist.txt"
        _where=$( { [ -f "$_bl" ] && sed 's/#.*//' "$_bl" | awk 'NF{print $1}'; printf '%s\n' "${BLOCKLIST_INLINE:-}" | sed 's/#.*//' | awk 'NF{print $1}'; } | sort -u | awk '{printf "%shost_key LIKE \"%%%s\"", (n++?" OR ":""), $1}')
        if [ -n "$_where" ]; then
            _n=$(sqlite3 "$WAM_COOKIES" "SELECT count(*) FROM cookies WHERE $_where" 2>/dev/null)
            if [ "${_n:-0}" -gt 0 ]; then
                if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) delete $_n tracker cookies"
                else sqlite3 "$WAM_COOKIES" "PRAGMA busy_timeout=3000; DELETE FROM cookies WHERE $_where" 2>/dev/null && ok "deleted $_n tracker cookies from the web-app profile" || warn "could not delete tracker cookies (store busy)"; fi
            else info "no tracker cookies in the web-app profile"; fi
        fi
    fi
    if [ "${1:-}" = "--web-cookies" ] && [ -f "$WAM_COOKIES" ]; then
        run "rm web-app cookie store" rm -f "$WAM_COOKIES" "$WAM_COOKIES-journal" && ok "web-app cookie store removed (web apps will ask you to sign in again)"
    fi
    head_ "purge done"
    toast "Own Your Glass: collected data cleared, advertising ID reset"
}

# settings.sh — system settings through LG's settings service.
#
# settings_apply <category> <json>: records the previous values of the keys
# once (kv settings.<category>), then sets the private ones. Only keys the TV
# reported are sent: settingsservice rejects a whole call over one unknown
# key, and keys come and go between firmware versions (homeSense* and
# autoBackupEnabled exist only on webOS 11).
# settings_restore <category>: puts the recorded values back.
# SETTINGS_CHANGED: after settings_apply, the keys it changed.

# The reply to getSystemSettings is pretty-printed JSON; keep only its
# "settings" object (python3 where it exists; otherwise by brace depth: a
# sed that trimmed the outer brace broke on the documented layout, where
# "returnValue" follows "settings", and webOS 5 and 6 never got a setting)
# so it can be handed straight back to setSystemSettings.
_settings_obj() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try: print(json.dumps(json.load(sys.stdin).get("settings", {}), separators=(",", ":")))
except Exception: print("")'
    else json_obj_of settings; fi
}
# top-level keys of a JSON object, as a JSON string list body: a","b","c
_settings_keys() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c 'import json,sys; print("\",\"".join(json.load(sys.stdin).keys()))'
    else printf '%s' "$1" | grep -o '"[A-Za-z0-9_]*":' | tr -d '":' | paste -sd, - | sed 's/,/","/g'; fi
}
# the wanted object restricted to the keys present in the TV's reply.
# Without python3 it is rebuilt from the key|value lines the engine passes
# in SETTINGS_PAIRS (a value can be an object, which no sed would cut out).
_settings_filter() {  # _settings_filter <wanted> <reply settings object>
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
w, h = json.loads(sys.argv[1]), json.loads(sys.argv[2] or "{}")
print(json.dumps({k: v for k, v in w.items() if k in h}, separators=(",", ":")))' "$1" "$2" 2>/dev/null
    elif [ -n "${SETTINGS_PAIRS:-}" ]; then
        printf '%s\n' "$SETTINGS_PAIRS" | awk -F'|' -v h="$2" 'NF >= 2 && index(h, "\"" $1 "\"") { o = o (o == "" ? "" : ",") "\"" $1 "\":" substr($0, length($1) + 2) } END { print "{" o "}" }'
    else printf '%s' "$1"; fi
}

settings_apply() {  # settings_apply <category> <json object of private values>
    SETTINGS_CHANGED=""
    command -v luna-send >/dev/null 2>&1 || return 0
    _cat=$1; _want=$2
    _cur=$(luna luna://com.webos.settingsservice/getSystemSettings "{\"category\":\"$_cat\",\"keys\":[\"$(_settings_keys "$_want")\"]}" | _settings_obj)
    case $_cur in \{*\}) ;; *) warn "could not read $_cat settings"; kv_set "settings_failed.$_cat" 1; return 1 ;; esac
    _send=$(_settings_filter "$_want" "$_cur")
    [ "$_send" = "{}" ] && { info "none of the $_cat settings exist on this TV"; return 0; }
    # the keys this call actually changes, for a hook that needs to know
    # (without python3: all of them)
    SETTINGS_CHANGED=$(python3 -c 'import json,sys
s, c = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(" ".join(k for k in s if c.get(k) != s[k]))' "$_send" "$_cur" 2>/dev/null) || SETTINGS_CHANGED=$(_settings_keys "$_send" | sed 's/","/ /g')
    # the previous values, recorded the first time each key is changed (a
    # newer version may add keys to a category recorded long ago)
    _rec=$(kv_get "settings.$_cat")
    if [ -z "$_rec" ]; then kv_set "settings.$_cat" "$_cur"; info "previous $_cat settings recorded"
    elif command -v python3 >/dev/null 2>&1; then
        _m=$(python3 -c 'import json,sys
r, c = json.loads(sys.argv[1]), json.loads(sys.argv[2])
n = [k for k in c if k not in r]; r.update({k: c[k] for k in n})
print(json.dumps(r, separators=(",", ":")) if n else "")' "$_rec" "$_cur" 2>/dev/null)
        [ -n "$_m" ] && kv_set "settings.$_cat" "$_m"
    fi
    [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) setSystemSettings $_cat $_send"; return 0; }
    # a miss is recorded, so status can say so (it used to report only successes)
    if luna_ok luna://com.webos.settingsservice/setSystemSettings "{\"category\":\"$_cat\",\"settings\":$_send}"; then
        ok "settings ($_cat) set to private"; kv_set "settings_failed.$_cat" ""
    else warn "settingsservice rejected the $_cat settings"; kv_set "settings_failed.$_cat" 1; return 1; fi
}
settings_restore() {  # settings_restore <category>
    command -v luna-send >/dev/null 2>&1 || return 0
    _prev=$(kv_get "settings.$1"); [ -n "$_prev" ] || return 0
    [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) restore $1 settings"; return 0; }
    case $_prev in
        \{\}) ;;
        \{*\}) luna_ok luna://com.webos.settingsservice/setSystemSettings "{\"category\":\"$1\",\"settings\":$_prev}" && ok "settings ($1) restored" || warn "could not restore the $1 settings (their record is kept)" ;;
    esac
}

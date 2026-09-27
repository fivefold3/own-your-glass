# eula.sh — LG's consent state, read and written the way LG's own first-use
# and Settings apps do it: one setSystemSettings call carrying the eulaStatus
# booleans and the eulaInfoNetwork list (no category). settingsservice then
# rewrites its cache (/var/luna/preferences/eula) together with the md5
# sidecar that bootd's settingsCacheValidator checks at boot, and
# eula-service, which is notified, syncs its own stores.
#
# 1.2.x edited the cache file with sed instead. That matched only the dead
# 2014 list (in eulaInfoNetwork "_id" sits between "id" and "accepted"), left
# eula.md5 stale, and settingsservice's in-memory copy would have overwritten
# it anyway.
#
# Only what OYG flips is recorded (kv "eula.flipped": id:S_x, flag:<name>,
# updated:S_x), and restore flips back only that, so the owner's own later
# choices survive.

EULA_CACHE=/var/luna/preferences/eula
# the eulaStatus booleans gated services and apps read (acrOn, voice, ads,
# third-party sharing, remote diagnostics) and the consent ids declined, from
# the knowledge base (etc/options.sh). generalTermsAllowed, networkAllowed
# and chpAllowed are the basic terms: declining those only raises the
# agreements wall on every launch.
EULA_TRACKING_FLAGS=${EULA_FLAGS:-}
CONSENT_IDS=${EULA_IDS:-}

eula_read() { luna-send -n 1 luna://com.webos.settingsservice/getSystemSettings '{"keys":["eulaStatus","eulaInfoNetwork"]}' </dev/null 2>/dev/null; }

# eula_edit <mode> <args>: reply of eula_read on stdin; prints the settings
# object to send (line 1) and what changed (line 2), nothing if unchanged.
#   decline "<ids>" "<flags>"   accepted:false / flag false
#   updated                     every "updated":true → false (terms nag)
#   restore "<flipped>"         undo exactly the recorded flips
_EULA_PY='
import json, sys
mode = sys.argv[1]
d = json.load(sys.stdin)
s = d.get("settings") or {}
st = s.get("eulaStatus") if isinstance(s.get("eulaStatus"), dict) else None
net = s.get("eulaInfoNetwork") if isinstance(s.get("eulaInfoNetwork"), dict) else None
lst = (net or {}).get("eulaList") or []
done = []
if mode == "decline":
    ids, flags = set(sys.argv[2].split()), sys.argv[3].split()
    for e in lst:
        if isinstance(e, dict) and e.get("id") in ids and e.get("accepted") is True:
            e["accepted"] = False; done.append("id:" + e["id"])
    for f in flags:
        if st is not None and st.get(f) is True:
            st[f] = False; done.append("flag:" + f)
elif mode == "updated":
    for e in lst:
        if isinstance(e, dict) and e.get("updated") is True:
            e["updated"] = False; done.append("updated:" + str(e.get("id", "")))
elif mode == "restore":
    want = set(sys.argv[2].split())
    for e in lst:
        if isinstance(e, dict):
            if "id:" + str(e.get("id")) in want and e.get("accepted") is False: e["accepted"] = True; done.append("id:" + e["id"])
            if "updated:" + str(e.get("id")) in want and e.get("updated") is False: e["updated"] = True; done.append("updated:" + e["id"])
    for w in want:
        if w.startswith("flag:") and st is not None and st.get(w[5:]) is False:
            st[w[5:]] = True; done.append(w)
if done:
    out = {}
    if st is not None and any(x.startswith("flag:") for x in done): out["eulaStatus"] = st
    if net is not None and any(not x.startswith("flag:") for x in done): out["eulaInfoNetwork"] = net
    print(json.dumps({"settings": out}, separators=(",", ":")))
    print(" ".join(done))
'
eula_edit() { command -v python3 >/dev/null 2>&1 && python3 -c "$_EULA_PY" "$@"; }

# Without python3 (webOS 5 and 6): the same three edits in awk and sed.
# The list's entries are flat objects, so each innermost {...} carrying an
# "id" is one entry; the flags object is edited by name. (Until 1.4.55 only
# the flags were declined there, the list was left accepted, and a restore
# did nothing at all.)
_EULA_LIST_AWK='
function val(o, k,   m) { if (match(o, "\"" k "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) { m = substr(o, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*"/, "", m); sub(/"$/, "", m); return m } return "" }
BEGIN { n = split(IDS, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
{ s = $0; out = ""
  while (match(s, /\{[^{}]*\}/)) {
    st = RSTART; ln = RLENGTH; o = substr(s, st, ln); id = val(o, "id")
    if (id != "") {
      if (MODE == "decline" && (id in w) && o ~ /"accepted"[[:space:]]*:[[:space:]]*true/) { sub(/"accepted"[[:space:]]*:[[:space:]]*true/, "\"accepted\":false", o); d = d " id:" id }
      if (MODE == "updated" && o ~ /"updated"[[:space:]]*:[[:space:]]*true/) { sub(/"updated"[[:space:]]*:[[:space:]]*true/, "\"updated\":false", o); d = d " updated:" id }
      if (MODE == "restore") {
        if (("id:" id) in w && o ~ /"accepted"[[:space:]]*:[[:space:]]*false/) { sub(/"accepted"[[:space:]]*:[[:space:]]*false/, "\"accepted\":true", o); d = d " id:" id }
        if (("updated:" id) in w && o ~ /"updated"[[:space:]]*:[[:space:]]*false/) { sub(/"updated"[[:space:]]*:[[:space:]]*false/, "\"updated\":true", o); d = d " updated:" id }
      }
    }
    out = out substr(s, 1, st - 1) o; s = substr(s, st + ln)
  }
  print out s; print substr(d, 2) }'
_eula_edit_sh() {  # same arguments and output as eula_edit; reply on stdin
    _r=$(tr -d '\r\n')
    _net=$(printf '%s' "$_r" | json_obj_of eulaInfoNetwork); _st=$(printf '%s' "$_r" | json_obj_of eulaStatus)
    _o=""; _d=""
    case $1 in decline|restore) _ids=$2 ;; *) _ids="" ;; esac
    if [ -n "$_net" ]; then
        _l=$(printf '%s' "$_net" | awk -v MODE="$1" -v IDS="$_ids" "$_EULA_LIST_AWK")
        _ld=$(printf '%s\n' "$_l" | sed -n 2p)
        [ -n "$_ld" ] && { _o="\"eulaInfoNetwork\":$(printf '%s\n' "$_l" | sed -n 1p)"; _d=$_ld; }
    fi
    if [ -n "$_st" ]; then
        _fd=""
        case $1 in
            decline) for _f in ${3:-}; do
                printf '%s' "$_st" | grep -q "\"$_f\"[[:space:]]*:[[:space:]]*true" || continue
                _st=$(printf '%s' "$_st" | sed "s/\"$_f\"[[:space:]]*:[[:space:]]*true/\"$_f\":false/"); _fd="$_fd flag:$_f"; done ;;
            restore) for _w in $2; do case $_w in flag:*) _f=${_w#flag:}
                printf '%s' "$_st" | grep -q "\"$_f\"[[:space:]]*:[[:space:]]*false" || continue
                _st=$(printf '%s' "$_st" | sed "s/\"$_f\"[[:space:]]*:[[:space:]]*false/\"$_f\":true/"); _fd="$_fd flag:$_f" ;; esac; done ;;
        esac
        [ -n "$_fd" ] && { _o="$_o${_o:+,}\"eulaStatus\":$_st"; _d="$_d${_d:+ }${_fd# }"; }
    fi
    [ -n "$_d" ] || return 0
    printf '{"settings":{%s}}\n%s\n' "$_o" "$_d"
}
# the editor this TV has
eula_editor() { if command -v python3 >/dev/null 2>&1; then eula_edit "$@"; else _eula_edit_sh "$@"; fi; }

eula_write() {  # eula_write <settings json>
    luna_ok luna://com.webos.settingsservice/setSystemSettings "$1"
}

# eula_apply decline|updated: flip, write, record. Returns 1 if the write failed.
eula_apply() {
    _mode=$1
    command -v luna-send >/dev/null 2>&1 || return 0
    _reply=$(eula_read)
    printf '%s' "$_reply" | grep -q '"returnValue"[[:space:]]*:[[:space:]]*true' || { warn "could not read the consent state from settingsservice"; return 1; }
    case $_mode in
        decline) _out=$(printf '%s' "$_reply" | eula_editor decline "$CONSENT_IDS" "$EULA_TRACKING_FLAGS") ;;
        updated) _out=$(printf '%s' "$_reply" | eula_editor updated) ;;
    esac
    [ -n "$_out" ] || return 0
    _json=$(printf '%s\n' "$_out" | sed -n 1p); _done=$(printf '%s\n' "$_out" | sed -n 2p)
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) settingsservice: $_done"; return 0; fi
    if eula_write "$_json"; then
        kv_set eula.flipped "$(printf '%s %s\n' "$(kv_get eula.flipped)" "$_done" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
        ok "consents changed through settingsservice: $_done"
    else warn "settingsservice refused the consent change ($_done)"; return 1; fi
}
eula_restore() {
    _fl=$(kv_get eula.flipped); [ -n "$_fl" ] || return 0
    command -v luna-send >/dev/null 2>&1 || return 0
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) settingsservice: undo $_fl"; return 0; fi
    _out=$(eula_read | eula_editor restore "$_fl")
    if [ -z "$_out" ]; then info "consents already as the owner set them"; return 0; fi
    eula_write "$(printf '%s\n' "$_out" | sed -n 1p)" && ok "consents restored: $(printf '%s\n' "$_out" | sed -n 2p)" || warn "could not restore consents ($_fl)"
}

# Status, read-only and without luna: the cached list and booleans.
# eulaInfoNetwork entries order their keys fileName,id,…,accepted: an id's
# "accepted" is the one before the next "id".
eula_accepted_ids() {  # ids of CONSENT_IDS accepted in the cached live list
    eula_network_obj | awk -v IDS="$CONSENT_IDS" '
        BEGIN { n = split(IDS, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        { s = $0
          while (match(s, /"id"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
              id = substr(s, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*"/, "", id); sub(/"$/, "", id)
              s = substr(s, RSTART + RLENGTH); seg = s
              if (match(seg, /"id"[[:space:]]*:/)) seg = substr(seg, 1, RSTART - 1)
              if ((id in want) && seg ~ /"accepted"[[:space:]]*:[[:space:]]*true/) hit[id] = 1
          } }
        END { for (k in hit) print k }' | sort -u
}
eula_true_flags() {  # tracking eulaStatus flags that are true, wherever settingsservice caches them
    _files=$(grep -l generalTermsAllowed /var/luna/preferences/* 2>/dev/null)
    [ -n "$_files" ] || return 0
    for _f in $EULA_TRACKING_FLAGS; do
        cat $_files 2>/dev/null | tr -d '\r\n' | grep -q "\"$_f\"[[:space:]]*:[[:space:]]*true" && printf '%s\n' "$_f"
    done
}
# the eulaInfoNetwork object of the cache (the live list; "eulaInfo" is the
# inert 2014 one), found by brace depth
eula_network_obj() { [ -f "$EULA_CACHE" ] && json_obj_of eulaInfoNetwork < "$EULA_CACHE"; return 0; }
eula_update_pending() { eula_network_obj | grep -q '"updated"[[:space:]]*:[[:space:]]*true'; }

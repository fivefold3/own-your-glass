# consent — LG's consent stores and the settings that gate data collection.
#
# The TV keeps its consents in several places and has been seen flipping
# them back to accepted after component updates. We decline every tracking
# consent in every store, sideline the 2-year "allow marketing again" nag,
# and turn off the privacy-relevant system settings through LG's own
# settings service, so the features gated on them never engage.
#
# Stores:
#   /var/luna/preferences/eula                        "id":"S_xxx","accepted":true|false
#   /mnt/lg/{cmn_data,cache,user}/sdp/eula-service/eula.json
#                                                     statusList[].status "A" -> "W" (what the TV itself writes for a withdrawn consent)
#   /mnt/lg/cmn_data/sdp/eula-service/marketingAllowedDate.json   moved aside
MOD_CONSENT_DESC="Decline every tracking consent, disable ad and data settings"
MOD_CONSENT_DEFAULT=on

EULA_MAIN=/var/luna/preferences/eula
EULA_SDP="/mnt/lg/cmn_data/sdp/eula-service/eula.json /mnt/lg/cache/sdp/eula-service/eula.json /mnt/lg/user/sdp/eula-service/eula.json"
NAG=/mnt/lg/cmn_data/sdp/eula-service/marketingAllowedDate.json
# Consents that are purely about data collection / advertising. Anything
# else (the basic terms, the software licence) is left as the owner set it.
CONSENT_IDS="S_VNG S_PRV S_TAD S_TAG S_ADG S_ADC S_ADD S_VDC S_VDD S_NVC S_NVD S_MKT S_DPA"

# settings service keys: each line is  category|json-settings-object
# Keys that do not exist on a given firmware are ignored by the service.
CONSENT_SETTINGS='
general|{"homePromotion":"off","personalRecommend":{"value":"off","changedByUser":true},"screenSaverAd":"off","aiNudge":"off","aiSettingsNudge":"off","adCookie":"off","customizedAd":"off","lmt":"on","doNotSellMyPersonalInformation":"on","sportsAlarm":"off","lifeAlarm":"off","welcomeFeature":"off"}
option|{"livePlus":"off","usageCare":false,"dbgLogUpload":false,"faultLogUpload":false,"watchedListCollection":"off","thirdPartyCookie":"off"}
'

_consent_flip_main() {
    [ -f "$EULA_MAIN" ] || return 0
    backup_once "$EULA_MAIN"
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) decline consents in $EULA_MAIN"; return 0; fi
    _tmp="$EULA_MAIN.oyg.tmp"; cp "$EULA_MAIN" "$_tmp" || return 1
    for id in $CONSENT_IDS; do
        sed -i "s/\"id\":\"$id\",\"accepted\":true/\"id\":\"$id\",\"accepted\":false/g; s/\"id\": *\"$id\", *\"accepted\": *true/\"id\":\"$id\",\"accepted\":false/g" "$_tmp"
    done
    # sanity: still one JSON object
    if [ "$(head -c1 "$_tmp")" = "{" ] || [ "$(head -c1 "$_tmp")" = "[" ]; then mv "$_tmp" "$EULA_MAIN"; ok "consents declined in $EULA_MAIN"; else rm -f "$_tmp"; warn "$EULA_MAIN did not look like JSON, untouched"; fi
}
_consent_flip_sdp() {
    for f in $EULA_SDP; do
        [ -f "$f" ] || continue
        backup_once "$f"
        [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) decline consents in $f"; continue; }
        _tmp="$f.oyg.tmp"
        # only the tracking consents: "managementTypeCode":"S_xxx" ... "status":"A"
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$f" "$_tmp" "$CONSENT_IDS" <<'PY' && mv "$_tmp" "$f" && ok "consents declined in $f" || warn "could not rewrite $f"
import json, sys
src, dst, ids = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
d = json.load(open(src))
n = 0
for e in d.get("statusList", []):
    if e.get("managementTypeCode") in ids and e.get("status") == "A":
        e["status"] = "W"; n += 1
json.dump(d, open(dst, "w"), separators=(", ", ": "))
PY
        else
            cp "$f" "$_tmp"
            for id in $CONSENT_IDS; do
                sed -i "s/\(\"managementTypeCode\": *\"$id\"[^}]*\"status\": *\)\"A\"/\1\"W\"/g" "$_tmp"
            done
            mv "$_tmp" "$f" && ok "consents declined in $f"
        fi
    done
}
# The reply to getSystemSettings is pretty-printed JSON; keep only its
# "settings" object (python3 ships on webOS; sed fallback trims the outer
# brace) so it can be handed straight back to setSystemSettings on restore.
_settings_obj() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try: print(json.dumps(json.load(sys.stdin).get("settings", {}), separators=(",", ":")))
except Exception: print("")'
    else tr -d '\n' | sed 's/^.*"settings" *: *//; s/ *} *$//'; fi
}
_consent_settings() {
    command -v luna-send >/dev/null 2>&1 || return 0
    printf '%s\n' "$CONSENT_SETTINGS" | while IFS='|' read -r cat json; do
        [ -n "$cat" ] || continue
        if [ -z "$(kv_get "settings.$cat")" ]; then   # remember the previous values once
            keys=$(printf '%s' "$json" | grep -o '"[A-Za-z]*":' | tr -d '":' | tr '\n' ',' | sed 's/,$//; s/,/","/g')
            prev=$(luna luna://com.webos.settingsservice/getSystemSettings "{\"category\":\"$cat\",\"keys\":[\"$keys\"]}" | _settings_obj)
            case $prev in \{*\}) kv_set "settings.$cat" "$prev"; info "previous $cat settings recorded" ;; *) warn "could not read previous $cat settings" ;; esac
        fi
        [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) setSystemSettings $cat"; continue; }
        if luna_ok luna://com.webos.settingsservice/setSystemSettings "{\"category\":\"$cat\",\"settings\":$json}"; then ok "settings ($cat) set to private"; else warn "settingsservice rejected category $cat (keys may not exist on this firmware)"; fi
    done
}

mod_consent_apply() {
    _consent_flip_main
    _consent_flip_sdp
    if [ -f "$NAG" ]; then
        backup_once "$NAG"
        run "sideline $NAG" mv "$NAG" "$NAG.oyg-off" && mark_moved "$NAG" "$NAG.oyg-off" && ok "marketing re-consent nag sidelined"
    fi
    _consent_settings
    kv_set applied 1
}
mod_consent_restore() {
    command -v luna-send >/dev/null 2>&1 && printf '%s\n' "$CONSENT_SETTINGS" | while IFS='|' read -r cat json; do
        [ -n "$cat" ] || continue
        prev=$(kv_get "settings.$cat"); [ -n "$prev" ] || continue
        [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) restore $cat settings"; continue; }
        case $prev in \{*\}) luna_ok luna://com.webos.settingsservice/setSystemSettings "{\"category\":\"$cat\",\"settings\":$prev}" && ok "settings ($cat) restored" || warn "could not restore $cat settings: $prev" ;; esac
    done
    generic_restore
}
mod_consent_status() {
    _r=0
    if [ -f "$EULA_MAIN" ]; then
        _on=""
        for id in $CONSENT_IDS; do grep -q "\"id\": *\"$id\", *\"accepted\": *true" "$EULA_MAIN" && _on="$_on $id"; done
        [ -z "$_on" ] && st CONSENT OK "tracking consents declined" || { st CONSENT FAIL "accepted:$_on"; _r=1; }
    else st CONSENT NA "no eula store"; fi
    _a=0
    for f in $EULA_SDP; do [ -f "$f" ] || continue
        for id in $CONSENT_IDS; do grep -q "\"managementTypeCode\": *\"$id\"[^}]*\"status\": *\"A\"" "$f" && _a=$((_a+1)); done
    done
    [ $_a = 0 ] && st CONSENT OK "service-side consent stores declined" || { st CONSENT FAIL "$_a service-side consents still accepted"; _r=1; }
    [ -f "$NAG" ] && st CONSENT WARN "marketing re-consent nag armed"
    [ -n "$(kv_get settings.general)" ] && st CONSENT OK "ad and data settings off"
    return $_r
}

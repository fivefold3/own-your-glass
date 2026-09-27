# consents — LG's consent state (option consents).
#
# The TV has been seen flipping consents back to accepted after component
# updates. We decline every tracking consent and sideline the 2-year "allow
# marketing again" nag. (The privacy settings each belong to the option
# whose feature they gate; the engine sets them.)
#
# Consents go through settingsservice (lib/eula.sh), the way LG's first-use
# and Settings apps write them: the eulaInfoNetwork list (the ids below) and
# the eulaStatus booleans apps and services actually read (acrOn, voice,
# marketing, custom ads, third-party sharing, remote diagnostics...). The
# basic terms (S_SVC terms of use, S_PRG privacy policy) stay as the owner
# set them: declining those raises the agreements wall on every launch.
#   eula-service keeps its own copy (/mnt/lg/{cmn_data,cache,user}/sdp/
#   eula-service/eula.json, statusList A/W) and syncs it from settingsservice;
#   status reads it.
#   /mnt/lg/cmn_data/sdp/eula-service/marketingAllowedDate.json   moved aside
EULA_SDP="/mnt/lg/cmn_data/sdp/eula-service/eula.json /mnt/lg/cache/sdp/eula-service/eula.json /mnt/lg/user/sdp/eula-service/eula.json"
NAG=/mnt/lg/cmn_data/sdp/eula-service/marketingAllowedDate.json

hook_consents_apply() {
    eula_apply decline
    if [ -f "$NAG" ]; then
        backup_once "$NAG"
        run "sideline $NAG" mv "$NAG" "$NAG.oyg-off" && mark_moved "$NAG" "$NAG.oyg-off" && ok "marketing re-consent nag sidelined"
    fi
    return 0
}
hook_consents_restore() { :; }   # the engine undoes the recorded consent flips
hook_consents_status() {
    _r=0; _m=$1
    _on=$(eula_accepted_ids | tr '\n' ' ' | sed 's/ $//')
    _fl=$(eula_true_flags | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$_on" ]; then st "$_m" FAIL "tracking consents accepted: $_on"; _r=1
    elif [ -f "$EULA_CACHE" ]; then st "$_m" OK "tracking consents declined"
    else st "$_m" NA "no consent store"; fi
    [ -n "$_fl" ] && { st "$_m" FAIL "tracking permissions on: $_fl"; _r=1; }
    _a=0
    for f in $EULA_SDP; do [ -f "$f" ] || continue
        for id in $CONSENT_IDS; do grep -q "\"managementTypeCode\": *\"$id\"[^}]*\"status\": *\"A\"" "$f" && _a=$((_a+1)); done
    done
    [ $_a = 0 ] || { st "$_m" WARN "eula-service still records $_a tracking consents as accepted"; _r=1; }
    [ -f "$NAG" ] && st "$_m" WARN "marketing re-consent nag armed"
    return $_r
}

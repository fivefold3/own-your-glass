# acr — Automatic Content Recognition and the advertising stack built on it.
#
# acr2 captures audio and video from broadcast and HDMI and runs a
# downloaded recognition library on it (the "solution"; Alphonso data under
# /mnt/lg/cmn_data/acr); adoverlay-service draws shoppable / interactive ads
# over live TV and HDMI inputs; livepick-plus turns ACR and guide data into
# notice-bar offers; admanager holds the advertising identifier, the ad
# cookie and click tracking. Consent normally keeps most of these dormant —
# ACR is started by an activity on every boot and waits for consent. This
# module makes them unable to start at all.
# contentminer is not ACR either: it downloads the per-app preview rows on
# the Home screen from LG (optionally personalised) and is stopped for that.
# objectdetection(-utilizer) is left alone: it looked like part of this
# pipeline, but on the C5 it is on-device text and sign-language detection
# for the accessibility "sign language zoom" feature, with no network code.
# Earlier versions blocked it; apply releases it on TVs that still have it
# bound.
#
# Spec fields: id|unit|binary|comm|argmatch  ("?" = discover, see lib/svc.sh)
MOD_ACR_DESC="ACR content recognition, ad overlays, ad-ID manager"
MOD_ACR_DEFAULT=on

ACR_SPEC='
acr||?|acr2|
adoverlay||?|adoverlay-service|
adoverlay-legacy|adoverlay.service|?|adoverlay|
admanager||?|admanager|
livepick-plus||?|livepick-plus|
contentminer|contentminer.service|?|contentminer|
'

ACR_RELEASED="objectdetection objectdetectionutilizer"

mod_acr_apply() {
    printf '%s\n' "$ACR_SPEC" | svc_apply
    svc_release $ACR_RELEASED
    return 0
}
mod_acr_restore() { generic_restore; }
mod_acr_status()  { printf '%s\n' "$ACR_SPEC" | svc_status ACR; }

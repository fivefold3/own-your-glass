# acr — Automatic Content Recognition and the advertising stack built on it.
#
# acr2 fingerprints whatever is on screen and reports it; adoverlay-service
# draws shoppable / interactive ads over live TV and HDMI inputs;
# livepick-plus is the shoppable-ACR matcher; admanager hands out the
# advertising identifier; contentminer and objectdetection feed the same
# pipeline. Consent normally keeps most of these dormant — ACR is started by
# an activity on every boot and waits for consent. This module makes them
# unable to start at all.
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
objectdetection|objectdetection.service|?|objectdetection|
objectdetectionutilizer|objectdetectionutilizer.service|?|objectdetectionutilizer|
'

mod_acr_apply()   { printf '%s\n' "$ACR_SPEC" | svc_apply; }
mod_acr_restore() { generic_restore; }
mod_acr_status()  { printf '%s\n' "$ACR_SPEC" | svc_status ACR; }

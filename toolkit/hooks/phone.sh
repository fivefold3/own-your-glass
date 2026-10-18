# phone — the restart LG's phone server needs after the option is undone
# (option phone; its setting and services are declarative).
#
# The option turns allowMobileDeviceAccess off. LG's second-screen gateway
# (SSAP, the phone remote API) starts its server only once per run of the
# service, and only while the setting is on: when the setting comes back on
# later in the same boot, the server stays down until the TV restarts, and
# phone remote apps can neither find the TV nor pair. That holds whether the
# setting went off in this boot or was already off when the TV started
# (verified on the C5, 2026-10-17, with a phone app; an earlier reading that
# a boot started with the setting off needed no restart was wrong), and
# whoever turns it back on, OYG's undo or LG's own menus.
#
# So the restart is decided once the settings are back (hook_phone_restored,
# run by opt_restore): it is asked for when OYG had turned the setting off
# (its recorded previous value is true) and the TV now has it on (oyg
# status: META|restart; the app offers Restart now / Later). A setting the
# owner had off before OYG asks for nothing, and so does an undo
# settingsservice refused: no restart would bring the phones back then.

PHONE_BACK="Phone remote apps work again"
PHONE_KEY=allowMobileDeviceAccess

# the TV's phone access is on now
phone_access_on() {
    luna luna://com.webos.settingsservice/getSystemSettings "{\"category\":\"network\",\"keys\":[\"$PHONE_KEY\"]}" \
        | grep -q "\"$PHONE_KEY\"[[:space:]]*:[[:space:]]*true"
}

hook_phone_apply() {
    restart_drop "$PHONE_BACK"   # phones are shut out again: nothing to wait for
    return 0
}
hook_phone_restore() { :; }   # the settings are put back next: see hook_phone_restored
hook_phone_restored() {
    kv_get settings.network | grep -q "\"$PHONE_KEY\"[[:space:]]*:[[:space:]]*true" || return 0
    command -v luna-send >/dev/null 2>&1 || return 0
    [ "$OYG_DRYRUN" = 1 ] && return 0
    phone_access_on && need_restart "$PHONE_BACK"
    return 0
}
hook_phone_status() { return 0; }   # the setting shows in the app; the service lines cover the rest

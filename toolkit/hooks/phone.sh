# phone — the restart LG's phone server needs after the option is undone
# (option phone; its setting and services are declarative).
#
# The option turns allowMobileDeviceAccess off. LG's second-screen gateway
# (SSAP, the phone remote API) stops its server when the setting goes off,
# but starts it only once per run of the service: when the setting comes
# back on, the server stays down until the TV restarts, and phone remote apps
# can neither connect nor pair (verified on the C5). If the TV restarted
# while the setting was off, the gateway never started its server and does
# so when the setting comes back on: no restart needed.
#
# So the boot in which OYG turned the setting off is recorded; undoing the
# option in that same boot asks for a restart (oyg status: META|restart; the
# app offers Restart now / Later).

PHONE_BACK="Phone remote apps work again"

hook_phone_apply() {
    case " $OPT_SETTINGS_CHANGED " in
        *" allowMobileDeviceAccess "*) kv_set off_boot "$(boot_stamp)" ;;
    esac
    restart_drop "$PHONE_BACK"   # phones are shut out again: nothing to wait for
    return 0
}
hook_phone_restore() {   # runs before the settings are put back
    same_boot "$(kv_get off_boot)" && need_restart "$PHONE_BACK"
    return 0
}
hook_phone_status() { return 0; }   # the setting shows in the app; the service lines cover the rest

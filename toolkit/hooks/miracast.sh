# miracast — Screen Share needs a restart once OYG has stopped it (option
# miracast; its services are declarative).
#
# Starting Miracast again after an undo (and avahi first, which it calls at
# start-up) is not enough: the TV is listed again and even shows the phone's
# request, but the connection fails until the TV restarts (C5, Smart View
# from a Galaxy S25; fine after a restart). So the boot in
# which Miracast was stopped is recorded, and undoing the option in that same
# boot asks for a restart. After a restart with the option on, the boot apply
# stops Miracast again, so that boot counts too.

MIRACAST_BACK="Screen Share works again"

hook_miracast_apply() {
    state_has units miracast.service && kv_set stopped_boot "$(boot_stamp)"
    restart_drop "$MIRACAST_BACK"   # it is off again: nothing to wait for
    return 0
}
hook_miracast_restore() {   # runs before the services start again
    same_boot "$(kv_get stopped_boot)" && need_restart "$MIRACAST_BACK"
    return 0
}
hook_miracast_status() { return 0; }

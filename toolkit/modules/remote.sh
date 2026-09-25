# remote — LG remote support and the LAN doors a rooted TV leaves open.
#
#   remotediag        RemoteOne: LG support can push authorized_keys, install
#                     dropbear, capture the screen, send keys, reboot and
#                     factory-reset the TV (rone-*.lge.com). The unit is gated
#                     by /mnt/lg/cmn_data/remoteDebug/remoteDebug.sh, but the
#                     daemon is also dbus/luna-activatable, so the binary is
#                     bound whatever the gate says.
#   telnet            Homebrew Channel starts an unauthenticated root shell
#                     on :23 unless webosbrew_telnet_disabled exists. Its
#                     failsafe boot path starts telnetd regardless of the flag.
#   hbchannel tree    ships 0777 (service.js, bin/, certs/): any sandboxed app
#                     could rewrite the root service. Tightened to 0755/0644.
MOD_REMOTE_DESC="Remote support daemon, telnet root shell, world-writable root service"
MOD_REMOTE_DEFAULT=on

REMOTE_SPEC='
remotediag|remotediag.service|?|remotediag|
'
REMOTE_GATE=/mnt/lg/cmn_data/remoteDebug
TELNET_FLAG=/var/luna/preferences/webosbrew_telnet_disabled
HBC_SVC=/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service

mod_remote_apply() {
    printf '%s\n' "$REMOTE_SPEC" | svc_apply
    if [ -e "$REMOTE_GATE" ]; then
        warn "$REMOTE_GATE exists: remote support has been provisioned on this TV (left in place, inspect it)"
    fi
    if [ ! -e "$TELNET_FLAG" ]; then
        run "touch $TELNET_FLAG" touch "$TELNET_FLAG" && mark_created "$TELNET_FLAG"
        kill_procs telnetd
        ok "telnet root shell disabled (takes effect now and at boot)"
    fi
    if [ -d "$HBC_SVC" ]; then
        # the whole tree: bin/ and certs/ ship 0777 too, and an update of
        # Homebrew Channel puts service.js back to 0666. Executables keep
        # their x bit, everything else becomes 0644.
        find "$HBC_SVC" -type d | while read -r d; do set_mode "$d" 755; done
        find "$HBC_SVC" -type f | while read -r f; do
            if [ -x "$f" ]; then set_mode "$f" 755; else set_mode "$f" 644; fi
        done
        ok "homebrew channel service tree is no longer world-writable"
    fi
    return 0
}
mod_remote_restore() { generic_restore; }
mod_remote_status() {
    printf '%s\n' "$REMOTE_SPEC" | svc_status REMOTE; _r=$?
    [ -e "$REMOTE_GATE" ] && { st REMOTE FAIL "remote-debug gate present ($REMOTE_GATE)"; _r=1; }
    if running telnetd; then st REMOTE FAIL "telnetd is listening"; _r=1
    elif [ -e "$TELNET_FLAG" ]; then st REMOTE OK "telnet disabled"
    else st REMOTE WARN "telnet flag not set"; fi
    if [ -d "$HBC_SVC" ]; then
        _ww=$(find "$HBC_SVC" -perm -002 ! -type l 2>/dev/null | head -1)
        if [ -n "$_ww" ]; then st REMOTE WARN "hbchannel service tree is world-writable ($_ww)"; else st REMOTE OK "hbchannel service tree locked"; fi
    fi
    return $_r
}

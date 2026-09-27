# adid — zero LG's advertising ID and keep it zero (option adid).
#
# The advertising ID (IFA) lives in /var/lib/secretagent/IFA.txt (a UUID,
# no newline). admanager hands it to apps and LG Channels' engine puts it in
# its beacons; something rewrites it now and then (C5). All zeros is what
# "limit ad tracking" means on other platforms. A zero file is bound over it
# read-only, so nothing can write a new one while the option is on; the real
# file underneath is untouched and undo only unbinds. Re-applied at boot
# like every option. The device IDs next to it (nduid) are left alone: LG's
# servers use them to authenticate the TV.

ADID_FILE=/var/lib/secretagent/IFA.txt
ADID_ZERO=00000000-0000-0000-0000-000000000000

hook_adid_apply() {
    [ -f "$ADID_FILE" ] || { info "no advertising ID file on this TV"; return 0; }
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) zero the advertising ID ($ADID_FILE)"; return 0; fi
    _az="$OYG_ROOT/adid.zero"
    if is_mounted "$ADID_FILE" && state_has mounts "$ADID_FILE" && [ "$(cat "$ADID_FILE" 2>/dev/null)" = "$ADID_ZERO" ] && ro_ok "$_az"; then
        ok "advertising ID zeroed (unchanged)"; return 0
    fi
    printf '%s' "$ADID_ZERO" > "$_az"
    if bind_file_ro "$_az" "$ADID_FILE"; then ok "advertising ID zeroed (read-only)"; else warn "could not zero the advertising ID"; fi
    return 0
}
hook_adid_restore() { :; }   # the bind is recorded: generic restore
hook_adid_status() {
    [ -f "$ADID_FILE" ] || { st "$1" NA "no advertising ID file on this TV"; return 0; }
    [ "$(cat "$ADID_FILE" 2>/dev/null)" = "$ADID_ZERO" ] && { st "$1" OK "advertising ID is zero"; return 0; }
    st "$1" WARN "advertising ID is not zero (apply again)"; return 1
}

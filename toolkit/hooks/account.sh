# account — block the LG account (option account): remove any signed-in
# account, and sinkhole LG's sign-in page and account server (kb/hosts.toml)
# so none can sign in again.
#
# A signed-in LG account signs itself in at every boot (there is no LG switch
# for "stored but not signed in": loginAccount carries no such flag), and
# after that sign-in accountmanager checks the account's terms and raises the
# terms prompt. With no account LG cannot tie what the TV does to one and the
# prompt has nothing to check; with sign-in blocked none comes back (the
# Content Store cannot install apps then: turn the option off to sign in).
#
# The sign-out is LG's own call, logoutAccount (captured on the C5 from the
# TV's account page): mode "shallow" signs out and keeps the account on the
# TV; mode "deep" also deletes its stored sign-in. Whether an account is
# signed in is a yes/no from getLoginID: the login id itself is never kept,
# printed or logged, and the user number the call needs stays inside one
# command. The option removes the account (deep).
# Undoing the option does not sign back in (that takes the password).

ACCOUNT_SVC=LGE
ACCOUNT_LOGOUT_MODE=${ACCOUNT_LOGOUT_MODE:-shallow}   # sign out as the TV's own account page does; deep also removes it

account_signed_in() {
    luna luna://com.webos.service.accountmanager/getLoginID "{\"serviceName\":\"$ACCOUNT_SVC\"}" | grep -q '"id" *: *"[^"]'
}
account_signout() {  # account_signout [shallow|deep]
    _am=${1:-$ACCOUNT_LOGOUT_MODE}
    [ -n "$_am" ] || { warn "LG account sign-out is not available in this version"; return 1; }
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) sign out of the LG account ($_am)"; return 0; fi
    luna_ok luna://com.webos.service.accountmanager/logoutAccount "{\"serviceName\":\"$ACCOUNT_SVC\",\"mode\":\"$_am\",\"userNo\":\"$(luna luna://com.webos.service.accountmanager/getLoginID "{\"serviceName\":\"$ACCOUNT_SVC\"}" | sed -n 's/.*"lastSignInUserNo" *: *"\([^"]*\)".*/\1/p')\"}"
}
# accountmanager answers the sign-out before it has finished: give it a few
# seconds to report the account gone
account_gone() { _ag=0; while [ $_ag -lt 10 ]; do account_signed_in || return 0; sleep 0.5; _ag=$((_ag+1)); done; return 1; }
# oyg account status|signout|remove: signout keeps the account on the TV
# (mode shallow, as the TV's own account page does); remove also deletes its
# stored sign-in from the TV (mode deep)
do_account() {
    case ${1:-status} in
        status) account_signed_in && echo "signed in" || echo "signed out" ;;
        signout|remove)
            need_root
            account_signed_in || { ok "no LG account is signed in"; return 0; }
            _mode=shallow; [ "$1" = remove ] && _mode=deep
            if account_signout "$_mode" && account_gone; then
                [ "$_mode" = deep ] && ok "LG account removed from this TV" || ok "signed out of the LG account"
            else warn "the LG account is still signed in"; return 1; fi ;;
        *) die "usage: oyg account status|signout|remove" ;;
    esac
}

# 1.4.31-1.4.32 ran a watcher that removed the account after each wake from
# standby; with sign-in blocked there is nothing to watch, so it is stopped.
ACCOUNT_WATCH="$OYG_ROOT/account-watch.sh"
ACCOUNT_PID="$OYG_ROOT/account-watch.pid"
account_watch_stop() {
    [ -f "$ACCOUNT_PID" ] || [ -f "$ACCOUNT_WATCH" ] || return 0
    [ "$OYG_DRYRUN" = 1 ] && return 0
    _p=$(cat "$ACCOUNT_PID" 2>/dev/null)
    ps_snapshot
    # its own process group only: other programs follow the power state too
    [ -n "$_p" ] && kill_pids account-watch "$_p" $(pgrp_pids "$_p") $(orphans_of_arg account-watch.sh)
    rm -f "$ACCOUNT_PID" "$ACCOUNT_WATCH" "$OYG_ROOT/account-watch.log"
}

hook_account_apply() {
    account_watch_stop
    command -v luna-send >/dev/null 2>&1 || return 0
    if account_signed_in; then
        if account_signout deep && account_gone; then ok "LG account removed from this TV"; else warn "could not remove the LG account"; fi
    else ok "no LG account on this TV"; fi
    info "LG account sign-in blocked (its page and account server are sinkholed)"
    return 0
}
hook_account_restore() { account_watch_stop; info "LG account sign-in allowed again: sign in from LG Account when you need it"; }
hook_account_status() {
    command -v luna-send >/dev/null 2>&1 || { st "$1" NA "no account service"; return 0; }
    if account_signed_in; then st "$1" WARN "an LG account is signed in (apply again to remove it)"; return 1; fi
    st "$1" OK "no LG account on this TV"
}

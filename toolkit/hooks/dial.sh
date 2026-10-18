# dial — DIAL's ports closed to the network (option dial).
#
# DIAL is how a phone app finds the TV and starts an app on it, with no
# pairing (Spotify, YouTube), and it can turn the TV off. xinetd answers it
# on 36866 (phones) and 18181 (TV apps) and hands each connection to
# com.webos.service.dial in the shared JS server. The option's launch block
# keeps that service from loading, but when it loaded before the boot hook
# it stays (RESIDENT) and nothing can unload it on its own. One chain
# refuses both ports on every interface but loopback, whoever answers them,
# so the block holds in that boot too. Computers on the LAN firewall's
# allow list still get through. The sockets are dual-stack and netfilter
# here is IPv4 only: status says so when the TV has an IPv6 address.

DIAL_CHAIN=OYG_DIAL
DIAL_PORTS="36866 18181"

# shellcheck disable=SC2086
dial_rules() { ports_rules "$1" $DIAL_PORTS; }
# shellcheck disable=SC2086
dial_closed() { ports_closed "$DIAL_CHAIN" $DIAL_PORTS; }

hook_dial_apply() {
    command -v iptables >/dev/null 2>&1 || { info "no iptables on this TV: DIAL's ports cannot be closed"; return 0; }
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) close DIAL's ports ($DIAL_PORTS) to the network"; return 0; fi
    if ipt_chain "$DIAL_CHAIN" dial_rules && dial_closed; then
        ok "DIAL closed to the network$( [ -s "$LAN_ALLOW" ] && echo " (allowed devices excepted)")"
    else warn "could not close DIAL's ports (iptables refused a rule)"; fi
    return 0
}
hook_dial_restore() { :; }   # the chain is recorded: generic restore
hook_dial_status() {
    command -v iptables >/dev/null 2>&1 || { st "$1" NA "no iptables on this TV"; return 0; }
    if ! dial_closed; then st "$1" WARN "DIAL open to the network"; return 1; fi
    st "$1" OK "DIAL closed to the network"
    ipv6_reachable && { st "$1" WARN "the TV has an IPv6 address, which the firewall cannot cover (the LAN firewall option turns IPv6 off)"; return 1; }
    return 0
}

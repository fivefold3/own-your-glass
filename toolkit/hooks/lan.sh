# lan — close the TV to incoming connections from the network (option lan).
#
# A rooted TV answers more of the LAN than its owner expects: the phone
# remote API (SSAP, 3000/3001: screenshots, input, power once paired), DIAL
# (36866/18181: unauthenticated app launch and power-off), LG Link (webOS 11,
# 50051/50052: insecure gRPC), AirPlay and HomeKit, the Chromecast receiver,
# unauthenticated printing (LPD, 515) and the web-app debugger (9998). The
# last two have options of their own in every preset (printing, debugger),
# and DIAL's ports are closed by the DIAL option as well.
#
# One chain, OYG_LAN, jumped to first from INPUT. The kernels of webOS 10
# and 11 track connections but have no iptables match for it (no
# xt_conntrack, no xt_state), so the chain works on packets:
#   - TCP: every packet that opens a connection (SYN) is refused, SSH
#     included, except from the allow list (oyg lan allow <ip>: a computer
#     that should keep SSH). The way back otherwise is the app on the TV. Answers to
#     connections the TV opened itself never open one, so browsing and
#     streaming are untouched. This covers every TCP service, known or not.
#   - UDP: the TV's own service ports (everything below the range the
#     kernel hands out for outgoing traffic, plus LIFX's 56700) are closed,
#     except DHCP. Answers to the TV's DNS, time and QUIC traffic arrive on
#     ports from that range and still get through.
#   - ping is not answered.
# Loopback always passes.
#
# Netfilter on these kernels is IPv4 only (webOS 10 and 11), so IPv6 is
# switched off on eth0 and wlan0 while the option is on (recorded, and put
# back on restore); webOS 11 also turns on router advertisements at every
# boot (accept_ra 2). On webOS 10 and older, rdisc (any LAN host can inject
# a default route) and ninfod are stopped. The printing port (LPD, 515) is
# the printing option's, in every preset.

LAN_CHAIN=OYG_LAN
LAN_KEEP_TCP=""                    # nothing, SSH included (the owner's call); oyg lan allow lets a device through
LAN_UDP_EXTRA="56700"              # LIFX (Universal Control's scanner), a fixed port in the high range
LAN_UNITS="rdisc.service ninfod.service"

# Up to 1.5.1 this option stopped the printing socket. Its record moves to
# the printing option that owns it now, so undoing the LAN firewall cannot
# start the port again behind the printing option's back.
lan_handover_lpd() {
    state_has units cups-lpd.socket || return 0
    [ "$OYG_DRYRUN" = 1 ] && return 0
    state_del units cups-lpd.socket
    _lho=$OYG_MOD; OYG_MOD=printing; state_add units cups-lpd.socket; OYG_MOD=$_lho
}

lan_rules() {  # lan_rules <chain>
    ipt -A "$1" -i lo -j RETURN || return 1
    for _p in $LAN_KEEP_TCP; do ipt -A "$1" -p tcp --dport "$_p" -j RETURN || return 1; done
    if [ -f "$LAN_ALLOW" ]; then
        for _a in $(grep -v '^#' "$LAN_ALLOW"); do ipt -A "$1" -s "$_a" -j RETURN || return 1; done
    fi
    { ipt -A "$1" -p tcp --syn -j REJECT --reject-with tcp-reset || ipt -A "$1" -p tcp --syn -j DROP; } || return 1
    ipt -A "$1" -p udp --sport 67 --dport 68 -j RETURN || return 1
    ipt -A "$1" -p udp --dport "1:$(( $(lan_ephemeral) - 1 ))" -j DROP || return 1
    for _p in $LAN_UDP_EXTRA; do ipt -A "$1" -p udp --dport "$_p" -j DROP || return 1; done
    ipt -A "$1" -p icmp --icmp-type echo-request -j DROP
}
# the chain is in place and refuses new TCP connections
lan_closed() {
    ipt -C INPUT -j "$LAN_CHAIN" || return 1
    ipt -C "$LAN_CHAIN" -p tcp --syn -j REJECT --reject-with tcp-reset || ipt -C "$LAN_CHAIN" -p tcp --syn -j DROP
}
# the first port of the kernel's range for outgoing traffic (32768 by default)
lan_ephemeral() { _r=$(cut -f1 /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null | tr -d ' '); printf '%s' "${_r:-32768}"; }

# oyg lan allow|deny <ip or cidr>, oyg lan list: the devices that may still
# connect to the TV (applied at once when the LAN firewall is on)
do_lan() {
    case ${1:-list} in
        list) [ -f "$LAN_ALLOW" ] && grep -v '^#' "$LAN_ALLOW" | grep . || echo "(no devices allowed)" ;;
        allow|deny)
            need_root; [ -n "${2:-}" ] || die "usage: oyg lan $1 <ip or cidr>"
            printf '%s' "$2" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' || die "not an IPv4 address or CIDR: $2"
            [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) lan $1 $2"; return 0; }
            mkdir -p "$OYG_ROOT"
            { grep -vxF "$2" "$LAN_ALLOW" 2>/dev/null; [ "$1" = allow ] && printf '%s\n' "$2"; } > "$LAN_ALLOW.t"; mv "$LAN_ALLOW.t" "$LAN_ALLOW"
            # the address stays out of the log (it is on flash): the count is enough
            [ "$1" = allow ] && ok "one more device may connect to the TV ($(grep -c . "$LAN_ALLOW") allowed)" || ok "a device left the allow list ($(grep -c . "$LAN_ALLOW") allowed)"
            _sel=$(selected_options)
            for _lo in lan debugger dial; do
                printf '%s\n' "$_sel" | grep -qx "$_lo" && { OYG_MOD=$_lo; "hook_${_lo}_apply"; OYG_MOD=core; }
            done ;;
        *) die "usage: oyg lan allow|deny <ip or cidr> | oyg lan list" ;;
    esac
}

hook_lan_apply() {
    lan_handover_lpd
    command -v iptables >/dev/null 2>&1 || { info "no iptables on this TV: LAN firewall not available"; return 0; }
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) close the TV to incoming connections"; return 0; fi
    # the chain is built complete before the jump moves to it (ipt_chain): the
    # SSH session running this keeps working, and no port opens in between
    if ipt_chain "$LAN_CHAIN" lan_rules && lan_closed; then
        ok "the TV is closed to incoming connections$( [ -s "$LAN_ALLOW" ] && echo " (allowed devices excepted)")"
    else warn "could not close the TV to incoming connections (iptables refused a rule)"; fi
    for _u in $LAN_UNITS; do have_unit "$_u" && stop_unit "$_u"; done
    # IPv6 is not filtered: switch it off, and stop taking router advertisements
    for _i in $LAN_IFACES; do
        for _k in disable_ipv6:1 accept_ra:0; do
            _n=${_k%%:*}; _want=${_k#*:}; _sys=/proc/sys/net/ipv6/conf/$_i/$_n
            [ -w "$_sys" ] || continue
            _v=$(cat "$_sys"); [ "$_v" = "$_want" ] && continue
            [ -n "$(kv_get "$_n.$_i")" ] || kv_set "$_n.$_i" "$_v"
            printf %s "$_want" > "$_sys"
        done
    done
    info "IPv6 is off on $LAN_IFACES while the LAN firewall is on (it cannot filter IPv6)"
    return 0
}
hook_lan_restore() {
    for _i in $LAN_IFACES; do
        for _n in accept_ra disable_ipv6; do
            _v=$(kv_get "$_n.$_i"); [ -n "$_v" ] || continue
            [ "$OYG_DRYRUN" = 1 ] || printf '%s' "$_v" > "/proc/sys/net/ipv6/conf/$_i/$_n" 2>/dev/null
        done
    done
}   # the chain and the units are recorded: generic restore
hook_lan_status() {
    command -v iptables >/dev/null 2>&1 || { st "$1" NA "no iptables on this TV"; return 0; }
    if ! lan_closed; then st "$1" WARN "LAN firewall not in place"; return 1; fi
    st "$1" OK "closed to incoming connections"
    _v6=""; for _i in $LAN_IFACES; do [ "$(cat "/proc/sys/net/ipv6/conf/$_i/disable_ipv6" 2>/dev/null)" = 0 ] && _v6="$_v6 $_i"; done
    [ -z "$_v6" ] || { st "$1" WARN "IPv6 is on for$_v6, which the firewall cannot cover (apply again)"; return 1; }
    return 0
}

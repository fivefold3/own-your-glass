# debugger — the web-app debugger (option debugger).
#
# WebAppMgr is started with --remote-debugging-port=9998 and
# ENABLE_INSPECTOR=1 on every surveyed image (webOS 5.6 to 11.2), Developer
# Mode or not, and listens on 0.0.0.0 (C5). There is no password: anyone on
# the network can attach to a web app that is open (the Content Store, LG's
# web apps, Homebrew Channel, whose service runs as root) and run code in it.
# One chain refuses the port on every interface but loopback, so
# `ssh -L 9998:localhost:9998` (what ares-inspect does) still reaches it, and
# so do the computers on the LAN firewall's allow list (`oyg lan allow`).
# The listener is IPv4 only, as netfilter on these kernels is; status says
# so if that ever changes. The LAN firewall (option lan) closes the port as
# well, with everything else.

DBG_CHAIN=OYG_DBG
DBG_PORT=9998

dbg_rules() { ports_rules "$1" "$DBG_PORT"; }
dbg_closed() { ports_closed "$DBG_CHAIN" "$DBG_PORT"; }

hook_debugger_apply() {
    command -v iptables >/dev/null 2>&1 || { info "no iptables on this TV: the debugger port cannot be closed"; return 0; }
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) close port $DBG_PORT to the network"; return 0; fi
    if ipt_chain "$DBG_CHAIN" dbg_rules && dbg_closed; then
        ok "web-app debugger closed to the network$( [ -s "$LAN_ALLOW" ] && echo " (allowed devices excepted)")"
    else warn "could not close the web-app debugger (iptables refused a rule)"; fi
    return 0
}
hook_debugger_restore() { :; }   # the chain is recorded: generic restore
hook_debugger_status() {
    command -v iptables >/dev/null 2>&1 || { st "$1" NA "no iptables on this TV"; return 0; }
    if ! dbg_closed; then st "$1" WARN "web-app debugger open to the network"; return 1; fi
    st "$1" OK "web-app debugger closed to the network"
    port_listening "$DBG_PORT" v6 && { st "$1" WARN "the debugger also listens on IPv6, which the firewall cannot cover"; return 1; }
    return 0
}

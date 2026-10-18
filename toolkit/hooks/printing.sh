# printing — the LPD print server (option printing; the socket unit and the
# cups-lpd binary are the option's service spec, kb/services.toml).
#
# systemd listens on port 515 on every address, IPv4 and IPv6, for CUPS's
# LPD server and starts cups-lpd for each connection, with no login. The
# spec stops the socket and binds cups-lpd to /dev/null, so a socket started
# again cannot run it either. Status checks that nothing listens on 515.

LPD_BIN=/usr/libexec/cups/daemon/cups-lpd


hook_printing_apply() { :; }     # the service spec does it
hook_printing_restore() { :; }   # recorded: generic restore
hook_printing_status() {
    [ -e "$LPD_BIN" ] || return 0   # no LPD server on this TV (the spec says so)
    if port_listening 515; then st "$1" WARN "printing port 515 still open"; return 1; fi
    st "$1" OK "printing port 515 closed"
}

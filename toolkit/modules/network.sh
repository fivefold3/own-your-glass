# network — sinkhole the ad, ACR and telemetry hostnames.
#
# Secondary by design: the modules above stop the senders; this catches
# anything that is still curious (HbbTV pages, app SDKs, the browser).
# /etc is read-only, so the generated hosts file is bind-mounted over
# /etc/hosts. Every name gets an IPv4 and an IPv6 entry, because an
# IPv4-only sinkhole lets AAAA lookups fall through. Homebrew Channel may
# already have its own hosts overlay in place (update blocking); ours is
# generated from whatever /etc/hosts currently shows, so it keeps those
# entries, and restoring unmounts only our layer.
#
# The fixed list is in etc/blocklist.txt. On top of it come the hosts that
# only blocked sdx services use, read from sdx's own routing table with the
# country and region prefixes this TV uses (sdx_blocked_hosts, modules/sdx.sh),
# so the list fits whatever region the TV is set to.
# Anything that resolves names without /etc/hosts is not covered; that gap is
# best closed at the router. This toolkit never touches ConnMan.
MOD_NETWORK_DESC="Sinkhole ad, ACR and telemetry hostnames via /etc/hosts"
MOD_NETWORK_DEFAULT=on
MOD_NETWORK_BREAKS="Anything that uses a sinkholed host stops working; LG's clock, Content Store and sign-in hosts are left alone"

HOSTS_GEN="$OYG_ROOT/hosts"
HOSTS_MARK="# own-your-glass"
BLOCKLIST="$OYG_ROOT/toolkit/etc/blocklist.txt"

# tools/bundle.sh inlines etc/blocklist.txt as $BLOCKLIST_INLINE for single-file runs
network_source() { if [ -f "$BLOCKLIST" ]; then cat "$BLOCKLIST"; else printf '%s\n' "${BLOCKLIST_INLINE:-}"; fi; }
network_domains() { { network_source | sed 's/#.*//' | awk 'NF{print $1}'; sdx_blocked_hosts; } | sort -u; }

mod_network_apply() {
    [ -f "$BLOCKLIST" ] || BLOCKLIST="$OYG_TK/etc/blocklist.txt"
    _doms=$(network_domains); _nd=$(printf '%s\n' "$_doms" | grep -c .)   # built once: it asks sdx
    [ -n "$_doms" ] || { fail "blocklist not found"; return 1; }
    # base = the hosts file as it is now, minus any previous layer of ours
    if grep -q "^$HOSTS_MARK" /etc/hosts 2>/dev/null; then unbind /etc/hosts; fi
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) bind generated hosts ($_nd names) over /etc/hosts"; return 0; fi
    { cat /etc/hosts 2>/dev/null; printf '%s begin\n' "$HOSTS_MARK"
      printf '%s\n' "$_doms" | awk 'NF{printf "0.0.0.0 %s\n::1 %s\n", $1, $1}' 
      printf '%s end\n' "$HOSTS_MARK"; } > "$HOSTS_GEN.tmp" && mv "$HOSTS_GEN.tmp" "$HOSTS_GEN"
    bind_file "$HOSTS_GEN" /etc/hosts && ok "$_nd hostnames sinkholed"
    kv_set applied 1
}
mod_network_restore() { generic_restore; rm -f "$HOSTS_GEN"; }
mod_network_status() {
    if grep -q "^$HOSTS_MARK" /etc/hosts 2>/dev/null; then st NETWORK OK "$(grep -c '^0\.0\.0\.0' /etc/hosts) hostnames sinkholed"; return 0; fi
    st NETWORK WARN "hosts overlay not mounted"; return 1
}

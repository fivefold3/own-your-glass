# network — sinkhole the hostnames the enabled options list.
#
# Secondary by design: the services each option stops are the senders; this
# catches anything that is still curious (HbbTV pages, app SDKs, the browser).
# /etc is read-only, so the generated hosts file is bind-mounted over
# /etc/hosts. Every name gets an IPv4 and an IPv6 entry, because an
# IPv4-only sinkhole lets AAAA lookups fall through. Homebrew Channel may
# already have its own hosts overlay in place (update blocking); ours is
# generated from whatever /etc/hosts currently shows, so it keeps those
# entries, and restoring unmounts only our layer.
#
# The names come from the enabled options (etc/options.sh, set by the engine
# as NET_HOSTS), with two templates: {ric}.x is x and its aic./eic./kic.
# variants, {cc}.x uses this TV's country. On top of them come the hosts that
# only blocked gateway names use, read from sdx's own routing table with the
# prefixes this TV uses (sdx_blocked_hosts, resources/sdx.sh). Whatever an
# option says, the never list (the online check, the terms UI, the gateway
# and Store hosts sign-in and the clock ride on) is filtered out.
# App jails (Prime Video, the voice performer, ThinQ AI, Chromecast) get a
# private copy of /etc/hosts when they are set up, so a jail that exists
# before apply never sees the bind; those copies get our list written into
# them (a write, not a bind: the jailer replaces the file when it rebuilds a
# jail, and a mountpoint there would make that fail).
# Anything that resolves names without /etc/hosts is not covered; that gap is
# best closed at the router. This toolkit never touches ConnMan.

HOSTS_GEN="$OYG_ROOT/hosts"
HOSTS_MARK="# own-your-glass"
NET_HOSTS=${NET_HOSTS:-}

# The country codes LG serves: the TV's own list where it exists
# (etc/palm/countryList.json, on every surveyed image) plus the knowledge
# base's copy; placeholders (__, xa-xe) left out.
lg_countries() {
    { [ -f /etc/palm/countryList.json ] && grep -o '"shortName": *"[A-Za-z][A-Za-z]"' /etc/palm/countryList.json | sed 's/.*"\([A-Za-z]*\)"$/\1/'
      printf '%s\n' $OYG_COUNTRIES; } | tr 'A-Z' 'a-z' | grep -E '^[a-z]{2}$' | grep -vE '^x[a-e]$' | sort -u
}
# {cc}. takes the TV's country once sdx has told it (sdx.prefixes); until
# then, every country LG serves, so a first apply while sdx is silent still
# covers the account and diagnostics hosts (the names used to be dropped)
hosts_cc_known() { [ -n "$(sdx_known default)" ]; }
hosts_expand() {  # names (any whitespace) on stdin → concrete lower-case names
    _cc=$(sdx_known default | tr 'A-Z' 'a-z')
    [ -n "$_cc" ] || _cc=$(lg_countries | tr '\n' ' ')
    tr 'A-Z' 'a-z' | awk -v ccs="$_cc" -v rics="$OYG_RICS" '
        BEGIN { nc = split(ccs, c, " "); nr = split(rics, r, " ") }
        { for (i = 1; i <= NF; i++) { n = $i
            if (substr(n, 1, 6) == "{ric}.") { b = substr(n, 7); print b; for (j = 1; j <= nr; j++) print r[j] "." b }
            else if (substr(n, 1, 5) == "{cc}.") { for (j = 1; j <= nc; j++) print c[j] "." substr(n, 6) }
            else print n } }'
}
hosts_never_filter() {  # drop never-sinkhole names (etc/options.sh NEVER_HOST_*)
    awk -v names="$NEVER_HOSTS" -v suf="$NEVER_HOST_SUFFIXES" -v pre="$NEVER_HOST_PREFIXED" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) nv[a[i]] = 1; ns = split(suf, s, " "); np = split(pre, p, " ") }
        { h = $0; if (h == "" || (h in nv)) next
          for (i = 1; i <= ns; i++) if (length(h) >= length(s[i]) && substr(h, length(h) - length(s[i]) + 1) == s[i]) next
          for (i = 1; i <= np; i++) { if (h == p[i]) next; t = "." p[i]
              if (length(h) > length(t) && substr(h, length(h) - length(t) + 1) == t && index(substr(h, 1, length(h) - length(t)), ".") == 0) next }
          print h }'
}
# with gateway routes cut, the TV looks up <prefix>.oyg.invalid (the sink the
# table points at): answer those here instead of at the router
network_domains() { { printf '%s\n' "$NET_HOSTS" | hosts_expand; [ -n "${SDX_BLOCK:-}" ] && printf '%s\n' "$SDX_SINK {ric}.$SDX_SINK {cc}.$SDX_SINK" | hosts_expand; sdx_blocked_hosts | tr 'A-Z' 'a-z'; } | hosts_never_filter | sort -u; }

res_network_apply() {
    _doms=$(network_domains); _nd=$(printf '%s\n' "$_doms" | grep -c .)
    if [ -z "$_doms" ]; then res_network_restore; return 0; fi
    if [ "$OYG_DRYRUN" = 1 ]; then
        _jn=0; for f in $(network_jail_hosts); do grep -q "^$HOSTS_MARK" "$f" 2>/dev/null || _jn=$((_jn+1)); done
        info "(dry-run) bind generated hosts ($_nd names) over /etc/hosts; write them into $_jn app jails"; return 0
    fi
    # base = the hosts file as it is now, minus any previous layer of ours
    { sed "/^$HOSTS_MARK begin/,/^$HOSTS_MARK end/d" /etc/hosts 2>/dev/null; printf '%s begin\n' "$HOSTS_MARK"
      printf '%s\n' "$_doms" | awk 'NF{printf "0.0.0.0 %s\n::1 %s\n", $1, $1}'
      printf '%s end\n' "$HOSTS_MARK"; } > "$HOSTS_GEN.new"
    # unchanged and still read-only: leave the bind alone (re-binding opens a
    # moment with no sinkhole)
    if grep -q "^$HOSTS_MARK" /etc/hosts 2>/dev/null && state_has mounts /etc/hosts \
        && [ "$(md5sum < "$HOSTS_GEN.new")" = "$(md5sum < /etc/hosts)" ] && ro_ok "$HOSTS_GEN"; then
        rm -f "$HOSTS_GEN.new"; ok "$_nd hostnames sinkholed (unchanged)"
    else
        mv "$HOSTS_GEN.new" "$HOSTS_GEN"
        bind_file_ro "$HOSTS_GEN" /etc/hosts && ok "$_nd hostnames sinkholed"
    fi
    # jails without the block get it; a jail whose block is older (set up
    # under an earlier bind, so never written by OYG) is brought up to date
    if hosts_cc_known; then kv_set fallback ""
    else
        kv_set fallback 1
        warn "the TV's country is not known yet: the country-coded names are sinkholed for every country LG serves (apply again once the TV has been online)"
        toast "Own Your Glass: TV's country not known yet, blocking those addresses for every country. Apply again later."
    fi
    _j=0; _bm=$(sed -n "/^$HOSTS_MARK begin/,/^$HOSTS_MARK end/p" "$HOSTS_GEN" | md5sum)
    for f in $(network_jail_hosts); do
        if grep -q "^$HOSTS_MARK" "$f" 2>/dev/null; then
            [ "$(sed -n "/^$HOSTS_MARK begin/,/^$HOSTS_MARK end/p" "$f" | md5sum)" = "$_bm" ] && continue
        fi
        backup_once "$f" && cat "$HOSTS_GEN" > "$f" && _j=$((_j+1))
    done
    [ $_j = 0 ] || ok "sinkhole written into $_j app jails"
    kv_set applied 1
    kv_set count "$_nd"
}
JAIL_ROOT=${JAIL_ROOT:-/var/palm/jail}
network_jail_hosts() { for _f in "$JAIL_ROOT"/*/etc/hosts; do [ -f "$_f" ] && ! is_mounted "$_f" && printf '%s\n' "$_f"; done; }
# A jail the jailer sets up while the sinkhole is bound copies it, and older
# versions left their marked block in jails too; neither copy is on record.
# The sinkhole is the stock file plus our block, so taking the block out
# gives the stock file back. The file keeps its time.
network_strip_jails() {
    _n=0
    for f in $(network_jail_hosts); do
        grep -q "^$HOSTS_MARK" "$f" 2>/dev/null || continue
        _n=$((_n+1)); [ "$OYG_DRYRUN" = 1 ] && continue
        edit_keep_mtime "$f" sed "/^$HOSTS_MARK begin/,/^$HOSTS_MARK end/d"
    done
    [ $_n = 0 ] && return 0
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) take the sinkhole out of $_n app jails"; else ok "sinkhole taken out of $_n app jails"; fi
}
res_network_restore() { generic_restore; network_strip_jails; unbind_src "$HOSTS_GEN"; [ "$OYG_DRYRUN" = 1 ] || rm -f "$HOSTS_GEN"; }
res_network_status() {
    if ! grep -q "^$HOSTS_MARK" /etc/hosts 2>/dev/null; then st "$1" WARN "hosts overlay not mounted"; return 1; fi
    st "$1" OK "$(grep -c '^0\.0\.0\.0' /etc/hosts) hostnames sinkholed"; _r=0
    [ "$(kv_get fallback)" = 1 ] && { st "$1" WARN "the TV's country is not known yet: country-coded names sinkholed for every country (apply again once online)"; _r=1; }
    _rw=$(rw_peers "$HOSTS_GEN" | head -1)
    [ -n "$_rw" ] && { st "$1" FAIL "hosts overlay is writable at $_rw"; _r=1; }
    _u=0; for f in $(network_jail_hosts); do grep -q "^$HOSTS_MARK" "$f" 2>/dev/null || _u=$((_u+1)); done
    [ $_u = 0 ] || { st "$1" WARN "$_u app jails have their own hosts file without the sinkhole (apply again)"; _r=1; }
    return $_r
}

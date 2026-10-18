# screenshots — the screenshots the TV takes besides the OLED panel's
# (option screenshots; that one is the capture option).
#
#   Recents     surface-manager saves a JPEG of the app on screen (at app
#               switches, and again a little later) for Home's Recents row, in
#               /tmp/snapshots/<account>/ (default with no LG account), with
#               a backup path on flash (WEBOS_SCREEN_CAPTURE_BACKUP_PATH,
#               /mnt/lg/cmn_data/snapshots). /tmp is shared into every app
#               sandbox and /tmp/snapshots is 0755, so any app can list the
#               account folders. Up to webOS 10 the compositor plugin makes
#               each account folder 0660 itself (QFile::setPermissions; the
#               JPEGs in it are 0644); webOS 11's compositor sets nothing
#               visible. The compositor and Home (native or Flutter on every
#               surveyed image) run as root, so the folders above become
#               0700: Recents keeps its pictures, the sandboxes see nothing.
#               /tmp's is made ahead of the compositor when it is missing
#               (Qt's mkpath leaves a directory that exists as it is).
#   phone API   a paired phone app with the display permission can take a
#               screenshot through the second-screen gateway three ways:
#               capture/executeOneShot, apiadapter/tv/executeOneShot, and the
#               virtual tv/executeOneShot that forwards to it. A copy of each
#               interface file without that method is bound over it, so the
#               call is refused as unknown (404 rather than 401) and
#               everything else phone apps do keeps working. The gateway
#               reads these files at the first phone request after it starts
#               (managers.js builds the table lazily) and keeps that table
#               until the TV restarts, either way: a phone that used it
#               before the binds keeps the calls, and undoing the shield
#               keeps them refused, until a restart. A request with no
#               client key gets 401 for a call the table has and 404 for
#               one it does not, so a check from the TV itself (python3,
#               phone access on) tells which, and status says RESIDENT.
#               A copy is written to a new file and checked (whole JSON,
#               the call gone) before it replaces the one bound.
#   capture.jpg apiadapter's screenshot lands in /tmp/capture.jpg: root-only,
#               as /tmp/capture.rgb is (shield_file, hooks/capture.sh).

SNAP_DIRS="/tmp/snapshots /mnt/lg/cmn_data/snapshots"
SNAP_MAKE=/tmp/snapshots   # made ahead of the compositor when missing
SSG_IFACES=/usr/palm/services/com.webos.service.secondscreen.gateway/interfaces
SSG_SHOTS="com.webos.service.capture.interface:/executeOneShot com.webos.service.apiadapter.interface:/tv/executeOneShot tv.interface:/executeOneShot"
SHOT_JPG=/tmp/capture.jpg
SHOTS_BACK="Phone screenshots work again"
SSG_PORT=3000   # the phone API on the TV itself (xinetd lets only 127.0.0.1 in)

# ssg_drop <method path>: an interface file (stdin) without that method.
# The files are JSON whose one top-level array is "methods" (all 99 on the
# surveyed images), so a method is an object two levels down. Done on the
# text, keeping everything else byte for byte: webOS 5 and 6 have no python3.
_SSG_DROP_AWK='
{ s = s $0 "\n" }
END {
    n = length(s); d = 0; q = 0; e = 0; k = 0
    re = "\"path\"[[:space:]]*:[[:space:]]*\"" p "\""
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q) { if (e) e = 0; else if (c == "\\") e = 1; else if (c == "\"") q = 0; continue }
        if (c == "\"") q = 1
        else if (c == "{" || c == "[") { if (d == 2 && c == "{") ob = i; d++ }
        else if (c == "}" || c == "]") { d--; if (d == 2 && c == "}" && substr(s, ob, i - ob + 1) ~ re) { k++; a[k] = ob; b[k] = i } }
    }
    out = ""; from = 1
    for (j = 1; j <= k; j++) {
        x = a[j]; y = b[j]
        # take the comma after it, or else the one before it
        t = y + 1; while (substr(s, t, 1) ~ /[[:space:]]/) t++
        if (substr(s, t, 1) == ",") { y = t; t++; while (substr(s, t, 1) ~ /[[:space:]]/) t++; y = t - 1 }
        else { t = x - 1; while (t > from && substr(s, t, 1) ~ /[[:space:]]/) t--; if (substr(s, t, 1) == ",") x = t }
        out = out substr(s, from, x - from); from = y + 1
    }
    printf "%s", out substr(s, from)
}'
ssg_drop() { awk -v p="$1" "$_SSG_DROP_AWK"; }

# ssg_valid <copy> <method>: a whole JSON object, without that method (BusyBox
# awk exits 0 on a write error, so a full disk could leave half a file)
ssg_valid() {
    [ -s "$1" ] && ! grep -q "\"path\"[[:space:]]*:[[:space:]]*\"$2\"" "$1" || return 1
    [ "$(tr -d ' \t\r\n' < "$1" | tail -c 1)" = "}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
}
# the interface file has that call (status: one without it is not missing)
ssg_has() { grep -q "\"path\"[[:space:]]*:[[:space:]]*\"$2\"" "$1" 2>/dev/null; }
# ask the phone API on the TV itself for a screenshot, with no client key:
# prints 404 (the call is gone from the gateway's table), 401 (the table
# still has it) or nothing (no answer)
_SSG_PROBE_PY='
import base64, json, os, socket, sys
def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
    k = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % k).encode())
    r = b""
    while b"\r\n\r\n" not in r: r += rx(s, 1)
    if b" 101 " not in r.split(b"\r\n")[0]: raise EOFError
    d = json.dumps({"type": "request", "id": "oyg", "uri": "ssap://com.webos.service.capture/executeOneShot", "payload": {}}).encode()
    m = os.urandom(4)
    s.sendall(bytes([0x81, 0x80 | len(d)]) + m + bytes(c ^ m[i % 4] for i, c in enumerate(d)))
    while True:
        h = rx(s, 2); n = h[1] & 0x7F
        if n == 126: n = int.from_bytes(rx(s, 2), "big")
        elif n == 127: n = int.from_bytes(rx(s, 8), "big")
        body = rx(s, n)
        if h[0] & 0x0F != 1: continue
        msg = json.loads(body.decode("utf-8", "replace"))
        if msg.get("id") == "oyg":
            e = str(msg.get("error", ""))[:3]
            print(e if e in ("401", "404") else "")
            break
except Exception:
    pass
'
ssg_probe() { python3 -c "$_SSG_PROBE_PY" "$SSG_PORT" 2>/dev/null; }

hook_screenshots_apply() {
    _ssn=0
    for _ssd in $SNAP_DIRS; do
        [ -L "$_ssd" ] && { warn "$_ssd is a link: left alone"; continue; }
        if [ ! -d "$_ssd" ]; then
            [ "$_ssd" = "$SNAP_MAKE" ] && run "mkdir $_ssd" mkdir "$_ssd" || continue
        fi
        set_mode "$_ssd" 700 && _ssn=$((_ssn+1))
    done
    [ $_ssn = 0 ] || ok "Recents screenshots are root-only"
    _ssp=0
    for _sse in $SSG_SHOTS; do
        _ssf=$SSG_IFACES/${_sse%%:*}; _ssm=${_sse#*:}
        [ -f "$_ssf" ] || continue
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) take $_ssm out of the phone API (${_ssf##*/})"; continue; fi
        _sss="$OYG_ROOT/ssg.${_ssf##*/}"
        if is_mounted "$_ssf"; then
            if state_has mounts "$_ssf" && ro_ok "$_sss"; then _ssp=$((_ssp+1)); continue; fi
            state_has mounts "$_ssf" && unbind "$_ssf"
            is_mounted "$_ssf" && { warn "${_ssf##*/} is bound by something else: left alone"; continue; }
        fi
        # a new file, checked before it replaces the copy: the copy may be
        # the source of a bind that is still in place somewhere
        ssg_drop "$_ssm" < "$_ssf" > "$_sss.new" || { rm -f "$_sss.new"; continue; }
        if cmp -s "$_ssf" "$_sss.new"; then rm -f "$_sss.new"; info "${_ssf##*/} has no $_ssm"; continue; fi
        if ! ssg_valid "$_sss.new" "$_ssm"; then rm -f "$_sss.new"; warn "${_ssf##*/}: could not make a copy without $_ssm (left alone)"; continue; fi
        mv "$_sss.new" "$_sss" && bind_file_ro "$_sss" "$_ssf" && _ssp=$((_ssp+1))
    done
    if [ $_ssp -gt 0 ]; then
        ok "phone apps can no longer take screenshots"
        restart_drop "$SHOTS_BACK"   # on again: nothing to wait for
        # did the gateway read its table before the binds? Asked only where
        # phones can reach it (otherwise no phone can ask either)
        if command -v python3 >/dev/null 2>&1 && command -v luna-send >/dev/null 2>&1 && phone_access_on; then
            case $(ssg_probe) in
                401) kv_set ssg_stale "$(boot_stamp)"; warn "the phone service read its calls before the shield: phone apps can take screenshots until the TV restarts" ;;
                404) kv_set ssg_stale "" ;;
            esac
        fi
    fi
    shield_file "$SHOT_JPG"
    case $? in 0) ok "phone screenshot file shielded (root-only)" ;; esac
    return 0
}
# The gateway keeps the table it built with the copies until it restarts:
# undoing the shield where phones can reach it asks for a restart.
hook_screenshots_restore() {
    state_list mounts | grep -q "^$SSG_IFACES/" || return 0
    [ "$OYG_DRYRUN" = 1 ] && return 0
    command -v luna-send >/dev/null 2>&1 && phone_access_on && need_restart "$SHOTS_BACK"
    return 0
}   # binds, modes and the file we made are recorded: generic restore
hook_screenshots_status() {
    _ssr=0; _sso=""
    for _ssd in $SNAP_DIRS; do
        [ -d "$_ssd" ] || continue
        { [ ! -L "$_ssd" ] && [ "$(_oct "$(mode_of "$_ssd")")" = "$(_oct 700)" ]; } || _sso="$_sso $_ssd"
    done
    if [ -n "$_sso" ]; then st "$1" WARN "Recents screenshots readable by apps:$_sso"; _ssr=1
    else st "$1" OK "Recents screenshots root-only"; fi
    _ssc=0; _ssb=0
    for _sse in $SSG_SHOTS; do
        _ssf=$SSG_IFACES/${_sse%%:*}; [ -f "$_ssf" ] || continue
        if is_mounted "$_ssf" && state_has mounts "$_ssf"; then _ssc=$((_ssc+1)); _ssb=$((_ssb+1))
        elif ssg_has "$_ssf" "${_sse#*:}"; then _ssc=$((_ssc+1)); fi   # a file without the call needs nothing
    done
    if [ $_ssc -gt 0 ]; then
        if [ $_ssb != $_ssc ]; then st "$1" WARN "phone apps can take screenshots ($_ssb of $_ssc calls removed)"; _ssr=1
        elif same_boot "$(kv_get ssg_stale)"; then st "$1" RESIDENT "phone screenshot calls removed, but the phone service read them before: they stay until the TV restarts"
        else st "$1" OK "phone screenshot calls removed"; fi
    fi
    shield_status "$1" "$SHOT_JPG" "phone screenshot file" || _ssr=1
    return $_ssr
}

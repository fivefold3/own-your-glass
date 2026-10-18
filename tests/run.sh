#!/bin/sh
# tests/run.sh — offline tests of the toolkit's parsers and helpers, run
# under BusyBox sh and awk, which is what the TV has. Every fixture is
# synthetic: no LG file is ever read or committed.
#
#   BUSYBOX=/path/to/busybox tests/run.sh      (default: busybox on PATH)
#
# The host's python3 is kept on PATH: the TV has one from webOS 8 on, and
# the consent code uses it where it exists. So is sqlite3 (webOS has one).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
if [ -z "${OYG_TEST_INNER:-}" ]; then
    BB=${BUSYBOX:-$(command -v busybox 2>/dev/null)}
    [ -n "$BB" ] && [ -x "$BB" ] || { echo "tests/run.sh: needs busybox (set BUSYBOX=/path/to/busybox)" >&2; exit 2; }
    T=$(mktemp -d); mkdir -p "$T/bin"
    for a in $("$BB" --list); do ln -s "$BB" "$T/bin/$a"; done
    # nopy: the same applets without python3 and sqlite3, for the webOS 5/6 paths
    cp -R "$T/bin" "$T/nopy"
    PY=$(command -v python3 2>/dev/null); [ -n "$PY" ] && ln -sf "$PY" "$T/bin/python3"
    SQ=$(command -v sqlite3 2>/dev/null); [ -n "$SQ" ] && ln -sf "$SQ" "$T/bin/sqlite3"
    export OYG_TEST_INNER=1 TDIR="$T" BB
    PATH="$T/bin" "$BB" sh "$0" "$@"; rc=$?
    rm -rf "$T"; exit $rc
fi

pass=0; nfail=0
check() {  # check <name> <cmd...>
    _name=$1; shift
    if "$@"; then pass=$((pass+1)); else nfail=$((nfail+1)); echo "FAIL: $_name"; fi
}
eq() { [ "$1" = "$2" ] && return 0; printf '    expected: %s\n    got:      %s\n' "$2" "$1"; return 1; }

# a sandbox the toolkit writes its state into
export OYG_ROOT="$TDIR/root" OYG_DRYRUN=0 OYG_MOD=test OYG_PROC="$TDIR/proc"
mkdir -p "$OYG_ROOT/state" "$OYG_ROOT/backup" "$OYG_PROC/self"
: > "$OYG_PROC/mounts"; : > "$OYG_PROC/self/mountinfo"
OYG_TK="$REPO/toolkit"
. "$REPO/toolkit/lib/common.sh"
. "$REPO/toolkit/etc/options.sh"
. "$REPO/toolkit/lib/svc.sh"
. "$REPO/toolkit/lib/blocklist.sh"
. "$REPO/toolkit/lib/settings.sh"
. "$REPO/toolkit/lib/eula.sh"
. "$REPO/toolkit/lib/options.sh"
for f in "$REPO"/toolkit/hooks/*.sh "$REPO"/toolkit/resources/*.sh; do . "$f"; done
log() { :; }   # keep the output to test results
F="$TDIR/fx"; mkdir -p "$F"

# ------------------------------------------------------------------ sdx --
cat > "$F/sdx-pretty.conf" <<'EOF'
{
    "version": "0",
    "severDomain": {
        "default": [
            {
                "serviceName": "sdp_auth",
                "domainType": "default",
                "domain": "tv.wiselg.com",
                "baseResource": "auth/"
            },
            {
                "domain": "tv.wiselg.com",
                "serviceName": "sdp_logging",
                "baseResource": "logging/",
                "domainType":	"ric"
            },
            {
                "serviceName": "rdx_secure", "domainType": "default", "domain": "rdx2.nextlgsdp.com", "baseResource": "rdx/"
            },
            {
                "serviceName": "service_setting_secure", "domainType": "ric", "domain": "tv.wiselg.com", "baseResource": "s/"
            }
        ],
        "C01": [
            { "serviceName": "sdp_auth", "domainType": "default", "domain": "tv.wiselg.cn", "baseResource": "auth/" },
            { "serviceName": "sdp_logging", "domainType": "ric", "domain": "tv.wiselg.cn", "baseResource": "logging/" }
        ]
    }
}
EOF
printf '{"version":"2.5","severDomain":{"10.0.0":[{"domainType":"default","domain":"nextlgsdp.com","serviceName":"sdp_common","baseResource":"c/"},{"serviceName":"nudge_secure","domain":"nudge.lgtvcommon.com","domainType":"ric","baseResource":"n/"}]}}\r\n' > "$F/sdx-min.conf"

check "sdx: pretty table, two groups, shuffled keys" eq "$(sdx_entries "$F/sdx-pretty.conf" | tr '\n' ' ')" \
    "default|sdp_auth|default|tv.wiselg.com default|sdp_logging|ric|tv.wiselg.com default|rdx_secure|default|rdx2.nextlgsdp.com default|service_setting_secure|ric|tv.wiselg.com C01|sdp_auth|default|tv.wiselg.cn C01|sdp_logging|ric|tv.wiselg.cn "
check "sdx: one-line server push with CRLF" eq "$(sdx_entries "$F/sdx-min.conf" | tr '\n' ' ')" \
    "10.0.0|sdp_common|default|nextlgsdp.com 10.0.0|nudge_secure|ric|nudge.lgtvcommon.com "
SDX_BLOCK="sdp_logging rdx_secure nudge_secure"
tr -d '\r\n' < "$F/sdx-pretty.conf" | awk -v BLOCK="$SDX_BLOCK" -v SINK="$SDX_SINK" "$SDX_AWK" > "$F/sdx-gen.conf"
check "sdx: rewrite routes only blocked names, in every group" eq "$(sdx_entries "$F/sdx-gen.conf" | awk -F'|' '$4 == "oyg.invalid" { print $1 "/" $2 }' | tr '\n' ' ')" \
    "default/sdp_logging default/rdx_secure C01/sdp_logging "
check "sdx: rewrite validates" sdx_validate "$F/sdx-pretty.conf" "$F/sdx-gen.conf"
sed 's/"tv.wiselg.cn"/"evil.example"/' "$F/sdx-gen.conf" > "$F/sdx-bad.conf"
check "sdx: a changed kept host fails validation" eval '! sdx_validate "$F/sdx-pretty.conf" "$F/sdx-bad.conf"'
OYG_MOD=sdx; printf 'default=AU\nric=KIC\ngroup=default\n' > "$SDX_PREFIXES"
SDX_ORIG="$F/sdx-pretty.conf"
check "sdx: hosts only blocked names use, never the shared gateway" eq "$(sdx_blocked_hosts | tr '\n' ' ')" "AU.rdx2.nextlgsdp.com "
rm -f "$SDX_PREFIXES"; printf 'prefix_default=NZ\nprefix_ric=AIC\ngroup=default\n' > "$OYG_STATE/kv.sdx"
check "sdx: prefixes recorded by 1.2.x still read" eq "$(sdx_known default)/$(sdx_known ric)" "NZ/AIC"
printf 'default=AU\n' > "$SDX_PREFIXES"
check "sdx: the prefix cache wins over 1.2.x records" eq "$(sdx_known default)/$(sdx_known ric)" "AU/AIC"
OYG_MOD="test"

# ------------------------------------------------------------ processes --
ls() { cat <<'EOF'
lrwxrwxrwx    1 root     root             0 Sep 25 22:48 /proc/1/exe -> /lib/systemd/systemd
lrwxrwxrwx    1 6156     6156             0 Sep 25 22:48 /proc/5627/exe -> /var/palm/jail/com.webos.service.voice.performer/usr/sbin/performer
lrwxrwxrwx    1 root     root             0 Sep 25 22:48 /proc/700/exe -> /usr/sbin/acr2 (deleted)
EOF
}
ps() { case $1 in -eo) cat <<'EOF'
  PID COMMAND         COMMAND
    1 systemd         /lib/systemd/systemd
 5627 performer       /usr/sbin/performer --plugin
  700 acr2            /usr/sbin/acr2
  800 node            /usr/bin/node /usr/palm/services/x/discovery-server.js
EOF
;; esac; }
ps_snapshot
check "ps: jailed copy matches its host path" eq "$(pids_of_exe /usr/sbin/performer)" "5627 "
check "ps: deleted exe still matches" eq "$(pids_of_exe /usr/sbin/acr2)" "700 "
check "ps: argv[0] only when the exe is unreadable" eq "$(pids_of_exe /usr/bin/node)" "800 "
check "ps: comm" eq "$(pids_of acr2)" "700 "
check "ps: command line" eq "$(pids_of_arg discovery-server.js)" "800 "
printf 'perf|/usr/sbin/performer||\nacr|/usr/sbin/acr2|acr2|\ndial|||discovery-server.js\nnone|/usr/sbin/nope|nope|\n' > "$F/res"
check "svc_match: one pass over spec and snapshot" eq "$(svc_match "$F/res" | sort | tr '\n' ' ')" "acr 700 dial 800 perf 5627 "
# a killed process's systemd unit is recorded only when it runs that binary
mkdir -p "$F/units" "$OYG_PROC/700" "$OYG_PROC/5627" "$OYG_PROC/1"
printf '[Service]\nExecStart=-/usr/sbin/acr2 --x\n' > "$F/units/acr.service"
printf '[Service]\nExecStart=/usr/bin/jailer -t native\n' > "$F/units/perf.service"
printf '2:cpu:/\n1:name=systemd:/system.slice/acr.service\n' > "$OYG_PROC/700/cgroup"
printf '0::/system.slice/perf.service\n' > "$OYG_PROC/5627/cgroup"
printf '0::/init.scope\n' > "$OYG_PROC/1/cgroup"
_ud=$OYG_UNIT_DIRS; OYG_UNIT_DIRS="$F/units"
printf 'acr 700\nperf 5627\nx 1\nacr 700\n' | svc_hit_units
check "units: a killed process's own unit is recorded, a jailer's is not" eq "$(cat "$OYG_STATE/units.test")" "acr.service"
OYG_UNIT_DIRS=$_ud; rm -f "$OYG_STATE/units.test"
# undo: the block list is rewritten before any stopped daemon starts again
_order="$F/order"; : > "$_order"
blocklist_sync() { echo "sync $(cat "$OYG_STATE"/ls2.* 2>/dev/null | tr '\n' ' ')" >> "$_order"; }
systemctl() { [ "$1" = start ] && echo "start $2" >> "$_order"; return 0; }
printf 'com.x.cast\n' > "$OYG_STATE/ls2.test"; printf 'cast.service\n' > "$OYG_STATE/units.test"
: | svc_restore
check "restore: names leave the block list before daemons start" eq "$(tr '\n' '|' < "$_order")" "sync |start cast.service|"
: > "$_order"
printf 'com.x.cast\n' > "$OYG_STATE/ls2.test"; printf 'cast.service\n' > "$OYG_STATE/units.test"
printf 'cast|cast.service|/usr/sbin/nothere|nothere||com.x.cast|\n' | svc_release
check "release: names leave the block list before daemons start" eq "$(tr '\n' '|' < "$_order")" "sync |start cast.service|"
check "release: records dropped" eval '[ ! -s "$OYG_STATE/ls2.test" ] && [ ! -s "$OYG_STATE/units.test" ]'
unset -f blocklist_sync systemctl; . "$REPO/toolkit/lib/blocklist.sh"; rm -f "$OYG_STATE/ls2.test" "$OYG_STATE/units.test"
# BusyBox ps rejects -e: the fallback must still list everything
ps() { case $1 in -eo) return 1 ;; -o) printf '  PID COMMAND COMMAND\n  700 acr2 /usr/sbin/acr2\n' ;; esac; }
ps_snapshot
check "ps: BusyBox fallback" eq "$(pids_of acr2)" "700 "
unset -f ls ps

# ----------------------------------------------------------------- modes --
mkdir -p "$F/m"; : > "$F/m/node"; chmod 600 "$F/m/node"
check "modes: octal compare (600 vs 0600)" eval 'set_mode "$F/m/node" 0600 && [ ! -s "$OYG_STATE/modes.test" ]'
set_mode "$F/m/node" 000
check "modes: chmod 000 records the original" eq "$(cat "$OYG_STATE/modes.test")" "$F/m/node 600"
check "modes: stat prints 0, which equals 000" eval 'set_mode "$F/m/node" 000 && [ "$(wc -l < "$OYG_STATE/modes.test")" = 1 ]'
printf '%s\n' "$F/m/node" > "$OYG_MSNAP"; : > "$OYG_MSNAP.o"
chmod 644 "$F/m/node"
check "modes: never chmod through a bind" eval 'set_mode "$F/m/node" 000 && [ "$(stat -c %a "$F/m/node")" = 644 ]'
check "modes: a bound path keeps its record on restore" eval 'restore_modes; [ -s "$OYG_STATE/modes.test" ]'
: > "$OYG_MSNAP"
restore_modes
check "modes: restore once unbound" eval '[ "$(stat -c %a "$F/m/node")" = 600 ] && [ ! -f "$OYG_STATE/modes.test" ]'
check "modes: /dev/null is refused" eval '! set_mode /dev/null 000 2>/dev/null'

# ---------------------------------------------------------------- binds --
mkdir -p "$F/fs/bin" "$F/fs/usr/sbin" "$F/fs/sbin"
: > "$F/fs/bin/busybox"; ln -s ../../bin/busybox "$F/fs/usr/sbin/telnetd"; : > "$F/fs/usr/sbin/acr2"; ln -s ../usr/sbin/acr2 "$F/fs/sbin/acr2"
check "bind: an applet link to a multi-call binary is refused" eval '! ( OYG_DRYRUN=1 bind_null "$F/fs/usr/sbin/telnetd" ) >/dev/null'
check "bind: a usr-merge link resolves to the real path" eq "$(canon "$F/fs/sbin/acr2")" "$(canon "$F/fs/usr/sbin/acr2")"
cat > "$OYG_PROC/self/mountinfo" <<EOF
100 20 0:15 /null /usr/sbin/acr2 rw,relatime shared:1 - devtmpfs devtmpfs rw
101 30 179:40 /lib/own-your-glass/sdx-routes.conf /mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf ro,relatime shared:5 - ext4 /dev/mmcblk0p40 rw
102 31 179:40 /lib/own-your-glass/sdx-routes.conf /mnt/lg/cache/sdp/sdx/server_addr_version.conf rw,relatime shared:5 - ext4 /dev/mmcblk0p40 rw
103 32 179:40 /lib/own-your-glass/hosts /etc/hosts rw,relatime - ext4 /dev/mmcblk0p40 rw
EOF
check "bind: peers of our file from mountinfo" eq "$(bind_peers "$OYG_ROOT/sdx-routes.conf" | tr '\n' ' ')" \
    "/mnt/lg/cache/sdp/sdx/server_addr_version.conf /mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf "
printf 'a /x ext4 ro 0 0\nb /y ext4 rw,relatime 0 0\nc /y ext4 ro 0 0\nd /z ext4 rw 0 0\n' > "$OYG_PROC/mounts"; mounts_snapshot
check "bind: read-only state of the top layer" eval '! is_rw /x && ! is_rw /y && is_rw /z'

# ------------------------------------------------------------ blocklist --
printf '{"blockedServices":["com.webos.service.signlanguageavatar"]}\n' > "$F/lg.json"
check "blocklist: LG's entries kept, union sorted" eq "$(blocklist_json "$F/lg.json" com.webos.service.acr lg.thinqai.adapter)" \
    '{"blockedServices":["com.webos.service.acr","com.webos.service.signlanguageavatar","lg.thinqai.adapter"]}'
check "blocklist: no LG file" eq "$(blocklist_json "$F/none.json" com.webos.service.acr)" '{"blockedServices":["com.webos.service.acr"]}'
mkdir -p "$F/sd" "$F/dbus"
printf 'Name=com.webos.service.voiceinput.preprocessor;com.webos.service.voiceinput.preprocessor.sync\nExec=/usr/sbin/voiceinput_preprocessor\nType=dynamic\n' > "$F/sd/a.service"
printf 'Name=com.webos.service.voiceconductor\nExec=/usr/sbin/voiceconductor\nType=static\n' > "$F/sd/b.service"
printf '[D-BUS Service]\r\nName=com.webos.service.acr\r\n#Exec=/old\r\nExec=/usr/sbin/acr2\r\nType=dynamic\r\n' > "$F/dbus/c.service"
LS2_DIRS="$F/sd $F/dbus"; LS2_INDEX="$F/ls2.index"; ls2_index_build
check "ls2: index keeps exec, type and first name (CRLF file)" eq "$(awk -F'\t' '$1 == "com.webos.service.acr" { print $2 "|" $3 "|" $4 }' "$LS2_INDEX")" "dynamic|/usr/sbin/acr2|1"
check "ls2: only a dynamic first name can be blocked" eval 'ls2_blockable com.webos.service.voiceinput.preprocessor && ! ls2_blockable com.webos.service.voiceinput.preprocessor.sync && ! ls2_blockable com.webos.service.voiceconductor'
check "ls2: never block the voice hub or Settings' services" eval 'ls2_denied com.webos.service.voiceinput && ls2_denied com.webos.service.ics.adapter && ! ls2_denied com.webos.service.voiceinput.hidraw && ls2_denied com.palm.db && ! ls2_denied com.palm.uploadd'

# ------------------------------------------------- helpers keep caller vars --
_f=mine; _p=mine2
kv_set probe 1; state_add mounts /x; state_del mounts /x
check "kv_set and state_del leave the caller's variables alone" eq "$_f/$_p" "mine/mine2"

# ---------------------------------------------------------------- flags --
svc_flags "u,j=amazon.alexa.adapter,L=jailed"
check "spec flags parse without forking" eq "$_fu|$_fm|$_fj|$_fL" "1||amazon.alexa.adapter|jailed"

# ------------------------------------------------------------- consents --
REPLY='{"returnValue":true,"settings":{"eulaStatus":{"generalTermsAllowed":true,"acrAllowed":true,"voiceAllowed":false,"networkAllowed":true},"eulaInfoNetwork":{"eulaList":[{"fileName":"a","id":"S_SVC","_id":"","version":"1","accepted":true,"updated":false},{"fileName":"b","id":"S_VNG","_id":"","version":"1","accepted":true,"updated":true}]}}}'
if command -v python3 >/dev/null 2>&1; then
    out=$(printf '%s' "$REPLY" | eula_edit decline "$CONSENT_IDS" "$EULA_TRACKING_FLAGS")
    check "eula: decline flips only tracking ids and flags" eq "$(printf '%s\n' "$out" | sed -n 2p)" "id:S_VNG flag:acrAllowed"
    check "eula: basic terms stay accepted" eval 'printf "%s" "$out" | sed -n 1p | python3 -c "import json,sys; s=json.load(sys.stdin)[\"settings\"]; l={e[\"id\"]:e[\"accepted\"] for e in s[\"eulaInfoNetwork\"][\"eulaList\"]}; sys.exit(0 if l==dict(S_SVC=True,S_VNG=False) and s[\"eulaStatus\"][\"generalTermsAllowed\"] and not s[\"eulaStatus\"][\"acrAllowed\"] else 1)"'
    declined=$(printf '%s' "$out" | sed -n 1p | python3 -c 'import json,sys; d=json.load(sys.stdin); d["returnValue"]=True; print(json.dumps(d))')
    check "eula: restore undoes exactly the recorded flips" eq "$(printf '%s' "$declined" | eula_edit restore "id:S_VNG flag:acrAllowed" | sed -n 2p)" "id:S_VNG flag:acrAllowed"
    check "eula: clearing the terms-update flag" eq "$(printf '%s' "$REPLY" | eula_edit updated | sed -n 2p)" "updated:S_VNG"
    check "eula: nothing to change prints nothing" eq "$(printf '%s' "$declined" | eula_edit decline "$CONSENT_IDS" "$EULA_TRACKING_FLAGS")" ""
fi
# without python3 (webOS 5 and 6): the shell editor makes the same edits
nopy() { PATH="$TDIR/nopy" "$@"; }
_sh_out=$(printf '%s' "$REPLY" | nopy eula_editor decline "$CONSENT_IDS" "$EULA_TRACKING_FLAGS")
check "eula (no python): decline flips the same ids and flags" eq "$(printf '%s\n' "$_sh_out" | sed -n 2p)" "id:S_VNG flag:acrAllowed"
check "eula (no python): the edited reply is JSON with the basic terms kept" eval 'printf "%s" "$_sh_out" | sed -n 1p | python3 -c "import json,sys; s=json.load(sys.stdin)[\"settings\"]; l={e[\"id\"]:e[\"accepted\"] for e in s[\"eulaInfoNetwork\"][\"eulaList\"]}; sys.exit(0 if l==dict(S_SVC=True,S_VNG=False) and s[\"eulaStatus\"][\"generalTermsAllowed\"] and not s[\"eulaStatus\"][\"acrAllowed\"] else 1)"'
_sh_declined=$(printf '%s' "$_sh_out" | sed -n 1p | sed 's/^{"settings"/{"returnValue":true,"settings"/')
check "eula (no python): restore undoes exactly the recorded flips" eq "$(printf '%s' "$_sh_declined" | nopy eula_editor restore "id:S_VNG flag:acrAllowed" | sed -n 2p)" "id:S_VNG flag:acrAllowed"
check "eula (no python): clearing the terms-update flag" eq "$(printf '%s' "$REPLY" | nopy eula_editor updated | sed -n 2p)" "updated:S_VNG"
check "eula (no python): nothing to change prints nothing" eq "$(printf '%s' "$_sh_declined" | nopy eula_editor decline "$CONSENT_IDS" "$EULA_TRACKING_FLAGS")" ""
# settings without python3: the documented reply layout, pretty-printed
_sreply='{
    "subscribed": false,
    "category": "option",
    "method": "getSystemSettings",
    "settings": {
        "livePlus": "on",
        "livePromotion": {"value": "on", "changedByUser": false}
    },
    "returnValue": true
}'
_sobj=$(printf '%s' "$_sreply" | nopy _settings_obj)
check "settings (no python): the settings object is found by brace depth" eq "$(printf '%s' "$_sobj" | tr -d ' ')" '{"livePlus":"on","livePromotion":{"value":"on","changedByUser":false}}'
check "settings (no python): the keys" eq "$(nopy _settings_keys '{"livePlus":"off","livePromotion":"off"}')" 'livePlus","livePromotion'
SETTINGS_PAIRS='livePlus|"off"
livePromotion|{"value":"off","changedByUser":true}
notOnThisTv|"off"'
check "settings (no python): only keys the TV reported are sent, objects intact" eq "$(nopy _settings_filter '{}' "$_sobj")" '{"livePlus":"off","livePromotion":{"value":"off","changedByUser":true}}'
unset SETTINGS_PAIRS
cat > "$F/eula" <<'EOF'
{"eulaInfo":{"eulaList":[{"id":"S_TAG","accepted":true,"updated":true}]},
 "eulaInfoNetwork":{"eulaList":[{"fileName":"x","id":"S_VNG","_id":"","version":"1","accepted":true,"updated":false},{"fileName":"y","id":"S_SVC","_id":"","accepted":true}]}}
EOF
EULA_CACHE="$F/eula"
check "eula status: only the live list, id and accepted apart" eq "$(eula_accepted_ids | tr '\n' ' ')" "S_VNG "
check "eula status: the legacy list's update flag is ignored" eval '! eula_update_pending'

# ------------------------------------------------------- whole CLI, dry --
cli() { OYG_ROOT="$TDIR/cli" OYG_DRYRUN=1 OYG_PROC=/proc "$BB" sh "$REPO/toolkit/oyg" "$@" 2>&1; }
st_out=$(cli status)
check "cli: status runs under set -u" eval 'printf "%s\n" "$st_out" | grep -q "^META|version|" && ! printf "%s\n" "$st_out" | grep -qi "parameter not set\|not found"'
check "cli: status lists every option" eq "$(printf '%s\n' "$st_out" | grep -c '^OPT|')" "$(printf '%s\n' $OYG_OPTIONS | grep -c .)"
check "cli: catalogue has every option" eq "$(cli catalog | grep -c '^OPT|')" "$(printf '%s\n' $OYG_OPTIONS | grep -c .)"
ap_out=$(cli apply)
check "cli: dry-run apply completes" eval 'printf "%s\n" "$ap_out" | grep -q "^== done" && ! printf "%s\n" "$ap_out" | grep -qi "parameter not set\|fatal"'
tr_out=$(cli try remote-config)
check "cli: dry-run try applies the option and says how to undo" eval 'printf "%s\n" "$tr_out" | grep -q "Remote configuration" && printf "%s\n" "$tr_out" | grep -q "restart the TV or Re-apply to undo"'
check "cli: try refuses an unknown option" eval '! cli try no-such-option >/dev/null'
check "cli: a full restore gives the glass back until the next apply" eval 'cli restore | grep -q "nothing is re-applied at start-up"'
check "cli: restoring one option does not" eval '! cli restore trackers | grep -q "nothing is re-applied"'
[ -d "$TDIR/cli" ] && check "cli: dry-run writes nothing" eq "$(find "$TDIR/cli" -type f | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------- hooks --
missing=""
for o in $OYG_OPTIONS; do
    h=$(ov "$o" hook); [ -n "$h" ] || continue
    for f in apply restore status; do command -v "hook_${h}_$f" >/dev/null 2>&1 || missing="$missing hook_${h}_$f"; done
done
check "every option's hook exists" eq "$missing" ""

# restart: reasons live under the boot time and empty themselves after a restart
printf 'cpu 1 2 3\nbtime 1790411163\n' > "$OYG_PROC/stat"
OYG_RESTART="$F/restart"; rm -f "$OYG_RESTART"
need_restart "A works again" >/dev/null; need_restart "B works again" >/dev/null; need_restart "A works again" >/dev/null
check "restart: reasons listed once" eq "$(restart_reasons | tr '\n' '|')" "B works again|A works again|"
restart_drop "B works again"
check "restart: a reason can be dropped" eq "$(restart_reasons | tr '\n' '|')" "A works again|"
printf 'cpu 1 2 3\nbtime 1790411203\n' > "$OYG_PROC/stat"
check "restart: a clock step of 40 s is the same boot" eq "$(restart_reasons)" "A works again"
printf 'cpu 1 2 3\nbtime 1790419000\n' > "$OYG_PROC/stat"
check "restart: a restart empties the list" eq "$(restart_reasons)" ""
printf 'a79bc963-74eb-4e8c-bb11-997a4e5dbcb5\nPhone remote apps work again\n' > "$OYG_RESTART"
check "restart: a list stamped with a boot_id (1.4.13-1.4.17) counts as an earlier boot" eq "$(restart_reasons)" ""
# phone: the restart is decided once the setting is back (hook_phone_restored):
# asked whenever OYG had turned phone access off and the TV now has it on,
# in whatever boot (LG's phone server never comes back within one)
OYG_MOD=phone; rm -f "$OYG_RESTART" "$OYG_STATE/kv.phone"
mkdir -p "$F/stubp"; printf '#!/bin/sh\nexit 0\n' > "$F/stubp/luna-send"; chmod 755 "$F/stubp/luna-send"   # the hook checks it exists
# a settings service whose state outlives the $(...) subshells: $F/pv holds
# the TV's value, $F/pv.refuse makes setSystemSettings answer false
luna() {
    case $1 in
        */setSystemSettings) [ -f "$F/pv.refuse" ] && { echo '{"returnValue":false}'; return 0; }
            case $2 in *'"allowMobileDeviceAccess":true'*) echo true > "$F/pv" ;; *'"allowMobileDeviceAccess":false'*) echo false > "$F/pv" ;; esac
            echo '{"returnValue":true}' ;;
        */getSystemSettings) printf '{\n    "returnValue": true,\n    "settings": {\n        "allowMobileDeviceAccess": %s\n    }\n}\n' "$(cat "$F/pv")" ;;
    esac
}
rm -f "$F/pv.refuse"; echo true > "$F/pv"
kv_set settings.network '{"allowMobileDeviceAccess":true}'
(PATH="$F/stubp:$PATH"; hook_phone_restored >/dev/null)
check "phone: access back on after the undo asks for a restart" eq "$(restart_reasons)" "$PHONE_BACK"
rm -f "$OYG_RESTART"; printf 'cpu 1 2 3\nbtime 1790500000\n' > "$OYG_PROC/stat"
(PATH="$F/stubp:$PATH"; hook_phone_restored >/dev/null)
check "phone: so does an undo in a later boot than the one that turned it off" eq "$(restart_reasons)" "$PHONE_BACK"
rm -f "$OYG_RESTART"; kv_set settings.network '{"allowMobileDeviceAccess":false}'
(PATH="$F/stubp:$PATH"; hook_phone_restored >/dev/null)
check "phone: access the owner had off before asks for nothing" eq "$(restart_reasons)" ""
# the whole undo, in opt_restore's order: OYG turned access off, the owner
# turned it on again in LG's menus, then the option is undone
echo true > "$F/pv"; kv_set settings.network '{"allowMobileDeviceAccess":true}'; kv_set applied 1
(PATH="$F/stubp:$PATH"; opt_restore phone >/dev/null 2>&1)
check "phone: access turned on in LG's menus still asks (the server is down until a restart)" eq "$(restart_reasons)" "$PHONE_BACK"
check "phone: a restore that went through drops the record" eq "$(kv_get settings.network)" ""
rm -f "$OYG_RESTART"; echo false > "$F/pv"; : > "$F/pv.refuse"; kv_set settings.network '{"allowMobileDeviceAccess":true}'; kv_set applied 1
(PATH="$F/stubp:$PATH"; opt_restore phone >/dev/null 2>&1)
check "phone: a restore settingsservice refused promises no restart" eq "$(restart_reasons)" ""
check "phone: and keeps the record for the next restore" eq "$(kv_get settings.network)" '{"allowMobileDeviceAccess":true}'
check "phone: the option is no longer applied, its record is still there" eval '! opt_applied phone && has_state phone'
rm -f "$F/pv.refuse"; OYG_MOD=phone; need_restart "$PHONE_BACK" >/dev/null; hook_phone_apply
check "phone: turning it on again drops the pending restart" eq "$(restart_reasons)" ""
OYG_MOD=phone; kv_drop; OYG_MOD=test
_or=$OYG_RESTART; unset -f luna; . "$REPO/toolkit/lib/common.sh"; OYG_RESTART=$_or; log() { :; }
printf 'cpu 1 2 3\nbtime 1790419000\n' > "$OYG_PROC/stat"
# Screen Share: a restart is asked for when Miracast was stopped in this boot
OYG_MOD=miracast; rm -f "$OYG_RESTART" "$OYG_STATE/kv.miracast" "$OYG_STATE/units.miracast"
hook_miracast_apply; hook_miracast_restore >/dev/null
check "miracast: nothing stopped, no restart" eq "$(restart_reasons)" ""
printf 'miracast.service\n' > "$OYG_STATE/units.miracast"; hook_miracast_apply; hook_miracast_restore >/dev/null
check "miracast: undo in the boot it was stopped asks for a restart" eq "$(restart_reasons)" "$MIRACAST_BACK"
OYG_MOD=test; rm -f "$OYG_STATE/kv.phone" "$OYG_STATE/kv.miracast" "$OYG_STATE/units.miracast" "$OYG_RESTART"

# LG account: a yes/no from getLoginID; the sign-out never shows the login id
mkdir -p "$F/stub"; printf '#!/bin/sh\nexit 0\n' > "$F/stub/luna-send"; chmod 755 "$F/stub/luna-send"   # the hook checks it exists
_amsg="$F/am.calls"; : > "$_amsg"; _am_in=1
luna() {
    case $1 in
        */getLoginID) if [ "$_am_in" = 1 ]; then printf '{\n    "id": "someone@example.com",\n    "lastSignInUserNo": "AU000123",\n    "returnValue": true\n}\n'; else printf '{\n    "id": "",\n    "lastSignInUserNo": "",\n    "returnValue": true\n}\n'; fi ;;
    esac
}
luna_ok() { echo "$1 $2" >> "$_amsg"; _am_in=0; return 0; }
check "account: signed in is a yes" eval 'account_signed_in'
ACCOUNT_LOGOUT_MODE=testmode; _out=$(PATH="$F/stub:$PATH"; OYG_MOD=account hook_account_apply 2>&1); _am_in=0
check "account: sign-out sends LG's call with the user number" eq "$(cat "$_amsg")" 'luna://com.webos.service.accountmanager/logoutAccount {"serviceName":"LGE","mode":"deep","userNo":"AU000123"}'
check "account: the login id is never printed" eval '! printf "%s" "$_out" | grep -q example.com'
check "account: signed out after" eval '! account_signed_in'
: > "$_amsg"; (PATH="$F/stub:$PATH"; OYG_MOD=account hook_account_apply >/dev/null 2>&1)
check "account: nothing to do when signed out" eq "$(cat "$_amsg")" ""
unset -f luna luna_ok; . "$REPO/toolkit/lib/common.sh"; . "$REPO/toolkit/hooks/account.sh"; ACCOUNT_LOGOUT_MODE=shallow

# the sink the gateway table points at is answered locally
check "network: the gateway sink resolves on the TV" eval 'SDX_BLOCK="sdp_logging" NET_HOSTS="" network_domains | grep -qx kic.oyg.invalid'
check "network: no sink names when no route is cut" eval '! SDX_BLOCK="" NET_HOSTS="x.example" network_domains | grep -q oyg.invalid'

# a watcher's process group holds its children and nothing else (the shell
# and at least one child: how many sleeps are alive at the moment of the
# read varies between hosts, and under an emulator the group is not seen)
setsid sh -c 'sleep 30 & sleep 30; :' </dev/null >/dev/null 2>&1 & _g=$!
sleep 3 & _other=$!
_n=0; while [ $_n -lt 20 ]; do _gp=$(pgrp_pids "$_g"); [ "$(echo $_gp | wc -w)" -ge 2 ] && break; nap 0.1; _n=$((_n+1)); done
check "pgrp: the watcher and its children" eval '[ "$(echo $_gp | wc -w | tr -d " ")" -ge 2 ]'
check "pgrp: never another process" eval 'case " $_gp " in *" $_other "*) false;; *) true;; esac'
kill $_gp 2>/dev/null; wait $_other 2>/dev/null

# hidden apps: showing one again asks for a restart, hiding more does not
OYG_MOD=apps; rm -f "$OYG_RESTART" "$OYG_STATE"/*.apps; _af="$F/apps.json"; printf '{"blocked_system_applist":["lg.own"]}\n' > "$_af"
apps_file() { echo "$_af"; }; app_exists() { return 0; }
APPS_IDS="a.one b.two"; res_apps_apply >/dev/null
check "apps: hiding asks for nothing" eq "$(restart_reasons)" ""
APPS_IDS="a.one"; res_apps_apply >/dev/null
check "apps: showing one again asks for a restart" eq "$(restart_reasons)" "$APPS_BACK"
check "apps: LG's own entry stays hidden" eval 'grep -q lg.own "$_af" && ! grep -q b.two "$_af"'
unset -f apps_file app_exists; . "$REPO/toolkit/resources/apps.sh"; rm -f "$OYG_RESTART" "$OYG_STATE"/*.apps; OYG_MOD=test

# trials: undone unless selected, and the list goes
_tcalls=""; opt_restore() { _tcalls="$_tcalls $1"; }; selected_options() { echo keepme; }
printf 'keepme\ntrialopt\n' > "$TRIAL_FILE"; trial_undo
check "trial: an unselected trial is restored, a selected one kept" eq "$_tcalls" " trialopt"
check "trial: the list is gone" eval '[ ! -f "$TRIAL_FILE" ]'
unset -f opt_restore selected_options; . "$REPO/toolkit/lib/options.sh"

# never-touch: hard paths always refused; soft ones only for a Lockdown-only option
check "never: a hard path is refused even in Lockdown" eval 'OYG_SOFT_OK=1 bind_denied /usr/sbin/sdx'
check "never: a soft path is refused outside Lockdown" eval 'OYG_SOFT_OK=0 bind_denied /usr/sbin/iconnectivity'
check "never: a soft path is allowed for a Lockdown-only option" eval '! OYG_SOFT_OK=1 bind_denied /usr/sbin/iconnectivity'

# undo starts again the on-demand services that were running when stopped
luna() { echo "$1" >> "$F/relaunch.calls"; echo '{"returnValue":false}'; }; : > "$F/relaunch.calls"
printf 'com.x.ics\n' > "$OYG_STATE/relaunch.test"; generic_restore >/dev/null 2>&1
check "relaunch: undo calls the service once" eq "$(cat "$F/relaunch.calls")" "luna://com.x.ics/oygWake"
check "relaunch: the record goes" eval '[ ! -f "$OYG_STATE/relaunch.test" ]'
unset -f luna; . "$REPO/toolkit/lib/common.sh"

# toasts are off unless the owner turned them on
luna() { echo "$1" >> "$F/toast.calls"; echo '{"returnValue":true}'; }; : > "$F/toast.calls"; rm -f "$OYG_TOASTS_FILE"
toast "off by default" >/dev/null 2>&1
check "toasts: none by default" eq "$(cat "$F/toast.calls")" ""
: > "$OYG_TOASTS_FILE"; toast "turned on" >/dev/null 2>&1
check "toasts: shown once turned on" eq "$(cat "$F/toast.calls")" "luna://com.webos.notification/createToast"
rm -f "$OYG_TOASTS_FILE"; : > "$F/toast.calls"; OYG_TOAST=1 toast "past the root" >/dev/null 2>&1
check "toasts: OYG_TOAST=1 keeps them on without the file" eq "$(cat "$F/toast.calls")" "luna://com.webos.notification/createToast"
unset OYG_TOAST
rm -f "$OYG_TOASTS_FILE"; : > "$F/toast.calls"; toast_always "root shell back" >/dev/null 2>&1
check "toasts: a warning that must be heard is shown with them off" eq "$(cat "$F/toast.calls")" "luna://com.webos.notification/createToast"
unset -f luna; . "$REPO/toolkit/lib/common.sh"

# ---------------------------------------------------------------- resync --
# an option whose services changed drops the records of what it no longer lists
OPT_fakeopt_name="Fake"; OPT_fakeopt_spec=""
printf '/usr/sbin/nolonger\n' > "$OYG_STATE/mounts.fakeopt"; printf 'com.example.gone\n' > "$OYG_STATE/ls2.fakeopt"
printf 'spec_md5=0123\n' > "$OYG_STATE/kv.fakeopt"
opt_apply fakeopt >/dev/null
check "resync: a changed option drops what it no longer lists" eq "$(cat "$OYG_STATE/mounts.fakeopt" "$OYG_STATE/ls2.fakeopt" 2>/dev/null)" ""
check "resync: the new service list is recorded" eval '[ "$(sed -n "s/^spec_md5=//p" "$OYG_STATE/kv.fakeopt")" != 0123 ]'
printf '/usr/sbin/stays\n' > "$OYG_STATE/mounts.fakeopt"
opt_apply fakeopt >/dev/null
check "resync: an unchanged option keeps its records" eq "$(cat "$OYG_STATE/mounts.fakeopt")" "/usr/sbin/stays"
rm -f "$OYG_STATE"/*.fakeopt

# ------------------------------------------------------------ selection --
S="$TDIR/sel"; mkdir -p "$S"; PRESET_FILE="$S/preset"; CUSTOM_FILE="$S/custom"
check "selection: nothing chosen is Recommended" eq "$(selected_options | tr '\n' ' ')" "$(printf '%s ' $PRESET_recommended)"
printf 'strict\n' > "$PRESET_FILE"
check "selection: a preset" eq "$(selected_options | tr '\n' ' ')" "$(for o in $OYG_OPTIONS; do case " $PRESET_strict " in *" $o "*) printf '%s ' "$o";; esac; done)"
printf 'custom\n' > "$PRESET_FILE"; printf 'base=recommended\nvoice=off\nhbbtv=on\n' > "$CUSTOM_FILE"
sel=" $(selected_options | tr '\n' ' ') "
check "selection: Custom = base preset plus explicit choices" eval 'case "$sel" in *" voice "*) false;; esac && case "$sel" in *" hbbtv "*) true;; *) false;; esac && case "$sel" in *" acr "*) true;; *) false;; esac'
check "selection: catalogue order" eq "$(selected_options | head -1)" "acr"

# ------------------------------------------------------------ migration --
# a 1.4 state tree: its records go to the options that own them
M="$TDIR/mig"; mkdir -p "$M/state" "$M/backup"
(
    OYG_ROOT=$M; OYG_STATE=$M/state; OYG_BACKUP=$M/backup; PRESET_FILE=$M/preset; CUSTOM_FILE=$M/custom
    printf 'nag\nacr\ncloud\n' > "$M/enabled"
    printf '/usr/sbin/acr2\n/usr/sbin/contentminer\n/usr/sbin/admanager\n' > "$M/state/mounts.acr"
    printf '/var/palm/jail/lg.thinqai.adapter/usr/sbin/lg.thinqai.adapter\n/usr/sbin/airessrvallocator\n' > "$M/state/mounts.voice"
    printf 'chromecast-provisioning.service\n' > "$M/state/units.cloud"
    printf 'com.webos.service.dial\n' > "$M/state/ls2.cloud"
    printf '/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf\n' > "$M/state/mounts.sdx"
    printf 'applied=1\nprefix_default=AU\n' > "$M/state/kv.sdx"
    printf '%s\n' 'settings.general={"adCookie":"on","sportsAlarm":"on"}' 'eula.flipped=id:S_VNG' 'applied=1' > "$M/state/kv.consent"
    oyg_migrate_modules >/dev/null
) 
check "migration: records go to their option" eq "$(cat "$M/state/mounts.acr" 2>/dev/null)/$(cat "$M/state/mounts.promos" 2>/dev/null)/$(cat "$M/state/mounts.ads" 2>/dev/null)" "/usr/sbin/acr2//usr/sbin/contentminer//usr/sbin/admanager"
check "migration: jailed copies by their host path" eq "$(cat "$M/state/mounts.voice" 2>/dev/null)" "/var/palm/jail/lg.thinqai.adapter/usr/sbin/lg.thinqai.adapter"
check "migration: released services go to legacy" eq "$(cat "$M/state/mounts.legacy" 2>/dev/null)" "/usr/sbin/airessrvallocator"
check "migration: units and launch names by owner" eq "$(cat "$M/state/units.cast" 2>/dev/null)/$(cat "$M/state/ls2.dial" 2>/dev/null)" "chromecast-provisioning.service/com.webos.service.dial"
check "migration: resources keep their records" eq "$(cat "$M/state/mounts.sdx")/$(sed -n 's/^prefix_default=//p' "$M/state/kv.sdx")" "/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf/AU"
if command -v python3 >/dev/null 2>&1; then
    check "migration: settings split by owning option" eq "$(sed -n 's/^settings.general=//p' "$M/state/kv.ads")|$(sed -n 's/^settings.general=//p' "$M/state/kv.buddy-sports")" '{"adCookie":"on"}|{"sportsAlarm":"on"}'
fi
check "migration: consent flips kept for the consents option" eq "$(sed -n 's/^eula.flipped=//p' "$M/state/kv.consents")" "id:S_VNG"
check "migration: selection becomes Recommended" eq "$(cat "$M/preset")/$(find "$M/state" -name '*.consent' -o -name '*.cloud' | wc -l | tr -d ' ')" "recommended/0"

# --------------------------------------------------------------- survey --
. "$REPO/toolkit/lib/survey.sh"
cat > "$OYG_PROC/mounts" <<'EOF'
/dev/mmcblk0p58 /mnt/lg/cache/sdp ext4 rw,nosuid,relatime 0 0
/dev/sda1 /tmp/usb/sda/sda1 vfat rw,relatime,gid=5000,fmask=0002 0 0
/dev/sda1 /var/palm/jail/com.webos.app.browser/tmp/usb/sda/sda1 vfat rw,relatime 0 0
/dev/sdb1 /tmp/usb/sdb/sdb1 vfat ro,relatime 0 0
EOF
check "survey: USB storage is the owner's writable mount, not a jail's" eq "$(usb_dirs | tr '\n' ' ')" "/tmp/usb/sda/sda1 "
check "survey: usb-check lists it" eq "$(do_survey usb-check)" "USB|/tmp/usb/sda/sda1"
printf '{\n  "webos_release": "10.3.1",\n  "webos_manufacturing_version": "33.31.68",\n  "core_os_release": "10.3.1-3006"\n}\n' > "$F/os_info.json"
check "survey: firmware as Settings shows it" eq "$(NYX_OS_INFO=$F/os_info.json survey_firmware)" "33.31.68"
_sv() { NYX_OS_INFO=$F/os_info.json; model_name() { printf 'OLED55C5PSA'; }; webos_version() { printf '10.3.1'; }; sdx_known() { case $1 in default) printf au ;; ric) printf aic ;; esac; }; }
check "survey: file name has model, country, webOS and firmware" eq "$(_sv; survey_filename)" "oyg-report_OLED55C5PSA_AU_webOS10.3.1_fw33.31.68.txt"
check "survey: region when the country is unknown, odd characters replaced" eq "$(_sv; model_name() { printf 'OLED 55/C5'; }; sdx_known() { [ "$1" = ric ] && printf aic; }; survey_filename)" "oyg-report_OLED_55_C5_AIC_webOS10.3.1_fw33.31.68.txt"
mkdir -p "$F/usb"; SURVEY_FILE=$F/report.txt
( _sv; survey_lines() { _t=/wrong _n=wrong; echo 'SURVEY|oyg|x'; echo 'ls: noise' >&2; }; survey_report > "$F/shown.txt" )
check "survey: the report is kept, with a header and without stderr" eq "$(sed 's/, [0-9-]* [0-9:]*$//' "$SURVEY_FILE" 2>/dev/null)" \
    "# Own Your Glass TV report
SURVEY|oyg|x"
check "survey: what is printed is what is kept" cmp -s "$F/shown.txt" "$SURVEY_FILE"
( _sv; usb_dirs() { printf '%s\n' "$F/usb"; }; survey_lines() { echo 'SURVEY|oyg|changed'; }; survey_usb >/dev/null )
check "survey: USB gets the report shown, not a new one" cmp -s "$F/shown.txt" "$F/usb/oyg-report_OLED55C5PSA_AU_webOS10.3.1_fw33.31.68.txt"
rm -f "$SURVEY_FILE" "$F/usb/"*
( _sv; usb_dirs() { printf '%s\n' "$F/usb"; }; survey_lines() { echo 'SURVEY|oyg|new'; }; survey_usb >/dev/null )
check "survey: USB gets a new report when there is none" eq "$(tail -n 1 "$F/usb/oyg-report_OLED55C5PSA_AU_webOS10.3.1_fw33.31.68.txt" 2>/dev/null)" "SURVEY|oyg|new"
check "survey: no USB storage, nothing written" eval '! ( usb_dirs() { :; }; survey_usb ) >/dev/null 2>&1'

# ------------------------------------------------------------ forgetting --
if command -v sqlite3 >/dev/null 2>&1; then
    WAM_ORIGINS=$F/AppsOrigins INSTALL_HISTORY=$F/installHistory2.db
    sqlite3 "$WAM_ORIGINS" "CREATE TABLE applications(id INTEGER PRIMARY KEY,app_id LONGVARCHAR NOT NULL,installed INTEGER DEFAULT 0 NOT NULL);
        CREATE TABLE origins(id INTEGER PRIMARY KEY,url LONGVARCHAR NOT NULL); CREATE TABLE access(id_app INTEGER NOT NULL,id_origin INTEGER NOT NULL);
        INSERT INTO applications VALUES(1,'com.webos.app.lgchannels-webos',0),(2,'$OYG_APPID-webos',1);
        INSERT INTO origins VALUES(1,'https://oyg.invalid/'),(2,'https://kic.oyg.invalid/'),(3,'https://kic.lgtvcommon.com/'),(4,'https://notoyg.invalid.example/');
        INSERT INTO access VALUES(1,1),(1,2),(1,3),(1,4),(2,3);"
    sqlite3 "$INSTALL_HISTORY" "CREATE TABLE InstallHistory(appId TEXT NOT NULL UNIQUE, name TEXT, status INTEGER, details TEXT);
        INSERT INTO InstallHistory VALUES('$OYG_APPID','x',31,'{\"state\":\"removed\"}'),('netflix','n',30,'{}');"
    ( OYG_DRYRUN=1 forget_traces ) >/dev/null
    check "forget: a dry run leaves the origins" eq "$(sqlite3 "$WAM_ORIGINS" 'SELECT count(*) FROM origins')" "4"
    forget_origins >/dev/null
    check "forget: only the placeholder origins go" eq "$(sqlite3 "$WAM_ORIGINS" 'SELECT url FROM origins ORDER BY id' | tr '\n' ' ')" "https://kic.lgtvcommon.com/ https://notoyg.invalid.example/ "
    check "forget: and their access rows" eq "$(sqlite3 -separator : "$WAM_ORIGINS" 'SELECT id_app, id_origin FROM access ORDER BY 1, 2' | tr '\n' ' ')" "1:3 1:4 2:3 "
    # WAM and the installer on removal (webOS's SQLite keeps deleted bytes; some hosts' builds wipe them)
    sqlite3 "$WAM_ORIGINS" "PRAGMA secure_delete=OFF; DELETE FROM access WHERE id_app=2; DELETE FROM applications WHERE id=2;" >/dev/null
    sqlite3 "$INSTALL_HISTORY" "PRAGMA secure_delete=OFF; DELETE FROM InstallHistory WHERE appId='$OYG_APPID'" >/dev/null
    if grep -q -F "$OYG_APPID" "$INSTALL_HISTORY"; then check "forget: a deleted row stays in the file" true
    else echo "note: this host's sqlite wipes deleted rows (the TV's keeps them): the rebuild is exercised on a clean file"; fi
    forget_files "$WAM_ORIGINS" "$INSTALL_HISTORY" >/dev/null
    check "forget: rebuilt, the app is nowhere in either file" eval '! grep -q -F -e "$OYG_APPID" -e //oyg.invalid/ -e kic.oyg.invalid "$WAM_ORIGINS" "$INSTALL_HISTORY"'
    check "forget: other rows kept" eq "$(sqlite3 "$INSTALL_HISTORY" 'SELECT appId FROM InstallHistory')" "netflix"
    touch -d 2020-01-01 "$INSTALL_HISTORY"; forget_files "$INSTALL_HISTORY" >/dev/null
    check "forget: a clean file is left alone" eq "$(date -r "$INSTALL_HISTORY" +%Y)" "2020"
    unset WAM_ORIGINS INSTALL_HISTORY
else echo "skip: forget tests need sqlite3"; fi
FIRST_USE=$F/firstUseAppInfo.json
for _l in '"io.strem.tv", "org.ownyourglass.app"' '"org.ownyourglass.app", "io.strem.tv"' '"netflix", "org.ownyourglass.app", "io.strem.tv"'; do
    printf '{"first_use_apps": [%s]}' "$_l" > "$FIRST_USE"; touch -d '2026-09-20 10:00:00' "$FIRST_USE"
    forget_first_use >/dev/null
    check "forget: the app comes off the first-use list ($_l)" eq "$(grep -c ownyourglass "$FIRST_USE"; sed 's/"netflix", //' "$FIRST_USE")" '0
{"first_use_apps": ["io.strem.tv"]}'
done
check "forget: the first-use list keeps its time" eq "$(date -r "$FIRST_USE" '+%F %T')" "2026-09-20 10:00:00"
printf '{"first_use_apps": ["org.ownyourglass.app"]}' > "$FIRST_USE"; forget_first_use >/dev/null
check "forget: a list that held only the app goes" eval '[ ! -e "$FIRST_USE" ]'
printf '{"first_use_apps": ["netflix"]}' > "$FIRST_USE"; touch -d '2026-09-20 10:00:00' "$FIRST_USE"; forget_first_use >/dev/null
check "forget: a list without the app is left alone" eq "$(cat "$FIRST_USE"; date -r "$FIRST_USE" +%F)" '{"first_use_apps": ["netflix"]}2026-09-20'
printf '{"first_use_apps": ["netflix", "org.ownyourglass.app"]}' > "$FIRST_USE"; touch -d '2026-09-20 10:00:00' "$FIRST_USE"
forget_first_use >/dev/null; first_use_note; printf '{"first_use_apps": ["netflix", "com.webos.app.home"]}' > "$FIRST_USE"
first_use_settle >/dev/null
check "forget: what the restore's window added goes too" eq "$(cat "$FIRST_USE"; date -r "$FIRST_USE" '+ %F %T')" '{"first_use_apps": ["netflix"]} 2026-09-20 10:00:00'
rm -f "$FIRST_USE"; first_use_note; printf '{"first_use_apps": ["com.webos.app.home"]}' > "$FIRST_USE"; first_use_settle >/dev/null
check "forget: no first-use list before, none after" eval '[ ! -e "$FIRST_USE" ]'
printf '{\n  "first_use_apps": [\n    "netflix",\n    "org.ownyourglass.app"\n  ]\n}' > "$FIRST_USE"
if command -v python3 >/dev/null 2>&1; then forget_first_use >/dev/null 2>&1
    check "forget: a layout the edit would break is left alone" eq "$(grep -c ownyourglass "$FIRST_USE")" "1"; fi
unset FIRST_USE
printf 'a\nb\n' > "$F/ek"; touch -d '2026-09-20 10:00:00' "$F/ek"
edit_keep_mtime "$F/ek" sed 's/b/c/'
check "edit: content replaced, time kept, no work file left" eq "$(cat "$F/ek"; date -r "$F/ek" '+%F %T'; ls "$F" | grep -c 'ek.oyg')" 'a
c
2026-09-20 10:00:00
0'
edit_keep_mtime "$F/ek" false
check "edit: a failed command leaves the file as it was" eq "$(cat "$F/ek"; date -r "$F/ek" '+%F %T')" 'a
c
2026-09-20 10:00:00'
_jr=$JAIL_ROOT; JAIL_ROOT=$F/jail; _stock='127.0.0.1	localhost
::1	localhost ip6-localhost'
mkdir -p "$JAIL_ROOT/browser/etc" "$JAIL_ROOT/alexa/etc" "$JAIL_ROOT/netflix/etc"
printf '%s\n# own-your-glass begin\n0.0.0.0 ads.example\n::1 ads.example\n# own-your-glass end\n' "$_stock" > "$JAIL_ROOT/browser/etc/hosts"   # set up while bound
printf '%s\n# own-your-glass begin\n# own-your-glass end\n' "$_stock" > "$JAIL_ROOT/alexa/etc/hosts"                                # an old version's block
printf '%s\n' "$_stock" > "$JAIL_ROOT/netflix/etc/hosts"
touch -d '2026-09-23 16:49:46' "$JAIL_ROOT"/*/etc/hosts
( OYG_DRYRUN=1 network_strip_jails ) >/dev/null
check "jails: a dry run leaves the sinkhole" grep -q '^# own-your-glass' "$JAIL_ROOT/browser/etc/hosts"
network_strip_jails >/dev/null
for _j in browser alexa netflix; do
    check "jails: $_j gets the stock hosts file back, with its time" eq "$(cat "$JAIL_ROOT/$_j/etc/hosts"; date -r "$JAIL_ROOT/$_j/etc/hosts" '+%F %T')" "$_stock
2026-09-23 16:49:46"
done
check "jails: no work files left" eval '[ -z "$(ls "$JAIL_ROOT"/*/etc | grep oyg)" ]'
JAIL_ROOT=$_jr

# BusyBox grep -f with an empty pattern file matches everything: minus_file guards it
printf 'a\n' > "$F/minus"
check "minus_file: lines in the file go" eq "$(printf 'a\nb\n' | minus_file "$F/minus" | tr '\n' ' ')" "b "
check "minus_file: an empty file takes nothing" eq "$(printf 'a\nb\n' | minus_file /dev/null | tr '\n' ' ')" "a b "

# codes: {ric} takes every region LG names; {cc} takes the TV's country, or
# every country LG serves until sdx has told it
OYG_MOD=sdx; printf 'default=AU\nric=KIC\ngroup=default\n' > "$SDX_PREFIXES"
check "codes: {ric} expands to the five regions and the bare name" eq "$(printf '{ric}.x.example' | hosts_expand | sort | tr '\n' ' ')" "aic.x.example cic.x.example eic.x.example kic.x.example ruc.x.example x.example "
check "codes: {cc} is the TV's country when known" eq "$(printf '{cc}.x.example' | hosts_expand | tr '\n' ' ')" "au.x.example "
rm -f "$SDX_PREFIXES" "$OYG_STATE/kv.sdx"
_all=$(printf '{cc}.x.example' | hosts_expand)
check "codes: {cc} unknown: every LG country, no placeholders" eval 'printf "%s\n" "$_all" | grep -qx kr.x.example && printf "%s\n" "$_all" | grep -qx au.x.example && ! printf "%s\n" "$_all" | grep -q "^x[a-e]\." && [ "$(printf "%s\n" "$_all" | grep -c .)" -gt 90 ]'
check "codes: unknown is reported" eval '! hosts_cc_known'
SDX_ORIG="$F/sdx-pretty.conf"
check "codes: table-derived hosts fall back too, never the shared gateway" eval 'sdx_blocked_hosts | grep -qx kr.rdx2.nextlgsdp.com && ! sdx_blocked_hosts | grep -qE "^[a-z]+\.nextlgsdp\.com$"'
OYG_MOD=test

# static entries: skipped on a release not run on, unless untested is on
_kr=$OYG_KB_RUN; OYG_KB_RUN="9.9"; rm -f "$UNTESTED_FILE"
check "static: skipped on a release not run on" static_skipped static
check "static: a dynamic entry is never skipped" eval '! static_skipped dynamic'
check "static: untested on includes it" eval '! OYG_UNTESTED=1 static_skipped static'
OYG_KB_RUN="9.9 $(webos_generation)"
check "static: applied on a release run on" eval '! static_skipped static'
OYG_KB_RUN=$_kr

# lock: stale when its pid is gone, from another boot, or not an oyg run
printf 'cpu 1 2 3\nbtime 1790500000\n' > "$OYG_PROC/stat"
mkdir -p "$OYG_ROOT/lock"; printf 'sleep 30\n' > "$F/oyg-lock-holder"; sh "$F/oyg-lock-holder" & _lh=$!
printf '%s\n1790500000\n' "$_lh" > "$OYG_ROOT/lock/pid"
check "lock: a live oyg run in this boot holds it" eval '! lock_stale'
printf '%s\n1790400000\n' "$_lh" > "$OYG_ROOT/lock/pid"
check "lock: a pid from another boot is stale" lock_stale
printf '%s\n' "$_lh" > "$OYG_ROOT/lock/pid"
check "lock: a 1.4 lock without a boot stamp is stale" lock_stale
printf '%s\n1790500000\n' "$$" > "$OYG_ROOT/lock/pid"
check "lock: a live pid that is not an oyg run is stale" lock_stale
kill "$_lh" 2>/dev/null; wait "$_lh" 2>/dev/null
printf '%s\n1790500000\n' "$_lh" > "$OYG_ROOT/lock/pid"
check "lock: a dead pid is stale" lock_stale
rm -rf "$OYG_ROOT/lock"

# screenshots: the phone API without its screenshot calls. One method object
# goes, with its comma; everything else stays byte for byte, braces and
# quotes inside strings included.
cat > "$F/ssg.interface" <<'EOF'
{
	"service": "com.example.api",
	"methods": [
		{
			"path": "/first",
			"description": "a } and a \" in a string { ["
		},
		{
			"path": "/tv/executeOneShot",
			"requiredPermissions": [
				"CONTROL_DISPLAY"
			],
			"resources": {
				"media": {
					"responseProperties": [
						"imageUri"
					]
				}
			}
		},
		{
			"path": "/last"
		}
	]
}
EOF
cat > "$F/ssg.mid" <<'EOF'
{
	"service": "com.example.api",
	"methods": [
		{
			"path": "/first",
			"description": "a } and a \" in a string { ["
		},
		{
			"path": "/last"
		}
	]
}
EOF
ssg_drop /tv/executeOneShot < "$F/ssg.interface" > "$F/ssg.out"
check "screenshots: a method in the middle goes with its comma" cmp -s "$F/ssg.out" "$F/ssg.mid"
ssg_drop /last < "$F/ssg.mid" > "$F/ssg.out"
check "screenshots: the last method takes the comma before it" eq "$(cat "$F/ssg.out")" "$(sed -n '1,7p;11,$p' "$F/ssg.mid" | sed '7s/},/}/')"
printf '{\n\t"service": "x",\n\t"methods": [\n\t\t{\n\t\t\t"path": "/executeOneShot"\n\t\t}\n\t]\n}\n' | ssg_drop /executeOneShot > "$F/ssg.out"
check "screenshots: the only method leaves an empty list" eq "$(tr -d ' \t\n' < "$F/ssg.out")" '{"service":"x","methods":[]}'
ssg_drop /executeOneShot < "$F/ssg.interface" > "$F/ssg.out"
check "screenshots: a path that only ends the same is kept" cmp -s "$F/ssg.out" "$F/ssg.interface"
ssg_drop /first < "$F/ssg.interface" > "$F/ssg.out"
check "screenshots: braces inside a string do not confuse the depth" eq "$(grep -c '"path"' "$F/ssg.out")/$(sed -n 4p "$F/ssg.out" | tr -d '\t')" "2/{"

# screenshots: Recents directories root-only (the missing one made first),
# undone from the records; a bind that fails (not root here) is survivable.
# mount and umount are stubbed as shell functions, never as files on PATH: a
# BusyBox built with standalone applets (Ubuntu's, on CI) runs its own
# applet before it looks at PATH, and a function comes before either.
_sd="$TDIR/snap"; mkdir -p "$_sd/old"; chmod 755 "$_sd/old"
SNAP_DIRS="$_sd/old $_sd/new"; SNAP_MAKE="$_sd/new"; SSG_IFACES="$F/none"; CAP_DIR="$F/capdir"; SHOT_JPG="$F/capture.jpg"
(umask 022; mount() { return 1; }; OYG_MOD=screenshots; hook_screenshots_apply >/dev/null 2>&1)
check "screenshots: Recents directories become 0700" eq "$(stat -c %a "$_sd/old")/$(stat -c %a "$_sd/new" 2>/dev/null)" "700/700"
check "screenshots: their modes are recorded" eq "$(grep -F "$_sd/" "$OYG_STATE/modes.screenshots" | sort | tr '\n' '|')" "$_sd/new 755|$_sd/old 755|"
check "screenshots: status says root-only" eq "$(OYG_MOD=screenshots hook_screenshots_status s | head -1)" "s|OK|Recents screenshots root-only"
(OYG_MOD=screenshots; generic_restore >/dev/null 2>&1)
check "screenshots: restore puts the modes back and removes the file it made" eq "$(stat -c %a "$_sd/old")/$(stat -c %a "$_sd/new")/$([ -e "$SHOT_JPG" ] && echo left)" "755/755/"

# screenshots and the capture shield, the whole way: fixture interface files,
# and mount/umount stubs that keep $OYG_PROC/mounts the way the kernel would
_pm_keep="$F/mounts.keep"; cp "$OYG_PROC/mounts" "$_pm_keep"
mkdir -p "$F/ssg" "$TDIR/tmp"
mount() { [ "$1" = --bind ] && printf 'fake %s tmpfs rw 0 0\n' "$3" >> "$OYG_PROC/mounts"; return 0; }
umount() { _umt=$1; [ "$_umt" = -l ] && _umt=$2; grep -v " $_umt " "$OYG_PROC/mounts" > "$OYG_PROC/mounts.t"; mv "$OYG_PROC/mounts.t" "$OYG_PROC/mounts"; }
cat > "$F/ssg/com.webos.service.capture.interface" <<'EOF'
{
	"service": "com.webos.service.capture",
	"methods": [
		{
			"path": "/executeOneShot",
			"requiredPermissions": ["CONTROL_DISPLAY"]
		}
	]
}
EOF
cat > "$F/ssg/com.webos.service.apiadapter.interface" <<'EOF'
{
	"service": "com.webos.service.apiadapter",
	"methods": [
		{ "path": "/audio/getVolume", "requiredPermissions": ["READ_STATUS"] },
		{ "path": "/tv/executeOneShot", "requiredPermissions": ["CONTROL_DISPLAY"], "resources": { "media": { "responseProperties": ["imageUri"] } } },
		{ "path": "/tv/getCurrentChannel" }
	]
}
EOF
cat > "$F/ssg/tv.interface" <<'EOF'
{
	"virtualService": "tv",
	"methods": [
		{ "path": "/getCurrentChannel", "provider": "com.webos.service.apiadapter/tv/getCurrentChannel" },
		{ "path": "/executeOneShot", "provider": "com.webos.service.apiadapter/tv/executeOneShot" }
	]
}
EOF
cp -R "$F/ssg" "$F/ssg.orig"
SNAP_DIRS="$_sd/none"; SNAP_MAKE="$_sd/none"; SSG_IFACES="$F/ssg"; CAP_DIR="$TDIR/run-oyg"; SHOT_JPG="$TDIR/tmp/capture.jpg"
ss_apply() { (OYG_MOD=screenshots; mounts_snapshot; hook_screenshots_apply; echo "apply went on") > "$F/ss.log" 2>&1; }
ss_status() { (OYG_MOD=screenshots; mounts_snapshot; hook_screenshots_status s); }
ss_restore() { (OYG_MOD=screenshots; mounts_snapshot; hook_screenshots_restore >/dev/null 2>&1; generic_restore >/dev/null 2>&1); }
ss_apply
check "screenshots: the three phone-API files are bound" eq "$(grep -c "^$F/ssg/" "$OYG_STATE/mounts.screenshots")" "3"
check "screenshots: each copy is whole JSON without its screenshot call, the rest kept" python3 -c '
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/ssg.com.webos.service.capture.interface"))
a = json.load(open(d + "/ssg.com.webos.service.apiadapter.interface"))
t = json.load(open(d + "/ssg.tv.interface"))
paths = lambda j: [m["path"] for m in j["methods"]]
sys.exit(0 if (paths(c), paths(a), paths(t)) == ([], ["/audio/getVolume", "/tv/getCurrentChannel"], ["/getCurrentChannel"]) else 1)' "$OYG_ROOT"
check "screenshots: the files under the binds are untouched" diff -r "$F/ssg" "$F/ssg.orig"
check "screenshots: the phone screenshot file is shielded from a root-only folder" eq "$(stat -c %a "$CAP_DIR")/$(stat -c %a "$CAP_DIR/capture.jpg")/$(grep -c " $SHOT_JPG " "$OYG_PROC/mounts")" "700/600/1"
check "screenshots: status after apply" eq "$(ss_status | tail -2 | tr '\n' '|')" "s|OK|phone screenshot calls removed|s|OK|phone screenshot file root-only|"
OYG_MOD=screenshots; kv_set ssg_stale "$(boot_stamp)"; OYG_MOD=test
check "screenshots: a gateway that read its calls first is RESIDENT" eval 'ss_status | grep -q "^s|RESIDENT|phone screenshot calls removed, but the phone service read them before"'
OYG_MOD=screenshots; kv_set ssg_stale ""; OYG_MOD=test
# undo: a restart where phones can reach the TV, none where they cannot
_ssp_on=true; luna() { case $1 in */getSystemSettings) printf '{"returnValue": true, "settings": {"allowMobileDeviceAccess": %s}}\n' "$_ssp_on" ;; esac; }
rm -f "${OYG_RESTART:?}"; (PATH="$F/stubp:$PATH"; ss_restore)
check "screenshots: undo where phones reach the TV asks for a restart" eq "$(restart_reasons)" "$SHOTS_BACK"
check "screenshots: undo unbinds and removes the file it made" eq "$(grep -c "$F/ssg/\| $SHOT_JPG " "$OYG_PROC/mounts")/$([ -e "$SHOT_JPG" ] && echo left)" "0/"
rm -f "${OYG_RESTART:?}"; _ssp_on=false; ss_apply; (PATH="$F/stubp:$PATH"; ss_restore)
check "screenshots: undo where phones cannot reach the TV asks for nothing" eq "$(restart_reasons)" ""
# a file without its screenshot call is left as it is, and status counts it as done
printf '{\n\t"virtualService": "tv",\n\t"methods": [\n\t\t{ "path": "/getCurrentChannel" }\n\t]\n}\n' > "$F/ssg/tv.interface"
ss_apply
check "screenshots: a file without the call is not bound" eq "$(grep -c "$F/ssg/tv.interface" "$OYG_STATE/mounts.screenshots")" "0"
check "screenshots: status counts it as done" eq "$(ss_status | grep 'phone screenshot calls')" "s|OK|phone screenshot calls removed"
umount_one() { grep -v " $1 " "$OYG_PROC/mounts" > "$OYG_PROC/mounts.t"; mv "$OYG_PROC/mounts.t" "$OYG_PROC/mounts"; }
umount_one "$F/ssg/com.webos.service.capture.interface"
check "screenshots: a call file left unbound is reported" eq "$(ss_status | grep 'screenshots (')" "s|WARN|phone apps can take screenshots (1 of 2 calls removed)"
ss_restore; cp "$F/ssg.orig/tv.interface" "$F/ssg/tv.interface"
# a copy that does not come out whole is never bound
printf '{\n\t"service": "x",\n\t"methods": [\n\t\t{ "path": "/a" },\n\t\t{ "pa' > "$F/half.json"
check "screenshots: a cut-short copy fails the check" eval '! ssg_valid "$F/half.json" /executeOneShot'
check "screenshots: a whole copy passes it" ssg_valid "$OYG_ROOT/ssg.tv.interface" /executeOneShot
# a link at a shielded path: left alone, and the apply goes on (a failed
# redirection used to stop the whole oyg run there)
rm -f "${SHOT_JPG:?}"; printf 'keep me\n' > "$F/victim"; chmod 644 "$F/victim"; ln -s "$F/victim" "$SHOT_JPG"
ss_apply
check "shield: a link at the path is left alone and the apply goes on" eval 'grep -q "is not a plain file: left alone" "$F/ss.log" && grep -q "^apply went on" "$F/ss.log"'
check "shield: what the link points to is untouched" eq "$(cat "$F/victim")/$(stat -c %a "$F/victim")" "keep me/644"
check "shield: status reports the link" eval 'ss_status | grep -q "^s|WARN|phone screenshot file is a link"'
ss_restore; rm -f "${SHOT_JPG:?}"
# a shield bound by 1.5.5 or older (copy in /tmp) is made again from CAP_DIR
: > "$SHOT_JPG"; printf 'fake %s tmpfs rw 0 0\n' "$SHOT_JPG" >> "$OYG_PROC/mounts"
(OYG_MOD=screenshots; state_add mounts "$SHOT_JPG")
(OYG_MOD=screenshots; mounts_snapshot; shield_file "$SHOT_JPG" >/dev/null 2>&1; echo $? > "$F/rc")
check "shield: an older build's shield is made again" eq "$(cat "$F/rc")/$(OYG_MOD=screenshots kv_get shadow.capture.jpg)" "0/$CAP_DIR/capture.jpg"
(OYG_MOD=screenshots; mounts_snapshot; shield_file "$SHOT_JPG" >/dev/null 2>&1; echo $? > "$F/rc")
check "shield: then it is left as it is" eq "$(cat "$F/rc")" "2"
# what jails see under a bind is the file itself: emptied and root-only first
printf 'last frame' > "$TDIR/tmp/frame.rgb"; chmod 644 "$TDIR/tmp/frame.rgb"
(OYG_MOD=capture; mounts_snapshot; shield_file "$TDIR/tmp/frame.rgb" >/dev/null 2>&1)
check "shield: the file under the bind is emptied and made root-only first" eq "$(stat -c '%s %a' "$TDIR/tmp/frame.rgb")" "0 600"
(OYG_MOD=capture; mounts_snapshot; generic_restore >/dev/null 2>&1)
check "shield: restore unbinds it and gives the mode back" eq "$(grep -c " $TDIR/tmp/frame.rgb " "$OYG_PROC/mounts")/$(stat -c %a "$TDIR/tmp/frame.rgb")" "0/644"
rm -f "${TDIR:?}/tmp/frame.rgb"
ss_restore; rm -f "${SHOT_JPG:?}"; _or=$OYG_RESTART; unset -f luna umount_one mount umount; . "$REPO/toolkit/lib/common.sh"; OYG_RESTART=$_or; log() { :; }
cp "$_pm_keep" "$OYG_PROC/mounts"

# capture: OLED care's screen samples, where it takes any
EPL_BIN="$F/eplmanager"; printf 'bin\0/tmp/capture.rgb\0' > "$EPL_BIN"; CAP_FILE="$F/capture.rgb"; printf 'x' > "$CAP_FILE"
EPL_OSD_OFF="$F/osdCaptureDisable"
printf '42\teplmanager\t/usr/sbin/eplmanager\t/usr/sbin/eplmanager\n' > "$OYG_PSF"
check "capture: a fresh sample means OLED care is fed" eq "$(capture_oled_status c)" "c|OK|OLED care is getting its screen samples"
: > "$CAP_FILE"
check "capture: a fresh shield waits for its first sample" eq "$(capture_oled_status c)" "c|OK|OLED care: waiting for its first screen sample"
printf 'x' > "$CAP_FILE"; touch -t 202001010000 "$CAP_FILE"
check "capture: a stale sample is reported" eval 'capture_oled_status c | grep -q "^c|WARN|OLED care has had no screen sample"'
: > "$EPL_OSD_OFF"
check "capture: LG's switch-off is said, not warned about" eq "$(capture_oled_status c)" "c|OK|OLED care takes no screen samples here (switched off in LG's test menu)"
rm -f "${EPL_OSD_OFF:?}"; printf 'bin\0no samples\0' > "$EPL_BIN"
check "capture: a pixel care that samples nothing (before webOS 10) gets no line" eq "$(capture_oled_status c)" ""
printf 'bin\0/tmp/capture.rgb\0' > "$EPL_BIN"; printf '1\tinit\t/sbin/init\tinit\n' > "$OYG_PSF"
check "capture: eplmanager not running (an LCD set) gets no line" eq "$(capture_oled_status c)" ""
rm -f "${EPL_BIN:?}"
check "capture: no panel service, nothing to say" eq "$(capture_oled_status c)" ""
: > "$OYG_PSF"
check "debugger: no iptables, not available" eq "$(PATH="$TDIR/bin"; hook_debugger_status d)" "d|NA|no iptables on this TV"
. "$REPO/toolkit/hooks/capture.sh"; . "$REPO/toolkit/hooks/screenshots.sh"

# port_listening: the kernel's socket tables, IPv4 and IPv6, each skipped
# when the kernel has none
mkdir -p "$OYG_PROC/net"
printf '  sl  local_address rem_address   st\n   0: 00000000:0203 00000000:0000 0A\n' > "$OYG_PROC/net/tcp"
check "port: an IPv4 listener is found with no IPv6 table at all" port_listening 515
check "port: v6 asks IPv6 only" eval '! port_listening 515 v6'
printf '  sl  local_address rem_address   st\n   0: 00000000000000000000000000000000:270E 00000000000000000000000000000000:0000 0A\n' > "$OYG_PROC/net/tcp6"
check "port: an IPv6 listener is found" port_listening 9998 v6
check "port: a port nobody listens on" eval '! port_listening 23'
rm -rf "${OYG_PROC:?}/net"

# printing: port 515 read from the kernel's socket tables, IPv4 and IPv6
mkdir -p "$OYG_PROC/net"; LPD_BIN="$F/cups-lpd"; : > "$LPD_BIN"
printf '  sl  local_address rem_address   st\n   0: 00000000:0203 00000000:0000 0A\n' > "$OYG_PROC/net/tcp"
printf '  sl  local_address rem_address   st\n' > "$OYG_PROC/net/tcp6"
check "printing: a listener on 515 is reported" eq "$(hook_printing_status p)" "p|WARN|printing port 515 still open"
printf '  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A\n' > "$OYG_PROC/net/tcp"
printf '  sl  local_address rem_address   st\n   0: 00000000000000000000000000000000:0203 00000000000000000000000000000000:0000 06\n' > "$OYG_PROC/net/tcp6"
check "printing: closed when nothing listens on 515 (a connection winding down is not a listener)" eq "$(hook_printing_status p)" "p|OK|printing port 515 closed"
printf '  sl  local_address rem_address   st\n   0: 00000000000000000000000000000000:0203 00000000000000000000000000000000:0000 0A\n' > "$OYG_PROC/net/tcp6"
check "printing: an IPv6 listener counts" eq "$(hook_printing_status p)" "p|WARN|printing port 515 still open"
rm -f "${LPD_BIN:?}"
check "printing: no LPD server, nothing to say" eq "$(hook_printing_status p)" ""
rm -rf "${OYG_PROC:?}/net"; . "$REPO/toolkit/hooks/printing.sh"
# lan: the printing socket's record (1.5.1 and older) moves to the printing
# option, from oyg_migrate, before any restore pass
OYG_MOD=lan; rm -f "${OYG_STATE:?}/units.lan" "${OYG_STATE:?}/units.printing"
state_add units rdisc.service; state_add units cups-lpd.socket; OYG_MOD=test; oyg_migrate
check "lan: the printing socket's record moves to the printing option" eq "$(cat "$OYG_STATE/units.lan")/$(cat "$OYG_STATE/units.printing" 2>/dev/null)/$OYG_MOD" "rdisc.service/cups-lpd.socket/test"
OYG_MOD=lan; lan_handover_lpd; OYG_MOD=test
check "lan: the handover runs once" eq "$(cat "$OYG_STATE/units.lan")/$(cat "$OYG_STATE/units.printing" 2>/dev/null)" "rdisc.service/cups-lpd.socket"
rm -f "${OYG_STATE:?}/units.lan" "${OYG_STATE:?}/units.printing"

# firewall chains: built under a new name and swapped in, never flushed while
# INPUT jumps to them; a refused rule leaves the chain that was there
IPT_DIR="$F/ipt"; mkdir -p "$IPT_DIR" "$F/stubi"; : > "$IPT_DIR/INPUT"; export IPT_DIR
cat > "$F/stubi/iptables" <<'EOF'
#!/bin/sh
# a stateful iptables: one file per chain, a rule per line; $IPT_LOG gets
# every call, $IPT_FAIL makes appends containing it fail
[ "$1" = -w ] && shift
op=$1; c=$2; shift 2; d=${IPT_DIR:?}
[ -n "${IPT_LOG:-}" ] && printf '%s %s %s\n' "$op" "$c" "$*" >> "$IPT_LOG"
case $op in
    -N) [ -e "$d/$c" ] && exit 1; : > "$d/$c" ;;
    -F) [ -e "$d/$c" ] || exit 1; : > "$d/$c" ;;
    -X) [ -e "$d/$c" ] && [ ! -s "$d/$c" ] || exit 1; grep -qx -- "-j $c" "$d/INPUT" && exit 1; rm -f "${d:?}/${c:?}" ;;
    -A) [ -e "$d/$c" ] || exit 1; case " $* " in *"${IPT_FAIL:-@@}"*) exit 1 ;; esac; printf '%s\n' "$*" >> "$d/$c" ;;
    -I) [ -e "$d/$c" ] || exit 1; shift; { printf '%s\n' "$*"; cat "$d/$c"; } > "$d/$c.t"; mv "$d/$c.t" "$d/$c" ;;
    -C) [ -e "$d/$c" ] && grep -qxF -- "$*" "$d/$c" ;;
    -D) [ -e "$d/$c" ] && grep -qxF -- "$*" "$d/$c" || exit 1; grep -vxF -- "$*" "$d/$c" > "$d/$c.t"; mv "$d/$c.t" "$d/$c" ;;
    -E) [ -e "$d/$c" ] && [ ! -e "$d/$1" ] || exit 1; mv "$d/$c" "$d/$1"; for f in "$d"/*; do sed -i "s/^-j $c\$/-j $1/" "$f"; done ;;
esac
EOF
chmod 755 "$F/stubi/iptables"
ipt_run() { (PATH="$F/stubi:$PATH"; log() { printf '%s\n' "$*"; }; OYG_MOD=$1; shift; "$@") 2>&1; }
ipt_run debugger hook_debugger_apply > "$F/ipt.out"
check "firewall: the debugger chain refuses 9998 except on loopback" eq "$(tr '\n' '|' < "$IPT_DIR/OYG_DBG")/$(cat "$IPT_DIR/INPUT")" "-i lo -j RETURN|-p tcp --dport 9998 -j REJECT --reject-with tcp-reset|/-j OYG_DBG"
check "firewall: nothing is left of the build, and the chain is recorded" eq "$(ls "$IPT_DIR" | tr '\n' ' ')/$(cat "$OYG_STATE/chains.debugger")" "INPUT OYG_DBG /OYG_DBG"
check "firewall: status says closed" eq "$(ipt_run debugger hook_debugger_status d)" "d|OK|web-app debugger closed to the network"
printf '192.168.1.50\n' > "$LAN_ALLOW"; IPT_LOG="$F/ipt.log"; export IPT_LOG; : > "$IPT_LOG"
ipt_run debugger hook_debugger_apply > "$F/ipt.out"; unset IPT_LOG
check "firewall: a computer on the allow list gets through" eval 'grep -qx -- "-s 192.168.1.50 -j RETURN" "$IPT_DIR/OYG_DBG"'
check "firewall: a re-apply moves the jump to the new chain before the old one is flushed" eval '
    i=$(grep -n "^-I INPUT 1 -j OYG_DBG_N" "$F/ipt.log" | cut -d: -f1); r=$(grep -n "^-A OYG_DBG_N -p tcp --dport 9998" "$F/ipt.log" | cut -d: -f1); f=$(grep -n "^-F OYG_DBG \$" "$F/ipt.log" | cut -d: -f1)
    [ -n "$i" ] && [ -n "$r" ] && [ -n "$f" ] && [ "$r" -lt "$i" ] && [ "$i" -lt "$f" ]'
IPT_FAIL="--dport"; export IPT_FAIL; ipt_run debugger hook_debugger_apply > "$F/ipt.out"; unset IPT_FAIL
check "firewall: a refused rule says so" eval 'grep -q "could not close the web-app debugger" "$F/ipt.out"'
check "firewall: and leaves the chain that was there" eq "$(ipt_run debugger hook_debugger_status d)/$(ls "$IPT_DIR" | tr '\n' ' ')" "d|OK|web-app debugger closed to the network/INPUT OYG_DBG "
: > "$IPT_DIR/OYG_DBG"
check "firewall: status needs the rule, not only the jump" eq "$(ipt_run debugger hook_debugger_status d)" "d|WARN|web-app debugger open to the network"
# a run cut short after the jump moved to the build chain and before the
# rename: the next apply takes that chain's jump off first and builds anew
rm -f "$IPT_DIR/OYG_DBG"; printf -- '-i lo -j RETURN\n-p tcp --dport 9998 -j REJECT --reject-with tcp-reset\n' > "$IPT_DIR/OYG_DBG_N"; printf -- '-j OYG_DBG_N\n' > "$IPT_DIR/INPUT"
ipt_run debugger hook_debugger_apply > "$F/ipt.out"
check "firewall: a build chain a cut-short run left in INPUT is replaced" eq "$(ls "$IPT_DIR" | tr '\n' ' ')/$(cat "$IPT_DIR/INPUT")/$(ipt_run debugger hook_debugger_status d)" "INPUT OYG_DBG /-j OYG_DBG/d|OK|web-app debugger closed to the network"
# DIAL: both ports, whoever answers them (a service loaded before the hook)
ipt_run dial hook_dial_apply > "$F/ipt.out"
check "firewall: the DIAL chain refuses both ports, loopback and the allow list excepted" eq "$(tr '\n' '|' < "$IPT_DIR/OYG_DIAL")" "-i lo -j RETURN|-s 192.168.1.50 -j RETURN|-p tcp --dport 36866 -j REJECT --reject-with tcp-reset|-p tcp --dport 18181 -j REJECT --reject-with tcp-reset|"
mkdir -p "$OYG_PROC/net"; printf '00000000000000000000000000000001 01 80 10 80       lo\n' > "$OYG_PROC/net/if_inet6"
check "firewall: DIAL status says closed (loopback is not IPv6 on the network)" eq "$(ipt_run dial hook_dial_status x)" "x|OK|DIAL closed to the network"
printf 'fe80000000000000021122fffe334455 03 40 20 80    wlan0\n' >> "$OYG_PROC/net/if_inet6"
check "firewall: DIAL status warns when the TV has an IPv6 address" eq "$(ipt_run dial hook_dial_status x | tail -1)" "x|WARN|the TV has an IPv6 address, which the firewall cannot cover (the LAN firewall option turns IPv6 off)"
printf '00000000000000000000000000000001 01 80 10 80       lo\nfe80000000000000021122fffe334456 05 40 20 80     p2p0\n' > "$OYG_PROC/net/if_inet6"
check "firewall: a Wi-Fi Direct link's own address is not on the LAN" eq "$(ipt_run dial hook_dial_status x)" "x|OK|DIAL closed to the network"
rm -f "${OYG_PROC:?}/net/if_inet6"
check "firewall: no IPv6 table, no warning" eq "$(ipt_run dial hook_dial_status x)" "x|OK|DIAL closed to the network"
grep -vx -- "-p tcp --dport 18181 -j REJECT --reject-with tcp-reset" "$IPT_DIR/OYG_DIAL" > "$F/ipt.t"; mv "$F/ipt.t" "$IPT_DIR/OYG_DIAL"
check "firewall: DIAL status needs every port" eq "$(ipt_run dial hook_dial_status x)" "x|WARN|DIAL open to the network"
ipt_run lan hook_lan_apply > "$F/ipt.out"
check "firewall: the LAN chain refuses new connections, the allow list excepted" eval 'grep -qx -- "-p tcp --syn -j REJECT --reject-with tcp-reset" "$IPT_DIR/OYG_LAN" && grep -qx -- "-s 192.168.1.50 -j RETURN" "$IPT_DIR/OYG_LAN" && [ "$(ipt_run lan hook_lan_status l | head -1)" = "l|OK|closed to incoming connections" ]'
(PATH="$F/stubi:$PATH"; for _o in lan debugger dial; do OYG_MOD=$_o; restore_chains; done) >/dev/null 2>&1
check "firewall: restore takes the chains and their jumps away" eq "$(ls "$IPT_DIR" | tr '\n' ' ')/$(cat "$IPT_DIR/INPUT")" "INPUT /"
rm -f "${LAN_ALLOW:?}" "${OYG_STATE:?}/chains.debugger" "${OYG_STATE:?}/chains.lan" "${OYG_STATE:?}/chains.dial"; unset IPT_DIR

# Custom: only what differs from the base preset is kept (format=2), and a
# file saved before 1.5.5 (every option written) is rewritten once
_in=$(printf '%s\n' $(pv recommended) | head -1); _out=$(for o in $OYG_OPTIONS; do case " $(pv recommended) " in *" $o "*) ;; *) echo "$o"; break ;; esac; done)
printf '%s=on\n%s=off\n%s=on\n' "$_in" "$_out" voice | custom_write recommended
check "custom: lines that match the base go" eq "$(grep -c "^$_in=\|^$_out=" "$CUSTOM_FILE")/$(sed -n 1,2p "$CUSTOM_FILE" | tr '\n' ' ')" "0/base=recommended format=3 "
printf 'base=recommended\n%s=on\n%s=on\nscreenshots=off\ndebugger=off\nvoice=off\n' "$_in" "$_out" > "$CUSTOM_FILE"
custom_migrate
check "custom: an old file keeps only real changes, without the offs pinned on untested options" eq "$(grep -v '^base=\|^format=' "$CUSTOM_FILE" | sort | tr '\n' ' ')" "$(printf '%s\n' "$_out=on" $( case " $(pv recommended) " in *" voice "*) echo voice=off ;; esac) | sort | tr '\n' ' ')"
cp "$CUSTOM_FILE" "$F/custom.keep"; custom_migrate
check "custom: a migrated file is left as it is" cmp -s "$CUSTOM_FILE" "$F/custom.keep"
# 1.5.7: DIAL left the phone option, so a format 2 file with phone on keeps it
printf 'base=recommended\nformat=2\nphone=on\n' > "$CUSTOM_FILE"; custom_migrate
check "custom: phone on before 1.5.7 keeps DIAL blocked" eq "$(selected_options | grep -x 'phone\|dial' | tr '\n' ' ')/$(sed -n 's/^format=//p' "$CUSTOM_FILE")" "phone dial /3"
printf 'base=recommended\nformat=2\nphone=on\ndial=off\n' > "$CUSTOM_FILE"; custom_migrate
check "custom: a DIAL choice already made stands" eq "$(selected_options | grep -x 'phone\|dial' | tr '\n' ' ')" "phone "
printf 'base=strict\nformat=2\nphone=off\n' > "$CUSTOM_FILE"; custom_migrate
check "custom: phone off before 1.5.7 keeps DIAL open" eq "$(selected_options | grep -x 'phone\|dial' | tr '\n' ' ')/$(grep -c '^dial=off' "$CUSTOM_FILE")" "/1"
printf 'base=strict\nformat=2\nvoice=off\n' > "$CUSTOM_FILE"; custom_migrate
check "custom: a base with DIAL in it needs no line" eq "$(grep -c '^dial=' "$CUSTOM_FILE")/$(selected_options | grep -cx dial)" "0/1"
rm -f "${CUSTOM_FILE:?}" "${F:?}/custom.keep"

# awk on old BusyBox: `o = o (...)` reads as a call to a function o there
check "settings: the JSON is built without a function-call lookalike" eval '! grep -n "o = o (" "$REPO/toolkit/lib/options.sh" "$REPO/toolkit/lib/settings.sh"'
check "settings: two keys make one object" eq "$(printf 'general|a|1\ngeneral|b|"x"\n' | awk -F'|' -v c=general '$1 == c { v = substr($0, length($1) + length($2) + 3); o = o sep "\"" $2 "\":" v; sep = "," } END { print "{" o "}" }')" '{"a":1,"b":"x"}'

check "bundle: one file parses" eval '"$REPO/tools/bundle.sh" > "$TDIR/oyg.sh" && "$BB" sh -n "$TDIR/oyg.sh"'

echo "$pass passed, $nfail failed"
[ $nfail = 0 ]

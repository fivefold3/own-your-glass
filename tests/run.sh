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
check "bind: an applet link to a multi-call binary is refused" eval '! OYG_DRYRUN=1 bind_null "$F/fs/usr/sbin/telnetd" >/dev/null'
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
# phone: a restart is asked for only when OYG turned the setting off in this boot
OYG_MOD=phone; rm -f "$OYG_RESTART" "$OYG_STATE/kv.phone"
OPT_SETTINGS_CHANGED=" allowMobileDeviceAccess"; hook_phone_apply
hook_phone_restore >/dev/null
check "phone: undo in the same boot asks for a restart" eq "$(restart_reasons)" "$PHONE_BACK"
rm -f "$OYG_RESTART"; kv_set off_boot "1790411163"; hook_phone_restore >/dev/null
check "phone: after a restart the server comes back by itself" eq "$(restart_reasons)" ""
OPT_SETTINGS_CHANGED=""; kv_set off_boot "1790419000"; need_restart "$PHONE_BACK" >/dev/null; hook_phone_apply
check "phone: turning it on again drops the pending restart" eq "$(restart_reasons)" ""
check "phone: a boot apply that changes nothing keeps the old boot" eq "$(kv_get off_boot)" "1790419000"
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
_n=0; while [ $_n -lt 20 ]; do _gp=$(pgrp_pids "$_g"); [ "$(echo $_gp | wc -w)" -ge 2 ] && break; sleep 0.1; _n=$((_n+1)); done
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
check "migration: units and launch names by owner" eq "$(cat "$M/state/units.cast" 2>/dev/null)/$(cat "$M/state/ls2.phone" 2>/dev/null)" "chromecast-provisioning.service/com.webos.service.dial"
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

check "bundle: one file parses" eval '"$REPO/tools/bundle.sh" > "$TDIR/oyg.sh" && "$BB" sh -n "$TDIR/oyg.sh"'

echo "$pass passed, $nfail failed"
[ $nfail = 0 ]

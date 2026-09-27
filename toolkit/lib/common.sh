# common.sh — shared helpers for the own-your-glass toolkit.
# POSIX sh only: this runs on the BusyBox shell that ships on webOS.
#
# Every change the toolkit makes goes through a helper below, and every helper
# records what it did under $OYG_STATE, scoped to the module making the change
# ($OYG_MOD). `oyg restore` (and the boot hook, once the app has been
# uninstalled) replays those records to put the TV back. No module needs its
# own undo bookkeeping.

OYG_VERSION="1.5.0"

OYG_APPID=${OYG_APPID:-org.ownyourglass.app}
OYG_APPDIR=${OYG_APPDIR:-/media/developer/apps/usr/palm/applications/$OYG_APPID}
OYG_ROOT=${OYG_ROOT:-/var/lib/own-your-glass}
OYG_STATE="$OYG_ROOT/state"
OYG_BACKUP="$OYG_ROOT/backup"
OYG_LOG="$OYG_ROOT/oyg.log"
OYG_HOOK=${OYG_HOOK:-/var/lib/webosbrew/init.d/own-your-glass}
OYG_DRYRUN=${OYG_DRYRUN:-0}
OYG_MOD=${OYG_MOD:-core}
OYG_PROC=${OYG_PROC:-/proc}   # tests point this at a fixture tree

# ---------------------------------------------------------------- logging --
_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }
log()  { printf '%s\n' "$*"; [ "$OYG_DRYRUN" != 1 ] && [ -d "$OYG_ROOT" ] && printf '%s %s\n' "$(_ts)" "$*" >> "$OYG_LOG" 2>/dev/null; return 0; }
# /var is flash: keep every log we write under ~200 KB (called once per run)
rotate_logs() {
    for _f in "$OYG_LOG" "$OYG_ROOT/boot.log" "$OYG_ROOT/nag-watch.log"; do
        [ -f "$_f" ] && [ "$(wc -c < "$_f")" -gt 200000 ] && { tail -c 100000 "$_f" > "$_f.t" && mv "$_f.t" "$_f"; }
    done; return 0
}
info() { log "  $*"; }
ok()   { log "  ok    $*"; }
warn() { log "  warn  $*"; }
fail() { log "  FAIL  $*"; }
head_() { log "== $*"; }
die()  { log "fatal: $*"; exit 1; }

# status lines are machine-readable:  MODULE|LEVEL|text   (LEVEL: OK WARN FAIL NA OFF)
st() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }

# --------------------------------------------------------------- dry-run --
# run "description" cmd args...   — executes unless dry-run; logs failures.
run() {
    _d=$1; shift
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) $_d"; return 0; fi
    "$@" >/dev/null 2>&1; _rc=$?
    [ $_rc = 0 ] && return 0
    warn "$_d failed (rc=$_rc)"; return $_rc
}

# ------------------------------------------------------------ state lists --
# A state list is a flat file of unique lines: $OYG_STATE/<list>.<module>
# root-only: the records say what the TV had set, the backups are LG's files
oyg_init_dirs() { [ "$OYG_DRYRUN" = 1 ] || { mkdir -p "$OYG_STATE" "$OYG_BACKUP" 2>/dev/null; chmod 700 "$OYG_ROOT" 2>/dev/null; }; }
_sf() { printf '%s/%s.%s' "$OYG_STATE" "$1" "$OYG_MOD"; }
state_add()  { [ "$OYG_DRYRUN" = 1 ] && return 0; grep -qxF -- "$2" "$(_sf "$1")" 2>/dev/null || printf '%s\n' "$2" >> "$(_sf "$1")"; }
# (the helpers' own variables are prefixed so a caller's loop variables survive)
state_del()  { [ "$OYG_DRYRUN" = 1 ] && return 0; _sd_f=$(_sf "$1"); [ -f "$_sd_f" ] || return 0; grep -vxF -- "$2" "$_sd_f" > "$_sd_f.tmp" 2>/dev/null; mv "$_sd_f.tmp" "$_sd_f"; }
state_has()  { grep -qxF -- "$2" "$(_sf "$1")" 2>/dev/null; }
state_list() { cat "$(_sf "$1")" 2>/dev/null; }
state_drop() { [ "$OYG_DRYRUN" = 1 ] || rm -f "$(_sf "$1")"; }
# key/value flags per module: $OYG_STATE/kv.<module>
kv_set() { [ "$OYG_DRYRUN" = 1 ] && return 0; _kv_f=$(_sf kv); { grep -v "^$1=" "$_kv_f" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$_kv_f.tmp"; mv "$_kv_f.tmp" "$_kv_f"; }
kv_get() { sed -n "s/^$1=//p" "$(_sf kv)" 2>/dev/null | head -1; }
kv_drop() { [ "$OYG_DRYRUN" = 1 ] || rm -f "$(_sf kv)"; }

# --------------------------------------------------------------- mounts --
# Binaries, device nodes and unit files are neutralised by bind-mounting
# /dev/null over them: exec() of a bound binary fails, the first ALSA ioctl
# on a bound device node fails, and systemd treats a unit file that IS the
# /dev/null character device as masked. The read-only vendor filesystem is
# never modified; umount (or a reboot) undoes every bind.
#
# /proc/mounts lists the mountpoint in field 2. A /dev/null bind shows up as
# "devtmpfs" with root "/null", never as the literal "/dev/null", so we match
# on the mountpoint, never on the source.
# Our binds propagate into every app jail, so /proc/mounts grows to tens of
# thousands of lines once applied and reading it per check took 0.75 s.
# Read it once per run into a scratch dir and keep the snapshot current.
# /tmp is shared into every app jail, so the scratch dir has a name nothing
# can guess and mode 700 (mktemp -d), never a fixed name: a jailed process
# could have planted a link where root writes (the snapshot holds every
# process's command line).
# (made here, in the main shell: oyg_tmp runs inside $(...) subshells, whose
# variables never reach the caller)
_oyg_tmpd() { OYG_TMPD=$(mktemp -d /tmp/.own-your-glass.XXXXXX) || die "cannot make a scratch directory"; OYG_MSNAP="$OYG_TMPD/mounts"; OYG_PSF="$OYG_TMPD/ps"; }
{ [ -n "${OYG_TMPD:-}" ] && [ -d "$OYG_TMPD" ]; } || _oyg_tmpd   # (sourced again in one shell: keep the dir)
oyg_tmp() { [ -d "$OYG_TMPD" ] || mkdir -m 700 "$OYG_TMPD"; printf '%s/%s' "$OYG_TMPD" "$1"; }
oyg_cleanup() { [ -n "$OYG_TMPD" ] && rm -rf "$OYG_TMPD"; }
trap oyg_cleanup EXIT
# A detached job ( ... ) & outlives the run that started it, whose EXIT trap
# removes the scratch dir: give the job its own, or every is_mounted in it
# would read a missing snapshot and answer "not mounted".
oyg_detach_env() { _oyg_tmpd; trap oyg_cleanup EXIT; }
# The files the app and the toolkit share in /tmp (the job log, the TV
# report) live in one root-only directory, made here and by app.js alike;
# a link planted at its name is removed first.
OYG_APP_DIR=/tmp/.own-your-glass-app
oyg_app_dir() {
    [ -L "$OYG_APP_DIR" ] && rm -f "$OYG_APP_DIR"
    [ -d "$OYG_APP_DIR" ] || mkdir -m 700 "$OYG_APP_DIR" 2>/dev/null
    [ -d "$OYG_APP_DIR" ] && [ "$(stat -c %u "$OYG_APP_DIR" 2>/dev/null)" = "$(id -u)" ] && chmod 700 "$OYG_APP_DIR"
}
# stdin minus the lines of a file. BusyBox grep -f with an EMPTY pattern
# file matches every line (GNU grep matches none), so the file is checked first.
minus_file() { if [ -s "$1" ]; then grep -vxF -f "$1"; else cat; fi; }
# The top layer of a stacked mountpoint is its last line; .o keeps
# "mountpoint options" so a status can tell a read-only bind from a rw one.
mounts_snapshot() { oyg_tmp mounts >/dev/null; awk -v o="$OYG_MSNAP.o" '{print $2; print $2, $4 > o}' "$OYG_PROC/mounts" 2>/dev/null > "$OYG_MSNAP"; }
_msnap() { [ -s "$OYG_MSNAP" ] || mounts_snapshot; }
is_mounted() { _msnap; grep -qxF -- "$1" "$OYG_MSNAP"; }
is_rw() { _msnap; awk -v m="$1" '$1==m{o=$2} END{exit !(o ~ /^rw(,|$)/)}' "$OYG_MSNAP.o"; }
_msnap_add() { _msnap; printf '%s\n' "$1" >> "$OYG_MSNAP"; printf '%s %s\n' "$1" "${2:-rw}" >> "$OYG_MSNAP.o"; }
_msnap_del() { _msnap; grep -vxF -- "$1" "$OYG_MSNAP" > "$OYG_MSNAP.t" 2>/dev/null; mv "$OYG_MSNAP.t" "$OYG_MSNAP"; }

# Paths that must never be neutralised, whatever a spec or a unit's
# ExecStart says: interpreters, launchers and multi-call binaries shared by
# everything, the settings-delivery gateway (binding sdx silently kills the
# Settings UI), the TV data exchanger, the Integrated Control Service
# (Universal Control / IR blaster), the OLED pixel-care and capture services
# and the HID node every remote button rides on.
bind_denied() {
    case $1 in
        /bin/sh|/bin/bash|/bin/busybox|/usr/bin/busybox|/bin/busybox.*|/usr/bin/luna-send|/usr/bin/iotjs|/usr/bin/node|/usr/bin/run-iot-js-service|/usr/bin/run-js-service|/usr/bin/run-service|/usr/bin/jailer|/usr/bin/python3*|/usr/bin/socat|/usr/bin/jsservicelauncher|/usr/bin/flutter-client|/usr/sbin/ls-hubd|/usr/sbin/sdx|/usr/sbin/tvdataexchanger|/usr/sbin/pacrunner|/usr/sbin/crashd|/usr/sbin/eplmanager|/usr/sbin/captureservice|/dev/hidraw*|/usr/bin/systemctl|/bin/systemctl|/lib/systemd/systemd|/usr/lib/systemd/systemd|/usr/palm/services/jsservicelauncher*) return 0 ;;
    esac
    # soft never (kb/services.toml soft_paths): features the owner loses, not
    # a broken TV; allowed only while an option no preset but Lockdown
    # carries is applied (the option engine sets OYG_SOFT_OK)
    case $1 in
        /usr/sbin/iconnectivity) [ "${OYG_SOFT_OK:-0}" = 1 ] || return 0 ;;
    esac
    return 1
}
# The path a bind actually lands on: mount follows symlinks, so a bind on
# /usr/sbin/telnetd (a BusyBox applet link) would cover /bin/busybox itself.
canon() { readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"; }
bind_null() {  # bind_null <path>
    [ -e "$1" ] || return 1
    _t=$(canon "$1")
    if bind_denied "$1" || bind_denied "$_t"; then warn "refusing to neutralise $1"; return 1; fi
    # a link to a differently named file is an alias of a multi-call or
    # shared binary; usr-merge links (/sbin/x -> /usr/sbin/x) keep the name
    [ "${_t##*/}" = "${1##*/}" ] || { warn "refusing to neutralise $1: it is a link to $_t"; return 1; }
    is_mounted "$_t" && { state_add mounts "$_t"; return 0; }
    # the only device nodes we ever cover are ALSA capture nodes
    case $_t in /dev/snd/pcm*|/var/palm/jail/*/dev/snd/pcm*) ;; *) [ -c "$_t" ] && { warn "refusing to neutralise device $1"; return 1; } ;; esac
    run "bind /dev/null over $_t" mount --bind /dev/null "$_t" || return 1
    _msnap_add "$_t"; state_add mounts "$_t"
}
bind_file() {  # bind_file <src> <target>   (overlay a generated file on a read-only one)
    [ -e "$2" ] || return 1
    if is_mounted "$2" && state_has mounts "$2"; then
        run "umount $2 (re-bind)" umount "$2" || run "umount -l $2" umount -l "$2"
        _msnap_del "$2"
    fi
    run "bind $1 over $2" mount --bind "$1" "$2" || return 1
    _msnap_add "$2"; state_add mounts "$2"
}
# A bind propagates to every peer of the target's mount: the sdx table shows
# up under /mnt/lg/{cmn_data,cache,flash/data,user} (and inside jails), and
# remounting only the path we bound left three rw doors into our file. The
# peers are the mounts whose root (mountinfo field 4) is our source file. One
# mountinfo read, at apply time only.
bind_peers() {  # bind_peers <src>
    awk -v t="/own-your-glass/${1##*/}" '{r=$4; if (length(r) >= length(t) && substr(r, length(r)-length(t)+1) == t) print $5}' "$OYG_PROC/self/mountinfo" 2>/dev/null | sort -u
}
bind_file_ro() {  # bind_file_ro <src> <target>
    is_mounted "$2" && state_has mounts "$2" && unbind "$2"
    unbind_src "$1"
    bind_file "$1" "$2" || return 1
    [ "$OYG_DRYRUN" = 1 ] && return 0
    _pn=0; _pf=0; _pl=""
    for _m in $(bind_peers "$1"); do
        if mount -o remount,bind,ro "$_m" >/dev/null 2>&1; then _pn=$((_pn+1)); else _pf=$((_pf+1)); fi
        case $_m in /var/palm/jail/*) ;; *) _pl="$_pl $_m" ;; esac
    done
    kv_set "peers.${1##*/}" "${_pl# }"
    [ $_pf = 0 ] || warn "$_pf of $((_pn+_pf)) mounts of $2 could not be made read-only"
    mounts_snapshot
    [ $_pf = 0 ]
}
unbind_src() {  # unbind_src <src>: whatever peers of our file are still mounted
    [ "$OYG_DRYRUN" = 1 ] && return 0
    for _m in $(bind_peers "$1"); do umount "$_m" >/dev/null 2>&1 || umount -l "$_m" >/dev/null 2>&1; done
    mounts_snapshot
}
# peers of our file that are still writable (status: no mountinfo read)
rw_peers() { for _m in $(kv_get "peers.${1##*/}"); do is_mounted "$_m" && is_rw "$_m" && printf '%s\n' "$_m"; done; }
# our bind of <src> was made read-only by us (peers recorded) and still is;
# a bind left by an older version has no record and is re-done
ro_ok() { [ -n "$(kv_get "peers.${1##*/}")" ] && [ -z "$(rw_peers "$1")" ]; }
unbind() {  # unbind <target>
    if is_mounted "$1"; then
        run "umount $1" umount "$1" || run "umount -l $1" umount -l "$1" || return 1
        _msnap_del "$1"
    fi
    state_del mounts "$1"
}
restore_mounts() {  # undo every bind this module made (last first); a failed unbind keeps its record
    state_list mounts | sed '1!G;h;$!d' | while read -r _p; do [ -n "$_p" ] && unbind "$_p"; done
    [ -s "$(_sf mounts)" ] || state_drop mounts
}

# ---------------------------------------------------------------- modes --
mode_of() { stat -c %a "$1" 2>/dev/null; }
_oct() { printf '%d' "$((0$1))"; }   # stat prints 0 / 600 / 2755: compare as numbers
is_devnull() { [ "$(stat -L -c '%t:%T' "$1" 2>/dev/null)" = 1:3 ] && [ -c "$1" ]; }
set_mode() {  # set_mode <path> <mode>  (original mode recorded once)
    [ -e "$1" ] || return 1
    # never through a bind: a chmod of a bound node lands on /dev/null
    is_mounted "$1" && return 0
    is_devnull "$1" && { warn "refusing to chmod $1: it is /dev/null"; return 1; }
    _cur=$(mode_of "$1"); [ -n "$_cur" ] || return 1
    [ "$(_oct "$_cur")" = "$(_oct "$2")" ] && return 0
    grep -q "^$1 " "$(_sf modes)" 2>/dev/null || state_add modes "$1 $_cur"
    run "chmod $2 $1" chmod "$2" "$1"
}
restore_modes() {  # a path that is still bound keeps its record for the next restore
    _mf=$(_sf modes); [ -f "$_mf" ] || return 0
    state_list modes | while read -r _p _m; do
        [ -n "$_p" ] || continue
        if is_mounted "$_p" || is_devnull "$_p"; then continue; fi
        [ -e "$_p" ] && run "chmod $_m $_p" chmod "$_m" "$_p"
        state_del modes "$_p $_m"
    done
    [ -s "$_mf" ] || state_drop modes
}

# -------------------------------------------------------------- backups --
# backup_once <path>: copy a file to the backup dir the FIRST time only, so
# a later apply can never overwrite the pristine original.
_bk_name() { printf '%s' "$1" | sed 's#^/##; s#/#__#g'; }
backup_path() { printf '%s/%s' "$OYG_BACKUP" "$(_bk_name "$1")"; }
backup_once() {
    [ -f "$1" ] || return 1
    _b=$(backup_path "$1")
    [ -f "$_b" ] && { state_add files "$1"; return 0; }
    [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) backup $1"; return 0; }
    cp -p "$1" "$_b" && state_add files "$1"
}
restore_files() {  # put every backed-up file of this module back
    state_list files | while read -r _p; do
        [ -n "$_p" ] || continue
        _b=$(backup_path "$_p")
        [ -f "$_b" ] || continue
        run "restore $_p" cp -p "$_b" "$_p" && rm -f "$_b"
    done
    state_drop files
}
mark_created() { state_add created "$1"; }    # we created it: restore deletes it
restore_chains() {  # iptables chains we made (jumped to from INPUT)
    state_list chains | while read -r _c; do
        [ -n "$_c" ] || continue
        [ "$OYG_DRYRUN" = 1 ] && { info "(dry-run) remove firewall chain $_c"; continue; }
        while iptables -D INPUT -j "$_c" 2>/dev/null; do :; done
        iptables -F "$_c" 2>/dev/null; iptables -X "$_c" 2>/dev/null && info "firewall chain $_c removed"
    done
    state_drop chains
}
restore_immutable() {  # chattr +i files we made: clear the flag so they can go
    state_list immutable | while read -r _p; do [ -n "$_p" ] && run "chattr -i $_p" chattr -i "$_p"; done
    state_drop immutable
}
restore_created() {
    state_list created | while read -r _p; do [ -n "$_p" ] && run "rm $_p" rm -f "$_p"; done
    state_drop created
}
mark_moved() { state_add moved "$1|$2"; }     # we moved $1 -> $2: restore moves it back
restore_moved() {
    state_list moved | while IFS='|' read -r _a _b; do
        [ -n "$_a" ] && [ -e "$_b" ] && run "mv $_b $_a" mv "$_b" "$_a"
    done
    state_drop moved
}
write_atomic() {  # write_atomic <path>   (content on stdin; temp + mv)
    if [ "$OYG_DRYRUN" = 1 ]; then cat >/dev/null; info "(dry-run) write $1"; return 0; fi
    mkdir -p "$(dirname "$1")" && cat > "$1.oyg.tmp" && mv "$1.oyg.tmp" "$1"
}

# ------------------------------------------------------------ processes --
# One process snapshot per run, in a file so it survives $(...) subshells.
# Columns (tab-separated): pid, comm (15 chars), exe, args.
#
# procps' ps (on every LG image, webOS 5.6 to 11.2) selects only the
# caller's euid when there is no tty: without -e the jailed and non-root
# daemons (performer, lg.thinqai.adapter, the Chromecast receiver) were
# invisible, never killed, and reported "blocked". BusyBox ps lists
# everything and may reject -e, hence the fallback. exe comes from the
# /proc/<pid>/exe links read by ONE ls: the kernel resolves usr-merge links
# and shows a jailed copy by its host path (/var/palm/jail/<id>/usr/sbin/x).
# A cat per process took minutes on the TV.
ps_snapshot() {
    oyg_tmp ps >/dev/null; _T=$(printf '\t')
    { ls -l /proc/[0-9]*/exe 2>/dev/null | sed -n "s#^.* /proc/\([0-9][0-9]*\)/exe -> \(.*\)\$#E$_T\1$_T\2#p"
      { ps -eo pid,comm,args 2>/dev/null | sed 1d | grep . || ps -o pid,comm,args 2>/dev/null | sed 1d; } | sed "s/^/P$_T/"
    } | awk -F'\t' -v OFS='\t' '
        $1 == "E" { e = $3; sub(/ \(deleted\)$/, "", e); exe[$2] = e; next }
        { l = substr($0, 3); sub(/^ +/, "", l); p = l; sub(/ .*/, "", p)
          r = substr(l, length(p) + 1); sub(/^ +/, "", r); c = r; sub(/ .*/, "", c)
          a = substr(r, length(c) + 1); sub(/^ +/, "", a); print p, c, exe[p], a }' > "$OYG_PSF"
}
_ps() { [ -s "$OYG_PSF" ] || ps_snapshot; cat "$OYG_PSF"; }
pids_of() { _ps | awk -F'\t' -v n="$(printf '%s' "$1" | cut -c1-15)" '$2 == n { printf "%s ", $1 }'; }
# by executable: exact, or a jailed copy of it, or (exe unreadable) argv[0]
pids_of_exe() {
    _ps | awk -F'\t' -v e="$1" '{ x = $3; j = x; sub(/^\/var\/palm\/jail\/[^\/]+/, "", j)
        if (x == "") { x = $4; sub(/ .*/, "", x) }
        if (x == e || j == e) printf "%s ", $1 }'
}
pids_of_arg() { _ps | awk -F'\t' -v a="$1" -v self="$$" 'index($4, a) && $1 != self { printf "%s ", $1 }'; }
# by command line, but only processes orphaned to init: what an earlier
# version's watcher left behind, never a shell someone has open on the file
orphans_of_arg() {
    for _o in $(pids_of_arg "$1"); do
        [ "$(sed -n 's/^[0-9]* (.*) [A-Za-z] \([0-9]*\) .*/\1/p' "/proc/$_o/stat" 2>/dev/null)" = 1 ] && printf '%s ' "$_o"
    done
}
kill_pids() {  # kill_pids "<what>" pid...
    _w=$1; shift
    _p=$(printf '%s\n' "$@" | tr ' ' '\n' | grep -v '^$' | grep -vx "$$" | sort -u | tr '\n' ' ')
    [ -n "$(printf '%s' "$_p" | tr -d ' ')" ] || return 0
    # one kill per pid: BusyBox kill returns non-zero if any pid is already gone
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) TERM $_w ($_p)"; return 0; fi
    info "TERM $_w ($_p)"; for _i in $_p; do kill -TERM "$_i" 2>/dev/null; done
    # give them up to a second to exit, checking every 0.1 s
    _t=0; while [ $_t -lt 10 ]; do
        _left=""; for _i in $_p; do [ -d "/proc/$_i" ] && _left="$_left $_i"; done
        [ -z "$_left" ] && break
        sleep 0.1; _t=$((_t+1))
    done
    if [ -n "$_left" ]; then info "KILL $_w ($_left)"; for _i in $_left; do kill -KILL "$_i" 2>/dev/null; done; fi
    ps_snapshot
    return 0
}
kill_procs() {  # kill_procs <comm> [<exe-path>]
    kill_pids "$1" $(pids_of "$1") $( [ -n "${2:-}" ] && pids_of_exe "$2")
}
running() { [ -n "$(pids_of "$1" | tr -d ' ')" ]; }
running_exe() { [ -n "$(pids_of_exe "$1" | tr -d ' ')" ]; }

# -------------------------------------------------------------- systemd --
# `systemctl` is slow on this platform and status is polled from a UI, so
# status paths must never call it; apply/restore may. Unit lookups read the
# unit files directly.
OYG_UNIT_DIRS="/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system /run/systemd/system"
unit_path() { for _d in $OYG_UNIT_DIRS; do [ -f "$_d/$1" ] && { printf '%s\n' "$_d/$1"; return 0; }; done; return 1; }
unit_exec() {  # first ExecStart binary of a unit (prefixes -@+! stripped)
    _u=$(unit_path "$1") || return 1
    sed -n 's/^ExecStart=[-@+!:]*\([^ ]*\).*/\1/p' "$_u" | head -1
}
# the processes of one process group: a watcher started with setsid leads
# its own group, so this finds its subshells and luna-send children and
# nothing else (other programs subscribe to the same luna calls: the owner's
# lginputmapper follows the power state too)
pgrp_pids() {  # pgrp_pids <pgid>
    [ -n "${1:-}" ] || return 0
    for _ps in /proc/[0-9]*/stat; do sed -n 's/^\([0-9]*\) (.*) [A-Za-z] [0-9]* \([0-9]*\) .*/\1 \2/p' "$_ps" 2>/dev/null; done |
        awk -v g="$1" '$2 == g { printf "%s ", $1 }'
}
unit_active() { [ "$(systemctl is-active "$1" 2>/dev/null)" = active ]; }
have_unit()   { unit_path "$1" >/dev/null; }

OYG_NEED_RELOAD=0
stop_unit() {  # remembers units that were active so restore can start them
    unit_active "$1" || return 0   # already stopped (a re-apply): nothing to do
    state_add units "$1"
    # --no-block: a unit that ignores SIGTERM would otherwise hold us for its
    # stop timeout (90 s). We kill the process ourselves right after.
    run "systemctl stop $1" systemctl --no-block stop "$1"
}
# Masking: the unit file lives on a read-only filesystem, so `systemctl mask`
# fails. Binding /dev/null over the unit file and reloading makes systemd
# see it as masked. Opt-in (OYG_MASK_UNITS=1), not verified on hardware: the
# binary bind already stops every respawn path.
mask_unit() {
    [ "${OYG_MASK_UNITS:-0}" = 1 ] || return 0
    _u=$(unit_path "$1"); [ -n "$_u" ] || return 1
    bind_null "$_u" && OYG_NEED_RELOAD=1
}
daemon_reload_if_needed() {
    [ "$OYG_NEED_RELOAD" = 1 ] || return 0
    run "systemctl daemon-reload" systemctl daemon-reload; OYG_NEED_RELOAD=0
}
restore_units() {  # start again whatever was active before we stopped it
    state_list units | while read -r _u; do [ -n "$_u" ] && run "systemctl start $_u" systemctl start "$_u"; done
    state_drop units
}

# -------------------------------------------------------------- restart --
# Some changes take full effect only after the TV restarts (LG's phone
# server, for one, starts only with its service). What is waiting is listed
# in $OYG_ROOT/restart under the time this boot started, so the list empties
# itself once the TV has restarted. oyg status reports it; the app offers a
# restart.
#
# Not the kernel's boot_id: LG TVs resume a saved boot image (snapshot
# boot), and boot_id is the same after every restart (C5). The boot time
# (/proc/stat btime) is new each boot; it moves only with a clock change, so
# two stamps within two minutes are the same boot.
OYG_RESTART="$OYG_ROOT/restart"
boot_stamp() { sed -n 's/^btime //p' "$OYG_PROC/stat" 2>/dev/null; }
same_boot() {  # same_boot <stamp>
    case ${1:-x} in *[!0-9]*) return 1 ;; esac
    _sb=$(boot_stamp); [ -n "$_sb" ] || return 1
    _sb=$((_sb - $1)); [ "${_sb#-}" -le 120 ]
}
restart_reasons() { [ -f "$OYG_RESTART" ] && same_boot "$(head -1 "$OYG_RESTART")" && sed 1d "$OYG_RESTART"; return 0; }
_restart_write() {  # _restart_write <reason to drop> [reason to add]
    [ "$OYG_DRYRUN" = 1 ] && return 0
    _rw=$(restart_reasons | grep -vxF -- "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2")
    if [ -z "$_rw" ]; then rm -f "$OYG_RESTART"; return 0; fi
    { boot_stamp; printf '%s\n' "$_rw"; } > "$OYG_RESTART.t" && mv "$OYG_RESTART.t" "$OYG_RESTART"
}
need_restart() { warn "restart the TV: $1 after the restart"; _restart_write "$1" "$1"; }   # need_restart <what comes back>
restart_drop() { _restart_write "$1"; }

# ------------------------------------------------------------------ luna --
# luna-send reads the bus reply from a pipe that is also fed by stdin; if
# stdin closes first it exits 0 with NO output. Always close stdin.
luna() { luna-send -n 1 -f "$1" "$2" </dev/null 2>&1; }
luna_ok() { luna "$1" "$2" | grep -q '"returnValue"[[:space:]]*:[[:space:]]*true'; }
# toasts are off unless the owner turned them on (oyg toasts on); OYG_TOAST=1
# keeps them on past the removal of $OYG_ROOT (the uninstall's last word)
OYG_TOASTS_FILE="$OYG_ROOT/toasts"
toasts_on() { [ "${OYG_TOAST:-}" = 1 ] || [ -f "$OYG_TOASTS_FILE" ]; }
toast() { toasts_on || return 0; toast_always "$1"; }
# for what the owner must hear even with notifications off (a root shell
# given back on undo)
toast_always() {
    [ "$OYG_DRYRUN" = 1 ] && return 0
    luna_ok luna://com.webos.notification/createToast \
        "{\"message\":\"$(printf '%s' "$1" | sed 's/"/\\"/g')\",\"sourceId\":\"com.webos.surfacemanager\"}" \
        || warn "toast not shown: $1"
}
# At boot the notification service ignores toasts until the UI is up. Wait
# (up to ~3 min) for the boot manager to report a finished boot with the
# first app launched, then toast.
boot_done() {
    luna luna://com.webos.bootManager/getBootStatus '{}' | tr -d ' \n' | grep -q '"boot-done":true.*"firstAppLaunched":true\|"firstAppLaunched":true.*"boot-done":true'
}
wait_boot_done() { _i=0; while [ $_i -lt 36 ] && ! boot_done; do sleep 5; _i=$((_i+1)); done; }
toast_after_boot() {
    wait_boot_done
    sleep 3
    toast "$1"
}

# ----------------------------------------------------------------- misc --
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1; }
# the {...} value of the first "<key>" in the JSON on stdin, found by brace
# depth, so a pretty-printed reply and a one-line one read the same (the
# fallback where there is no python3: webOS 5 and 6)
json_obj_of() {  # json_obj_of <key>
    tr -d '\r\n' | awk -v k="\"$1\"" '{
        i = index($0, k); if (!i) exit
        s = substr($0, i + length(k)); j = index(s, "{"); if (!j) exit
        if (substr(s, 1, j - 1) !~ /^[[:space:]]*:[[:space:]]*$/) exit
        d = 0
        for (m = j; m <= length(s); m++) { c = substr(s, m, 1)
            if (c == "{") d++; else if (c == "}") { d--; if (d == 0) { print substr(s, j, m - j + 1); exit } } } }'
}
model_name()    { _m=$(json_str /var/run/nyx/device_info.json modelName); [ -z "$_m" ] && _m=$(json_str /var/run/nyx/device_info.json product_id | cut -d. -f1); printf '%s' "$_m"; }
webos_version() { sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"'; }
webos_generation() { webos_version | cut -d. -f1-2; }   # 10.3, 11.2: what decides the service set
app_installed() { [ -d "$OYG_APPDIR" ]; }

# ------------------------------------------------------------ forgetting --
# Two webOS files outlive the app. WAM's AppsOrigins lists the origins each
# web app reached, so LG Channels gains https://<prefix>.oyg.invalid/ while
# the sdx table is rewritten; the app installer's history deletes the app's
# row on removal, but SQLite leaves a deleted row's bytes in the page. So the
# placeholder origins are deleted, and a file that still holds the app's id
# or the placeholder anywhere is rebuilt (VACUUM), which drops free space.
OYG_SINK=oyg.invalid
OYG_APP_LOG="$OYG_APP_DIR/job.log"   # app.js LOG
WAM_ORIGINS=${WAM_ORIGINS:-/var/lib/wam/Default/AppsOrigins}
INSTALL_HISTORY=${INSTALL_HISTORY:-/var/palm/data/com.webos.appInstallService/installHistory2.db}
_sq() { sqlite3 -cmd '.timeout 5000' "$1" "$2" 2>/dev/null; }   # WAM and the installer keep theirs open
forget_origins() {
    [ -f "$WAM_ORIGINS" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
    _w="url LIKE '%://$OYG_SINK/%' OR url LIKE '%.$OYG_SINK/%'"
    _n=$(_sq "$WAM_ORIGINS" "SELECT count(*) FROM origins WHERE $_w")
    [ "${_n:-0}" -gt 0 ] || return 0
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) forget $_n placeholder origins in the web-app profile"; return 0; fi
    if _sq "$WAM_ORIGINS" "DELETE FROM access WHERE id_origin IN (SELECT id FROM origins WHERE $_w); DELETE FROM origins WHERE $_w;"
    then ok "forgot $_n placeholder origins in the web-app profile"; else warn "could not forget the placeholder origins (profile busy)"; fi
}
forget_files() {  # forget_files <sqlite file>...
    command -v sqlite3 >/dev/null 2>&1 || return 0
    for _db in "$@"; do
        [ -f "$_db" ] && grep -q -F -e "$OYG_APPID" -e "$OYG_SINK" "$_db" 2>/dev/null || continue
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) rebuild $_db"; continue; fi
        if _sq "$_db" VACUUM; then ok "rebuilt $_db"; else warn "could not rebuild $_db (busy)"; fi
    done
}
# Rewrite a file in place from a command's output (the old content on its
# stdin), keeping the file's inode and time. cp -p and touch -r do the time:
# every surveyed BusyBox has them, and the 1.29 on webOS 5.6 has no date -r.
edit_keep_mtime() {  # edit_keep_mtime <file> <cmd>...
    _ek=$1; shift; _ekk="$_ek.oyg"
    cp -p "$_ek" "$_ekk" || return 1
    if "$@" < "$_ekk" > "$_ek"; then touch -r "$_ekk" "$_ek"; rm -f "$_ekk"; return 0; fi
    cat "$_ekk" > "$_ek"; touch -r "$_ekk" "$_ek"; rm -f "$_ekk"; return 1
}
# LG's service-logger keeps a first-use list, /var/firstUseAppInfo.json. Its
# rule (etc/palm/service-logger/rules/getFirstUseAppInfo.py) runs on every
# foreground-app change: it reads the file, appends the app if it is new and
# logs NL_FIRSTUSE. It holds nothing in memory, so editing the file is
# enough, and it writes one line with ", " between ids. The app is taken off
# the list; the list itself goes if it held only the app (it did not exist
# before). Each edit keeps the file's time.
FIRST_USE=${FIRST_USE:-/var/firstUseAppInfo.json}
first_use_ids() { [ -f "$FIRST_USE" ] && tr ',' '\n' < "$FIRST_USE" | grep -o '"[^"]*"' | tr -d '"' | grep -vx first_use_apps; return 0; }
first_use_drop() {  # first_use_drop <app id> <what it is called in the log>
    [ -f "$FIRST_USE" ] && grep -q -F "\"$1\"" "$FIRST_USE" || return 0
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) take $2 off LG's first-use list"; return 0; fi
    _a=$(printf '%s' "$1" | sed 's/\./\\./g')
    _new=$(sed -e "s/, *\"$_a\"//" -e "s/\"$_a\", *//" -e "s/\"$_a\"//" "$FIRST_USE")
    # LG writes it as one line; a layout the edit cannot follow is left alone
    if command -v python3 >/dev/null 2>&1 && ! printf '%s' "$_new" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        warn "LG's first-use list is not laid out as expected: left alone"; return 1
    fi
    if printf '%s' "$_new" | tr -d ' \r\n' | grep -q '"first_use_apps":\[\]'; then rm -f "$FIRST_USE"; ok "removed LG's first-use list (it held only $2)"; return 0; fi
    edit_keep_mtime "$FIRST_USE" printf '%s' "$_new" && ok "took $2 off LG's first-use list"
}
forget_first_use() { first_use_drop "$OYG_APPID" "the app"; }
# The uninstall's restore starts service-logger again, and on the C5 that
# added the app then in front (Home, which the rule's own filter is meant to
# skip) to the list. The ids are noted before the restore; afterwards, once
# the list has changed (or after 10 s), any new id is taken off again, and a
# list that did not exist before goes.
first_use_note() {
    FIRST_USE_BEFORE=$(first_use_ids | tr '\n' ' '); FIRST_USE_HAD=0
    # a copy for the time only (cp -p keeps it), in this run's scratch dir
    [ -f "$FIRST_USE" ] && { FIRST_USE_HAD=1; cp -p "$FIRST_USE" "$(oyg_tmp first-use)" 2>/dev/null; }
    return 0
}
first_use_settle() {
    _i=0
    while [ $_i -lt 10 ] && [ "$(first_use_ids | tr '\n' ' ')" = "${FIRST_USE_BEFORE:-}" ] \
        && [ "$( [ -f "$FIRST_USE" ] && echo 1 || echo 0)" = "${FIRST_USE_HAD:-0}" ]; do sleep 1; _i=$((_i+1)); done
    [ -f "$FIRST_USE" ] || return 0
    if [ "${FIRST_USE_HAD:-1}" = 0 ]; then
        [ "$OYG_DRYRUN" = 1 ] || rm -f "$FIRST_USE"; ok "removed the first-use list the restore created"; return 0
    fi
    _fs=0
    for _id in $(first_use_ids); do
        case " ${FIRST_USE_BEFORE:-} " in *" $_id "*) ;; *) first_use_drop "$_id" "$_id (added while restoring)" && _fs=1 ;; esac
    done
    # LG's write gave the file a new time: back to the one from before
    [ $_fs = 1 ] && [ -f "$OYG_TMPD/first-use" ] && [ -f "$FIRST_USE" ] && touch -r "$OYG_TMPD/first-use" "$FIRST_USE"
    return 0
}
forget_traces() { forget_origins; forget_files "$WAM_ORIGINS" "$INSTALL_HISTORY"; forget_first_use; }
find_bin() {  # find_bin <name>  → first existing path, links resolved (usr-merge)
    for _d in /usr/sbin /usr/bin /sbin /bin /usr/libexec; do
        [ -e "$_d/$1" ] && { canon "$_d/$1"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------ migration --
# Repairs of state left by earlier versions. Idempotent; runs before every
# mutating command.
oyg_migrate() {
    [ "$OYG_DRYRUN" = 1 ] && return 0
    # 1.2.x: a manual re-apply of mic chmodded /dev/null to 0000 (through the
    # bind) and recorded "0" as the capture node's original mode
    if [ -c /dev/null ] && [ "$(_oct "$(mode_of /dev/null)")" != "$(_oct 666)" ]; then
        _was=$(mode_of /dev/null); chmod 666 /dev/null && log "  repaired /dev/null mode (was $_was)"
    fi
    _f="$OYG_STATE/modes.mic"
    if [ -f "$_f" ]; then grep -v ' 0*$' "$_f" > "$_f.t"; mv "$_f.t" "$_f"; [ -s "$_f" ] || rm -f "$_f"; fi
    # 1.2.x edited settingsservice's consent cache directly. Its backup is a
    # stale cache whose md5 no longer matches: never copy it back. Consents
    # now go through settingsservice (lib/eula.sh).
    for _m in consent nag; do
        _f="$OYG_STATE/files.$_m"
        [ -f "$_f" ] && grep -qxF /var/luna/preferences/eula "$_f" || continue
        grep -vxF /var/luna/preferences/eula "$_f" > "$_f.t"; mv "$_f.t" "$_f"; [ -s "$_f" ] || rm -f "$_f"
        _b=$(backup_path /var/luna/preferences/eula)
        [ -f "$_b" ] && mkdir -p "$OYG_BACKUP/legacy" && mv "$_b" "$OYG_BACKUP/legacy/" && log "  kept the 1.2.x consent-cache backup aside ($OYG_BACKUP/legacy)"
    done
    return 0
}

# ------------------------------------------------------------------ lock --
# One mutating run at a time (mkdir is atomic on every filesystem here).
# The lock names its holder's pid and the boot it was taken in: /var
# survives a power cut, and a boot-time pid is easily an LG daemon's at the
# next boot, so a lock from another boot, or whose pid is not an oyg run,
# is stale. A live holder is waited for (a boot apply or the late pass
# takes about 15 s) rather than refused: the app's job would fail otherwise.
lock_stale() {
    _lp=$(sed -n 1p "$OYG_ROOT/lock/pid" 2>/dev/null); _lb=$(sed -n 2p "$OYG_ROOT/lock/pid" 2>/dev/null)
    [ -n "$_lp" ] && [ -d "/proc/$_lp" ] || return 0
    same_boot "$_lb" || return 0
    tr '\0' ' ' < "/proc/$_lp/cmdline" 2>/dev/null | grep -q oyg || return 0
    return 1
}
oyg_lock() {
    [ "$OYG_DRYRUN" = 1 ] && return 0
    mkdir -p "$OYG_ROOT" 2>/dev/null
    _lw=0
    while ! mkdir "$OYG_ROOT/lock" 2>/dev/null; do
        if lock_stale; then rm -rf "$OYG_ROOT/lock"; continue; fi
        [ $_lw -lt 90 ] || die "another own-your-glass run is in progress (pid $(sed -n 1p "$OYG_ROOT/lock/pid" 2>/dev/null))"
        [ $_lw = 0 ] && info "waiting for another own-your-glass run to finish"
        sleep 1; _lw=$((_lw+1))
    done
    # our own pid even in a ( ... ) & job, where $$ is the parent's
    { printf '%s\n' "$(exec sh -c 'echo "$PPID"')"; boot_stamp; } > "$OYG_ROOT/lock/pid"
    trap 'rm -rf "$OYG_ROOT/lock"; oyg_cleanup' EXIT
}

# ---------------------------------------------------- module bookkeeping --
# Every module implements: mod_<name>_apply, mod_<name>_restore,
# mod_<name>_status and sets MOD_<NAME>_DESC. The generic restore below is
# what most modules call, after any module-specific work.
# Mounts come off first: a mode or a deleted file belongs to what is under a
# bind, and a chmod through a bind lands on /dev/null.
# on-demand services that were running when we stopped them: a call to an
# unknown method makes the bus start the service again (it only answers
# "unknown method")
restore_relaunch() {
    state_list relaunch | while read -r _rl; do
        [ -n "$_rl" ] || continue
        if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) start $_rl again"; continue; fi
        luna "luna://$_rl/oygWake" '{}' >/dev/null && info "$_rl started again"
    done
    state_drop relaunch
}
generic_restore() {
    restore_mounts; restore_chains; restore_immutable; restore_moved; restore_created; restore_files; restore_modes; restore_units; restore_relaunch
    daemon_reload_if_needed; state_drop ls2; kv_drop
}

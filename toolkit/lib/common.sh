# common.sh — shared helpers for the own-your-glass toolkit.
# POSIX sh only: this runs on the BusyBox shell that ships on webOS.
#
# Every change the toolkit makes goes through a helper below, and every helper
# records what it did under $OYG_STATE, scoped to the module making the change
# ($OYG_MOD). `oyg restore` (and the boot hook, once the app has been
# uninstalled) replays those records to put the TV back. No module needs its
# own undo bookkeeping.

OYG_VERSION="1.2.3"

OYG_APPID=${OYG_APPID:-org.ownyourglass.app}
OYG_APPDIR=${OYG_APPDIR:-/media/developer/apps/usr/palm/applications/$OYG_APPID}
OYG_ROOT=${OYG_ROOT:-/var/lib/own-your-glass}
OYG_STATE="$OYG_ROOT/state"
OYG_BACKUP="$OYG_ROOT/backup"
OYG_LOG="$OYG_ROOT/oyg.log"
OYG_HOOK=${OYG_HOOK:-/var/lib/webosbrew/init.d/own-your-glass}
OYG_DRYRUN=${OYG_DRYRUN:-0}
OYG_MOD=${OYG_MOD:-core}

# ---------------------------------------------------------------- logging --
_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }
log()  { printf '%s\n' "$*"; [ -d "$OYG_ROOT" ] && printf '%s %s\n' "$(_ts)" "$*" >> "$OYG_LOG" 2>/dev/null; return 0; }
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
oyg_init_dirs() { [ "$OYG_DRYRUN" = 1 ] || mkdir -p "$OYG_STATE" "$OYG_BACKUP" 2>/dev/null; }
_sf() { printf '%s/%s.%s' "$OYG_STATE" "$1" "$OYG_MOD"; }
state_add()  { [ "$OYG_DRYRUN" = 1 ] && return 0; grep -qxF -- "$2" "$(_sf "$1")" 2>/dev/null || printf '%s\n' "$2" >> "$(_sf "$1")"; }
state_del()  { [ "$OYG_DRYRUN" = 1 ] && return 0; _f=$(_sf "$1"); [ -f "$_f" ] || return 0; grep -vxF -- "$2" "$_f" > "$_f.tmp" 2>/dev/null; mv "$_f.tmp" "$_f"; }
state_has()  { grep -qxF -- "$2" "$(_sf "$1")" 2>/dev/null; }
state_list() { cat "$(_sf "$1")" 2>/dev/null; }
state_drop() { [ "$OYG_DRYRUN" = 1 ] || rm -f "$(_sf "$1")"; }
# key/value flags per module: $OYG_STATE/kv.<module>
kv_set() { [ "$OYG_DRYRUN" = 1 ] && return 0; _f=$(_sf kv); { grep -v "^$1=" "$_f" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$_f.tmp"; mv "$_f.tmp" "$_f"; }
kv_get() { sed -n "s/^$1=//p" "$(_sf kv)" 2>/dev/null | head -1; }
kv_drop() { [ "$OYG_DRYRUN" = 1 ] || rm -f "$(_sf kv)"; }

# --------------------------------------------------------------- mounts --
# Binaries, device nodes and unit files are neutralised by bind-mounting
# /dev/null over them: exec() of a bound binary fails, open() of a bound
# device node returns ENXIO, and systemd treats a unit file that IS the
# /dev/null character device as masked. The read-only vendor filesystem is
# never modified; umount (or a reboot) undoes every bind.
#
# /proc/mounts lists the mountpoint in field 2. A /dev/null bind shows up as
# "devtmpfs" with root "/null", never as the literal "/dev/null" — so we match
# on the mountpoint, never on the source.
# Our binds propagate into every app jail, so /proc/mounts grows to tens of
# thousands of lines once applied and reading it per check took 0.75 s.
# Read the mountpoint column once per run and keep the snapshot current.
OYG_MSNAP="/tmp/.own-your-glass.mounts.$$"
mounts_snapshot() { awk '{print $2}' /proc/mounts 2>/dev/null > "$OYG_MSNAP"; }
_msnap() { [ -s "$OYG_MSNAP" ] || mounts_snapshot; }
is_mounted() { _msnap; grep -qxF -- "$1" "$OYG_MSNAP"; }
_msnap_add() { _msnap; printf '%s\n' "$1" >> "$OYG_MSNAP"; }
_msnap_del() { _msnap; grep -vxF -- "$1" "$OYG_MSNAP" > "$OYG_MSNAP.t" 2>/dev/null; mv "$OYG_MSNAP.t" "$OYG_MSNAP"; }
trap 'rm -f "$OYG_MSNAP" "$OYG_MSNAP.t"' EXIT

# Paths that must never be neutralised, whatever a spec or a unit's
# ExecStart says: interpreters and launchers shared by everything, the
# settings-delivery service (binding it silently kills the Settings UI),
# the TV data exchanger, the Integrated Control Service (Universal Control /
# IR blaster) and the HID node every remote button rides on.
bind_denied() {
    case $1 in
        /bin/sh|/bin/bash|/usr/bin/luna-send|/usr/bin/iotjs|/usr/bin/node|/usr/bin/run-iot-js-service|/usr/bin/jsservicelauncher|/usr/bin/flutter-client|/usr/sbin/ls-hubd|/usr/sbin/sdx|/usr/sbin/tvdataexchanger|/usr/sbin/iconnectivity|/usr/sbin/pacrunner|/usr/sbin/crashd|/usr/sbin/eplmanager|/usr/sbin/captureservice|/dev/hidraw*|/usr/bin/systemctl|/bin/systemctl|/usr/palm/services/jsservicelauncher*) return 0 ;;
    esac
    return 1
}
bind_null() {  # bind_null <path>
    [ -e "$1" ] || return 1
    bind_denied "$1" && { warn "refusing to neutralise $1"; return 1; }
    is_mounted "$1" && { state_add mounts "$1"; return 0; }
    run "bind /dev/null over $1" mount --bind /dev/null "$1" || return 1
    _msnap_add "$1"; state_add mounts "$1"
}
bind_file() {  # bind_file <src> <target>   (overlay a generated file on a read-only one)
    [ -e "$2" ] || return 1
    if is_mounted "$2" && state_has mounts "$2"; then
        run "umount $2 (re-bind)" umount "$2" || run "umount -l $2" umount -l "$2"
    fi
    run "bind $1 over $2" mount --bind "$1" "$2" || return 1
    _msnap_add "$2"; state_add mounts "$2"
}
unbind() {  # unbind <target>
    if is_mounted "$1"; then
        run "umount $1" umount "$1" || run "umount -l $1" umount -l "$1" || return 1
        _msnap_del "$1"
    fi
    state_del mounts "$1"
}
restore_mounts() {  # undo every bind this module made (last first)
    state_list mounts | sed '1!G;h;$!d' | while read -r _p; do [ -n "$_p" ] && unbind "$_p"; done
    state_drop mounts
}

# ---------------------------------------------------------------- modes --
mode_of() { stat -c %a "$1" 2>/dev/null; }
set_mode() {  # set_mode <path> <mode>  (original mode recorded once)
    [ -e "$1" ] || return 1
    _cur=$(mode_of "$1"); [ "$_cur" = "$2" ] && return 0
    grep -q "^$1 " "$(_sf modes)" 2>/dev/null || state_add modes "$1 $_cur"
    run "chmod $2 $1" chmod "$2" "$1"
}
restore_modes() {
    state_list modes | while read -r _p _m; do
        [ -n "$_p" ] && [ -e "$_p" ] && run "chmod $_m $_p" chmod "$_m" "$_p"
    done
    state_drop modes
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
# One `ps` snapshot per run. Walking /proc with a cat per process is far too
# slow on the TV (a status of ~45 spec entries spawned tens of thousands of
# processes and never returned). Columns: pid, comm (15 chars), args.
OYG_PS=""
ps_snapshot() { OYG_PS=$(ps -o pid,comm,args 2>/dev/null | sed 1d); }
_ps() { [ -n "$OYG_PS" ] || ps_snapshot; printf '%s\n' "$OYG_PS"; }
pids_of()     { _ps | awk -v n="$(printf '%s' "$1" | cut -c1-15)" '$2==n{printf "%s ",$1}'; }
pids_of_exe() { _ps | awk -v e="$1" '$3==e{printf "%s ",$1}'; }
pids_of_arg() { _ps | awk -v a="$1" 'index($0,a) && $2!="awk"{printf "%s ",$1}'; }
kill_pids() {  # kill_pids "<what>" pid...
    _w=$1; shift
    _p=$(printf '%s\n' "$@" | tr ' ' '\n' | grep -v '^$' | grep -vx "$$" | sort -u | tr '\n' ' ')
    [ -n "$(printf '%s' "$_p" | tr -d ' ')" ] || return 0
    # one kill per pid: BusyBox kill returns non-zero if any pid is already gone
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) TERM $_w ($_p)"; return 0; fi
    info "TERM $_w ($_p)"; for _i in $_p; do kill -TERM "$_i" 2>/dev/null; done
    sleep 1
    _left=""; for _i in $_p; do [ -d "/proc/$_i" ] && _left="$_left $_i"; done
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
# status paths must never call it; apply/restore may.
unit_path()   { systemctl show -p FragmentPath "$1" 2>/dev/null | sed 's/^FragmentPath=//' | grep -v '^$'; }
unit_exec()   { systemctl show -p ExecStart "$1" 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1; }
unit_active() { [ "$(systemctl is-active "$1" 2>/dev/null)" = active ]; }
have_unit()   { [ -n "$(unit_path "$1")" ]; }

OYG_NEED_RELOAD=0
stop_unit() {  # remembers units that were active so restore can start them
    unit_active "$1" && state_add units "$1"
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

# ------------------------------------------------------------------ luna --
# luna-send reads the bus reply from a pipe that is also fed by stdin; if
# stdin closes first it exits 0 with NO output. Always close stdin.
luna() { luna-send -n 1 -f "$1" "$2" </dev/null 2>&1; }
luna_ok() { luna "$1" "$2" | grep -q '"returnValue"[[:space:]]*:[[:space:]]*true'; }
toast() {
    [ "$OYG_DRYRUN" = 1 ] && return 0
    luna_ok luna://com.webos.notification/createToast \
        "{\"message\":\"$(printf '%s' "$1" | sed 's/"/\\"/g')\",\"sourceId\":\"com.webos.surfacemanager\"}" \
        || warn "toast not shown: $1"
}
# At boot the notification service ignores toasts until the UI is up. Wait
# (up to ~3 min) for the boot manager to report a finished boot with the
# first app launched, then toast.
toast_after_boot() {
    _i=0
    while [ $_i -lt 36 ]; do
        luna luna://com.webos.bootManager/getBootStatus '{}' | tr -d ' \n' | grep -q '"boot-done":true.*"firstAppLaunched":true\|"firstAppLaunched":true.*"boot-done":true' && break
        sleep 5; _i=$((_i+1))
    done
    sleep 3
    toast "$1"
}

# ----------------------------------------------------------------- misc --
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1; }
model_name()    { _m=$(json_str /var/run/nyx/device_info.json modelName); [ -z "$_m" ] && _m=$(json_str /var/run/nyx/device_info.json product_id | cut -d. -f1); printf '%s' "$_m"; }
webos_version() { sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"'; }
app_installed() { [ -d "$OYG_APPDIR" ]; }
find_bin() {  # find_bin <name>  → first existing path
    for _d in /usr/sbin /usr/bin /sbin /bin /usr/libexec; do
        [ -e "$_d/$1" ] && { printf '%s\n' "$_d/$1"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------------ lock --
# One mutating run at a time (mkdir is atomic on every filesystem here).
oyg_lock() {
    [ "$OYG_DRYRUN" = 1 ] && return 0
    mkdir -p "$OYG_ROOT" 2>/dev/null
    if ! mkdir "$OYG_ROOT/lock" 2>/dev/null; then
        _lp=$(cat "$OYG_ROOT/lock/pid" 2>/dev/null)
        if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then die "another own-your-glass run is in progress (pid $_lp)"; fi
        rm -rf "$OYG_ROOT/lock"; mkdir "$OYG_ROOT/lock" 2>/dev/null || die "cannot take lock"
    fi
    printf '%s' "$$" > "$OYG_ROOT/lock/pid"
    trap 'rm -rf "$OYG_ROOT/lock"; rm -f "$OYG_MSNAP" "$OYG_MSNAP.t"' EXIT
}

# ---------------------------------------------------- module bookkeeping --
# Every module implements: mod_<name>_apply, mod_<name>_restore,
# mod_<name>_status and sets MOD_<NAME>_DESC. The generic restore below is
# what most modules call, after any module-specific work.
generic_restore() {
    restore_moved; restore_created; restore_files; restore_modes; restore_mounts; restore_units
    daemon_reload_if_needed; kv_drop
}

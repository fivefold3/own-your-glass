# mic — the microphone capture endpoints (option mic).
#
# ALSA capture nodes are /dev/snd/pcmC<card>D<dev>c, but on these SoCs most
# "capture" endpoints are internal audio routing, not microphones: the
# sound-out capture path that feeds Bluetooth headphones, LE audio, WiSA
# speakers and sound share (pcmC0D10c on the reference TV), the broadcast
# recorder tap (pcmC0D11c), audiod's mixer taps, speaker feedback and the
# sound-engine loop. Blocking those breaks audio features, not privacy.
#
# So this module blocks only endpoints whose driver name says microphone:
# the far-field array ("WoV PDM Mic", "FARFIELD", ...). The Magic Remote's
# mic is a Bluetooth HID stream handled by the voice module, and the ACR
# capture tap is moot with acr2 neutralised. With /dev/null bound over a
# node, open() still succeeds but ALSA's first ioctl fails, so nothing can
# record; playback nodes (…p) are never touched.
#
# The node is made 0000 before it is bound, because app jails bind their own
# view of /dev/snd (performer, thinqai, Chromecast, Prime Video) that a bind
# on the host path does not reach; their views are bound too when they exist.

MIC_NAME_MATCH='[Mm][Ii][Cc]|FARFIELD|[Ff]ar[Ff]ield|[Vv]oice'

# capture nodes whose /proc/asound/pcm entry names a microphone
mic_nodes() {
    grep -E ': capture' "$OYG_PROC/asound/pcm" 2>/dev/null | grep -E "$MIC_NAME_MATCH" | while IFS=: read -r cd _; do
        c=$(printf '%s' "${cd%%-*}" | sed 's/^0*//'); d=$(printf '%s' "${cd#*-}" | sed 's/^0*//')
        n="/dev/snd/pcmC${c:-0}D${d:-0}c"
        [ -e "$n" ] && printf '%s\n' "$n"
    done
}

mic_jail_views() { for _v in /var/palm/jail/*/dev/snd/"${1##*/}"; do [ -e "$_v" ] && printf '%s\n' "$_v"; done; }

hook_mic_apply() {
    _n=0
    for n in $(mic_nodes); do
        case $n in /dev/snd/pcmC[0-9]*D[0-9]*c) ;; *) continue ;; esac
        set_mode "$n" 000          # a no-op once bound: never chmod through a bind
        bind_null "$n" && _n=$((_n+1))
        for v in $(mic_jail_views "$n"); do bind_null "$v"; done
    done
    [ $_n = 0 ] && info "no microphone endpoints found (nothing to block)" || ok "$_n microphone endpoints blocked"
    return 0
}
hook_mic_restore() { :; }   # binds and modes are recorded: generic restore
hook_mic_status() {
    _t=0; _b=0; _jv=0
    for n in $(mic_nodes); do
        _t=$((_t+1)); is_mounted "$n" && _b=$((_b+1))
        for v in $(mic_jail_views "$n"); do is_mounted "$v" || _jv=$((_jv+1)); done
    done
    [ $_t = 0 ] && { st "$1" NA "no microphone endpoints on this TV"; return 0; }
    if [ $_b = "$_t" ]; then
        st "$1" OK "$_b microphone endpoints blocked"
        [ $_jv = 0 ] || { st "$1" WARN "$_jv app-jail views of the microphone not blocked (apply again)"; return 1; }
        return 0
    fi
    [ $_b = 0 ] && st "$1" WARN "microphone endpoints open ($_t)" || st "$1" WARN "$_b of $_t microphone endpoints blocked"
    return 1
}

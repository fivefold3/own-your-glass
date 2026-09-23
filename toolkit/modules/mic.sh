# mic — the microphone capture endpoints.
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
# capture tap is moot with acr2 neutralised. Binding /dev/null over a node
# makes every open() fail with ENXIO; playback nodes (…p) are never touched.
MOD_MIC_DESC="Built-in and far-field microphones"
MOD_MIC_DEFAULT=on

MIC_NAME_MATCH='[Mm][Ii][Cc]|FARFIELD|[Ff]ar[Ff]ield|[Vv]oice'

# capture nodes whose /proc/asound/pcm entry names a microphone
mic_nodes() {
    grep -E ': capture' /proc/asound/pcm 2>/dev/null | grep -E "$MIC_NAME_MATCH" | while IFS=: read -r cd _; do
        c=${cd%%-*}; d=${cd#*-}
        n="/dev/snd/pcmC$((10#$c))D$((10#$d))c"
        [ -e "$n" ] && printf '%s\n' "$n"
    done
}

mod_mic_apply() {
    _n=0
    for n in $(mic_nodes); do
        case $n in /dev/snd/pcmC[0-9]*D[0-9]*c) ;; *) continue ;; esac
        set_mode "$n" 000
        bind_null "$n" && _n=$((_n+1))
    done
    [ $_n = 0 ] && info "no microphone endpoints found (nothing to block)" || ok "$_n microphone endpoints blocked"
    kv_set applied 1
}
mod_mic_restore() { generic_restore; }
mod_mic_status() {
    _t=0; _b=0
    for n in $(mic_nodes); do _t=$((_t+1)); is_mounted "$n" && _b=$((_b+1)); done
    [ $_t = 0 ] && { st MIC NA "no microphone endpoints on this TV"; return 0; }
    if [ $_b = "$_t" ]; then st MIC OK "$_b microphone endpoints blocked"; return 0; fi
    [ $_b = 0 ] && st MIC WARN "microphone endpoints open ($_t)" || st MIC WARN "$_b of $_t microphone endpoints blocked"
    return 1
}

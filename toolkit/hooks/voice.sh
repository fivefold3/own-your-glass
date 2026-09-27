# voice — what the voice option does besides its services (option voice).
#
# voiceinput (the LS2 hub) and voiceconductor are deliberately left running:
# Settings and Home query them at startup, and a call to a blocked
# voiceconductor never returns (Settings' Date & Time page stopped loading).
# With every input neutralised and the microphone blocked they have nothing
# to hear. Transcripts and request dumps the voice stack left behind are
# cleared on apply.
VOICE_LEFTOVERS="/tmp/app.voice.log"
VOICE_LEFTOVER_DIRS="/tmp/thinqai /tmp/voiceinput /tmp/iflytek"

hook_voice_apply() {
    for f in $VOICE_LEFTOVERS; do [ -f "$f" ] && run "truncate $f" sh -c ": > $f"; done
    for d in $VOICE_LEFTOVER_DIRS; do
        [ -d "$d" ] || continue
        _c=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
        [ "$_c" = 0 ] || { run "clear $d" find "$d" -type f -exec rm -f {} + && info "cleared $_c files in $d"; }
    done
    return 0
}
hook_voice_restore() { :; }
hook_voice_status() { :; }

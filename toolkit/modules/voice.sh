# voice — the microphone pipelines and the assistants behind them.
#
# The Magic Remote mic is a Bluetooth HID raw stream on /dev/hidraw0 read by
# voiceinput_hidraw; the built-in far-field mic is read by voiceinput_sound
# and voiceinput_preprocessor for the wake-word triggers (trigger_alexa,
# trigger_thinq). voiceinput_network receives mic audio from a paired phone
# (the ThinQ / remote app). voiceconductor orchestrates each request (speech
# to text, intent, routing to Alexa or ThinQ AI); the speech itself goes to
# LG through nlpmanager and sdx. Transcripts were found in plaintext in
# /tmp/var/log/messages. /dev/hidraw0 itself is never touched: every other
# remote button rides on it. airessrvallocator is the NPU allocator from the
# ai-inference-manager package, not voice-only; it is here because the
# on-device voice models are its main user.
#
# voiceinput (the LS2 hub, com.webos.service.voiceinput) is deliberately left
# running: Settings and the Home app query it, and with it dead every launch
# waited out a luna timeout (Settings took 8 s instead of 1.2 s).
# voiceconductor is left running for the same reason, and worse: a call to it
# while it is blocked never returns, and Settings asks it for the supported
# languages at startup before it loads the Date & Time page, so "Set
# automatically" never showed its state and the time zone list never loaded.
# It has no network code. Earlier versions blocked it; apply releases it.
# nlpmanager is left running too (search uses it). Every input is neutralised
# and the capture devices are blocked by the mic module, so none of them has
# anything to hear.
MOD_VOICE_DESC="Remote and far-field mic pipelines, wake words, Alexa, ThinQ AI"
MOD_VOICE_DEFAULT=on

VOICE_SPEC='
voiceinput_hidraw||?|voiceinput_hidraw|
voiceinput_sound||?|voiceinput_sound|
voiceinput_preprocessor||?|voiceinput_preprocessor|
voiceinput_network||?|voiceinput_network|
voiceclick||?|voiceclick|
trigger_alexa||?|trigger_alexa|
trigger_thinq||?|trigger_thinq|
alexa-adapter||?|amazon-alexa-adapter|
thinqai-adapter||?|lg.thinqai.adapter|
airessrvallocator||?|airessrvallocator|
voice-performer||/usr/sbin/performer|performer|
'
VOICE_LOG=/tmp/app.voice.log

VOICE_RELEASED="voiceconductor"

mod_voice_apply() {
    printf '%s\n' "$VOICE_SPEC" | svc_apply
    svc_release $VOICE_RELEASED
    [ -f "$VOICE_LOG" ] && run "truncate $VOICE_LOG" sh -c ": > $VOICE_LOG"
    return 0
}
mod_voice_restore() { generic_restore; }
mod_voice_status()  { printf '%s\n' "$VOICE_SPEC" | svc_status VOICE; }

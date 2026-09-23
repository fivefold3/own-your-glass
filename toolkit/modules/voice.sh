# voice — the microphone pipelines and the assistants behind them.
#
# The Magic Remote mic is a Bluetooth HID raw stream on /dev/hidraw0 read by
# voiceinput_hidraw; the built-in far-field mic is read by voiceinput_sound
# and voiceinput_preprocessor for the wake-word triggers (trigger_alexa,
# trigger_thinq). Everything funnels through voiceinput → voiceconductor and
# on to the cloud (LG ThinQ AI, Alexa). Transcripts were found in plaintext
# in /tmp/var/log/messages. /dev/hidraw0 itself is never touched: every
# other remote button rides on it.
#
# voiceinput (the LS2 hub, com.webos.service.voiceinput) is deliberately left
# running: Settings and the Home app query it, and with it dead every launch
# waited out a luna timeout (Settings took 8 s instead of 1.2 s). Its inputs
# are all neutralised and the capture devices are blocked by the mic module,
# so it has nothing to hear; the cloud path (voiceconductor) stays cut.
MOD_VOICE_DESC="Remote and far-field mic pipelines, wake words, Alexa, ThinQ AI"
MOD_VOICE_DEFAULT=on

VOICE_SPEC='
voiceinput_hidraw||?|voiceinput_hidraw|
voiceinput_sound||?|voiceinput_sound|
voiceinput_preprocessor||?|voiceinput_preprocessor|
voiceinput_network||?|voiceinput_network|
voiceconductor|voiceconductor.service|?|voiceconductor|
voiceclick||?|voiceclick|
trigger_alexa||?|trigger_alexa|
trigger_thinq||?|trigger_thinq|
alexa-adapter||?|amazon-alexa-adapter|
thinqai-adapter||?|lg.thinqai.adapter|
airessrvallocator||?|airessrvallocator|
voice-performer||||com.webos.service.voice.performer
'
VOICE_LOG=/tmp/app.voice.log

mod_voice_apply() {
    printf '%s\n' "$VOICE_SPEC" | svc_apply
    [ -f "$VOICE_LOG" ] && run "truncate $VOICE_LOG" sh -c ": > $VOICE_LOG"
    return 0
}
mod_voice_restore() { generic_restore; }
mod_voice_status()  { printf '%s\n' "$VOICE_SPEC" | svc_status VOICE; }

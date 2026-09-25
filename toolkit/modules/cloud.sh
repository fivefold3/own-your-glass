# cloud — LG's cloud control plane and the "smart home" daemons.
#
# Off by default: this is the part that breaks features people may want.
#   iot-client               ThinQ MQTT link (connect-client.lgthinq.com)
#   iot-proxy                ThinQ HTTPS proxy for the Home Hub
#   pushclient               LG push channel (AWS IoT MQTT)
#   ruleengine               ThinQ/Matter routines, synced with LG's cloud
#   homeconnect / matter     Home Hub device manager and Matter commissioner
#   familycare               local screen-time limit lock (no network)
#   mycar                    connected-car features, over push topics
#   buddyconnector           LG Buddy: a linked family member can control the
#                            TV, get SOS alerts and video-call (KakaoTalk)
#   alwaysready              Always Ready: always-on display, motion wake
#   sportsalarm / sportsalert  sports score alerts (MQTT, iot_sports_secure)
#   ai-inference-manager     installs on-device AI models and sets up the NPU
#   google-home-controller   installs and runs the Google Home hub runtime
#   chromecast-provisioning  installs, starts and stops the cast receiver
#   appcasting               turns a phone screen share into an app deeplink
#   avahi                    DNS-SD publishing for Google Home and Miracast
#                            over LAN. AirPlay has its own mDNS (mdnsd) and
#                            the Chromecast receiver its own: neither is here
#   DIAL                     the DIAL server that lets phone apps launch
#                            YouTube/Netflix on the TV (upnpd still advertises
#                            it; launches time out)
#   wowplay                  WOWCAST: wireless audio to LG soundbars
# NOT here: /usr/sbin/iconnectivity is com.webos.service.ics, the Integrated
# Control Service behind Universal Control (the Magic Remote's IR blaster for
# soundbars and set-top boxes). Binding it broke Universal Control and made
# Settings take ~8 s to open. It is on the never-touch list.
MOD_CLOUD_DESC="ThinQ cloud link, push, rule engine, Google Home, casting, phone helpers"
MOD_CLOUD_DEFAULT=on
MOD_CLOUD_BREAKS="Breaks the ThinQ app, Home Hub and Matter, the Google Home hub, LG Buddy, WOWCAST soundbar audio, launching apps from a phone (DIAL), Family Care time limits, Always Ready. AirPlay is unaffected (tested); Chromecast runs its own discovery (untested)"

CLOUD_SPEC='
iot-client|iot-client.service|/usr/palm/services/com.webos.service.iotclient/iot-client||
iot-client-bin||/usr/bin/iot-client||
iot-proxy||?|iot-proxy|
pushclient|com.webos.service.pushclient.service|/usr/sbin/com.webos.service.pushclient||
ruleengine|com.webos.service.ruleengine.service|/usr/sbin/com.webos.service.ruleengine||
homeconnect||/usr/palm/services/com.webos.service.homeconnect/main.js||com.webos.service.homeconnect/main.js
matter||/usr/palm/services/com.webos.service.matter/chip-service||
familycare|com.webos.service.familycare.service|/usr/palm/services/com.webos.service.familycare/index.js||familycare/index.js
mycar|com.webos.service.mycar.service|/usr/sbin/com.webos.service.mycar||
buddyconnector|com.webos.service.buddyconnector.service|/usr/palm/services/com.webos.service.buddyconnector/com.webos.service.buddyconnector||
alwaysready|alwaysready.service|?|alwaysready|
sportsalarm||?|sportsalarm|
sportsalert||/usr/palm/services/com.webos.service.sportsalert/index.js||sportsalert/index.js
ai-inference|ai-inference-manager.service|?|ai-inference-manager|
google-home|google-home-controller.service|?|google-home-controller|
chromecast-prov|chromecast-provisioning.service|?|chromecast-provisioning|
appcasting|appcasting.service|?|appcasting|
avahi-daemon|avahi-daemon.service|?|avahi-daemon|
avahi-adaptor|avahi-adaptor.service|?|avahi-adaptor|
dial-discovery||/usr/palm/services/com.webos.service.dial/discovery-server.js||discovery-server.js
wowplay|wowplay.service|?|wowplay|
'

mod_cloud_apply()   { printf '%s\n' "$CLOUD_SPEC" | svc_apply; }
mod_cloud_restore() { generic_restore; }
mod_cloud_status()  { printf '%s\n' "$CLOUD_SPEC" | svc_status CLOUD; }

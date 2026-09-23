# cloud — LG's cloud control plane and the "smart home" daemons.
#
# Off by default: this is the part that breaks features people may want
# (ThinQ phone app, Google Home / Chromecast, AirPlay discovery, casting).
#   iot-client / iot-proxy   AWS IoT MQTT link to LG ThinQ
#   pushclient               LG push channel
#   ruleengine               syncs automation rules from LG's cloud
#   homeconnect / matter     smart-home hub
#   familycare / mycar / buddyconnector / alwaysready / sportsalarm / sportsalert
#   ai-inference-manager     on-device AI inference service
#   google-home-controller, chromecast-provisioning, appcasting
#   avahi, DIAL discovery    mDNS advertising and Chromecast-style discovery
#   wowplay                  phone screen-mirroring receiver
# NOT here: /usr/sbin/iconnectivity is com.webos.service.ics, the Integrated
# Control Service behind Universal Control (the Magic Remote's IR blaster for
# soundbars and set-top boxes). Binding it broke Universal Control and made
# Settings take ~8 s to open. It is on the never-touch list.
MOD_CLOUD_DESC="ThinQ cloud link, push, rule engine, Google Home, casting, phone helpers"
MOD_CLOUD_DEFAULT=off
MOD_CLOUD_BREAKS="Breaks the ThinQ app, Home Hub and Matter, Google Home, AirPlay and Chromecast discovery, phone casting, Always Ready"

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
avahi-daemon|avahi-daemon.service||avahi-daemon|
avahi-adaptor|avahi-adaptor.service|?|avahi-adaptor|
dial-discovery||/usr/palm/services/com.webos.service.dial/discovery-server.js||discovery-server.js
wowplay|wowplay.service|?|wowplay|
'

mod_cloud_apply()   { printf '%s\n' "$CLOUD_SPEC" | svc_apply; }
mod_cloud_restore() { generic_restore; }
mod_cloud_status()  { printf '%s\n' "$CLOUD_SPEC" | svc_status CLOUD; }

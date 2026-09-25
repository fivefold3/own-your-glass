# own-your-glass

Privacy hardening for rooted LG webOS TVs, packaged as a Homebrew Channel app.

It stops the parts of the TV that watch you: automatic content recognition
(ACR), the advertising overlays and ad-ID manager, log and crash uploaders,
LG remote support, the remote and far-field microphone pipelines and their
wake-word triggers, the world-readable screen-capture file, LG's cloud and
smart-home daemons, and the logging and marketing traffic that goes out
through LG's network gateway. It declines
every tracking consent in every store the TV keeps, turns the ad and data
settings off through LG's own settings service, and hides the ad, ACR and
demo apps from the launcher. Everything is undone by pressing one button or
by uninstalling the app.

Built and verified on a **2025 LG OLED (C5 series, webOS 10.3.1)**. The
module specs discover what exists at run time, so other recent webOS models
should work; anything that is not on your TV is skipped.

## How it works, in one paragraph

The app is an ordinary webOS web app. It runs a POSIX `sh` toolkit as root
through Homebrew Channel's root service. For each unwanted daemon the toolkit
stops its unit, bind-mounts `/dev/null` over its binary so nothing can start
it again, and kills what is running. Persistent files (consent stores, the
hidden-app list) are backed up once and rewritten. A boot hook in
`/var/lib/webosbrew/init.d` re-applies all of it on every boot, guarded by a
crash-loop breaker (see [Reboots](#reboots)). If it finds the app has been
uninstalled, it restores every recorded change and removes itself. Full
details in [docs/DESIGN.md](docs/DESIGN.md).

## Modules

| module | default | what it stops |
|---|---|---|
| `acr` | on | `acr2`, `adoverlay-service`, `admanager`, `livepick-plus`, plus `contentminer` (Home preview rows), which is not ACR |
| `telemetry` | on | `uploadd`, `rdxd`, `rdx_reporter`, `remotelogger`, `nudge`, `service-logger`, `user-context-manager`, `ocpservice`, `sdp-server-notice`, `ftms` |
| `remote` | on | `remotediag` (RemoteOne), the telnet root shell, the world-writable Homebrew Channel service tree |
| `voice` | on | `voiceinput_hidraw`, `voiceinput_sound`, `voiceinput_preprocessor`, `voiceinput_network`, `voiceclick`, `trigger_alexa`, `trigger_thinq`, `airessrvallocator`, the Alexa and ThinQ AI adapters and the voice performer, including their jailed copies (the `voiceinput` hub and `voiceconductor` stay up: Settings calls both, and a call to a blocked `voiceconductor` never returns, which stopped the Date & Time page loading; neither has any input left) |
| `mic` | on | the microphone capture endpoints (far-field "WoV" mic array); everything else that ALSA calls "capture" is internal audio routing (the sound-out path that feeds Bluetooth headphones, WiSA speakers and sound share, the recorder tap, mixer loops) and is left alone |
| `capture` | on | `/tmp/capture.rgb` is emptied and becomes root-only (bind of a 0600 tmpfs file); `vtCaptureTestSuite` blocked |
| `consent` | on | declines S_VNG/S_ADG/S_TAG/S_MKT/… in all four stores (the mandatory terms of use and privacy policy stay accepted, so no agreements wall); sets adCookie, aiNudge, thirdPartyCookie, watchedListCollection, usageCare, welcomeFeature and friends off |
| `nag` | on | keeps `launchEulaByHome` off with a watcher that resets it within a second (that flag is what makes the Home app raise the "User Agreements" wall); clears pending "updated" flags. `eula-service` is left running: stopping it broke SDX's eula status, which `accountmanager` checks at boot, and that re-raised the LG account terms prompt |
| `apps` | on | hides 41 ad/ACR/remote-support/demo app ids via `blockedSystemAppList/<REGION>.json` |
| `cloud` | on | ThinQ IoT client and proxy, push client, rule engine, Home Hub, Matter, Family Care, MyCar, LG Buddy, Always Ready, sports alerts, AI inference, the Google Home hub, Chromecast provisioning, app casting, Avahi, the DIAL server, WOWCAST |
| `sdx` | on | routes 23 of the 38 services behind LG's network gateway (logging, beacons, nudges, recommendations, shop, LG Channels) to nowhere, by rewriting its routing table; sign-in, the clock, the Content Store, AirPlay and Settings keep their LG hosts |
| `network` | on | bind-mounts a generated `/etc/hosts` that sinkholes the fixed list of ad, ACR, telemetry and DoH hostnames, plus the gateway hosts only blocked `sdx` services use, with this TV's own country and region prefixes (IPv4 and IPv6) |

Every module is on by default. Three of them cost features, and each says so
under its name in the app:

- `cloud` breaks the ThinQ phone app, the Home Hub, the Google Home hub, LG
  Buddy, WOWCAST soundbar audio and launching apps from a phone (DIAL).
  AirPlay is unaffected: it has its own mDNS service.
- `sdx` empties the Home screen's recommendation and promo rows, the LG
  Channels online guide, the LG shop and sports alerts. On the reference TV,
  the Content Store (including installing an app), AirPlay, Settings and
  automatic time were tested working with it on.
- `network` stops anything that uses a sinkholed host. It is the
  belt-and-braces layer behind the other modules, and it leaves LG's clock,
  Content Store and sign-in hosts alone.

### What each service does

Everything a module stops, and the services it deliberately leaves alone, as
found on a C5 (webOS 10.3.1) by reading its binary, its Luna
registration and its logs. "Inferred" marks what comes from names and strings
only. A service that is not on your TV is skipped.

| module | service | what it does | sends data |
|---|---|---|---|
| `acr` | `acr2` | captures audio and video from broadcast and HDMI and runs a downloaded recognition library on it (an Alphonso data directory is on the TV) | yes, through that library (inferred) |
| `acr` | `adoverlay-service` / `adoverlay` | draws shoppable and interactive ads over live TV and HDMI inputs | yes |
| `acr` | `admanager` | advertising identifier, ad cookie, ad downloads and click tracking; runs all the time | yes (sdx, direct) |
| `acr` | `livepick-plus` | turns ACR and guide data into notice-bar offers (food delivery, shopping) | downloads offers |
| `acr` | `contentminer` | downloads the per-app preview rows on the Home screen from LG, optionally personalised | yes (sdx) |
| – | `objectdetection`, `objectdetectionutilizer` | on-device text and sign-language detection for "sign language zoom". **Not blocked**: it sends nothing, and earlier versions only blocked it because it looked like part of ACR | no |
| `telemetry` | `uploadd` | sends crash and analytics reports to LG | yes |
| `telemetry` | `rdxd` | builds crash and analytics reports for `uploadd` | through `uploadd` |
| `telemetry` | `rdx_reporter` | command-line tool that makes one report | no |
| `telemetry` | `remotelogger` | crash backtrace helper | no network code |
| `telemetry` | `nudge` | "AI Recommendation" tips picked from your app and channel usage | indirectly |
| `telemetry` | `service-logger` | logs first use of each app, HDMI device brands, game inputs, volume and picture mode by rules LG can update | collects; upload path not traced |
| `telemetry` | `user-context-manager` | records app and channel watch start and end times with your user number; ranks recent apps | yes (sdx `nudge_log_secure`) |
| `telemetry` | `ocpservice` | OLED Care: panel hours, pixel-refresher runs, picture settings | yes (`ocp.lgtviot.com`) |
| `telemetry` | `sdp-server-notice` | LG server notices and "alarm nudge" popups | downloads only |
| `telemetry` | `ftms` | detects Bluetooth LE fitness machines (FTMS) | downloads the list of apps it may show over |
| `remote` | `remotediag` | RemoteOne: LG support can push SSH keys, install dropbear, capture the screen, send keys, reboot and reset the TV | yes (`rone-*.lge.com`) |
| `remote` | telnet | Homebrew Channel's root shell on port 23, with no password | – |
| `remote` | Homebrew Channel service tree | the root service's files, shipped world-writable | – |
| `voice` | `voiceinput_hidraw` | reads the Magic Remote microphone | no |
| `voice` | `voiceinput_sound`, `voiceinput_preprocessor` | read and prepare the built-in far-field microphone | no |
| `voice` | `voiceinput_network` | receives microphone audio from a paired phone | no |
| – | `voiceconductor` | orchestrates voice requests (speech to text, intent, Alexa or ThinQ AI). **Not blocked**: Settings asks it for the supported languages at startup and waits for the answer, so blocking it broke the Date & Time page | no; the speech goes out through `nlpmanager` |
| `voice` | `voiceclick` | finds clickable areas on screen for voice control | downloads its model |
| `voice` | `trigger_alexa`, `trigger_thinq` | wake-word listeners | no |
| `voice` | `amazon-alexa-adapter` | Alexa built-in (runs in a jail) | yes |
| `voice` | `lg.thinqai.adapter` | ThinQ AI assistant and voice ID (runs in a jail) | yes |
| `voice` | `airessrvallocator` | allocates the NPU for on-device AI models | no |
| `voice` | `performer` | carries out voice commands (runs in a jail) | yes |
| `mic` | "WoV PDM Mic" capture device | the built-in far-field microphone | – |
| `capture` | `/tmp/capture.rgb` | a 640x360 grab of the UI every 3 s, written by the OLED panel service (for pixel care) and readable by every app | – |
| `capture` | `vtCaptureTestSuite` | vendor command-line tool that dumps the video plane (nothing launches it) | no |
| `cloud` | `iot-client` | ThinQ MQTT link (`connect-client.lgthinq.com`) | yes |
| `cloud` | `iot-proxy` | ThinQ HTTPS proxy for the Home Hub | yes |
| `cloud` | `pushclient` | LG push channel (AWS IoT MQTT) | yes |
| `cloud` | `ruleengine` | ThinQ and Matter routines, synced with LG | yes |
| `cloud` | `homeconnect`, `matter` | Home Hub device manager and Matter commissioner | yes |
| `cloud` | `familycare` | local screen-time limit lock | no |
| `cloud` | `mycar` | connected-car features | yes |
| `cloud` | `buddyconnector` | LG Buddy: a linked family member can control the TV, get SOS alerts and video-call (KakaoTalk) | yes |
| `cloud` | `alwaysready` | Always Ready: always-on display and motion wake | logs through `uploadd` |
| `cloud` | `sportsalarm`, `sportsalert` | sports score alerts | yes |
| `cloud` | `ai-inference-manager` | installs on-device AI models and sets up the NPU (AI Picture/Sound, inferred) | no |
| `cloud` | `google-home-controller` | installs and runs the Google Home hub runtime | yes |
| `cloud` | `chromecast-provisioning` | installs, starts and stops the cast receiver | – |
| `cloud` | `appcasting` | turns a phone screen share into an app deeplink | yes (sdx) |
| `cloud` | `avahi-daemon`, `avahi-adaptor` | DNS-SD for Google Home and Miracast over LAN. AirPlay (`mdnsd`) and Chromecast have their own | – |
| `cloud` | `com.webos.service.dial` | DIAL server: phone apps launch YouTube or Netflix on the TV. `upnpd` still advertises it, so phones connect and time out | – |
| `cloud` | `wowplay` | WOWCAST: wireless audio to LG soundbars | no |
| `sdx` | logging and marketing endpoints | `sdp_logging`, `rdx_secure`, `rdxdev_secure`, `ibis_stat_secure`, `nudge_secure`, `nudge_log_secure`, `homeprv_secure`, `recommend_secure`, `tlamp_secure`, `web_browser_rcmd`, `qcard`, `sdp_nais`, `sdp_onnow`, `cdpbeacon_secure`, `cdp_service_secure`, `cpv_secure`, `lgshop_secure`, `lgshoplog_secure`, `iot`, `iot_push_secure`, `iot_sports_secure`, `voice_proxy_secure`, `buddy` | – |
| `network` | `/etc/hosts` | sends ad, ACR, telemetry and DNS-over-HTTPS hostnames to nowhere | – |

## Install

You need a rooted TV with Homebrew Channel (see <https://www.webosbrew.org/rooting/>).

### Homebrew Channel

Homebrew Channel > Settings > **Add repository**, and enter:

```
https://raw.githubusercontent.com/fivefold3/webos-homebrew-repo/main/repo.json
```

### Manual

```sh
tools/build-ipk.sh                       # -> dist/org.ownyourglass.app_<version>_all.ipk
tools/deploy.sh root@<tv-ip> --launch    # scp + the stock installer, no LG SDK needed
```

Installing changes nothing; open the app and press **Own the glass**. The
main screen shows one thing: whether the glass is owned by you or by LG.
Settings holds a toggle per protection (OK flips it, Apply commits), the log,
undo and uninstall. Options that cost you a feature say so under their name;
turn them off there if you need that feature.

## Clearing what was already collected

Stopping the collectors does not delete what they had gathered. Settings >
**Clear collected data** (`oyg purge`) removes it:

- the voice transcript logs (`/tmp/app.voice.log`, `/tmp/var/log/messages`);
- the ad manager's cached ad assets, home-promotion state, cookie and
  "fck" state, and the ad log service's encrypted log and backups;
- everything queued for upload to LG: the log uploader spool, the remote
  diagnostics spool and the fault manager's crash bundles;
- tracker cookies in the web-app profile whose host matches the blocklist
  (deleted row by row; the store itself is left alone so web apps stay
  signed in, unless you run `oyg purge --web-cookies`);
- and it **resets the advertising identifier** (`/var/lib/secretagent/IFA.txt`)
  to a new random UUID, keeping a copy of the old one in the backup
  directory. The device id next to it (`nduid`) is not touched: LG account
  and store features depend on it.

This is a one-off action, not a module: nothing about it is re-applied at
boot or undone on uninstall.

## Two different "terms" prompts

webOS has two unrelated agreement flows:

- **TV agreements** ("User Agreements": viewing information, interest-based
  ads, voice, marketing). `eula-service` fetches new versions and sets the
  `launchEulaByHome` setting; the Home app then raises the wall. The
  `consent` module declines the optional ones and keeps the mandatory Terms
  of Use and Privacy Policy accepted (declining those is what forces the wall
  on every launch); the `nag` module's watcher resets `launchEulaByHome` the
  moment anything sets it.
- **LG account terms** (LG Account Terms of Use and Privacy Policy, Smart
  Media Product Membership Privacy Policy). After the account auto-login at
  boot, `accountmanager` compares the account's agreed term ids with LG's
  latest and launches `com.webos.app.membership` when they differ. Nothing
  local satisfies that check without agreeing, so the `nag` watcher closes
  that app whenever `accountmanager` launched it (opening LG Account from
  Settings is a different caller and is left alone). LG's own rule is
  "agree or be signed out"; in practice the account kept working on the
  reference TV. Toggle `nag` off if you would rather see the prompt.

## Reboots

Protections are re-applied on every boot (binds and stopped services do not
survive a reboot on their own). A crash-loop breaker guards this: the boot
hook writes a marker before applying and clears it only after the TV has been
up for five minutes or the app has read the status; if the marker is still
there at the next boot, the previous boot never got that far, so persistence
switches itself off and nothing is applied. `oyg persist off` turns boot
re-apply off by hand (then a reboot brings the stock TV back and you press
Own the glass again). Homebrew Channel's own failsafe mode sits underneath
all of that.

## Undo

- **Give the glass back** (Settings) restores every change and keeps the app.
- **Restore and uninstall** restores, then removes the app.
- Uninstalling from Homebrew Channel also works: on the next boot the hook
  restores the TV and deletes itself.

## Command line

The toolkit also runs from an SSH shell. Everything the app does is
`oyg <command>`:

```sh
oyg status              # fast, safe to poll
oyg apply [module...]   # apply enabled modules (or the named ones)
oyg restore [module...] # undo
oyg enable|disable mod  # toggle and apply/undo one module
oyg persist on|off      # re-apply on boot (default on, crash-loop breaker armed)
oyg purge               # delete collected ad, diagnostic and voice data; reset the advertising ID
oyg uninstall           # restore, remove hook and state
OYG_DRYRUN=1 oyg apply  # print what would change, change nothing
```

To try it without installing anything:

```sh
tools/bundle.sh | ssh root@<tv-ip> 'OYG_DRYRUN=1 OYG_ROOT=/nonexistent sh -s -- apply'
```

## Safety notes

- Never flash the kernel, rootfs or TVService. This toolkit never writes to a
  system partition; it only bind-mounts, stops services and edits files under
  `/var`, `/mnt/lg` and `/media`.
- `sdx`, `tvdataexchanger`, `eplmanager`, `captureservice`, `iconnectivity`
  (Universal Control), ConnMan, the interpreters and `/dev/hidraw*` are on a
  hard never-touch list. Binding `sdx` silently kills the Settings UI (the
  `sdx` module edits its routing table and restarts it instead); touching
  ConnMan has taken a TV off the network for half an hour.
- A service that is blocked while something still calls it can hang the
  caller: a call to a blocked `voiceconductor` never returned, and Settings
  waited on it. That is why `voiceconductor` and the `voiceinput` hub are left
  running; after any change to a spec, the main screens are checked again.
- Firmware updates are not blocked here. Homebrew Channel has that toggle.
- Not a defence against an attacker who already has root.

## Repository layout

```
app/        webOS app (appinfo.json, index.html, app.js, style.css, icons)
toolkit/    oyg, boot-hook, lib/, modules/, etc/blocklist.txt  (bundled into the ipk)
tools/      build-ipk.sh, deploy.sh, bundle.sh
docs/       DESIGN.md, HOMEBREW.md
```

## Credits

This project exists because of other people's work:

- **Gamers Nexus** — the *Data Dragnet* investigation into LG smart TVs
  ([216,000,000 Spy TVs | The LG Smart TV Problem](https://www.youtube.com/watch?v=6IFVTcM28KA),
  with Level1Techs and independent researchers) is the source of the threat
  model here: ACR, standby audio capture, plaintext voice transcripts, network
  discovery and the upload paths. Every module maps back to something that
  investigation showed.
- **Julio Ferrero's [own-your-glass](https://github.com/JulioFerrero/own-your-glass)**
  (MIT) — the original toolkit of the same name and its verification report
  on a 2025 LG B5, which confirmed the Gamers Nexus findings on real hardware
  and worked out the mechanisms this project reuses: `/dev/null` bind mounts
  over binaries and device nodes, the `/etc/hosts` overlay, the consent
  stores, the hidden-apps list, the `luna-send` stdin trap and the
  never-touch list (`sdx`, the overlay containers, ConnMan). This is a
  re-implementation of that work as a Homebrew Channel app, re-verified on a
  C5.
- **[webosbrew](https://github.com/webosbrew)** — Homebrew Channel, its root
  service (`org.webosbrew.hbchannel.service/exec`), the boot hooks in
  `/var/lib/webosbrew/init.d` and the rooting guides. Nothing here would run
  without it.
- **[lg-tv-blocklist](https://github.com/furkan-bayrak/lg-tv-blocklist)**
  by furkan-bayrak (CC BY 4.0) — part of the hostname list in
  `toolkit/etc/blocklist.txt`.

MIT licence.

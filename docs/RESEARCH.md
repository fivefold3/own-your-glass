# Research notes

What was learned about LG webOS TVs while building Own Your Glass, and how
it was verified. This is the evidence behind the options in the app and the
entries in `kb/`. The full working notes (eleven per-area reports, a
catalogue of every service on the reference TV, and the firmware survey's
inventories and diffs) live in a separate research repository that also
holds extracted LG firmware, which cannot be published; this page is the
part that can.

Two sources, both from September 2026:

- **A read-only audit of one TV**: a 2025 LG OLED C5 (OLED55C5PSA) on
  webOS 10.3.1 (firmware 33.31.68). Its root, BSP and app-partition
  filesystems were dumped over SSH and indexed offline (467 services from
  systemd, the Luna service registries and the live process list, plus 100
  ActivityManager activities and all 157 running processes). Nothing was
  written, started or stopped on the TV during the audit.
- **A survey of 25 official LG firmware images**, downloaded from LG's own
  support servers: webOS 5.6 to 11.2; OLED, QNED and UHD; Australia, Europe,
  Singapore, North America and Korea. Unpacked with
  [epk2extract](https://github.com/openlgtv/epk2extract) and compared file by
  file. The C5's live dump is byte-identical to LG's published 33.31.68
  (100,472 files), which is how the survey was anchored to a real TV.

Then every option was applied and undone on the C5, with Settings, Home,
Date & Time, the Content Store, AirPlay, Cast, phone remote apps and Screen
Share exercised each time. Where a claim below is marked *(not verified on a
TV)* it comes from reading code or strings, not from watching it run.

## 1. What the services actually do

The audit's most useful outcome was replacing labels inherited from earlier
work with what each daemon does on the reference TV. The ones that shaped the
options:

**Ads and content recognition**

- `acr2` captures the TV's *output* audio (broadcast and HDMI, through ALSA,
  not the microphone) and fingerprints it with the Alphonso plugin. It sends
  fingerprints, nearby Wi-Fi BSSIDs, the wired MAC, HDMI device identity and
  the advertising ID to `prov-lg.alphonso.tv` and hosts it learns from there
  (the SDK learns more names at runtime, which is why a router-level block of
  `*.alphonso.tv` is still worth having).
- `adoverlay-service` and `livepick-plus` draw the shoppable overlays keyed
  on ACR. On webOS 11 `livepick-plus` gained a video path: it grabs frames of
  Live TV and HDMI through `captureservice` and carries EdgeVideo AI
  endpoints *(frame upload inferred from strings, not observed)*.
- `admanager` owns the advertising ID, ad cookie and click tracking and
  launches the consent-management and full-screen ad apps. Blocking it also
  silently breaks Settings' own "reset advertising ID", which is why OYG
  offers its own reset.
- `com.webos.service.lsa` ("log service for the advertisement", webOS 10
  and later) downloads an encrypted Python script through the gateway,
  which the TV decrypts and runs as root with full bus and HTTP rights. The
  version seen collects foreground-app sessions, channels, installs, the
  advertising ID and MAC. It was dormant on the reference TV only because of
  a country check in the script and a server-side flag.
- `lgchannelurl` (webOS 6 and 11, not 10) fills LG Channels' ad-insertion
  URLs with the device ID, advertising ID, zip code and more, whatever
  "limit ad tracking" says, and can likewise download its own replacement
  script.
- `contentminer` fills Home's preview rows and reports the installed-app
  list. It is not ACR, and it runs before OYG's boot hook on every boot.

**Usage data and diagnostics**

- `uploadd` and `rdxd` build and upload crash and analytics reports: usage
  logs, process lists, MAC, IP, eMMC and TV serial. Every crash report
  carries the last 40 KB of the system log, which on the reference TV
  contained voice transcripts.
- `service-logger` runs LG's usage-logging rules (first use of each app,
  HDMI device brands, game inputs, volume and picture-mode changes) and
  downloads new rule bundles that it runs with python3 as root. Its results
  leave through the system log's network whitelist. The first time any app
  is opened, including OYG itself, it notes that.
- `user-context-manager` keeps per-account app, channel and set-top-box
  watch history, ranks Home's recents and produces the monthly report.
  Stopping it disables Settings' "Reset usage data" and makes LG sign-in and
  sign-out time out (they still work; the screen shows an error).
- `ibis_stat_secure` is the Live TV per-channel-change log (channel,
  previous channel, zip code, user id): the most important viewing log
  outside ACR.
- `ocpservice` (OLED Care journal: panel hours, picture settings, device
  ID) sends directly to `ocp.lgtviot.com` and is not consent-gated.
- The system log's network whitelist is itself server-updated (757 entries
  versus 566 in the factory file on the reference TV) and includes ad
  impressions, shopping content shown, searches, picture reports with zip
  code, panel serial, USB and Bluetooth device names and the foreground app
  at every volume change. All of it leaves only through the gateway's
  `sdp_logging` route.

**Voice**

- The far-field microphone stack (`voiceinput_sound`, the `trigger_alexa`
  and `trigger_thinq` wake-word listeners) exists only on C- and G-series
  OLEDs. B-series, QNED and UHD sets have only the remote's microphone
  (`voiceinput_hidraw`), and 2021 sets have neither.
- `lg.thinqai.adapter` sends audio directly (not through the gateway) to
  `he-kr-ai.lgthinq.com`, with the LG account id for Voice ID. `performer`
  executes voice intents; on webOS 10 it could capture a frame for
  celebrity recognition and upload it to `wau.lgtvcommon.com` (removed in
  webOS 11).
- Only one ALSA capture node on the reference TV is a microphone ("WoV PDM
  Mic"). The other "capture" endpoints are internal routing: the sound-out
  path that feeds Bluetooth headphones, LE audio, WiSA and sound share, the
  broadcast recorder tap, and mixer feedback. Blocking those breaks audio,
  not tracking. OYG only blocks nodes whose driver name says microphone.
- `voiceconductor` and the `voiceinput` hub must stay running: Settings
  queries them at launch, and a call to a blocked copy never returns
  (Date & Time stopped loading). `airessrvallocator`, once labelled as
  voice, is the NPU allocator and has no caller in the firmware.

**Cloud and smart home**

- `iot-client`, `iot-proxy`, `pushclient` (AWS IoT with a device
  certificate, sends MACs, renews its certificate in the boot window),
  `ruleengine`, `matter`, `mycar`, `homeconnect` (webOS 10; it cached the
  LG account token in a world-readable file), `buddyconnector`.
- `google-home-controller` and `chromecast-provisioning` install and start
  runtimes that live on a separately updated partition and run in jails.
  The Chromecast receiver contacted Google before any terms were accepted.
- Four services that earlier work blocked turned out to be local features
  with no upload: `familycare` (screen-time limits), `alwaysready` (Always
  Ready), `ai-inference-manager` (the NPU arbiter behind AI Picture and AI
  Sound) and `wowplay` (WOWCAST and Dolby FlexConnect speakers). OYG
  releases them.

**Remote access**

- `remotediag` (LG RemoteOne) is a remote root shell with screen capture and
  key injection, and it can fetch its own package through the gateway.
- `iconnectivity` is Universal Control (the IR blaster and CEC control of
  boxes and soundbars, built on UEI QuickSet). Blocking it breaks the
  remote's control of other devices, so it is Lockdown-only. It does report the signatures of your
  devices to UEI's cloud (`www.ueiwsp.com`) and asks Philips Hue's discovery
  service; those hostnames are a separate, safe option.

## 2. LG's gateway

Most of the TV reaches LG through one daemon, `sdx`. A caller names a
service (`sdp_logging`, `nudge_secure`, `rdx_secure`, …) and `sdx` does the
HTTPS request, adding the device ID, the `fck` key, model, firmware, locale
and consent state. The hosts come from a routing table LG's server
refreshes, with a country prefix on some entries and a regional prefix
(`aic`, `eic`, `kic`, plus `cic` and `ruc` in LG's own service tables) on
others.

`sdx` cannot be stopped (Settings, the terms state and the clock depend on
it; on the reference TV the clock's first time source is the gateway, not
NTP). Neither can some of its callers, such as the system log daemon. So OYG
rewrites the table instead: blocked names point at `oyg.invalid`, kept
names keep their hosts, and the rewritten file is bound read-only over
every mount the table shows up under.

On webOS 11 this became the only lever: 33 of the 40 names, including the
logging, crash-report, recommendation and new AI-platform routes, share one
host (`<country>.tv.wiselg.com`) with sign-in, the clock and the Store, so
hostname blocking can no longer separate telemetry from what the TV needs.
Two 2020–2023 images ship an empty factory table and depend entirely on the
server-pushed one.

## 3. Levers that hold, and ones that do not

- **Bind-mounting `/dev/null` over a binary** stops systemd, the bus and
  activities from starting it again, without touching the read-only system
  partition. It does not reach a jail set up later (a jail's `/usr` is an
  overlay whose lower layer does not see the bind), nor a service loaded
  into the shared JS server.
- **LG's own launch block list**
  (`/var/preferences/servicemanager/blocked-services.json`): the launcher
  for on-demand Luna services exits before the jailer and before the binary
  if the service's first name is listed. LG uses it for one service of its
  own. It covers jails set up later, services on the app partition and JS
  services, and it cannot stop static services. OYG binds its own list over
  LG's, keeping LG's entries.
- **Static versus dynamic services**: a call to a blocked on-demand service
  fails at once; a call to a stopped always-on service waits (over 15 s for
  `nudge`, for ever for `voiceconductor`). That is why the app leaves
  always-on services running on webOS releases it has not been run on, and
  why every static entry was timed against Settings and Home before it
  joined a preset.
- **The shared JS server** hosts DIAL, the phone remote API, `homeconnect`,
  `sportsalert` and (webOS 11) `familycare` and LG Link. Nothing can unload
  one without killing the others, so a service loaded before the boot hook
  stays until the next restart; status reports it as resident rather than
  blocked.
- **Consents** are held by the settings service, with an md5 sidecar the
  boot checks. Editing the cache file directly (as earlier work did) left
  the sidecar stale, matched only a dead 2014 list, and never touched the
  `eulaStatus` booleans that the ad, ACR and voice services actually read.
  Going through `setSystemSettings` keeps everything consistent and lets
  restore put back exactly what was flipped.
- **The boot window**: LG's daemons get 10 to 30 s online before Homebrew
  Channel's boot hooks run. Seen in that window: the log daemon reaching
  the gateway, `service-logger`'s first-use rules, the push client renewing
  its certificate, the Chromecast receiver contacting Google, and DNS
  lookups for UEI's cloud and an AWS IoT endpoint. OYG raises the block
  list, the gateway rewrite and the sinkhole first, which shortens the
  window; a router-level block closes it.
- **Snapshot boot**: LG TVs resume a saved boot image, so the kernel's
  `boot_id` is the same after every restart. Anything that needs to tell
  restarts apart must use the boot time or the emptied `/run`.
- **Jails copy `/etc/hosts` when set up**, so a jail that exists before the
  sinkhole never sees it, and one set up while the sinkhole is bound keeps a
  copy after the sinkhole is gone. OYG writes its list into existing copies
  and strips it from every copy on restore.
- **The process list is not what it seems**: `/bin/ps` is procps on every
  surveyed image, and with no terminal it lists only the caller's own
  processes. A toolkit that reads `ps -o` as root never sees the jailed and
  non-root daemons. Read `ps -e` and `/proc/<pid>/exe`.

## 4. What the firmware survey showed

1. **One image per platform and webOS version, worldwide.** Australian,
   European, Singaporean, Canadian and Korean copies of the same build are
   byte-identical; Korean zips only add a manual. Regional behaviour comes
   from configuration and LG's servers, not from separate builds. North
   America gets a few extra build numbers that are minor refreshes (strings,
   keyboard plugins, a rebuilt audio daemon; no service added or removed).
2. **The webOS release decides the service set far more than the model.**
   All webOS 11 images, OLED and UHD, have almost identical inventories.
   That is why the knowledge base is organised by webOS generation, not by
   model.
3. **The core of what OYG targets exists on every image from 2020 to 2026**:
   ACR, the ad manager, the uploaders, the usage loggers, remote support,
   the voice adapters, the ThinQ client, the gateway, the capture service.
   Hardware decides the rest: the far-field microphone stack is OLED-only,
   and the pixel-care capture writer (`eplmanager`) is absent on UHD sets.
4. **webOS 11 (firmware 43.x, September 2026, for 2022–2025 sets)**: the
   gateway collapse above; `livepick-plus`'s frame capture; `lgchannelurl`;
   new services for presence sensing, sound awareness and universal control;
   `homeconnect` gone (smart home moved to a new framework); the account
   token cache and the celebrity-recognition upload gone; usr-merged
   filesystem, kernel 6.12, systemd 255, python 3.12. Jails, the launch
   block list and the capture writer are unchanged. The knowledge base was
   resolved against the C5's webOS 11 image, but OYG has not yet been *run*
   on webOS 11.
5. **Not surveyed**: 8K models (extraction keys missing), webOS 3 and 4,
   StanbyME and monitors.

The per-service, per-generation presence table is
[COMPATIBILITY.md](COMPATIBILITY.md), generated from the survey.

## 5. Corrections to earlier assumptions

Things this project started out believing, from earlier reports or its own
first versions, that turned out wrong on the reference TV:

- `iconnectivity` is Universal Control, not a phone helper; binding it took
  the remote's control of the soundbar away.
- The `voiceinput` hub and `voiceconductor` are queried by Settings at
  launch; blocking them made Settings take 8 s to open and broke Date &
  Time.
- Most ALSA "capture" nodes are internal audio routing, not microphones.
- `overlaycontainer*` are the Video-ACR overlay containers, not the
  quick-settings panel; `overlaymembership` is one of the two LG-account
  apps, not an ad app (hiding it broke the account picture on Home).
- `familycare`, `alwaysready`, `ai-inference-manager` and `wowplay` are
  local features, not telemetry.
- Editing the consent cache with `sed` did not hold (see §3).
- The routing-table rewrite was read-only on one of its four mount points;
  the others were still writable to a server push.
- LG's phone-remote server never starts again in the same boot after
  `allowMobileDeviceAccess` is turned off and on (an LG bug), and Miracast
  connects again only after a restart: hence the "Restart required" notice.
- A stored LG account signs itself in at every boot, and the account terms
  prompt that follows cannot be satisfied locally. There is no "keep the
  account but do not sign in" switch; removing the account is the only
  clean way to stop the prompt.

## 6. LAN exposure (hardening, separate from privacy)

A rooted TV answers more of the LAN than its owner expects: the phone
remote API on 3000/3001 (after one accepted pairing prompt: screenshots,
input injection, power; unpaired clients still get the device UUID and can
wake the screen), DIAL on 36866/18181 (unauthenticated app launch and
power-off), the Chromecast receiver, LPD printing on 515, the web-app
debugger on 9998, and `rdisc`, which lets any LAN host inject a default
route. `iptables` works on these kernels (IPv4 only; there is no IPv6
netfilter, so the LAN firewall option turns IPv6 off while it is on).

Two local findings are worth knowing about even without OYG. Homebrew
Channel's service tree and the directories above every homebrew app ship
world-writable, so any sandboxed app could rewrite a root service; the
"Remote support and root hygiene" option fixes the modes. The audit also
found a weakness in configuration LG ships that would let a sandboxed app
gain bus privileges it should not have. The same option closes it on a TV
running OYG; the details are held back until LG has had the chance to fix
it.

## 7. What is still open

- The KIC AWS IoT endpoint the reference TV looks up every few minutes with
  no app open has not been attributed to a program; it is documented, not
  blocked.
- Whether stopping a static service ever hangs a screen an owner uses
  (nothing seen so far; `nudge`'s callers wait but nothing visible waits on
  them).
- OYG on webOS 11, on the 5.6 to 9.2 generations, on 8K sets and on
  StanbyME: surveyed, not run.
- HbbTV options: not testable on the reference TV (no broadcast reception).
- Closing the boot window from inside the TV (an earlier bind step or unit
  drop-ins; LG itself uses `ExecCondition=` on webOS 11) is planned but not
  built.

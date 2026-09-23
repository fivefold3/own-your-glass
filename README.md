# own-your-glass

Privacy hardening for rooted LG webOS TVs, packaged as a Homebrew Channel app.

It stops the parts of the TV that watch you: automatic content recognition
(ACR), the advertising overlays and ad-ID manager, log and crash uploaders,
LG remote support, the remote and far-field microphone pipelines and their
wake-word triggers, and the world-readable screen-capture file. It declines
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
`/var/lib/webosbrew/init.d` re-applies all of it on boot only if you opted in
(off by default, so a reboot is always a way out). If it finds the app has
been uninstalled, it restores every recorded change and removes itself. Full details in [docs/DESIGN.md](docs/DESIGN.md).

## Modules

| module | default | what it stops |
|---|---|---|
| `acr` | on | `acr2`, `adoverlay-service`, `admanager`, `livepick-plus`, `contentminer`, `objectdetection` |
| `telemetry` | on | `uploadd`, `rdxd`, `rdx_reporter`, `remotelogger`, `nudge` |
| `remote` | on | `remotediag` (RemoteOne), the telnet root shell, the world-writable Homebrew Channel service tree |
| `voice` | on | `voiceinput_hidraw`, `voiceinput_sound`, `voiceinput_preprocessor`, `voiceinput_network`, `voiceconductor`, `voiceclick`, `trigger_alexa`, `trigger_thinq`, Alexa and ThinQ AI adapters (the `voiceinput` hub itself stays up: Settings queries it, and it has no inputs left) |
| `mic` | on | the microphone capture endpoints (far-field "WoV" mic array); everything else that ALSA calls "capture" is internal audio routing (the sound-out path that feeds Bluetooth headphones, WiSA speakers and sound share, the recorder tap, mixer loops) and is left alone |
| `capture` | on | `/tmp/capture.rgb` becomes root-only (bind of a 0600 tmpfs file); `vtCaptureTestSuite` blocked |
| `consent` | on | declines S_VNG/S_ADG/S_TAG/S_MKT/… in all four stores (the mandatory terms of use and privacy policy stay accepted, so no agreements wall); sets adCookie, aiNudge, thirdPartyCookie, watchedListCollection, usageCare, welcomeFeature and friends off |
| `nag` | on | keeps `launchEulaByHome` off with a watcher that resets it within a second (that flag is what makes the Home app raise the "User Agreements" wall); clears pending "updated" flags. `eula-service` is left running: stopping it broke SDX's eula status, which `accountmanager` checks at boot, and that re-raised the LG account terms prompt |
| `apps` | on | hides 41 ad/ACR/remote-support/demo app ids via `blockedSystemAppList/<REGION>.json` |
| `cloud` | off | ThinQ IoT client and proxy, push client, rule engine, home connect, Matter, family care, MyCar, buddy connector, always-ready, sports alerts, AI inference, Google Home, Chromecast provisioning, app casting, Avahi, DIAL discovery, WowPlay |
| `network` | off | bind-mounts a generated `/etc/hosts` that sinkholes 75 ad, ACR, telemetry and DoH hostnames (IPv4 and IPv6) |

`cloud` is off because it breaks the ThinQ phone app, Google Home, AirPlay
discovery and casting. `network` is off because stopping the senders is the
point; the sinkhole is a belt-and-braces layer, and the list deliberately
leaves LG's time-sync and app-store hosts alone.

## Install

You need a rooted TV with Homebrew Channel (see <https://www.webosbrew.org/rooting/>).

```sh
tools/build-ipk.sh                       # -> dist/org.ownyourglass.app_1.0.0_all.ipk
tools/deploy.sh root@<tv-ip> --launch    # scp + the stock installer, no LG SDK needed
```

or install the ipk from a GitHub release URL with Homebrew Channel's
installer. Both paths and the repository manifest are described in
[docs/HOMEBREW.md](docs/HOMEBREW.md). Installing changes nothing; open the app
and press **Own the glass**. The main screen shows one thing: whether the
glass is owned by you or by LG. Settings holds a toggle per protection (OK
flips it, Apply commits), the log, undo and uninstall. Options that cost you
a feature say so under their name and are off by default.

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
  hard never-touch list. Binding
  `sdx` silently kills the Settings UI; touching ConnMan has taken a TV off
  the network for half an hour.
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

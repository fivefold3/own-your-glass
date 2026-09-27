# own-your-glass

Not affiliated with or endorsed by LG Electronics. LG and webOS are trademarks of LG Electronics.

Privacy hardening for rooted LG webOS TVs, packaged as a Homebrew Channel app.

> **Built with AI assistance.** Most of the code, tooling, tests and
> research notes in this repository were written with Claude (Fable 5.1 and
> Opus 5.5), directed and reviewed by the author. It is not a one-prompt
> generation: every option was tested on a real TV, several rounds of
> review found and fixed bugs in AI-written and hand-written code alike, and
> the knowledge base was checked against 25 LG firmware images. Read the
> code with the same care you would give any other project that touches
> your TV as root; the tests and the [research notes](docs/RESEARCH.md) say
> what was verified and how.

It stops the parts of the TV that watch you: automatic content recognition
(ACR), the advertising overlays and ad-ID manager, log and crash uploaders,
usage and viewing logs, LG remote support, the voice assistants and the
built-in microphone, the world-readable screen-capture file, LG's cloud and
smart-home daemons, and the logging and marketing traffic that goes out
through LG's network gateway. It declines every tracking consent, turns the
ad and data settings off through LG's own settings service, and hides the ad
apps from the launcher. Everything is undone by pressing one button or by
uninstalling the app. If the app is uninstalled, cleans up after itself
leaving no trace after a reboot.

Pick a protection level and press **Own the glass**:

- **Recommended**: blocks tracking and ads, and keeps AirPlay, Chromecast,
  phone apps, LG Channels, HbbTV, the Content Store and LG sign-in working.
- **Strict**: also turns off AirPlay, Google Cast, phone control, Screen
  Share, LG Channels and LG's AI features, closes the TV to your network
  (SSH included) and blocks your LG account.
- **Lockdown**: also disables some LG system services. Settings gets slow
  to open, and automatic time and time zone, search, Universal Control and
  app installs stop working. Not recommended: the app asks before applying
  it.
- **Custom**: every option on or off, each with one line on what it does
  and what it breaks; saved as your one custom selection.

Built and verified on a **2025 LG OLED (C5 series, webOS 10.3.1)**.
Knowledge about other TVs comes from 25 official LG firmware images
(webOS 5.6 to 11.2; OLED, QNED and UHD; AU, EU, SG, North America and Korea):
see [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md). Anything that is not on
your TV is skipped. On a webOS release it knows from firmware only (so
far, every release but 10.3), LG's always-on services are left running by
default, because a stopped one can make the TV's own screens wait; the app
says so. Nothing they collect gets out (their upload routes are cut), but
they keep collecting on the TV. Settings > **Untested protections** applies
them anyway, and everything else not yet verified on a TV: you are then
the first to try them. If a screen stops responding, Give the glass back
or turn the switch off; if the TV does not start properly twice in a row,
re-apply switches itself off and the TV comes up stock. On an unrecognised
release, it applies only what it recognises, and says so.

**Help verify your TV's release.** Turn Untested protections on, use the
TV for a day (Settings, Date & Time, Home, the Content Store, your casting
and phone apps), then Settings > **Generate a TV report** > **Copy to USB
storage** and [open an issue](https://github.com/fivefold3/own-your-glass/issues/new)
with the report attached (it holds no identifiers: model, software,
which services exist, which were applied) and what worked or broke. A
release verified that way is added to the knowledge base (`run_on` in
`kb/services.toml`) and stops needing the switch.

## How it works

The app is an ordinary webOS web app. It runs a POSIX `sh` toolkit as root
through Homebrew Channel's root service. For each unwanted daemon the toolkit
bind-mounts `/dev/null` over its binary so nothing can start it again, adds
it to LG's own launch block list (which also covers the copies that run
inside app jails), stops its unit and kills what is running. Consents and
settings go through LG's settings service; LG's gateway is cut off from its
logging endpoints by rewriting its routing table; hostnames go to nowhere
through a generated `/etc/hosts`. Every change is recorded per option, so
any option can be undone on its own. A boot hook in
`/var/lib/webosbrew/init.d` re-applies all of it on every boot, guarded by a
crash-loop breaker (see [Reboots](#reboots)). If it finds the app has been
uninstalled, it restores every recorded change and removes itself. Full
details in [docs/DESIGN.md](docs/DESIGN.md); everything it knows about each
service is in [kb/](kb/).

## Presets and options

<!-- options:begin -->
| option | Recommended | Strict | Lockdown | breaks | notes |
|---|:-:|:-:|:-:|---|---|
| **Ads and content recognition** | | | | | |
| Content recognition (ACR) | ● | ● | ● | Live Plus overlays |  |
| Ad services | ● | ● | ● | Reset advertising ID, LG Shop |  |
| Opt-out advertising ID | ● | ● | ● | – | Re-applied at every start; the ID file is covered read-only, so nothing can write a new one. The device IDs LG uses to recognise the TV are left alone. |
| Home promotions and recommendations | ● | ● | ● | Home preview rows, promo cards, AI tips |  |
| LG Channels |  | ● | ● | LG Channels | Turned off again, LG Channels needs a TV restart (the TV reads its hidden apps only at start-up); the app offers one. |
| **Usage data and diagnostics** | | | | | |
| Crash and log uploads | ● | ● | ● | – |  |
| Viewing and usage logs | ● | ● | ● | Reset usage data, recent-apps order, monthly report |  |
| Tracking consents | ● | ● | ● | – | The basic terms of use and privacy policy stay accepted. |
| HbbTV tracking | ● | ● | ● | – |  |
| HbbTV (not yet verified) |  | ○ | ○ | Freeview Plus, red button | Not yet tested on a TV with broadcast reception. |
| **Voice and microphones** | | | | | |
| Voice assistants and wake words | ● | ● | ● | Voice search, Alexa, ThinQ AI |  |
| Built-in microphone | ● | ● | ● | Hands-free voice |  |
| Voice framework and search |  |  | ● | Settings speed, automatic time, time zones, search | Verified on the C5: Settings opens slowly, Date & Time cannot be set automatically, the time-zone list and search results do not load. |
| **Screen** | | | | | |
| Screen-capture shield | ● | ● | ● | – | Also blocks a vendor video-plane grabber. |
| **Casting and phones** | | | | | |
| AirPlay |  | ● | ● | AirPlay, HomeKit (Siri) | The TV still shows in the AirPlay list, but connecting fails. |
| Google Cast |  | ● | ● | Google Cast | The TV no longer shows up as a Cast device. |
| Phone apps and second screen |  | ● | ● | Phone remote apps, launching apps from a phone, LG Link | Turned off again, phone remote apps need a TV restart (LG's phone server starts only with the TV); the app offers one. |
| Screen Share |  | ● | ● | Screen Share | Also stops the TV's network announcements (avahi), which the Google Home hub uses to find devices. Turned off again, Screen Share needs a TV restart; the app offers one. |
| Universal Control cloud lookups |  | ● | ● | – | Devices already set up keep working and new ones still set up (C5). |
| LAN firewall |  | ● | ● | SSH, AirPlay, Google Cast, phone apps, Screen Share, network devices in Universal Control | Replies to connections the TV makes itself (streaming, browsing) still get through. IPv6 is off while it is on (the firewall cannot filter it). `oyg lan allow <ip>` lets a device through, for example your computer for SSH; otherwise turn the firewall off from the app on the TV. |
| **LG cloud and smart home** | | | | | |
| ThinQ and Home Hub | ● | ● | ● | ThinQ app, Home Hub, Matter, LG notifications |  |
| Google Home hub | ● | ● | ● | Google Home hub |  |
| LG Buddy and sports alerts | ● | ● | ● | LG Buddy, sports alerts |  |
| AI features |  | ● | ● | Life-on-Screen art, AI agent | The TV's own AI Picture and AI Sound keep working (they run on the TV). |
| Settings backup and presence | ● | ● | ● | Settings backup |  |
| Universal Control and LAN device scanning |  |  | ● | Universal Control | The remote no longer controls boxes and soundbars (the volume pop-up shows a cross). |
| **Network** | | | | | |
| Tracker hostnames | ● | ● | ● | – | For everything on the TV, apps and browser included; also public DNS-over-HTTPS servers. |
| LG Store and account traffic |  |  | ● | App installs and updates, Home content | Also stops Chromecast built-in from starting after a restart (Lockdown turns Cast off anyway). |
| Remote configuration |  |  | ● | Online programme guide | Also stops Chromecast built-in from starting after a restart (Lockdown turns Cast off anyway). Nothing else was noticed on the C5. |
| **Remote access and prompts** | | | | | |
| Remote support and root hygiene | ● | ● | ● | LG remote support | Also keeps Homebrew Channel's telnet root shell off and fixes world-writable root files. |
| Block LG account |  | ● | ● | Content Store installs, LG account features | The sign-in screen shows a network error. With no account, LG cannot tie the TV to one and the account terms prompt never appears. |
| Terms prompts | ● | ● | ● | – | The LG account terms prompt comes with a signed-in account: Block LG account stops it. |

● on in that preset, ○ joins it once verified on a TV.
<!-- options:end -->

What each option stops, per service and per webOS release, is in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Install

You need a rooted TV with Homebrew Channel (see <https://www.webosbrew.org/rooting/>).

### Homebrew Channel

Homebrew Channel > Settings > **Add repository**, and enter:

```
https://raw.githubusercontent.com/fivefold3/webos-homebrew-repo/main/repo.json
```

### Over SSH

Turn on the SSH server in Homebrew Channel's settings, download the
`.ipk` from the [latest release](https://github.com/fivefold3/own-your-glass/releases/latest)
(or build it yourself with `tools/build-ipk.sh`, which writes
`dist/org.ownyourglass.app_<version>_all.ipk`; no LG SDK needed), then hand
it to the TV's own installer:

```sh
scp org.ownyourglass.app_<version>_all.ipk root@<tv-ip>:/tmp/oyg.ipk
ssh root@<tv-ip> "luna-send -i -f luna://com.webos.appInstallService/dev/install \
  '{\"id\":\"com.ares.defaultName\",\"ipkUrl\":\"/tmp/oyg.ipk\",\"subscribe\":true}' </dev/null"
```

The installer reports its progress; once it prints `"state": "installed"`
press Ctrl-C and remove `/tmp/oyg.ipk`. (`luna-send` needs its stdin
closed, hence the `</dev/null`, or it prints nothing.)

`tools/deploy.sh root@<tv-ip> --launch` does the same in one go: it builds
the ipk, copies it over, waits for "installed", deletes the copy and opens
the app (`--no-build` uses the newest ipk already in `dist/`).

Installing changes nothing; open the app and press **Own the glass**. The
main screen shows whether the glass is owned by you or by LG, plus a notice
when something needs you ("Restart required", "LG Account signed in", "Not
re-applied at start-up").
Settings (top right) holds the protection level, **Customize** (every option,
with what it breaks), the actions, undo and uninstall.

## Clearing what was already collected

Stopping the collectors does not delete what they had gathered. Settings >
**Clear collected data** (`oyg purge`) removes it:

- the voice transcript logs (`/tmp/app.voice.log`, `/tmp/var/log/messages`)
  and the request dumps the voice, AI and ad stacks leave in `/tmp`;
- the ad manager's cached ad assets, home-promotion state, cookie and
  "fck" state, and everything the ad log service collected;
- everything queued for upload to LG: the log uploader spool, the remote
  diagnostics spool and the fault manager's crash bundles;
- the Home Hub's cached LG account token (webOS 10) and LG Channels' ad-URL
  cache;
- tracker cookies in the web-app profile: rows whose host is a sinkholed
  name, and analytics cookies (`_ga`, `_gid`, …) whatever site set them
  (the store itself is left alone so web apps stay signed in, unless you run
  `oyg purge --web-cookies`);
- and it **resets the advertising identifier** (`/var/lib/secretagent/IFA.txt`)
  to a new random UUID (the old one is not kept anywhere), unless the
  Opt-out advertising ID option already holds it at zeros. The device id
  next to it (`nduid`) is not touched: LG account and store features
  depend on it.

`oyg purge --forget` also deletes the Matter/Homey pairing keys. This is a
one-off action: nothing about it is re-applied at boot or undone on
uninstall.

## Two different "terms" prompts

webOS has two unrelated agreement flows:

- **TV agreements** ("User Agreements": viewing information, interest-based
  ads, voice, marketing). `eula-service` fetches new versions and sets the
  `launchEulaByHome` setting; the Home app then raises the wall. The
  "Tracking consents" option declines the optional ones and keeps the
  mandatory Terms of Use and Privacy Policy accepted (declining those is what
  forces the wall on every launch); the "Terms prompts" option's watcher
  resets `launchEulaByHome` the moment anything sets it.
- **LG account terms** (LG Account Terms of Use and Privacy Policy, Smart
  Media Product Membership Privacy Policy). A signed-in LG account signs
  itself in again at every restart, and `accountmanager` then checks the
  account's terms with LG's servers and opens `com.webos.app.membership`
  (it asked again at every restart on the reference TV). There is no local
  switch for "keep the account but don't sign in automatically", and Own
  Your Glass does not close LG's screen behind your back. Instead the main
  screen says **LG Account signed in**, and Settings offers **Sign out**
  (the account stays on the TV) or **Remove account** (the TV forgets it):
  either stops the prompt and stops LG tying what the TV does to your
  account. The Content Store then asks you to sign in before it installs an
  app. The "Block LG account" option removes any account and sinkholes LG's
  sign-in page and account server, so none can sign in again (the sign-in
  screen shows a network error; turn the option off to sign in).

## Reboots

Protections are re-applied on every boot (binds and stopped services do not
survive a reboot on their own). A crash-loop breaker guards this: the boot
hook writes a marker before applying and clears it once the TV's UI has been
up for two minutes or the app has read the status. A boot that never gets
that far is not confirmed; one is ordinary (the TV switched off again within
minutes), and two in a row switch re-apply off (a toast says so when
Notifications are on). The main screen then shows **Not re-applied at
start-up** and Settings > **Re-apply at start-up** turns it back on
(`oyg persist on`). `oyg persist off` turns it off by hand (then a restart
brings the stock TV back and you press Own the glass again). Homebrew
Channel's own failsafe mode sits underneath all of that.

### Notifications

Own Your Glass works silently by default. Settings > **Notifications**
(`oyg toasts on|off`) turns on the short messages it puts on the TV screen:
protections re-applied at start-up, collected data cleared, the TV restored
after an uninstall.

### Restarts the TV needs

A few changes only finish after a restart, and the app says so (**Restart
required**, with Restart now or Later):

- turning **Phone apps** off again: LG's phone server starts only with the TV;
- turning **Screen Share** off again: Miracast connects again only after a
  restart;
- showing an app again that an option had hidden (LG Channels): the TV reads
  its hidden-app list only when it starts;
- JS services that were already loaded when an option blocked them (DIAL,
  for one) keep running until the next restart.

## Undo

- **Give the glass back** (Settings) restores every change and keeps the app.
  Nothing is re-applied at start-up until you press Own the glass again.
- **Restore and uninstall** restores, then removes the app.
- Undo is faithful, so it also puts back what "Remote support and root
  hygiene" had closed: Homebrew Channel's telnet root shell (port 23, no
  password) is allowed again if Homebrew Channel has it on, and its files
  go back to world-writable. The log and a toast say so (this toast is
  shown even with Notifications off).
- Uninstalling from Homebrew Channel also works: on the next boot the hook
  restores the TV and deletes itself.

## Command line

The toolkit also runs from an SSH shell. Everything the app does is
`oyg <command>`:

```sh
oyg status                  # fast, safe to poll
oyg options                 # every option, and whether it is on
oyg preset strict           # choose recommended, strict or custom, and apply it
oyg set hbbtv=on voice=off  # change your Custom selection and apply it
oyg apply                   # apply the current selection again
oyg restore [option...]     # undo (everything, or the named options)
oyg persist on|off          # re-apply on boot (default on, crash-loop breaker armed)
oyg toasts on|off           # messages on the TV screen (default off)
oyg try lan                 # apply an option for a test only: Re-apply or a restart undoes it
oyg lan allow 192.168.1.50  # let one device through the LAN firewall (oyg lan list, oyg lan deny)
oyg untested on|off         # also apply what is not yet verified on a TV (Settings > Untested protections)
oyg purge                   # delete collected ad, diagnostic and voice data; reset the advertising ID
oyg survey                  # a report on this TV and which services it has (no IDs)
oyg survey usb              # the last report, as it is, saved to USB storage as a .txt
oyg account status          # is an LG account signed in (yes or no, never the id)
oyg account signout|remove  # sign out of it, or remove it from the TV
oyg reboot                  # restart the TV (some undos wait for one)
oyg uninstall               # restore, remove hook and state
OYG_DRYRUN=1 oyg apply      # print what would change, change nothing
```

To try it without installing anything:

```sh
tools/bundle.sh | ssh root@<tv-ip> 'OYG_DRYRUN=1 OYG_ROOT=/nonexistent sh -s -- apply'
```

## Servers LG picks at runtime

Some of what the TV talks to is not in its firmware: LG's gateway hands the
addresses out at runtime, and they differ by region. Own Your Glass can only
block names it has seen, so a TV in another region may reach servers that
are not in `kb/hosts.toml` yet. Names that carry LG's region code are
sinkholed for every region LG uses (`aic`, `eic`, `kic`, `cic`, `ruc`);
names that carry the country code use your TV's country once LG's gateway
has reported it, and until then every country LG serves (the app shows a
notice and a toast, and the next apply narrows it down). On the reference
TV (Australia, LG's "KIC" region) a router's DNS log showed:

- `www.ueiwsp.com`: UEI's QuickSet cloud, which Universal Control uploads
  the signatures of your devices to. Blocked by "Universal Control cloud
  lookups" (devices keep working, and new ones still set up).
- an AWS IoT (MQTT) endpoint in LG's Seoul region, looked up every few
  minutes together with LG's gateway, also with no app open. Which program
  asks is not proven yet, so it is noted here rather than blocked, and the
  exact name is left out: it may be specific to one region or set-up.
- For about the first 50 seconds after power-on, before the boot hook has
  applied anything, the TV already looks these up.

To see your own TV's lookups, turn on your router's DNS query log and filter
it by the TV's address (on OpenWrt: `uci set dhcp.@dnsmasq[0].logqueries='1';
uci commit dhcp; /etc/init.d/dnsmasq restart`, then
`logread -f | grep 'from <tv-ip>'`; set it back to `0` afterwards). Names
that are new, especially regional ones, are worth reporting.

## Safety notes

- Never flash the kernel, rootfs or TVService. This toolkit never writes to a
  system partition; it only bind-mounts, stops services and edits files under
  `/var`, `/mnt/lg` and `/media`.
- `sdx`, `tvdataexchanger`, `eplmanager`, `captureservice`, `iconnectivity`
  (Universal Control), ConnMan, the interpreters and `/dev/hidraw*` are on a
  hard never-touch list (`kb/services.toml`, checked in CI). Binding `sdx`
  silently kills the Settings UI (its routing table is rewritten instead);
  touching ConnMan has taken a TV off the network for half an hour.
- A call to a stopped **static** service waits for it (a blocked
  `voiceconductor` never answered, and Settings waited on it); a call to a
  blocked on-demand service fails at once. That is why `voiceconductor` and
  the `voiceinput` hub are left running, and why every change is checked on
  a TV against Settings, Date & Time and Home before it joins a preset.
- Firmware updates are not blocked here. Homebrew Channel has that toggle.
- Not a defence against an attacker who already has root.
- Opening the app for the first time is itself noted by LG's usage logger
  (an `NL_FIRSTUSE` line with the app's id) before anything is applied, and
  under the TV's existing consents that one line can go out.

## Repository layout

```
app/        webOS app (appinfo.json, index.html, app.js, style.css, icons)
toolkit/    oyg, boot-hook, lib/ (engine), hooks/ and resources/,
            etc/ (generated from kb/)            (bundled into the ipk)
kb/         the service knowledge base: every option, service, gateway name,
            hostname, setting and app OYG handles, with what it does, what
            breaks, and on which webOS releases it exists (tools/kb.py)
tools/      build-ipk.sh, deploy.sh, bundle.sh, kb.py,
            spec-check.py (resolves the knowledge base against extracted LG firmware)
tests/      run.sh (the toolkit under BusyBox sh), test_kb.py (the knowledge
            base's safety rules)
docs/       DESIGN.md, HOMEBREW.md, RESEARCH.md (what was learned about the
            TVs, and how), COMPATIBILITY.md (generated from kb/)
```

## Credits

This project exists because of other people's work:

- **Gamers Nexus** — the *Data Dragnet* investigation into LG smart TVs
  ([216,000,000 Spy TVs | The LG Smart TV Problem](https://www.youtube.com/watch?v=6IFVTcM28KA),
  with Level1Techs and independent researchers) is the source of the threat
  model here: ACR, standby audio capture, plaintext voice transcripts, network
  discovery and the upload paths. Every option maps back to something that
  investigation showed.
- **Julio Ferrero's [own-your-glass](https://github.com/JulioFerrero/own-your-glass)**
  (MIT) — the original toolkit of the same name and its verification report
  on a 2025 LG B5, the first of this work done on real hardware, were the
  starting point. This project keeps the name and several mechanisms that
  report established: `/dev/null` bind mounts over binaries, the
  `/etc/hosts` overlay, the hidden-apps list, the `luna-send` stdin trap,
  and never touching `sdx` or ConnMan. Since then the implementation has
  diverged: this is a Homebrew Channel app with an option engine, presets
  and per-option undo; its service list comes from a survey of 25 firmware
  images with each entry re-verified on a C5; consents go through LG's
  settings service; and LG's gateway is handled by rewriting its routing
  table. Where the two differ, it is the result of that later work, and
  none of it would have started without the original.
- **[webosbrew](https://github.com/webosbrew)** — Homebrew Channel, its root
  service (`org.webosbrew.hbchannel.service/exec`), the boot hooks in
  `/var/lib/webosbrew/init.d` and the rooting guides. Nothing here would run
  without it.
- **[lg-tv-blocklist](https://github.com/furkan-bayrak/lg-tv-blocklist)**
  by furkan-bayrak (CC BY 4.0) — part of the hostname list in
  `kb/hosts.toml`.

MIT licence.

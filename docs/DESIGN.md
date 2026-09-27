# Design

## Goals

1. **Kill at the source.** Stop the ACR, advertising, telemetry, remote-support
   and voice daemons and make them unable to start again. DNS blocking is a
   secondary layer.
2. **Homebrew Channel packaging.** One `.ipk`, installable from Homebrew
   Channel or with `luna-send`, containing the TV app and the toolkit.
3. **Reversible by uninstalling.** Removing the app removes every change,
   even changes that survive a reboot.

## How root works

The app is a plain webOS web app. It never has root itself. Every action is a
call to Homebrew Channel's root service
(`luna://org.webosbrew.hbchannel.service/exec`) that runs `oyg <command>` from
the toolkit bundled inside the app directory. Long jobs are started with
`nohup … &` and write to a log the app tails, so closing the app does not
kill a job and reopening it shows what happened.

## The toolkit

`toolkit/oyg` is POSIX `sh` for the BusyBox shell on the TV. What it does is
organised as **options**: the toggles the app's Customize screen shows and
the presets (Recommended, Strict, Lockdown) are made of. What each option
contains comes from the knowledge base (`kb/*.toml`), generated into
`toolkit/etc/options.sh` by `tools/kb.py gen`:

| content | what the engine does with it |
|---|---|
| `spec` | services to block (`lib/svc.sh`); `released` = ones it used to block |
| `settings` | system settings set through settingsservice (`lib/settings.sh`) |
| `hook` | code for what is not declarative (`hooks/<name>.sh`: mic, capture, remote, nag, consents, voice, diagnostics, lan, phone, miracast, account) |
| `sdx`, `hosts`, `apps` | contributions to the shared resources |

The **resources** are built from the union of the applied options'
contributions and rebuilt after every change: LG's launch block list, the
gateway table (`resources/sdx.sh`), `/etc/hosts` (`resources/network.sh`)
and the hidden-app list (`resources/apps.sh`).

The owner's selection is a preset or their one Custom set (`$OYG_ROOT/preset`,
`$OYG_ROOT/custom`: explicit choices over a base preset, so an option a later
version adds follows that preset). `oyg apply` brings the TV to the
selection: it restores every scope with records that is not selected, applies
every selected option, then rebuilds the resources. Entries not yet verified
on a TV are generated into separate lists and left out unless
`oyg untested on`; an option that is not yet verified stays out of the
presets but can be turned on in Customize.

Each option is also a **state scope**: everything it changes goes through
helpers in `toolkit/lib/common.sh` that record the change in
`/var/lib/own-your-glass/state/<kind>.<option>`:

| helper | what it records | how restore undoes it |
|---|---|---|
| `bind_null`, `bind_file`, `bind_file_ro` | `mounts` (and the read-only peers) | `umount` |
| `set_mode` | `modes` (path + original mode) | `chmod` back |
| `backup_once` | `files` + a pristine copy in `backup/` | copy back |
| `mark_created`, `mark_moved` | `created`, `moved` | `rm`, `mv` back |
| `state_add immutable` | files made `chattr +i` | `chattr -i` first |
| `state_add chains` | iptables chains jumped to from INPUT | delete |
| `stop_unit`, the kill pass | `units` (only those that were active, including the unit a killed process ran under) | `systemctl start` |
| the kill pass | `relaunch` (on-demand LS2 services that were running) | one call with an unknown method, which starts the service |
| `state_add ls2` | names for the launch block list | dropped; the list is rebuilt |
| `kv_set` | key/values (previous settings, consent flips) | settings and consents put back |

Because restore is driven by these records, `oyg restore` does not need the
option that made a change to still exist or to know what firmware it ran on:
an option a later version renames or drops is undone the same way.
Restore takes the mounts off first: a file mode or a created file belongs to
what is under a bind, and a `chmod` through a bind lands on `/dev/null`
(1.2.x did exactly that to `/dev/null` on a manual re-apply of `mic`). A bind
that cannot be undone keeps its record for the next restore.

Settings and consents are not files OYG edits: they go through LG's settings
service (`lib/settings.sh`, `lib/eula.sh`), which keeps its cache and the md5
sidecar bootd checks consistent. Only the values OYG changed are recorded,
and restore puts back only those.

### The service engine

`toolkit/lib/svc.sh` neutralises a service in passes over a spec
(`id|unit|binary|comm|argmatch|ls2|flags`), skipping whatever does not exist
on the TV:

1. `mount --bind /dev/null <binary>` so `systemd`, `ls-hubd` (luna-launched
   services) and activities cannot exec it again. The path is resolved
   first: `mount` follows symlinks, so a link to a differently named file (a
   BusyBox applet) is refused. Some daemons run chrooted in
   `/var/palm/jail/<id>`, whose `/usr` is an overlay of the pristine `/usr`
   set up with the jail; the copy in an existing jail is bound too.
2. The service's LS2 name goes on LG's own launch block list (see below).
3. `systemctl --no-block stop` for the active units, in one call
   (remembering which were active); optionally mask them by binding
   `/dev/null` over the unit file (`OYG_MASK_UNITS=1`; off, not verified on
   hardware).
4. One kill pass: every running process that matches an entry by executable
   (a jailed copy counts), by process name or by command line. The process
   list is `ps -e` plus the `/proc/<pid>/exe` links: plain `ps` over ssh or
   from a service lists only root's processes, which is how 1.2.x missed the
   jailed voice performer and ThinQ AI adapter. Before killing, it records
   what undo needs to bring back: the systemd unit a process runs under
   (from `/proc/<pid>/cgroup`, when that unit's `ExecStart` is the same
   binary), and every running on-demand LS2 service, which nothing may
   start again on its own (Universal Control stayed dead after an undo).
5. `systemctl reset-failed` for what was stopped, and any crash-report
   trigger a daemon left while going down is dropped, so `rdxd` never uploads
   it.

Undo runs in the opposite order: the option's names leave the launch block
list first (a daemon that is restarted may call them at once: Chromecast's
provisioning gives up on its receiver when the bus refuses), then binds go,
recorded units start, and each recorded on-demand service is called once
with an unknown method, which makes the bus start it.

### LG's launch block list

`ls-hubd` starts every on-demand (`Type=dynamic`) Luna service through
`/usr/bin/run-service` (webOS 10 and later), which exits before the jailer
and before the binary if the service's first LS2 name is in
`/var/preferences/servicemanager/blocked-services.json`. LG uses it for the
sign-language avatar. OYG keeps LG's entries, adds the names of every
dynamic service it blocks, and binds the result read-only (servicemanager
rewrites the file at boot). It covers what a bind on `/usr` cannot: jails set
up after apply, services installed on `/media/system`, and JS services that
load into the shared JS server. It cannot stop static services, and a small
deny list (`ls2_denied`) keeps it away from anything Settings, Home or the
bus itself waits on.

JS services loaded into the shared JS server (`run-js-service -u`: DIAL,
`homeconnect`, `sportsalert`) cannot be unloaded or killed without killing
the phone remote API and Settings' own services with them. If one loaded
before the boot hook ran, it stays until the TV restarts; status reports it
as `RESIDENT`, not as blocked.

Binds do not touch the read-only vendor filesystem and disappear on reboot,
which is why the boot hook exists.

### Lessons from the reference TV

Three of the B5 report's labels turned out wrong on the C5 and cost real
features before they were caught: `iconnectivity` is the Universal Control
service, not a phone helper; the `voiceinput` LS2 hub is queried by Settings
at launch (8 s timeouts while dead); and most ALSA "capture" nodes are
internal routing (`pcmC0D10c` feeds Bluetooth, LE audio, WiSA and sound
share; `pcmC0D11c` is the broadcast recorder tap), not microphones. The
rule that came out of it: neutralise a binary only when the TV's own
registry (`/usr/share/luna-service2/roles.d`, the driver names in
`/proc/asound/pcm`) says what it is, and time the main screens applied
versus restored after any change to a spec.

## Never-touch list

`bind_denied` in `common.sh` refuses to neutralise interpreters and launchers
(`sh`, `luna-send`, `iotjs`, `node`, `jsservicelauncher`, `flutter-client`),
`ls-hubd`, `sdx` (binding it silently breaks the Settings UI), `tvdataexchanger`,
`pacrunner`, `crashd`, `eplmanager`, `captureservice` and `/dev/hidraw*`.
`iconnectivity` (`com.webos.service.ics`: Universal Control and the IR
blaster) is on a softer list: refused unless the option being applied is one
only Lockdown carries (the knowledge base checks the same rule).
It also refuses BusyBox, `python3`, `run-js-service`, `run-service`,
`jailer`, `socat` and systemd itself, and anything whose path resolves to a
differently named file. ConnMan is never signalled, reloaded or restarted.

## LG's gateway (sdx)

Most of the TV reaches LG through one daemon, `sdx`. A caller asks
`luna://com.webos.service.sdx/send` for a service name and a path, and `sdx`
makes the HTTPS request, adding the device ID (derived from the MAC), the
`fck` key, model, firmware, locale and consent state as headers. The host
comes from its routing table, `/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf`,
which LG's server refreshes: 38 service names on a C5, each with a domain and
a domain type. `sdx` puts the TV's country code (`<CC>.`) in front of `default`
domains and a regional code (`<RIC>.`) in front of `ric` ones; `getServerUrl` reports the
result for any name.

`sdx` cannot be stopped (see the never-touch list), and several of its
callers cannot either: PmLogDaemon logs through `sdp_logging` and
`rdxdev_secure`. So the gateway resource edits the table, not the callers:
blocked names get the domain `oyg.invalid` (`.invalid` never resolves), and
the rewritten file is bound read-only over the live one so a server push
cannot restore it. The file shows up under several mounts
(`/mnt/lg/{cmn_data,cache,flash/data,user}`, and inside jails); every one of
them is made read-only, and status fails if one is writable or if the bound
table's md5 changed. The table is parsed without assuming key order or
layout: LG's factory copy is pretty-printed, its server push is one line,
and webOS 11 adds a second (China) group. `sdx` reads the table when it
starts and `ls-hubd` restarts it on the next call, so apply and restore end
the process, but only when the table changed (every `sdx` start stacks
another tmpfs on its package directory), and never while the TV is still
booting (`accountmanager` checks the terms status through `sdx` at boot):
at boot the table is bound at once and the restart waits in the background.

The kept names are the ones the Content Store, AirPlay and Settings were
found to use: the store's loader asks `sdx` for request headers and loads
the store from `<country>.app.lgwebostv.com`, `airplay-adaptor` uses
`sdp_init`, `mfi` uses `sdp_airplay`, and Settings uses `ibis_secure` and
`service_setting_secure`. The clock needs `sdx` too: with Settings > Date &
Time > Set automatically on, the TV's time sources are
`["sdp","broadcast-adjusted","broadcast","micom"]` (no NTP; LG ships
`AllowNTPTime` off), and on the C5 the source in use is `sdp`. With it off,
the time service ignores every outside source and keeps time on the micom
real-time clock, reported as `factory`.

The hosts resource reads the same table to find the hosts that only
blocked names use (`<CC>.rdx2.nextlgsdp.com`, `<CC>.ibsstat.nextlgsdp.com`,
`<RIC>.api.lgtviot.com`, `<RIC>.pnv.lgtvcommon.com` on the reference C5), so its
sinkhole follows the TV's region instead of a fixed list.

Region-coded names (`{ric}.`) are written for every region LG's own
service tables name (`aic`, `eic`, `kic`, `cic`, `ruc`) and need nothing
learned. Country-coded names (`{cc}.`) and the table-derived hosts take the
TV's own codes once `sdx` has reported them; until then (a first apply
while `sdx` is silent) they are written for every country LG serves, from
the TV's own `/etc/palm/countryList.json` plus the knowledge base's copy
(`kb/hosts.toml` `[codes]`), and the log, a status line and a toast say so.
The never list keeps the gateway hosts out whatever the prefix.

## The one watcher

Everything else is fire-and-forget, but the "Terms prompts" option keeps a
small shell watcher alive (`/var/lib/own-your-glass/nag-watch.sh`, restarted
on every apply and at boot, stopped on restore, started with `setsid` and
stopped by its own process group, never by a matching command line: other
programs subscribe to the same Luna calls). It subscribes to the
`launchEulaByHome` system setting and resets it to false whenever it flips
true (that flag is what makes the Home app raise the User Agreements wall).
`eula-service` itself is left running: neutralising it made SDX's eula
status fail.

## The LG account

A stored LG account signs itself in at every boot (nothing in `loginAccount`
says "don't"), and `accountmanager` then checks the account's terms with
LG's account server over HTTPS and opens `com.webos.app.membership` when it
wants them agreed. That check cannot be satisfied or faked locally, and
closing LG's screen behind the owner's back left them on Home without their
input. Instead:

- `oyg status` says `META|account|1` while an account is signed in
  (`getLoginID {"serviceName":"LGE"}` returns an id; only the yes/no is
  used), and the app shows **LG Account signed in**.
- Settings offers Sign out (`logoutAccount` mode `shallow`, what the TV's
  own account page sends: the account stays listed) or Remove account (mode
  `deep`: the TV forgets it). The user number the call needs stays inside one
  command.
- The "Block LG account" option removes any account and sinkholes the
  sign-in page (`{cc}.membership.lgwebostv.com`), the account server
  (`{cc}.emp.lgsmartplatform.com`) and the API it called
  (`{cc}.lgeapi.com`). The sign-in screen shows its network-error page; the
  Content Store still browses but cannot install.

## Restarts the TV needs

Some undos only take full effect after a restart, and the app says so
("Restart required", with Restart now / Later; `oyg reboot` goes through
LG's power service):

- **Phone apps.** LG's second-screen gateway stops its server when
  `allowMobileDeviceAccess` goes off but starts it only once per run; if the
  setting was turned off in this boot, turning it back on needs a restart.
- **Screen Share.** Miracast started again after an undo is listed but
  cannot connect until the TV restarts.
- **Hidden apps.** The app manager reads the hidden-app list only when it
  starts, so an app shown again (LG Channels) comes back after a restart.

Pending reasons live in `$OYG_ROOT/restart` under the boot time
(`/proc/stat` `btime`): LG TVs resume a saved boot image, so the kernel's
`boot_id` is the same after every restart.

## Trials

`oyg try <option>...` applies options without selecting them. The next apply
(Re-apply, a preset change, saving Custom) undoes them because they are not
selected, and the boot hook undoes them before anything else, so a trial
never outlives a restart. It is how the Lockdown options were tested.

## Boot and uninstall

`oyg install` copies the toolkit to `/var/lib/own-your-glass/toolkit` and drops
`/var/lib/webosbrew/init.d/own-your-glass`, which Homebrew Channel runs as
root on every boot. The hook detaches `oyg boot` (so a hang can never delay
Homebrew Channel's startup). If the app directory carries a toolkit of
another version (an update from Homebrew Channel that nobody has opened
yet), the boot hands over to that one, which installs itself; a fix for a
harmful entry used to reach the boot only once a button was pressed. Then
it does one of these things:

- if the app directory is gone (uninstalled from Homebrew Channel): restore
  every recorded change, delete the state directory and the hook itself;
- if the glass was given back (`given-back`, written by a full `oyg restore`
  and removed by the next apply): nothing, until Own the glass is pressed
  again. A give-back used to last only until the next restart;
- if persistence was turned off (`oyg persist off`, or by the breaker below):
  nothing. Binds and stopped services do not survive a reboot, so the TV is
  stock again until Own the glass is pressed;
- otherwise (the default): write `boot.unconfirmed`, undo any trial
  (`oyg try`), raise the shared layers
  first from what was applied before the reboot (the launch block list, the
  sinkhole, the gateway table; `sdx` restarts once the boot is done), apply
  the selection, clear the marker two minutes after the boot manager
  reports the UI up (or as soon as the app reads the status), then take a
  second pass for what appears late (jails set up after the hook,
  luna-launched daemons). If the marker is still present at the next boot,
  the previous boot never got that far. That is ordinary once (the TV was
  switched off again within minutes, which a fixed five-minute timer used
  to count as a crash), so the marker counts unconfirmed boots: the second
  in a row switches re-apply off (`nopersist` holds `breaker`), a toast says
  so, nothing is applied, and the app shows it with a Settings control to
  turn it back on.

The late pass runs only while there is still something to re-apply: the
app and the hook are there, re-apply is on and options are applied. A
give-back or an uninstall in the six minutes after boot leaves nothing for
it to do (once, it re-applied Recommended into a TV whose toolkit was
already gone). Every mutating command, uninstall included, holds one lock
(`/var/lib/own-your-glass/lock`), which names its holder's pid and boot: a
lock left by a power cut, or whose pid now belongs to something else, is
stale and taken over; a live holder is waited for.

On the owner's C5 the hook starts about 28 s after boot and is done 14 s
later; the late pass changes nothing.

So the persistent changes (consents, settings, the hidden-apps list, the
telnet flag, file modes on the Homebrew Channel tree) are undone on the first
boot after an uninstall, and the runtime changes (mounts, stopped services)
are already gone because they never survived the reboot.

The app's own "Restore and uninstall" button does the same without waiting
for a reboot: restore, remove the hook and state, then ask
`com.webos.appInstallService` to remove the app, wait until it is gone, and
delete OYG's files in `/tmp` once the app's job has ended, and toast the
outcome (the app is closed by then). It closes the app before restoring,
because LG's `service-logger` notes the app in front when it starts (its
first-use list, `/var/firstUseAppInfo.json`, and an `NL_FIRSTUSE` log
line), and the restore starts it. The app comes off that list before the
restore. LG's rule (`getFirstUseAppInfo.py`) reads the file on every
foreground change and holds nothing in memory, so the edit is enough; its
filter is meant to skip Home, yet on the C5 the restart added Home, so the
ids are noted before the restore and any id the restart adds is taken off
again once the list has changed (or after 10 s). Each edit keeps the
file's time (`cp -p` and `touch -r`: the BusyBox on webOS 5.6 has no
`date -r`).

Three webOS files would still name the app afterwards, and both uninstall
paths clean them. WAM's `AppsOrigins` lists the origins each web app reached, and LG
Channels reaches `https://<prefix>.oyg.invalid/` while the sdx table is
rewritten. Those origins are deleted whenever the sdx routing is restored.
The installer deletes the app's row from its `installHistory2.db`, but SQLite
leaves a deleted row's bytes in the page. So each file that still holds the
app's id or the placeholder anywhere is rebuilt with `VACUUM`. The app also
comes off LG's first-use list, which picks it up whenever the app is opened
while `service-logger` runs. The file is deleted if it held only the app. WAM's
LocalStorage is not touched: the app keeps nothing there. On removal, WAM
writes a deletion marker that names the app's origin, and LevelDB drops that
marker at its own next compaction. Forcing the compaction would mean stopping
WAM, which blanks the TV.

App jails keep their own copy of `/etc/hosts`. The restore puts back the
copies OYG wrote. A jail that webOS sets up while the sinkhole is bound
copies the sinkhole itself, and versions before 1.4 left their marked block
in jails too; neither kind of copy is on record. So the restore also takes
the `# own-your-glass begin`…`end` block out of every jail's hosts file. The
sinkhole is the stock file plus that block, so what is left is the stock
file, and each file keeps its time. Apply treats a jail whose block is older
than the current one the same as a jail without one: the copy is recorded
and rewritten, so the sinkhole in every jail follows the selection.

If a firmware update takes away root or Homebrew Channel, the hook never runs
again. Then nothing is restored or deleted, and nothing without root can do it.

### Upgrading from module-based versions (1.2, 1.4.0–1.4.3)

Those kept their records per module. The first run of the option engine
moves each record to the option that owns its path, unit, LS2 name or setting
(`toolkit/etc/owners.txt`, generated from the knowledge base), splits the
recorded settings by owner, and selects Recommended. It never restores and
re-applies on the way: flipping consents back, even for a moment, could make
eula-service report an acceptance to LG. Records no option owns (services
those versions blocked and the options no longer do) are restored.

## Actions that are not options

`oyg purge` (Settings > Clear collected data) deletes what the collectors
had already gathered and resets the advertising id; it records nothing for
restore, on purpose. While Opt-out advertising ID holds the ID at zero, the
reset is skipped. `oyg survey` (Settings > Generate a TV report) prints a
report on the TV: OYG, webOS and firmware versions, model, LG's service
country and region, chip, CPUs and memory, OYG's selection, which
knowledge-base services and apps exist, the gateway table's names, and
system LS2 services the knowledge base has never seen. It reads files only
and never prints a MAC, serial, IP, SSID, account or device ID.
The report is kept in `/tmp/.own-your-glass-app/report.txt` (a root-only
directory the app and the toolkit share; `/tmp` is seen by every app jail,
so nothing of OYG's in it has a guessable name outside it), which is what the
app shows; `oyg survey usb` (Copy to USB storage on the report screen)
copies that file as it is (a new report if there is none) to the first USB
storage the TV has mounted (`/tmp/usb/<disk>/<partition>`) as
`oyg-report_<model>_<country>_webOS<version>_fw<firmware>.txt`.
`oyg persist on|off` toggles the boot re-apply.
`oyg toasts on|off` (Settings > Notifications) lets `toast` put OYG's
messages on the TV screen; they are off by default (`$OYG_ROOT/toasts` exists =
on), and the uninstall carries the choice past the removal of `$OYG_ROOT`
for its last message. The one toast that ignores the setting
(`toast_always`) is the root-hygiene undo: it hands back a password-less root
shell, which the owner must hear about.

## Unknown firmware

`OYG_KB_GENS` lists the webOS releases the knowledge base was checked
against. On any other release the toolkit applies only what it recognises:
an entry is skipped when its executable is found only through a unit, or its
LS2 registration no longer has the launch model the knowledge base expects.
Status and the app say "Own Your Glass does not recognise your TV's
software. Everything recognised can be applied still. Keep an eye out for
Own Your Glass updates."

`OYG_KB_RUN` (from `kb/services.toml`, `run_on`) lists the releases Own
Your Glass has actually been run on: 10.3, the C5. Surveyed firmware says
what exists, not what waits on what, and a stopped static service holds
its callers (nudge for 15 s, voiceconductor for ever, both found on the
C5). So on a known but not-yet-run release the static entries (`L=static`)
are left running, status reports them as `SKIP`, and the app shows "Own
Your Glass knows your TV's software from LG's firmware but has not run on
it yet: LG's always-on services are left running unless Untested
protections is on." That switch (`oyg untested on`, the same flag that
includes the knowledge base's unverified entries) applies them anyway,
followed by a re-apply; the owner is then the first to try them, and the
crash-loop breaker is the net. A release joins the list once someone has
timed Settings, Home and Date & Time on it with the presets applied.

## Status output

`oyg catalog` prints the categories, presets and options once (`CAT|…`,
`PRESET|…`, `OPT|id|category|name|what|breaks|presets|warning|untested`).
`oyg status` prints one `META|key|value` block (including `preset`,
`generation`, `known`, `blocklist|<state>|<n>`, and when they apply
`restart|<reasons>`, `trial|<options>` and `account|1`), then per option
`OPT|id|selected|applied` followed by `ID|LEVEL|text` lines, then the shared
resources (`RES|name` and their lines). `LEVEL` is `OK`, `WARN`, `FAIL`, `NA`
(this entry is not on this TV), `RESIDENT` (loaded into the shared JS
server before OYG ran; nothing new can load, it goes at the next restart)
or `SKIP` (a static service left running on a release not yet run on a TV).
The app parses this; so can a script.

## What this does not do

- It is not a defence against someone who already has root.
- The first time the app is opened, LG's `service-logger` notes it
  (`NL_FIRSTUSE`, with the app's id) before anything can be applied. Under
  the TV's existing consents that one line can go out; nothing undoes it.
- The boot hook runs 10 to 30 s after LG's daemons start. Whatever they send
  in that window (seen: `PmLogDaemon` through the gateway, `service-logger`'s
  first rules, the push client's certificate renewal, and in a router's DNS
  log UEI's cloud, the Hue lookup and an AWS IoT endpoint) is not stopped;
  the launch block list and the gateway rewrite, both in place from the
  first seconds of the hook, shorten it. A router-level DNS block covers it;
  an experimental early layer is planned.
- Some servers are handed out at runtime and differ by region, so a TV
  elsewhere may reach names the knowledge base has not seen (README,
  "Servers LG picks at runtime").
- The only packet filter is the opt-in LAN firewall (every inbound
  connection, SSH included unless a device is on its allow list; IPv4 only:
  these kernels have no IPv6 netfilter, so IPv6 is switched off while it is
  on). There is no egress
  filter; LG's gateway is handled by its routing table and hostnames by
  `/etc/hosts`.
- It does not disable firmware updates. Homebrew Channel already has that
  toggle, and whether to take LG's kernel patches is the owner's call.

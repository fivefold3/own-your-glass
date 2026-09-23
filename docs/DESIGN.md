# Design

## Goals

1. **Kill at the source.** Stop the ACR, advertising, telemetry, remote-support
   and voice daemons and make them unable to start again. DNS blocking is a
   secondary, opt-in layer.
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

`toolkit/oyg` is POSIX `sh` for the BusyBox shell on the TV. Modules live in
`toolkit/modules/<name>.sh` and each implements three functions:

| function | contract |
|---|---|
| `mod_<name>_apply` | idempotent; records everything it changes |
| `mod_<name>_restore` | undoes what was recorded, usually just `generic_restore` |
| `mod_<name>_status` | prints `MODULE\|LEVEL\|text` lines; must be fast and must never call `systemctl` |

Everything a module changes goes through helpers in `toolkit/lib/common.sh`
that record the change in `/var/lib/own-your-glass/state/<kind>.<module>`:

| helper | what it records | how restore undoes it |
|---|---|---|
| `bind_null`, `bind_file` | `mounts` | `umount` |
| `set_mode` | `modes` (path + original mode) | `chmod` back |
| `backup_once` | `files` + a pristine copy in `backup/` | copy back |
| `mark_created`, `mark_moved` | `created`, `moved` | `rm`, `mv` back |
| `stop_unit` | `units` (only those that were active) | `systemctl start` |
| `kv_set` | per-module key/values (e.g. previous settings) | module-specific |

Because restore is driven by these records, `oyg restore` does not need the
module that made a change to still exist or to know what firmware it ran on.

### The service engine

`toolkit/lib/svc.sh` neutralises a service in four steps, skipping any step
whose target does not exist on the TV:

1. `systemctl stop <unit>` (remembering whether it was active),
2. optionally mask the unit by binding `/dev/null` over its unit file
   (`OYG_MASK_UNITS=1`; off, not verified on hardware),
3. `mount --bind /dev/null <binary>` so `systemd`, `ls-hubd` (luna-launched
   services) and activities cannot exec it again,
4. kill whatever is still running, by exact executable path, by process name,
   or by a substring of the command line for node/iotjs services.

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
`iconnectivity` (`com.webos.service.ics`: Universal Control and the IR
blaster; binding it broke external-speaker control and slowed Settings),
`pacrunner`, `crashd`, `eplmanager`, `captureservice` and `/dev/hidraw*`.
`com.webos.app.overlaycontainer*` is never hidden (it hosts the quick-settings
panel). ConnMan is never signalled, reloaded or restarted.

## The one watcher

Everything else is fire-and-forget, but the `nag` module keeps a small
shell watcher alive (`/var/lib/own-your-glass/nag-watch.sh`, restarted on
every apply and at boot, stopped on restore). It does two things: subscribes
to the `launchEulaByHome` system setting and resets it to false whenever it
flips true (that flag is what makes the Home app raise the User Agreements
wall), and polls the system log for SAM's launch record of
`com.webos.app.membership` with `accountmanager` as the caller, closing that
app when it appears (the LG account terms prompt). Both are "close the door
again" measures, because the services that open them cannot be stopped
without side effects: neutralising `eula-service` made SDX's eula status
fail, which is exactly what triggered the account prompt every boot.

## Boot and uninstall

`oyg install` copies the toolkit to `/var/lib/own-your-glass/toolkit` and drops
`/var/lib/webosbrew/init.d/own-your-glass`, which Homebrew Channel runs as
root on every boot. The hook detaches `oyg boot` (so a hang can never delay
Homebrew Channel's startup), which does one of three things:

- if the app directory is gone (uninstalled from Homebrew Channel): restore
  every recorded change, delete the state directory and the hook itself;
- if persistence was turned off (`oyg persist off`, or by the breaker below):
  nothing. Binds and stopped services do not survive a reboot, so the TV is
  stock again until Own the glass is pressed;
- otherwise (the default):
  write `boot.unconfirmed`, apply the enabled modules, clear the marker after
  five minutes (or as soon as the app reads the status), then take a second
  pass for the luna-launched daemons that appear late. If the marker is still
  present at the next boot, the previous boot never got that far: persistence
  is switched off, a toast says so, and nothing is applied.

So the persistent changes (consent stores, the hidden-apps list, the telnet
flag, file modes on the Homebrew Channel tree) are undone on the first boot
after an uninstall, and the runtime changes (mounts, stopped services) are
already gone because they never survived the reboot.

The app's own "Restore and uninstall" button does the same without waiting
for a reboot: restore, remove the hook and state, then ask
`com.webos.appInstallService` to remove the app.

## Actions that are not modules

`oyg purge` (Settings > Clear collected data) deletes what the collectors
had already gathered and resets the advertising id; it records nothing for
restore, on purpose. `oyg persist on|off` toggles the boot re-apply. Both
live in `toolkit/lib/purge.sh` and `toolkit/oyg` rather than in a module
because they are one-off and have no "status".

## Status output

`oyg status` prints one `META|key|value` block, then for each module a
`MOD|name|on/off|description` line followed by `NAME|LEVEL|text` lines with
`LEVEL` in `OK WARN FAIL NA OFF`. The app parses this; so can a script.

## What this does not do

- It is not a defence against someone who already has root.
- There is no packet filter layer yet. `iptables` was found working on a
  2025 LG OLED (the earlier B5 report found none); an `iptables`-based egress
  module is a natural next step.
- It does not disable firmware updates. Homebrew Channel already has that
  toggle, and whether to take LG's kernel patches is the owner's call.

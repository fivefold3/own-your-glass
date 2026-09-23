# Packaging and installing through Homebrew Channel

## Build

```sh
tools/build-ipk.sh
```

produces `dist/org.ownyourglass.app_<version>_all.ipk` plus a webosbrew
manifest (`dist/org.ownyourglass.app.manifest.json`) pointing at the GitHub
release for that version. No LG SDK is needed; the `ar` container is written
by a few lines of Python because macOS `ar` cannot produce a plain archive.

The `.ipk` layout is the standard webOS one:

```
usr/palm/applications/org.ownyourglass.app/   appinfo.json, index.html, app.js, style.css, icons
usr/palm/applications/org.ownyourglass.app/toolkit/   oyg, boot-hook, lib/, modules/, etc/
usr/palm/packages/org.ownyourglass.app/packageinfo.json
```

## Install

You need a rooted TV with Homebrew Channel (see <https://www.webosbrew.org/rooting/>).
Pick one:

### 1. From a GitHub release, over SSH (no LG SDK)

Download the `.ipk` from the release, then:

```sh
tools/deploy.sh root@<tv-ip> --no-build --launch
```

`deploy.sh` copies the ipk to `/tmp` on the TV and hands it to the stock
installer (`luna://com.webos.appInstallService/dev/install`), the same call
`ares-install` makes, and waits for "installed". Enable the SSH server in
Homebrew Channel's settings first.

### 2. From a Homebrew Channel repository

Homebrew Channel can list this app from any repository JSON whose package
entry has `manifestUrl` pointing at the release manifest:

```
https://github.com/fivefold3/own-your-glass/releases/latest/download/org.ownyourglass.app.manifest.json
```

The TV fetches the manifest and the ipk anonymously, so the release has to
be publicly reachable. This repository does not ship a repository file of
its own.

### 3. From a URL on your own network

Serve the build directory and let Homebrew Channel's installer fetch it:

```sh
tools/build-ipk.sh
( cd dist && python3 -m http.server 8765 )
```

then on the TV (SSH), with the sha256 printed by the build:

```sh
luna-send -i -f luna://org.webosbrew.hbchannel.service/install \
  '{"ipkUrl":"http://<your-computer-ip>:8765/org.ownyourglass.app_<version>_all.ipk","ipkHash":"<sha256>","subscribe":true}' </dev/null
```

Installing changes nothing on the TV. Open the app and press **Own the glass**.

## Uninstall

Uninstall from Homebrew Channel (or the app's own "Restore and uninstall"
button). On the next boot the hook notices the app is gone, restores the TV
and deletes itself. Details in [DESIGN.md](DESIGN.md).

## Trying it without installing

The whole toolkit can be flattened into one script and piped over SSH:

```sh
tools/bundle.sh | ssh root@<tv-ip> 'OYG_ROOT=/nonexistent sh -s -- status'
tools/bundle.sh | ssh root@<tv-ip> 'OYG_DRYRUN=1 OYG_ROOT=/nonexistent sh -s -- apply'
```

`status` only reads; `OYG_DRYRUN=1` prints every command that would run and
writes nothing.

#!/bin/sh
# build-ipk.sh — package app/ + toolkit/ into a Homebrew-Channel-installable .ipk
#
# Output (in dist/):
#   <id>_<version>_all.ipk          the package
#   <id>.manifest.json              webosbrew manifest (ipkUrl + sha256) for a
#                                   GitHub release
#   <id>.manifest.local.json        same, pointing at http://__HOST__:__PORT__/
#                                   for LAN installs (see docs/HOMEBREW.md)
# The release manifest is what a Homebrew Channel repository's package entry
# points at (manifestUrl).
#
# An .ipk is an `ar` archive with three members: debian-binary ("2.0\n"),
# control.tar.gz and data.tar.gz. The payload lives under
# usr/palm/applications/<id>/. We write the ar container ourselves because
# macOS BSD ar produces Mach-O static libraries, not plain ar archives.
#
# Usage: tools/build-ipk.sh [--release-base https://github.com/<user>/<repo>/releases/download/v<ver>]
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
APP="$REPO/app"
TOOLKIT="$REPO/toolkit"
DIST="$REPO/dist"
RELEASE_BASE=""
while [ $# -gt 0 ]; do
    case $1 in
        --release-base) RELEASE_BASE=$2; shift 2 ;;
        *) echo "build-ipk: unknown arg $1" >&2; exit 2 ;;
    esac
done

[ -f "$APP/appinfo.json" ] || { echo "build-ipk: no appinfo.json in $APP" >&2; exit 1; }
json() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$APP/appinfo.json" | head -1; }
ID=$(json id); VER=$(json version); TITLE=$(json title); DESC=$(json appDescription)
[ -n "$ID" ] && [ -n "$VER" ] || { echo "build-ipk: appinfo.json needs id and version" >&2; exit 1; }
[ -z "$RELEASE_BASE" ] && RELEASE_BASE="https://github.com/fivefold3/own-your-glass/releases/download/v$VER"

# The toolkit version must match the app version: the boot hook and the app
# compare them to detect a stale on-device copy.
TKVER=$(sed -n 's/^OYG_VERSION=\(.*\)$/\1/p' "$TOOLKIT/lib/common.sh" | tr -d '"')
[ "$TKVER" = "$VER" ] || { echo "build-ipk: toolkit OYG_VERSION ($TKVER) != app version ($VER)" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
COPYFILE_DISABLE=1; export COPYFILE_DISABLE   # no AppleDouble ._ files in tars

# --- control ---
mkdir -p "$WORK/control"
cat > "$WORK/control/control" <<CTL
Package: $ID
Version: $VER
Section: misc
Priority: optional
Architecture: all
Maintainer: own-your-glass
Description: $TITLE
webOS-Package-Format-Version: 2
webOS-Packager-Version: own-your-glass build-ipk.sh
CTL
( cd "$WORK/control" && tar czf "$WORK/control.tar.gz" --owner=0 --group=0 ./control 2>/dev/null || tar czf "$WORK/control.tar.gz" ./control )

# --- data ---
PAYLOAD="$WORK/data/usr/palm/applications/$ID"
mkdir -p "$PAYLOAD"
cp -R "$APP"/. "$PAYLOAD"/
mkdir -p "$PAYLOAD/toolkit"
cp -R "$TOOLKIT"/. "$PAYLOAD/toolkit"/
find "$WORK/data" \( -name '._*' -o -name '.DS_Store' \) -delete
chmod 755 "$PAYLOAD/toolkit/oyg" "$PAYLOAD/toolkit/boot-hook"
# packageinfo.json is what the app installer reads to know what is inside
mkdir -p "$WORK/data/usr/palm/packages/$ID"
cat > "$WORK/data/usr/palm/packages/$ID/packageinfo.json" <<PKG
{
  "app": "$ID",
  "id": "$ID",
  "loc_name": "$TITLE",
  "package_format_version": 2,
  "vendor": "own-your-glass",
  "version": "$VER"
}
PKG
( cd "$WORK/data" && tar czf "$WORK/data.tar.gz" --owner=0 --group=0 . 2>/dev/null || tar czf "$WORK/data.tar.gz" . )
printf '2.0\n' > "$WORK/debian-binary"

# --- ar container ---
mkdir -p "$DIST"
OUT="$DIST/${ID}_${VER}_all.ipk"
rm -f "$OUT"
python3 - "$OUT" "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.gz" <<'PY'
import os, sys
out, members = sys.argv[1], sys.argv[2:]
with open(out, "wb") as fh:
    fh.write(b"!<arch>\n")
    for path in members:
        data = open(path, "rb").read()
        name = os.path.basename(path)
        hdr = (name + "/").ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) \
            + "100644".ljust(8) + str(len(data)).ljust(10) + "`\n"
        fh.write(hdr.encode("ascii")); fh.write(data)
        if len(data) % 2: fh.write(b"\n")
PY

SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')
SIZE=$(wc -c < "$OUT" | tr -d ' ')
IPKNAME=$(basename "$OUT")

manifest() {  # $1 = base url for the ipk
    cat <<MF
{
  "id": "$ID",
  "version": "$VER",
  "type": "web",
  "title": "$TITLE",
  "appDescription": "$DESC",
  "iconUri": "https://raw.githubusercontent.com/fivefold3/own-your-glass/main/app/largeIcon.png",
  "sourceUrl": "https://github.com/fivefold3/own-your-glass",
  "rootRequired": true,
  "ipkUrl": "$1/$IPKNAME",
  "ipkHash": { "sha256": "$SHA" },
  "ipkSize": $SIZE
}
MF
}
manifest "$RELEASE_BASE" > "$DIST/$ID.manifest.json"
manifest "http://__HOST__:__PORT__" > "$DIST/$ID.manifest.local.json"

echo "built:    $OUT"
echo "size:     $SIZE bytes"
echo "sha256:   $SHA"
echo "manifest: $DIST/$ID.manifest.json"

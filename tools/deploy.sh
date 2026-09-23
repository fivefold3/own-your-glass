#!/bin/sh
# deploy.sh — build the .ipk and install it on a rooted TV over SSH.
#
# The TV needs Homebrew Channel with the SSH server enabled. We scp the ipk to
# /tmp on the TV and hand it to the stock app installer, which is exactly what
# ares-install does. No LG SDK required on this machine.
#
# Usage: tools/deploy.sh [user@]host [--no-build] [--launch]
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
HOST=${1:?usage: tools/deploy.sh [user@]host [--no-build] [--launch]}; shift
BUILD=1; LAUNCH=0
for a in "$@"; do case $a in --no-build) BUILD=0;; --launch) LAUNCH=1;; esac; done
case $HOST in *@*) ;; *) HOST="root@$HOST";; esac

[ $BUILD = 1 ] && "$HERE/build-ipk.sh"
IPK=$(ls -t "$REPO"/dist/*.ipk | head -1)
ID=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/app/appinfo.json" | head -1)

echo "deploy: $IPK -> $HOST"
scp -q "$IPK" "$HOST:/tmp/oyg.ipk"
# The installer is asynchronous: subscribe (-i) and wait for "installed"
# before deleting the ipk. luna-send needs stdin closed (</dev/null) or it
# prints nothing; the remote script itself arrives on ssh's stdin.
ssh "$HOST" 'sh -s' <<'REMOTE'
timeout 180 luna-send -i -f luna://com.webos.appInstallService/dev/install \
  '{"id":"com.ares.defaultName","ipkUrl":"/tmp/oyg.ipk","subscribe":true}' </dev/null 2>&1 \
  | while read -r l; do
      case $l in *'"state"'*) echo "  $l";; esac
      case $l in *'"installed"'*|*FAILED*|*failed*|*errorText*) sleep 1; break;; esac
    done
rm -f /tmp/oyg.ipk
REMOTE
if [ $LAUNCH = 1 ]; then
    ssh "$HOST" "luna-send -n 1 -f luna://com.webos.applicationManager/launch '{\"id\":\"$ID\"}' </dev/null"
fi

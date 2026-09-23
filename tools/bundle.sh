#!/bin/sh
# bundle.sh — flatten the toolkit into one script for `ssh tv sh -s -- <cmd>`.
# Handy for a dry run before installing anything:
#   tools/bundle.sh | ssh root@<tv> 'OYG_DRYRUN=1 OYG_ROOT=/nonexistent sh -s -- apply acr voice'
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); TK="$HERE/../toolkit"
printf '#!/bin/sh\nset -u\nOYG_BUNDLED=1\nOYG_TK=${OYG_TK:-/nonexistent}\n'
cat "$TK/lib/common.sh" "$TK/lib/svc.sh" "$TK/lib/purge.sh" "$TK"/modules/*.sh
printf "BLOCKLIST_INLINE='"; sed "s/'/'\\\\''/g" "$TK/etc/blocklist.txt"; printf "'\n"
sed '1,/^set -u$/d' "$TK/oyg" | sed '/^if \[ -z "\${OYG_BUNDLED:-}" \]; then$/,/^fi$/d'

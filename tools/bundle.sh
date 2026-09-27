#!/bin/sh
# bundle.sh — flatten the toolkit into one script for `ssh tv sh -s -- <cmd>`.
# Handy for a dry run before installing anything:
#   tools/bundle.sh | ssh root@<tv> 'OYG_DRYRUN=1 sh -s -- apply'
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); TK="$HERE/../toolkit"
printf '#!/bin/sh\nset -u\nOYG_BUNDLED=1\nOYG_TK=${OYG_TK:-/nonexistent}\n'
cat "$TK/lib/common.sh" "$TK/etc/options.sh" "$TK/lib/svc.sh" "$TK/lib/blocklist.sh" "$TK/lib/settings.sh" \
    "$TK/lib/eula.sh" "$TK/lib/options.sh" "$TK/lib/purge.sh" "$TK/lib/survey.sh" "$TK"/hooks/*.sh "$TK"/resources/*.sh
inline() { printf "%s='" "$1"; sed "s/'/'\\\\''/g" "$2"; printf "'\n"; }
inline OWNERS_INLINE "$TK/etc/owners.txt"
inline KNOWN_LS2_INLINE "$TK/etc/known-ls2.txt"
sed '1,/^set -u$/d' "$TK/oyg" | sed '/^if \[ -z "\${OYG_BUNDLED:-}" \]; then$/,/^fi$/d'

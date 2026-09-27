# diagnostics — besides the uploader chain (option diagnostics): the plain
# system log leaked voice utterances on the reference TV, and rdxd puts its
# last 40 KB into every crash report. Truncated on apply.
hook_diagnostics_apply() {
    [ -f /tmp/var/log/messages ] && run "truncate /tmp/var/log/messages" sh -c ": > /tmp/var/log/messages"
    return 0
}
hook_diagnostics_restore() { :; }
hook_diagnostics_status() { :; }

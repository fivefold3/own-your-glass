# survey.sh — `oyg survey`: a report on this TV, so the knowledge base can
# learn models and firmware it has not seen. The report is kept in
# $SURVEY_FILE and printed; the app shows that file, and `oyg survey usb`
# copies it as it is to USB storage, as a .txt named after the model,
# country and software: what the owner saw is what is saved.
#
# Read-only apart from those two copies: file reads only, no luna calls. It never
# prints a MAC, serial, IP, SSID, account or device ID, and looks only at the
# firmware's own registries, never at apps the owner installed. The one
# location it gives is LG's service country and region for the TV (AU, AIC),
# which the model suffix gives away anyway. Lines:
#   SURVEY|key|value        OYG and webOS versions, firmware, model, country,
#                           hardware traits, OYG's selection
#   ENTRY|option|id|present|launch     each knowledge-base service
#   SDX|group|name|type     the gateway table's names (no hosts)
#   APP|id|present          each knowledge-base app
#   UNKNOWN|name            system LS2 services the knowledge base has never seen

SURVEY_REGISTRIES="/usr/share/luna-service2/services.d /usr/share/dbus-1/system-services /usr/share/dbus-1/services"
NYX_OS_INFO=${NYX_OS_INFO:-/var/run/nyx/os_info.json}
HBC_INFO=/media/developer/apps/usr/palm/applications/org.webosbrew.hbchannel/appinfo.json
SURVEY_FILE=${SURVEY_FILE:-$OYG_APP_DIR/report.txt}   # the app reads it too (app.js REPORT)

# the firmware version Settings shows (33.31.68); older TVs name it differently
survey_firmware() { _f=$(json_str "$NYX_OS_INFO" webos_manufacturing_version); [ -n "$_f" ] || _f=$(json_str "$NYX_OS_INFO" firmwareVersion); printf '%s' "$_f"; }
# LG's service country and region, as sdx learned them when OYG applied
survey_country() { sdx_known default | tr 'a-z' 'A-Z'; }
survey_region()  { sdx_known ric | tr 'a-z' 'A-Z'; }
survey_soc() {
    _s=$(tr '\0' '\n' < "$OYG_PROC/device-tree/compatible" 2>/dev/null | grep . | tr '\n' ' ')
    [ -n "$_s" ] || _s=$(sed -n 's/^Hardware[[:space:]]*:[[:space:]]*//p' "$OYG_PROC/cpuinfo" 2>/dev/null | head -1)
    printf '%s' "${_s% }"
}

# USB storage the TV has mounted for the owner: webOS mounts each partition
# at /tmp/usb/<disk>/<partition> (and again inside app jails, not wanted here)
usb_dirs() { awk '$2 ~ /^\/tmp\/usb\/[^\/]+\/[^\/]+$/ && $4 ~ /(^|,)rw(,|$)/ { print $2 }' "$OYG_PROC/mounts" 2>/dev/null; }

# oyg-report_OLED55C5PSA_AU_webOS10.3.1_fw33.31.68.txt (a part left out when unknown)
survey_filename() {
    _n=oyg-report
    _m=$(model_name); _c=$(survey_country); [ -n "$_c" ] || _c=$(survey_region)
    _w=$(webos_version); _f=$(survey_firmware)
    [ -n "$_m" ] && _n="${_n}_$_m"
    [ -n "$_c" ] && _n="${_n}_$_c"
    [ -n "$_w" ] && _n="${_n}_webOS$_w"
    [ -n "$_f" ] && _n="${_n}_fw$_f"
    printf '%s.txt' "$(printf '%s' "$_n" | tr -c 'A-Za-z0-9._-' '_')"
}

# oyg survey: a new report, kept in $SURVEY_FILE (tmpfs, gone at restart) and
# printed. Anything the reads say on stderr stays out of it.
survey_report() {
    _su_t=$(oyg_tmp survey.txt)   # survey_lines reuses the short names
    { printf '# Own Your Glass TV report, %s\n' "$(date '+%Y-%m-%d %H:%M')"; survey_lines; } > "$_su_t" 2>/dev/null
    if [ "$OYG_DRYRUN" != 1 ]; then
        case $SURVEY_FILE in "$OYG_APP_DIR"/*) oyg_app_dir || die "cannot make $OYG_APP_DIR" ;; esac
        cp "$_su_t" "$SURVEY_FILE" && chmod 600 "$SURVEY_FILE"
    fi
    cat "$_su_t"
}

# oyg survey usb: the last report (a new one if there is none) as a .txt on
# the first USB storage, byte for byte what the app showed
survey_usb() {
    _d=$(usb_dirs | head -1)
    [ -n "$_d" ] || die "no USB storage connected"
    _n=$(survey_filename)
    if [ "$OYG_DRYRUN" = 1 ]; then info "(dry-run) save the TV report to $_d/$_n"; return 0; fi
    [ -s "$SURVEY_FILE" ] || survey_report >/dev/null
    cp "$SURVEY_FILE" "$_d/$_n" && sync || die "could not write to the USB storage"
    ok "TV report saved to USB storage: $_n"
}

do_survey() {  # do_survey [usb | usb-check]
    case ${1:-} in
        usb) survey_usb ;;
        usb-check) usb_dirs | sed 's/^/USB|/'; return 0 ;;
        *) survey_report ;;
    esac
}

survey_lines() {
    printf 'SURVEY|oyg|%s\n' "$OYG_VERSION"
    printf 'SURVEY|webos|%s\n' "$(webos_version)"
    printf 'SURVEY|known|%s\n' "$(known_generation && echo 1 || echo 0)"
    printf 'SURVEY|run|%s\n' "$(run_generation && echo 1 || echo 0)"
    printf 'SURVEY|model|%s\n' "$(model_name)"
    for _k in firmware:survey_firmware country:survey_country region:survey_region soc:survey_soc; do
        _v=$(${_k#*:}); [ -n "$_v" ] && printf 'SURVEY|%s|%s\n' "${_k%%:*}" "$_v"
    done
    for _k in core_os:core_os_release codename:webos_release_codename build:webos_build_datetime image:webos_imagename kernel:core_os_kernel_version; do
        _v=$(json_str "$NYX_OS_INFO" "${_k#*:}"); [ -n "$_v" ] && printf 'SURVEY|%s|%s\n' "${_k%%:*}" "$_v"
    done
    printf 'SURVEY|cpus|%s\n' "$(grep -c '^processor' "$OYG_PROC/cpuinfo" 2>/dev/null)"
    printf 'SURVEY|ram_mb|%s\n' "$(awk '/^MemTotal:/ { print int($2 / 1024) }' "$OYG_PROC/meminfo" 2>/dev/null)"
    _v=$(json_str "$HBC_INFO" version); [ -n "$_v" ] && printf 'SURVEY|homebrew_channel|%s\n' "$_v"
    _ff=0; grep -q 'capture' "$OYG_PROC/asound/pcm" 2>/dev/null && grep -E ': capture' "$OYG_PROC/asound/pcm" | grep -qE "$MIC_NAME_MATCH" && _ff=1
    printf 'SURVEY|farfield_mic|%s\n' "$_ff"
    printf 'SURVEY|pixel_care_capture|%s\n' "$( [ -e /usr/sbin/eplmanager ] && echo 1 || echo 0)"
    printf 'SURVEY|launch_block_list|%s\n' "$(blocklist_supported && echo 1 || echo 0)"
    printf 'SURVEY|python3|%s\n' "$(command -v python3 >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'SURVEY|iptables|%s\n' "$(command -v iptables >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'SURVEY|preset|%s\n' "$(current_preset)"
    printf 'SURVEY|options|%s\n' "$(selected_options | tr '\n' ' ' | sed 's/ $//')"
    _v=$(trial_options | tr '\n' ' ' | sed 's/ $//'); [ -n "$_v" ] && printf 'SURVEY|trying|%s\n' "$_v"
    _idx=$(oyg_tmp survey.ls2); LS2_DIRS=$SURVEY_REGISTRIES ls2_index_build "$_idx"
    printf 'SURVEY|ls2_services|%s\n' "$(cut -f1 "$_idx" | sort -u | grep -c .)"
    for o in $OYG_OPTIONS; do
        { ov "$o" spec; printf '\n'; ov "$o" spec_t; printf '\n'; } | while IFS='|' read -r id unit bin comm arg ls2 flags; do
            [ -n "$id" ] || continue
            _b=$(svc_resolve_bin "$unit" "$bin" "$comm")
            _p=absent; { [ -n "$_b" ] && [ -e "$_b" ]; } && _p=present
            _l=""
            if [ -n "$ls2" ]; then
                _l=$(awk -F'\t' -v n="$ls2" '$1 == n { print ($3 ~ /jailer/) ? "jailed" : ($3 ~ /run-js-service/ && $3 ~ / -u( |$)/) ? "unified" : $2; exit }' "$_idx")
                [ -n "$_l" ] && _p=present
            fi
            printf 'ENTRY|%s|%s|%s|%s\n' "$o" "$id" "$_p" "$_l"
        done
    done
    _t=$SDX_TABLE; [ -f "$_t" ] || _t=/usr/palm/sdx/server_addr_version.conf
    [ -f "$SDX_ORIG" ] && _t=$SDX_ORIG
    [ -f "$_t" ] && sdx_entries "$_t" | awk -F'|' '{ print "SDX|" $1 "|" $2 "|" $3 }'
    for o in $OYG_OPTIONS; do
        for a in $(ov "$o" apps) $(ov "$o" apps_t); do
            app_exists "$a" && printf 'APP|%s|present\n' "$a" || printf 'APP|%s|absent\n' "$a"
        done
    done
    _k=$OYG_TK/etc/known-ls2.txt
    if [ ! -f "$_k" ]; then _k=$(oyg_tmp known-ls2); printf '%s\n' "${KNOWN_LS2_INLINE:-}" > "$_k"; fi
    [ -s "$_k" ] && cut -f1 "$_idx" | sort -u | grep -vxF -f "$_k" | sed 's/^/UNKNOWN|/'
    return 0
}

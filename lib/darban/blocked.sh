#!/usr/bin/env bash
# Blocked destinations.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- blocked destinations ----------
# VPN clients cannot reach these addresses through this server, so those sites and services never see its address:
# the ranges of the countries chosen, and the owner's own. The ranges are written into nat.nft itself
# (darban_nat_rules), so they load at boot with NAT and follow a new VPN network. Nothing restarts: the rules apply at
# once, to connections already open too. The sites of those countries can go outside the VPN instead, through routes
# that bin/darban-ovpn-event gives each client when it connects.
address_label() { if (( $1 == 1 )); then printf '1 address'; else printf '%d addresses' "$1"; fi; }
blocked_extra_count() { local words; read -ra words <<<"$BLOCK_EXTRA"; printf '%d' "${#words[@]}"; }
country_name() {
    case $1 in
        ir) printf Iran ;; af) printf Afghanistan ;; ru) printf Russia ;; cn) printf China ;; tr) printf Turkey ;;
        by) printf Belarus ;; tm) printf Turkmenistan ;; *) printf '%s' "${1^^}" ;;
    esac
}
country_names() {
    local cc out=''
    for cc in $1; do out+="${out:+, }$(country_name "$cc")"; done
    printf '%s' "${out:-none}"
}
country_list() { printf '%s/%s.v4' "$GEO_DIR" "$1"; }
# country_value <code> <date|ranges>: empty for a country not downloaded yet. awk would fail on the missing file, and
# with errexit on, that would end the action that asked.
country_value() { [[ -f $GEO_DIR/$1.info ]] || return 0; awk -v k="$2" '$1==k {print $2}' "$GEO_DIR/$1.info" 2>/dev/null || true; }
mode_label() {
    case $COUNTRY_DIRECT in yes) printf 'outside the VPN' ;; no-android) printf 'outside the VPN, not for Android' ;; *) printf blocked ;; esac
}
lists_label() {
    # The oldest list of the countries chosen, or what is missing.
    local cc date oldest=''
    [[ -n $BLOCK_COUNTRIES ]] || { printf 'no country chosen'; return 0; }
    for cc in $BLOCK_COUNTRIES; do
        date=$(country_value "$cc" date)
        if [[ -z $date || ! -s $(country_list "$cc") ]]; then printf '%s not downloaded' "$(country_name "$cc")"; return 0; fi
        if [[ -z $oldest || $date < $oldest ]]; then oldest=$date; fi
    done
    printf '%s' "$oldest"
}
blocked_summary() {
    local extra parts=''
    extra=$(blocked_extra_count)
    if [[ -n $BLOCK_COUNTRIES ]]; then
        parts=$(country_names "$BLOCK_COUNTRIES")
        if [[ $COUNTRY_DIRECT != no ]]; then parts+=', outside the VPN'; fi
    fi
    if (( extra )); then parts+="${parts:+, and }$(address_label "$extra") of your own"; fi
    printf '%s' "${parts:-none}"
}
geo_migrate() {
    # The list of Iran from before other countries came, where it lived then.
    if [[ -s $CONFIG_DIR/iran.v4 && ! -e $GEO_DIR/ir.v4 ]]; then
        install -d -m 700 "$GEO_DIR" && mv -f -- "$CONFIG_DIR/iran.v4" "$GEO_DIR/ir.v4" || return 1
        if [[ -f $CONFIG_DIR/iran.v4.info ]]; then mv -f -- "$CONFIG_DIR/iran.v4.info" "$GEO_DIR/ir.info" || return 1; fi
    fi
    return 0
}
valid_block_entry() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] && python3 -I "$GEO_PY" entry "$1" >/dev/null 2>&1; }
blocked_needs_full_tunnel() {
    conf_full_tunnel && return 0
    info 'In a split tunnel, clients reach the internet without this server, so there is nothing to block here. Switch to the full tunnel first (Settings > Advanced > 1).'
    return 1
}
blocked_apply() {
    # The list of blocked ranges from the settings in memory, then NAT from it, checked by nft and loaded in one
    # transaction. When anything fails, the rules that ran and both files stay as they were. Needs the lock.
    local nat=$CONFIG_DIR/nat.nft net iface cc lists=() block_new nat_new nat_old block_old had_block=0
    if [[ ! -f $nat ]]; then
        fail 'NAT on this server was not set up by this tool, so it cannot block destinations. Nothing was changed.'
        return 1
    fi
    net=$(darban_conf_net)
    iface=$(darban_nat_iface "$nat" 2>/dev/null) || iface=''
    if ! valid_ipv4 "${net:-}" || [[ ! $iface =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        fail 'server.conf has no single /24 VPN network, or NAT names no outgoing interface. Nothing was changed.'
        return 1
    fi
    for cc in $BLOCK_COUNTRIES; do
        [[ -s $(country_list "$cc") ]] || { fail "The list of $(country_name "$cc") is not on this server. Nothing was changed."; return 1; }
        lists+=(--list "$(country_list "$cc")")
    done
    block_new=$(mktemp "$CONFIG_DIR/.blocked.XXXXXXXX") || return 1
    darban_tmp_register "$block_new"
    nat_new=$(mktemp "$CONFIG_DIR/.nat.XXXXXXXX") || return 1
    darban_tmp_register "$nat_new"
    nat_old=$(mktemp) || return 1
    darban_tmp_register "$nat_old"
    block_old=$(mktemp) || return 1
    darban_tmp_register "$block_old"
    # With no range left, geolist.py removes the file it was given.
    if ! python3 -I "$GEO_PY" merge --out "$block_new" "${lists[@]}" --extra "$BLOCK_EXTRA" >/dev/null; then
        fail 'Could not write the list of blocked destinations. Nothing was changed.'
        return 1
    fi
    DARBAN_BLOCKED=$block_new darban_nat_rules "$net" "$iface" >"$nat_new" && chmod 600 "$nat_new" || return 1
    if ! nft -c -f "$nat_new" >/dev/null 2>&1; then fail 'nft refused the new rules. Nothing was changed.'; return 1; fi
    cp -a -- "$nat" "$nat_old" || return 1
    if [[ -f $DARBAN_BLOCKED ]]; then cp -a -- "$DARBAN_BLOCKED" "$block_old" && had_block=1 || return 1; fi
    critical_begin
    mv -f -- "$nat_new" "$nat"
    if [[ -f $block_new ]]; then chmod 600 "$block_new" && mv -f -- "$block_new" "$DARBAN_BLOCKED"; else rm -f -- "$DARBAN_BLOCKED"; fi
    if ! nft -f "$nat" >/dev/null 2>&1; then
        cp -a -- "$nat_old" "$nat" || true
        if (( had_block )); then cp -a -- "$block_old" "$DARBAN_BLOCKED" || true; else rm -f -- "$DARBAN_BLOCKED"; fi
        nft -f "$nat" >/dev/null 2>&1 || urgent 'Could not load the previous NAT rules again. Check: nft list ruleset'
        critical_end
        fail 'The new rules did not load. Nothing was changed.'
        return 1
    fi
    critical_end
}
blocked_commit() {
    # blocked_commit <countries> <own ranges> [no|yes|no-android]: the rules from these settings, then the settings
    # saved, then the routes for their sites outside the VPN. A save that fails takes the rules back, so the file and
    # the kernel never disagree. Without a country, nothing goes outside the VPN either.
    local old_countries=$BLOCK_COUNTRIES old_extra=$BLOCK_EXTRA old_direct=$COUNTRY_DIRECT
    ca_lock || return 1
    BLOCK_COUNTRIES=$1 BLOCK_EXTRA=$2 COUNTRY_DIRECT=${3:-$COUNTRY_DIRECT}
    if [[ -z $BLOCK_COUNTRIES ]]; then COUNTRY_DIRECT=no; fi
    if ! blocked_apply; then BLOCK_COUNTRIES=$old_countries BLOCK_EXTRA=$old_extra COUNTRY_DIRECT=$old_direct; return 1; fi
    if ! save_config; then
        BLOCK_COUNTRIES=$old_countries BLOCK_EXTRA=$old_extra COUNTRY_DIRECT=$old_direct
        blocked_apply || true
        fail 'The setting could not be saved, so the previous rules were put back.'
        return 1
    fi
    direct_write
}
direct_write() {
    # The two routes files from the lists and the setting in memory, each replaced in one step; gone when it is off.
    # Clients get them when they next connect.
    local android=yes cc lists=() out info
    if [[ -z $BLOCK_COUNTRIES || $COUNTRY_DIRECT == no ]]; then
        rm -f -- "$DIRECT_ROUTES" "$DIRECT_ROUTES_SMALL" "$DIRECT_INFO"
        return 0
    fi
    if [[ $COUNTRY_DIRECT == no-android ]]; then android=no; fi
    for cc in $BLOCK_COUNTRIES; do lists+=(--list "$(country_list "$cc")"); done
    if ! python3 -I "$GEO_PY" routes "${lists[@]}" --out "$DIRECT_ROUTES_SMALL" --android "$android" --budget "$DIRECT_BUDGET_SMALL" >/dev/null \
        || ! out=$(python3 -I "$GEO_PY" routes "${lists[@]}" --out "$DIRECT_ROUTES" --android "$android" --budget "$DIRECT_BUDGET"); then
        fail "Could not write the routes for their sites to $DIRECT_ROUTES; see: sudo darban status"
        return 1
    fi
    # One line for each country: its code, its ranges, how many go outside the VPN, and the share of its addresses.
    info=$(mktemp "$GEO_DIR/.direct.XXXXXXXX") || return 1
    darban_tmp_register "$info"
    sed -n 's#^list=.*/\([a-z][a-z]\)\.v4 ranges=\([0-9]*\) sent=\([0-9]*\) share=\([0-9.]*\)$#\1 \2 \3 \4#p' <<<"$out" >"$info" \
        && chmod 600 "$info" && mv -f -- "$info" "$DIRECT_INFO"
}
direct_coverage() {
    # A line for each country that does not fit whole: the rest of it stays blocked.
    local cc ranges sent share
    while read -r cc ranges sent share; do
        [[ $cc =~ ^[a-z]{2}$ && $ranges =~ ^[0-9]+$ && $sent =~ ^[0-9]+$ ]] || continue
        if (( sent < ranges )); then
            bullet "$(country_name "$cc"): the largest $sent of its $ranges ranges, $share% of its addresses, go outside the VPN; the rest stays blocked"
        fi
    done 2>/dev/null <"$DIRECT_INFO" || true
}
country_fetch() {
    # country_fetch <code>: a new list of that country in place, or the last one kept: geolist.py replaces it only
    # when every check passes. Runs without the lock: it may wait for the network, and the file changes in one step.
    local out rc=0 ranges info
    install -d -m 700 "$GEO_DIR" || return 1
    out=$(python3 -I "$GEO_PY" fetch --source "$GEO_SOURCE" --country "$1" --out "$(country_list "$1")" 2>&1) || rc=$?
    if (( rc != 0 )); then
        GEO_WHY=$(tail -n 1 <<<"$out")
        GEO_WHY=$(safe_text "${GEO_WHY:-the download failed}")
        return 1
    fi
    ranges=$(sed -n 's/^ranges=\([0-9]*\) .*/\1/p' <<<"$out")
    info=$(mktemp "$GEO_DIR/.info.XXXXXXXX") || return 1
    darban_tmp_register "$info"
    printf 'date %s\nranges %s\n' "$(date -u +%Y-%m-%d)" "${ranges:-0}" >"$info" && chmod 600 "$info" && mv -f -- "$info" "$GEO_DIR/$1.info"
}
valid_country_tokens() {
    local token
    [[ -n $1 ]] || return 1
    for token in $1; do [[ $token =~ ^[1-7]$ || $token =~ ^[A-Za-z]{2}$ ]] || return 1; done
}
set_countries() {
    local cc i=0 mark ranges token choices new parts added=() kept=()
    read -ra choices <<<"$COUNTRY_CHOICES"
    info "VPN clients cannot reach the addresses of these countries through this server, so their sites never see its address. Choose the countries your users live in. Item 2 decides whether their sites are blocked or go outside the VPN."
    say
    for cc in "${choices[@]}"; do
        i=$((i + 1))
        mark='[ ]'
        if [[ " $BLOCK_COUNTRIES " == *" $cc "* ]]; then mark='[x]'; fi
        ranges=$(country_value "$cc" ranges)
        say "  $C_KEY$i$C_RESET  $mark $(printf '%-14s' "$(country_name "$cc")") ${ranges:+$ranges ranges}"
    done
    for cc in $BLOCK_COUNTRIES; do
        [[ " $COUNTRY_CHOICES " == *" $cc "* ]] || say "     [x] $(printf '%-14s' "$(country_name "$cc")") $(country_value "$cc" ranges) ranges"
    done
    say
    prompt_valid 'Numbers or two-letter country codes to turn on or off, such as 2 3 or kz (Enter = cancel): ' valid_country_tokens \
        'Enter numbers from the list, or two-letter country codes such as kz, separated by spaces.' || return 0
    new=" $BLOCK_COUNTRIES "
    for token in $REPLY; do
        if [[ $token =~ ^[1-7]$ ]]; then cc=${choices[token - 1]}; else cc=${token,,}; fi
        if [[ $new == *" $cc "* ]]; then new=${new/ $cc / }; else new+="$cc "; fi
    done
    read -ra parts <<<"$new"
    new="${parts[*]}"
    if [[ $new == "$BLOCK_COUNTRIES" ]]; then info 'Same as now; nothing changed.'; return 0; fi
    if (( ${#parts[@]} > COUNTRIES_MAX )); then fail "At most $COUNTRIES_MAX countries can be blocked. Nothing was changed."; return 1; fi
    if [[ -n $new ]]; then blocked_needs_full_tunnel || return 0; fi
    kv Now "$(country_names "$BLOCK_COUNTRIES")"
    kv New "$(country_names "$new")"
    if [[ -n $new ]]; then
        if [[ $COUNTRY_DIRECT == no ]]; then
            bullet 'their sites and apps do not open while the VPN is connected; item 2 can send them outside the VPN instead'
        else
            bullet 'their sites go outside the VPN, for every client that can take the routes, when it next connects'
        fi
        bullet 'the lists come from github.com/Chocolate4U/Iran-v2ray-rules, made each day from public GeoIP data, and are updated every day'
    fi
    if [[ -z $new && $COUNTRY_DIRECT != no ]]; then bullet 'their sites outside the VPN (item 2) turns off too'; fi
    bullet 'no restart: it applies at once'
    say
    confirm_choice 'Apply this change?' 'No, keep them as they are' 'Apply' caution || { cancelled; return 0; }
    for cc in "${parts[@]}"; do
        if [[ " $BLOCK_COUNTRIES " == *" $cc "* ]]; then kept+=("$cc"); continue; fi
        info "Downloading the list of $(country_name "$cc")..."
        if country_fetch "$cc"; then
            kept+=("$cc")
        elif [[ -s $(country_list "$cc") ]]; then
            warn "A new list of $(country_name "$cc") could not be downloaded: $GEO_WHY. The one from $(country_value "$cc" date) is used."
            kept+=("$cc")
        else
            warn "The list of $(country_name "$cc") could not be downloaded: $GEO_WHY. It is left out."
        fi
    done
    new="${kept[*]}"
    if [[ $new == "$BLOCK_COUNTRIES" ]]; then fail 'Nothing was changed.'; return 1; fi
    blocked_commit "$new" "$BLOCK_EXTRA" || return 1
    if [[ -n $BLOCK_COUNTRIES ]]; then
        if ! systemctl enable --now darban-geo.timer >/dev/null 2>&1; then
            warn 'The daily update of the lists did not start, so they stay as they are now. See: systemctl status darban-geo.timer'
        fi
    elif [[ -z $NAME_LISTS ]]; then
        systemctl disable --now darban-geo.timer >/dev/null 2>&1 || true
    fi
    audit "blocked destinations: countries $(country_names "$BLOCK_COUNTRIES")"
    if [[ -z $BLOCK_COUNTRIES ]]; then ok 'Saved: no country is blocked now.'; return 0; fi
    ok "Saved: blocked countries $(country_names "$BLOCK_COUNTRIES"). Applied at once."
    for cc in $BLOCK_COUNTRIES; do bullet "$(country_name "$cc"): $(country_value "$cc" ranges) ranges"; done
    if [[ $COUNTRY_DIRECT != no ]]; then direct_coverage; fi
}
valid_direct_choice() { [[ $1 =~ ^[1-3]$ ]]; }
set_country_mode() {
    local choice
    kv Now "$(mode_label)"
    info "What happens to the sites of the countries of item 1. Either way they never see this server's address."
    say
    say "  ${C_KEY}1${C_RESET}  Blocked: they do not open while the VPN is connected"
    say "  ${C_KEY}2${C_RESET}  Outside the VPN: they open, through the user's own internet"
    say "  ${C_KEY}3${C_RESET}  Outside the VPN, except Android phones"
    say
    bullet 'outside the VPN reaches each client when it next connects; nothing restarts'
    bullet 'OpenVPN 2, and OpenVPN Connect with an OpenVPN 3 core of 3.11.1 or newer, such as 3.7.3 on Android and 3.9.0 on Windows, take the whole list; an older app takes a shorter one, and the rest stays blocked for it'
    bullet 'Android 12 and older were not tested with so many routes; choose 3 if Android users cannot connect'
    say
    prompt_valid 'Choose 1-3 (Enter = cancel): ' valid_direct_choice 'Enter 1, 2 or 3.' || return 0
    case $REPLY in 1) choice=no ;; 2) choice=yes ;; *) choice=no-android ;; esac
    if [[ $choice == "$COUNTRY_DIRECT" ]]; then info 'Same as now; nothing changed.'; return 0; fi
    if [[ $choice != no ]]; then
        if [[ -z $BLOCK_COUNTRIES ]]; then info 'Choose the countries first (item 1).'; return 0; fi
        blocked_needs_full_tunnel || return 0
        if ! events_lines_on; then
            fail 'Connection events are off, so OpenVPN does not run the script that gives clients the routes. Nothing was changed; see: sudo darban status'
            return 1
        fi
    fi
    blocked_commit "$BLOCK_COUNTRIES" "$BLOCK_EXTRA" "$choice" || return 1
    audit "blocked destinations: their sites $(mode_label)"
    if [[ $choice == no ]]; then ok 'Saved: their sites are blocked.'; return 0; fi
    ok "Saved: their sites $(mode_label). Clients get it when they next connect."
    direct_coverage
}
block_address() {
    local entry count
    blocked_needs_full_tunnel || return 0
    count=$(blocked_extra_count)
    kv Blocked "$(address_label "$count") of your own"
    if (( count >= BLOCK_EXTRA_MAX )); then fail "At most $BLOCK_EXTRA_MAX addresses of your own can be blocked. Unblock one first."; return 1; fi
    info "The address of a site or service that should never see this server's address, or a range of them."
    say
    prompt_valid 'Address or range to block, such as 203.0.114.10 or 203.0.114.0/24 (Enter = cancel): ' valid_block_entry \
        'Enter a public IPv4 address, or a range of them no larger than /8, such as 203.0.114.0/24.' || return 0
    entry=$(python3 -I "$GEO_PY" entry "$REPLY") || return 1
    if [[ " $BLOCK_EXTRA " == *" $entry "* ]]; then info "$entry is already blocked; nothing changed."; return 0; fi
    blocked_commit "$BLOCK_COUNTRIES" "${BLOCK_EXTRA:+$BLOCK_EXTRA }$entry" || return 1
    audit "blocked destinations: $entry blocked"
    ok "Blocked: $entry. Applied at once."
}
valid_unblock_choice() { [[ $1 =~ ^[0-9]{1,3}$ ]] && (( 10#$1 >= 1 && 10#$1 <= UNBLOCK_COUNT )); }
unblock_address() {
    local words kept=() entry i
    read -ra words <<<"$BLOCK_EXTRA"
    if (( ${#words[@]} == 0 )); then info 'No address of your own is blocked.'; return 0; fi
    for i in "${!words[@]}"; do say "  $C_KEY$((i + 1))$C_RESET  ${words[i]}"; done
    say
    UNBLOCK_COUNT=${#words[@]}
    prompt_valid "Choose 1-${#words[@]} to unblock (Enter = cancel): " valid_unblock_choice "Enter a number from 1 to ${#words[@]}." || return 0
    entry=${words[10#$REPLY - 1]}
    for i in "${!words[@]}"; do (( i == 10#$REPLY - 1 )) || kept+=("${words[i]}"); done
    blocked_commit "$BLOCK_COUNTRIES" "${kept[*]}" || return 1
    audit "blocked destinations: $entry unblocked"
    ok "Unblocked: $entry. Applied at once."
}
update_lists() {
    # Also what darban-geo.timer runs each day, through "darban geo-update".
    local cc failed=0 summary=''
    geo_migrate || true
    if [[ -z $BLOCK_COUNTRIES ]]; then
        info 'No country is blocked, so no list is used. Item 1 chooses them.'
        # The owner's own ranges are written and loaded again, as after a restore, which brings the settings only.
        if [[ -n $BLOCK_EXTRA ]]; then
            blocked_commit '' "$BLOCK_EXTRA" || return 1
            ok 'Your own addresses are loaded again.'
        fi
        return 0
    fi
    for cc in $BLOCK_COUNTRIES; do
        info "Downloading the list of $(country_name "$cc")..."
        if ! country_fetch "$cc"; then
            failed=1
            fail "The list of $(country_name "$cc") was not updated: $GEO_WHY. The one from $(country_value "$cc" date) stays in use."
            audit "blocked destinations: the list of $(country_name "$cc") was not updated: $GEO_WHY"
        fi
    done
    blocked_commit "$BLOCK_COUNTRIES" "$BLOCK_EXTRA" || return 1
    (( ! failed )) || return 1
    for cc in $BLOCK_COUNTRIES; do summary+="${summary:+, }$(country_name "$cc") $(country_value "$cc" ranges) ranges"; done
    ok "The lists are up to date: $summary."
}
blocked_health() {
    # blocked_health <VPN network>: the rules that refuse blocked destinations run, and hold what the file says.
    local want live cc date age oldest='' name=''
    [[ -n $BLOCK_COUNTRIES || -n $BLOCK_EXTRA || -s $DARBAN_BLOCKED ]] || return 0
    if ! darban_live_blocked_ok "$1"; then
        check bad "Blocked destinations are not refused: their rules are not loaded $S_ARROW sudo systemctl restart darban-nat.service"
        return 0
    fi
    want=$(grep -c . "$DARBAN_BLOCKED" 2>/dev/null) || want=0
    live=$(darban_live_blocked_count) || live=0
    if (( want == 0 )) && [[ -n $BLOCK_COUNTRIES || -n $BLOCK_EXTRA ]]; then
        # As after a restore: it brings the settings, not the lists.
        check bad "Settings block $(blocked_summary), but no list of them is loaded $S_ARROW sudo darban, then Settings > Blocked destinations > 5"
    elif (( want > 0 && live == 0 )); then
        check bad "Blocked destinations are not refused: the loaded list is empty $S_ARROW sudo systemctl restart darban-nat.service"
    else
        check ok "Blocked destinations are refused: $want $( (( want == 1 )) && printf range || printf ranges) ($(blocked_summary))"
    fi
    [[ -n $BLOCK_COUNTRIES ]] || return 0
    for cc in $BLOCK_COUNTRIES; do
        date=$(country_value "$cc" date)
        if [[ -z $oldest || ${date:-0000} < $oldest ]]; then oldest=${date:-0000}; name=$(country_name "$cc"); fi
    done
    [[ $oldest != 0000 ]] || oldest=1970-01-01
    age=$(( ($(date -u +%s) - $(date -u -d "$oldest" +%s 2>/dev/null || echo 0)) / 86400 ))
    if (( age > 7 )); then
        check warn "The list of $name is $age days old: its daily update fails $S_ARROW sudo systemctl status darban-geo.service"
    elif ! systemctl is-active --quiet darban-geo.timer 2>/dev/null; then
        check warn "The daily update of the lists of countries is off $S_ARROW sudo systemctl enable --now darban-geo.timer"
    fi
    [[ $COUNTRY_DIRECT != no ]] || return 0
    want=$(grep -c '^push "route ' "$DIRECT_ROUTES" 2>/dev/null) || want=0
    if (( want == 0 )) || [[ ! -s $DIRECT_ROUTES_SMALL ]]; then
        check bad "Their sites should go outside the VPN, but the routes are not on this server, so every client sends them through the VPN, where they are blocked $S_ARROW sudo darban, then Settings > Blocked destinations > 5"
    elif ! events_lines_on; then
        check bad "Their sites should go outside the VPN, but connection events are off, so no client gets the routes $S_ARROW see Connection events below"
    elif [[ $COUNTRY_DIRECT == no-android ]]; then
        check ok "Their sites go outside the VPN: $want routes, given at connection to every client that can take them but Android phones"
    else
        check ok "Their sites go outside the VPN: $want routes, given at connection to every client that can take them"
    fi
}

#!/usr/bin/env bash
# Blocked names, on DNS on this server.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- blocked names, on DNS on this server ----------
# Unbound answers "no such name" for each blocked name and all under it, from a zone of response policy. The lists
# come from the same source as the lists of countries; Iranian sites abroad are the names of Iran's list whose every
# address lies outside Iran's ranges, found by asking the upstream DNS once a week. The owner's own names are blocked
# too, and the names the owner allows pass even inside a blocked one.
names_in_use() { [[ -n $NAME_LISTS || -n $NAMES_BLOCK || -n $NAMES_ALLOW ]]; }
name_list_title() {
    case $1 in abroad) printf 'Iranian sites hosted abroad' ;; ads) printf 'Ads and trackers' ;; malware) printf 'Malware and phishing' ;; esac
}
name_list_short() { case $1 in abroad) printf 'Iranian sites abroad' ;; ads) printf ads ;; malware) printf malware ;; esac; }
name_lists_label() {
    local list out=''
    for list in $1; do out+="${out:+, }$(name_list_short "$list")"; done
    printf '%s' "${out:-none}"
}
names_count_label() {
    local words
    read -ra words <<<"$1"
    if (( ${#words[@]} == 1 )); then printf '1 name'; else printf '%d names' "${#words[@]}"; fi
}
name_list_file() { printf '%s/names-%s.txt' "$GEO_DIR" "$1"; }
name_list_value() { [[ -f $GEO_DIR/names-$1.info ]] || return 0; awk -v k="$2" '$1==k {print $2}' "$GEO_DIR/names-$1.info" 2>/dev/null || true; }
name_lists_date() {
    local list date oldest=''
    [[ -n $NAME_LISTS ]] || { printf 'no list chosen'; return 0; }
    for list in $NAME_LISTS; do
        date=$(name_list_value "$list" date)
        if [[ -z $date ]]; then printf '%s not downloaded' "$(name_list_short "$list")"; return 0; fi
        if [[ -z $oldest || $date < $oldest ]]; then oldest=$date; fi
    done
    printf '%s' "$oldest"
}
names_fetch() {
    # names_fetch <list>: a new copy of one list in place, or the last one kept. Iranian sites abroad needs the
    # ranges of Iran, and asks the upstream DNS for every name of Iran's list: a few minutes.
    local list=$1 out rc=0 count info server
    install -d -m 700 "$GEO_DIR" || return 1
    case $list in
        ads) out=$(python3 -I "$GEO_PY" names --source "$GEO_SOURCE" --file category-ads-all.txt --out "$(name_list_file ads)" 2>&1) || rc=$? ;;
        malware) out=$(python3 -I "$GEO_PY" names --source "$GEO_SOURCE" --file malware.txt --file phishing.txt --file cryptominers.txt \
            --out "$(name_list_file malware)" 2>&1) || rc=$? ;;
        abroad)
            if [[ ! -s $(country_list ir) ]] && ! country_fetch ir; then NAMES_WHY="the ranges of Iran: $GEO_WHY"; return 1; fi
            read -r server _ <<<"$(dns_upstream)"
            out=$(python3 -I "$GEO_PY" abroad --source "$GEO_SOURCE" --file ir.txt --ranges "$(country_list ir)" --server "$server" \
                --port "$NAMES_DNS_PORT" --out "$(name_list_file abroad)" 2>&1) || rc=$? ;;
        *) return 1 ;;
    esac
    if (( rc != 0 )); then
        NAMES_WHY=$(tail -n 1 <<<"$out")
        NAMES_WHY=$(safe_text "${NAMES_WHY:-the download failed}")
        return 1
    fi
    count=$(sed -n 's/^names=\([0-9]*\)$/\1/p' <<<"$out")
    info=$(mktemp "$GEO_DIR/.names.XXXXXXXX") || return 1
    darban_tmp_register "$info"
    printf 'date %s\nnames %s\n' "$(date -u +%Y-%m-%d)" "${count:-0}" >"$info" && chmod 600 "$info" && mv -f -- "$info" "$GEO_DIR/names-$list.info"
}
names_zone_write() {
    # The zone from the lists on and the owner's names, replaced in one step; gone when there is nothing to block.
    local list lists=()
    if ! names_in_use; then rm -f -- "$UNBOUND_RPZ"; return 0; fi
    for list in $NAME_LISTS; do
        [[ -s $(name_list_file "$list") ]] || { NAMES_WHY="the list $(name_list_title "$list") is not on this server"; return 1; }
        lists+=(--list "$(name_list_file "$list")")
    done
    install -d -m 755 "${UNBOUND_RPZ%/*}" || return 1
    python3 -I "$GEO_PY" rpz "${lists[@]}" --block "$NAMES_BLOCK" --allow "$NAMES_ALLOW" --out "$UNBOUND_RPZ" >/dev/null \
        || { NAMES_WHY='the zone of blocked names could not be written'; return 1; }
}
names_commit() {
    # names_commit <lists> <block> <allow>: the zone and Unbound from these settings, then the settings saved. When
    # Unbound does not take them, everything stays as it was.
    local old_lists=$NAME_LISTS old_block=$NAMES_BLOCK old_allow=$NAMES_ALLOW zone_old had_zone=0
    ca_lock || return 1
    NAME_LISTS=$1 NAMES_BLOCK=$2 NAMES_ALLOW=$3
    if [[ $DNS_SERVER == yes ]]; then
        zone_old=$(mktemp) || return 1
        darban_tmp_register "$zone_old"
        if [[ -f $UNBOUND_RPZ ]]; then cp -a -- "$UNBOUND_RPZ" "$zone_old" && had_zone=1; fi
        if ! names_zone_write || ! unbound_apply; then
            NAME_LISTS=$old_lists NAMES_BLOCK=$old_block NAMES_ALLOW=$old_allow
            if (( had_zone )); then cp -a -- "$zone_old" "$UNBOUND_RPZ"; else rm -f -- "$UNBOUND_RPZ"; fi
            fail "The blocked names were not changed: ${NAMES_WHY:-$DNS_WHY}."
            return 1
        fi
    fi
    save_config || { fail 'The setting could not be saved.'; return 1; }
}
names_effect() {
    # How the change reaches clients: at once, or when DNS on this server is turned on.
    if [[ $DNS_SERVER == yes ]]; then printf 'Applied at once; only Unbound restarted.'; else printf 'It applies when DNS on this server is turned on (item 1).'; fi
}
valid_name_list_tokens() { local token; [[ -n $1 ]] || return 1; for token in $1; do [[ $token =~ ^[1-3]$ ]] || return 1; done; }
set_name_lists() {
    local lists=(abroad ads malware) i mark list new token added=() kept=()
    info "Names Unbound answers \"no such name\" for, with every name under them. Clients reach none of these sites through this server, and they never see its address."
    say
    for i in 0 1 2; do
        list=${lists[i]}
        mark='[ ]'
        if [[ " $NAME_LISTS " == *" $list "* ]]; then mark='[x]'; fi
        say "  $C_KEY$((i + 1))$C_RESET  $mark $(printf '%-28s' "$(name_list_title "$list")") $(name_list_value "$list" names)"
    done
    say
    bullet 'Iranian sites hosted abroad: about one Iranian site in five; the server asks for every name of Iran once a week, which takes a few minutes'
    bullet 'the lists come from github.com/Chocolate4U/Iran-v2ray-rules and are updated every day; about 92,000 names of ads, 17,000 of malware'
    say
    prompt_valid 'Numbers to turn on or off, such as 1 3 (Enter = cancel): ' valid_name_list_tokens 'Enter numbers from 1 to 3, separated by spaces.' || return 0
    new=" $NAME_LISTS "
    for token in $REPLY; do
        list=${lists[token - 1]}
        if [[ $new == *" $list "* ]]; then new=${new/ $list / }; else new+="$list "; fi
    done
    # Always in the same order.
    for list in "${lists[@]}"; do [[ $new == *" $list "* ]] && kept+=("$list"); done
    new="${kept[*]}"
    if [[ $new == "$NAME_LISTS" ]]; then info 'Same as now; nothing changed.'; return 0; fi
    kv Now "$(name_lists_label "$NAME_LISTS")"
    kv New "$(name_lists_label "$new")"
    say
    confirm_choice 'Apply this change?' 'No, keep them as they are' 'Apply' caution || { cancelled; return 0; }
    kept=()
    for list in $new; do
        if [[ " $NAME_LISTS " == *" $list "* && -s $(name_list_file "$list") ]]; then kept+=("$list"); continue; fi
        info "Downloading the list $(name_list_title "$list")${S_ELL}"
        if names_fetch "$list"; then
            kept+=("$list")
        elif [[ -s $(name_list_file "$list") ]]; then
            warn "A new list $(name_list_title "$list") could not be made: $NAMES_WHY. The one from $(name_list_value "$list" date) is used."
            kept+=("$list")
        else
            warn "The list $(name_list_title "$list") could not be made: $NAMES_WHY. It is left out."
        fi
    done
    new="${kept[*]}"
    if [[ $new == "$NAME_LISTS" ]]; then fail 'Nothing was changed.'; return 1; fi
    names_commit "$new" "$NAMES_BLOCK" "$NAMES_ALLOW" || return 1
    if [[ -n $NAME_LISTS ]]; then
        systemctl enable --now darban-geo.timer >/dev/null 2>&1 || warn 'The daily update of the lists did not start. See: systemctl status darban-geo.timer'
    elif [[ -z $BLOCK_COUNTRIES ]]; then
        systemctl disable --now darban-geo.timer >/dev/null 2>&1 || true
    fi
    audit "blocked names: lists $(name_lists_label "$NAME_LISTS")"
    ok "Saved: name lists $(name_lists_label "$NAME_LISTS"). $(names_effect)"
}
valid_own_name_choice() {
    if [[ $1 =~ ^[0-9]{1,3}$ ]]; then (( 10#$1 >= 1 && 10#$1 <= OWN_COUNT )); return; fi
    python3 -I "$GEO_PY" name "$1" >/dev/null 2>&1
}
set_own_names() {
    # set_own_names <block|allow>: the owner's own names of one kind: a name typed is added, a number removes one.
    local kind=$1 current words i entry kept=() block=$NAMES_BLOCK allow=$NAMES_ALLOW
    if [[ $kind == block ]]; then current=$NAMES_BLOCK; else current=$NAMES_ALLOW; fi
    read -ra words <<<"$current"
    if [[ $kind == block ]]; then
        info 'A name to block, such as example.com: it and every name under it answer "no such name".'
    else
        info 'A name that always passes, with every name under it, even when a list blocks it: for a site a list blocks by mistake.'
    fi
    for i in "${!words[@]}"; do say "  $C_KEY$((i + 1))$C_RESET  ${words[i]}"; done
    say
    OWN_COUNT=${#words[@]}
    prompt_valid "A name to add$( (( OWN_COUNT )) && printf ', or the number of one to remove') (Enter = cancel): " valid_own_name_choice \
        'Enter a name such as example.com, or a number from the list.' || return 0
    if [[ $REPLY =~ ^[0-9]{1,3}$ ]]; then
        entry=${words[10#$REPLY - 1]}
        for i in "${!words[@]}"; do (( i == 10#$REPLY - 1 )) || kept+=("${words[i]}"); done
        current="${kept[*]}"
    else
        entry=$(python3 -I "$GEO_PY" name "$REPLY") || return 1
        if [[ " $current " == *" $entry "* ]]; then info "$entry is there already; nothing changed."; return 0; fi
        if (( OWN_COUNT >= NAMES_OWN_MAX )); then fail "At most $NAMES_OWN_MAX names of each kind. Remove one first."; return 1; fi
        current="${current:+$current }$entry"
    fi
    if [[ $kind == block ]]; then block=$current; else allow=$current; fi
    names_commit "$NAME_LISTS" "$block" "$allow" || return 1
    audit "blocked names: $kind list $current"
    if [[ $REPLY =~ ^[0-9]{1,3}$ ]]; then ok "Removed: $entry. $(names_effect)"; return 0; fi
    if [[ $kind == block ]]; then ok "Blocked: $entry. $(names_effect)"; else ok "Allowed: $entry. $(names_effect)"; fi
}
set_names_block() { set_own_names block; }
set_names_allow() { set_own_names allow; }
update_name_lists() {
    # update_name_lists [daily]: a new copy of each list on. The daily job makes Iranian sites abroad again only
    # once a week, since it asks the upstream DNS for every name of Iran.
    local list failed=0 date age summary=''
    if [[ -z $NAME_LISTS ]]; then info 'No name list is on. Item 6 turns them on.'; return 0; fi
    for list in $NAME_LISTS; do
        if [[ ${1:-} == daily && $list == abroad ]]; then
            date=$(name_list_value abroad date)
            age=$(( ($(date -u +%s) - $(date -u -d "${date:-1970-01-01}" +%s 2>/dev/null || echo 0)) / 86400 ))
            if (( age < 7 )); then continue; fi
        fi
        info "Downloading the list $(name_list_title "$list")${S_ELL}"
        if ! names_fetch "$list"; then
            failed=1
            fail "The list $(name_list_title "$list") was not updated: $NAMES_WHY. The one from $(name_list_value "$list" date) stays in use."
            audit "blocked names: the list $(name_list_title "$list") was not updated: $NAMES_WHY"
        fi
    done
    names_commit "$NAME_LISTS" "$NAMES_BLOCK" "$NAMES_ALLOW" || return 1
    (( ! failed )) || return 1
    for list in $NAME_LISTS; do summary+="${summary:+, }$(name_list_short "$list") $(name_list_value "$list" names) names"; done
    ok "The name lists are up to date: $summary."
}
geo_daily() {
    # What darban-geo.timer runs each day: the lists of countries, then the name lists.
    local rc=0
    if [[ -n $BLOCK_COUNTRIES || -n $BLOCK_EXTRA || -z $NAME_LISTS ]]; then update_lists || rc=1; fi
    if [[ -n $NAME_LISTS ]]; then update_name_lists daily || rc=1; fi
    return "$rc"
}
names_health() {
    # Unbound has the zone of blocked names, and the lists are renewed.
    local zone list date age oldest='' name=''
    names_in_use || return 0
    zone=$(grep -c ' CNAME \.$' "$UNBOUND_RPZ" 2>/dev/null) || zone=0
    if [[ ! -s $UNBOUND_RPZ ]] || ! grep -q '^rpz:' "$UNBOUND_CONF" 2>/dev/null; then
        check bad "Names should be blocked, but Unbound has no zone of them $S_ARROW sudo darban, then Settings > DNS on this server > 9"
        return 0
    fi
    check ok "DNS on this server blocks $(( zone / 2 )) names ($(name_lists_label "$NAME_LISTS"), and $(names_count_label "$NAMES_BLOCK") of your own)"
    for list in $NAME_LISTS; do
        date=$(name_list_value "$list" date)
        if [[ -z $oldest || ${date:-0000} < $oldest ]]; then oldest=${date:-0000}; name=$(name_list_title "$list"); fi
    done
    [[ -n $oldest ]] || return 0
    [[ $oldest != 0000 ]] || oldest=1970-01-01
    age=$(( ($(date -u +%s) - $(date -u -d "$oldest" +%s 2>/dev/null || echo 0)) / 86400 ))
    if (( age > 14 )); then
        check warn "The list $name is $age days old: its update fails $S_ARROW sudo systemctl status darban-geo.service"
    fi
}

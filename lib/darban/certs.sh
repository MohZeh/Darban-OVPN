#!/usr/bin/env bash
# The certificate the links use: Certbot, the pairs it is kept in, and one already on this server.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

link_cert_usable() {
    # link_cert_usable <host> [seconds]: valid that much longer, by default an hour longer than a link lasts,
    # and for the address clients will open.
    local host=$1 seconds=${2:-$(( ($(link_hours) + 1) * 3600 ))} check
    [[ -s $LINK_CERT && -s $LINK_KEY ]] || return 1
    openssl x509 -in "$LINK_CERT" -noout -checkend "$seconds" >/dev/null 2>&1 || return 1
    # A key and a certificate that do not belong together, whatever left them so, are replaced like any
    # unusable pair, instead of stopping every link until the certificate is changed by hand.
    cert_key_matches "$LINK_CERT" "$LINK_KEY" || return 1
    if host_is_ip "$host"; then check=-checkip; else check=-checkhost; fi
    openssl x509 -in "$LINK_CERT" -noout "$check" "$host" 2>/dev/null | grep 'does match' >/dev/null
}
link_cert_source() {
    # Where the links' certificate came from: letsencrypt (this tool's), copied (from another tool or a file),
    # self-signed, or none.
    local kind
    if [[ ! -s $LINK_CERT ]]; then printf 'none\n'; return; fi
    if kind=$(link_pair_kind); then printf '%s\n' "$kind"; return; fi
    # A pair from before v1.0.0, until its first change.
    if [[ -s $LINK_CERT_SOURCE ]]; then printf 'copied\n'
    elif [[ -L $LINK_CERT ]]; then printf 'letsencrypt\n'
    else printf 'self-signed\n'
    fi
}
link_cert_problem() {
    # link_cert_problem [host]: why a browser would warn about the links' certificate now, or nothing when it
    # would not. Whatever the certificate came from: the same check for the menu, the note and the password.
    local host=${1:-$(domain)}
    if [[ ! -s $LINK_CERT || ! -s $LINK_KEY ]]; then printf 'there is none yet\n'; return; fi
    if ! openssl x509 -in "$LINK_CERT" -noout -checkend 0 >/dev/null 2>&1; then printf 'it ended on %s\n' "$(cert_end_date "$LINK_CERT")"; return; fi
    if ! cert_covers "$LINK_CERT" "$host"; then printf 'it is not for %s\n' "$host"; return; fi
    if ! cert_key_matches "$LINK_CERT" "$LINK_KEY"; then printf 'its key does not belong to it\n'; return; fi
    if ! cert_publicly_trusted "$LINK_CERT"; then printf 'browsers do not trust who issued it\n'; fi
}
link_cert_is_trusted() { [[ -z $(link_cert_problem "${1:-}") ]]; }
have_snap() { command -v snap >/dev/null; }
version_at_least() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1) == "$2" ]]; }
find_certbot() {
    # find_certbot <minimum version>: prints a certbot that is new enough, if there is one.
    local candidate version
    for candidate in /snap/bin/certbot "$(command -v certbot 2>/dev/null || true)"; do
        [[ -n $candidate && -x $candidate ]] || continue
        version=$("$candidate" --version 2>/dev/null | awk '{print $2; exit}') || continue
        if [[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] && version_at_least "$version" "$1"; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}
record_added() {
    # What the server setup's record lists is what Remove everything takes away again.
    local marker=$CONFIG_DIR/.server-setup-started
    if [[ -e $marker ]]; then printf '%s\n' "$1" >>"$marker" || true; fi
}
install_certbot() {
    # install_certbot <minimum version>: Ubuntu's own package when it is new enough; otherwise the Certbot
    # project's snap. There is no third way: get_trusted_cert does not offer one without snap.
    # How long each part took goes to the journal (journalctl -t darban), so a slow one shows where the time went.
    local need=$1 start rc=0
    start=$SECONDS
    apt-get -o DPkg::Lock::Timeout=120 -qq update >/dev/null || rc=$?
    audit "certbot install, apt update: $((SECONDS - start)) s, exit $rc"
    rc=0
    start=$SECONDS
    if [[ $need == 0 ]]; then
        info "Installing certbot from Ubuntu${S_ELL}"
        apt-get -o DPkg::Lock::Timeout=120 -y -q --no-install-recommends install certbot >/dev/null || rc=$?
        audit "certbot from apt: $((SECONDS - start)) s, exit $rc"
        (( rc == 0 )) || return 1
        record_added 'package certbot'
    else
        info "Installing certbot from the Certbot project (snap)${S_ELL}"
        # Recorded for removal only when this install put it here; one that was there is only refreshed.
        darban_snap_install_certbot "$CONFIG_DIR/.server-setup-started" || rc=$?
        audit "certbot from the snap store: $((SECONDS - start)) s, exit $rc"
        (( rc == 0 )) || return 1
    fi
}
get_trusted_cert() {
    # get_trusted_cert <host> [asked]: Let's Encrypt for a hostname or a public IP address. It needs TCP 80
    # from the internet for a moment. "asked" means the person already chose it, so there is no question.
    local host=$1 asked=${2:-} need=0 certbot renewing=0
    local -a target
    if host_is_ip "$host"; then
        is_private_ip "$host" && return 1
        need=$CERTBOT_IP_MIN
        target=(--preferred-profile shortlived --ip-address "$host")
    else
        target=(-d "$host")
    fi
    if [[ $need != 0 ]] && ! find_certbot "$need" >/dev/null && ! have_snap; then
        info "A trusted certificate for an IP address needs certbot $CERTBOT_IP_MIN or newer. Ubuntu does not ship it yet, and this server has no snap to get it from the Certbot project."
        return 1
    fi
    # The certificate of an earlier request is renewed: certbot then tells Let's Encrypt which one it replaces
    # (ARI), and such a renewal can be exempt from the weekly limit.
    if [[ -s $LE_DIR/renewal/$CERT_NAME.conf ]] && cert_covers "$LE_DIR/live/$CERT_NAME/fullchain.pem" "$host"; then renewing=1; fi
    if [[ $asked != asked ]]; then
        say
        info "A trusted certificate means no browser warning for the person opening the link. It needs TCP port 80 open for a moment, and yes accepts the Let's Encrypt subscriber agreement."

        if (( renewing )); then
            choose_one 'Renew the Let'"'"'s Encrypt certificate this server got earlier?' 'Yes, renew it' 'No, use a self-signed certificate (browser warning)' || return 1
        else
            choose_one 'Get a free Let'"'"'s Encrypt certificate?' 'Yes, get a certificate' 'No, use a self-signed certificate (browser warning)' || return 1
        fi
        (( CHOSEN == 1 )) || return 1
    fi
    if [[ $need != 0 ]]; then
        info "For an IP address it lasts six days, and a new one is requested when a link needs it. It needs certbot $CERTBOT_IP_MIN or newer, from the Certbot project."
    fi
    if tcp_port_taken 80; then warn "TCP port 80 is used by $(safe_text "$(tcp_port_program 80)"), so certbot cannot answer on it."; return 1; fi
    if ! certbot=$(find_certbot "$need"); then
        install_certbot "$need" || { warn 'Could not install certbot.'; return 1; }
        certbot=$(find_certbot "$need") || { warn "No certbot $need or newer is available."; return 1; }
    fi
    local live=$LE_DIR/live/$CERT_NAME/fullchain.pem before after out used next rc=0 kind=new
    before=$(cert_fingerprint "$live")
    out=$(mktemp) || return 1
    if (( renewing )); then
        set_link_renew_hook present || true
        # Nothing is done when it is not due yet.
        kind=renew
        info "Renewing the certificate for $host${S_ELL}"
        "$certbot" renew --non-interactive --cert-name "$CERT_NAME" --no-random-sleep-on-renew >"$out" 2>&1 || rc=$?
    else
        # This server's record is only an estimate: Let's Encrypt keeps the count, and refuses with its own time
        # when the week is used up. A refused request changes nothing here, so it is asked anyway.
        read -r used next <<<"$(issue_budget "$host")"
        if (( next > 0 )); then
            warn "This server recorded $used new certificates for $host in the last 7 days. Let's Encrypt gives 5 a week for the same address, one more every 34 hours, so it may refuse until about $(date -u -d "@$next" '+%Y-%m-%d %H:%M UTC'). Asking anyway."
        fi
        info "Requesting a certificate for $host${S_ELL}"
        "$certbot" certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --cert-name "$CERT_NAME" \
            "${target[@]}" --deploy-hook "$SBIN_DIR/darban reload-links" >"$out" 2>&1 || rc=$?
    fi
    if (( rc != 0 )); then
        explain_certbot_failure "$out"
        rm -f -- "$out"
        return 1
    fi
    rm -f -- "$out"
    after=$(cert_fingerprint "$live")
    if [[ -n $after && $after != "$before" ]]; then
        log_link_cert_issue "$host" "$kind"
        if [[ $kind == renew ]]; then
            use_own_cert "Renewed: the certificate for $host is valid until $(cert_end_date "$live")."
        else
            use_own_cert "New certificate from Let's Encrypt for $host, valid until $(cert_end_date "$live")."
        fi
    else
        # certbot succeeds without doing anything while the certificate is not due: no new one, and none counted.
        use_own_cert "Not due for renewal yet: the certificate for $host stays valid until $(cert_end_date "$live"). Nothing was issued."
    fi
}
cert_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'; }
explain_certbot_failure() {
    # explain_certbot_failure <certbot output>: the weekly limit is named with the time Let's Encrypt gave.
    local retry
    if grep -qiE 'too many certificates|rateLimited' "$1"; then
        retry=$(grep -oiE 'retry after [0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]+( UTC)?' "$1" | head -n 1 | cut -c13-)
        warn "Let's Encrypt gives at most 5 new certificates a week for the same address, and they are used up${retry:+. The next one can be issued after $retry}."
    else
        warn 'certbot could not get a certificate. Check that the address points here and TCP 80 is open in the provider firewall.'
        info "Details: $(cmd tail -n 20 /var/log/letsencrypt/letsencrypt.log)"
    fi
}
log_link_cert_issue() {
    # log_link_cert_issue <host> <new|renew>: one line per certificate Let's Encrypt issued for the links that this
    # tool asked for, "<time> <address> <kind>". The first two fields are what v1.0.0-rc.8 reads. Renewals by
    # certbot's own timer do not pass through here.
    install -d -m 700 "${LINK_CERT_LOG%/*}" 2>/dev/null || return 0
    printf '%s %s %s\n' "$(date -u +%s)" "$1" "$2" >>"$LINK_CERT_LOG" 2>/dev/null || return 0
    chmod 600 "$LINK_CERT_LOG" 2>/dev/null || true
    audit "link certificate from Let's Encrypt for $1 ($2)"
}
issue_counts() {
    # issue_counts <host>: "<new> <renewals> <unknown>" recorded in the last 7 days. A line written before the kind
    # was recorded is unknown.
    [[ -s $LINK_CERT_LOG ]] || { printf '0 0 0\n'; return; }
    awk -v host="$1" -v now="$(date -u +%s)" '
        $2 == host && $1 ~ /^[0-9]+$/ && now - $1 < 604800 { if ($3 == "new") n++; else if ($3 == "renew") r++; else u++ }
        END { print n + 0, r + 0, u + 0 }' "$LINK_CERT_LOG"
}
issue_budget() {
    # issue_budget <host>: "<new in the last 7 days> <epoch when another one should be allowed, or 0>", an
    # estimate from this server's own record. Let's Encrypt counts 5 a week for one address and gives one back
    # every 34 hours. Renewals are left out: certbot asks for them as such, and they can be exempt. A line of
    # unknown kind counts, as before.
    [[ -s $LINK_CERT_LOG ]] || { printf '0 0\n'; return; }
    awk -v host="$1" -v now="$(date -u +%s)" '
        $2 == host && $1 ~ /^[0-9]+$/ && $3 != "renew" {
            if (seen == 0) tokens = 5; else { tokens += ($1 - last) / 122400; if (tokens > 5) tokens = 5 }
            tokens -= 1; last = $1; seen++
            if (now - $1 < 604800) week++
        }
        END {
            if (seen == 0) { print 0, 0; exit }
            tokens += (now - last) / 122400; if (tokens > 5) tokens = 5
            print week + 0, (tokens >= 1 ? 0 : int(now + (1 - tokens) * 122400 + 1))
        }' "$LINK_CERT_LOG"
}
own_cert_usable() {
    # own_cert_usable <host>: the certificate this tool got earlier, kept through a removal, still serves host.
    local dir=$LE_DIR/live/$CERT_NAME
    [[ -s $dir/fullchain.pem && -s $dir/privkey.pem ]] || return 1
    [[ -z $(cert_problem "$dir/fullchain.pem" "$dir/privkey.pem" "$1" "$(link_lifetime_seconds)") ]]
}
link_lifetime_seconds() { printf '%s\n' "$(( ($(link_hours) + 1) * 3600 ))"; }
own_cert_renewable() {
    # This tool's certificate for host can be renewed: certbot knows it, and it names host.
    [[ -s $LE_DIR/renewal/$CERT_NAME.conf ]] && cert_covers "$LE_DIR/live/$CERT_NAME/fullchain.pem" "$1"
}
explain_kept_cert() {
    # A Let's Encrypt certificate this tool got before, kept through a removal, that cannot serve host: why, so
    # nobody wonders why a certificate is asked for again.
    local host=$1 dir=$LE_DIR/live/$CERT_NAME names problem
    [[ -s $dir/fullchain.pem ]] || return 0
    if ! cert_covers "$dir/fullchain.pem" "$host"; then
        names=$(openssl x509 -in "$dir/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | sed -n '2p' | sed 's/^ *//; s/DNS://g; s/IP Address://g')
        info "The Let's Encrypt certificate kept on this server is for ${names:-another address}, not $host, so a new one is needed."
        return 0
    fi
    problem=$(cert_problem "$dir/fullchain.pem" "$dir/privkey.pem" "$host" "$(link_lifetime_seconds)")
    [[ -n $problem ]] || return 0
    if [[ -s $LE_DIR/renewal/$CERT_NAME.conf ]]; then
        info "The Let's Encrypt certificate kept on this server for $host cannot be used as it is: $problem It can be renewed instead of asked for anew."
    else
        info "The Let's Encrypt certificate kept on this server for $host cannot be used: $problem"
    fi
}
use_own_cert() {
    # use_own_cert [message]: the links take a copy of the certificate this tool got, and say so. The copy is a
    # snapshot: a renewal by certbot reaches the links through its hook, darban reload-links.
    # Recorded only once it exists, so a removal never deletes a certificate this tool did not get.
    record_added "certbot_cert $CERT_NAME"
    # A certificate kept through an uninstall has no hook of this tool any more: it gets it back here.
    set_link_renew_hook present || true
    if with_link_lock link_pair_install letsencrypt "$LE_DIR/live/$CERT_NAME/fullchain.pem" "$LE_DIR/live/$CERT_NAME/privkey.pem"; then
        if [[ -n ${1:-} ]]; then
            ok "$1"
        else
            ok "Links use the Let's Encrypt certificate this server got earlier, valid until $(cert_end_date "$LINK_CERT"). Nothing was requested."
        fi
        return 0
    fi
    warn 'The certificate could not be put in place; the current one stays.'
    return 1
}
make_self_signed_cert() {
    # Made in a folder of its own and then put in use, so a failure keeps the old pair.
    with_link_lock link_pair_self_signed "$1" && return 0
    fail 'Could not create a certificate for the link.'
    return 1
}

# ---------- the certificate pair the links use ----------
# Each certificate is kept with its key in a folder of its own, link-cert/pairs/<id>, with a file that says where it
# came from. link-cert/current points at the pair in use and is changed by one rename, and link-cert.pem,
# link-key.pem and link-cert.source point through it. So a reader never gets the certificate of one pair with the
# key of another, and the pair used before a change is still whole and can be put back.
# A change takes the CA lock. A session marks the pairs it still needs in hold.<pid>, so another session cleaning
# up never deletes them.
link_pair_layout() {
    [[ $(readlink "$LINK_CERT" 2>/dev/null) == link-cert/current/fullchain.pem \
        && $(readlink "$LINK_KEY" 2>/dev/null) == link-cert/current/privkey.pem ]]
}
link_pair_current() {
    local target
    target=$(readlink "$LINK_PAIRS/current" 2>/dev/null) || return 1
    target=${target##*/}
    [[ -n $target && -d $LINK_PAIRS/pairs/$target ]] || return 1
    printf '%s\n' "$target"
}
link_pair_kind() {
    # letsencrypt, copied or self-signed: what the pair in use says of itself.
    local id kind=''
    link_pair_layout && id=$(link_pair_current) || return 1
    [[ -r $LINK_PAIRS/pairs/$id/kind ]] && IFS= read -r kind <"$LINK_PAIRS/pairs/$id/kind"
    [[ -n $kind ]] || return 1
    printf '%s\n' "$kind"
}
with_link_lock() {
    # with_link_lock <command>...: runs it holding the CA lock, which every change of the pair takes. A lock the
    # caller already holds stays held.
    local had=$CA_LOCKED rc=0
    ca_lock || return 1
    "$@" || rc=$?
    (( had )) || ca_unlock
    return "$rc"
}
link_pair_hold() {
    # link_pair_hold <id>...: this session needs these pairs until link_pair_settle.
    install -d -m 700 "$LINK_PAIRS" || return 1
    printf '%s\n' "$@" >>"$LINK_PAIRS/hold.$$"
}
link_pair_settle() {
    # The end of a change: this session needs no pair any more, and every pair nobody uses or holds goes.
    local current file pid id dir
    local -A keep=()
    rm -f -- "$LINK_PAIRS/hold.$$"
    [[ -d $LINK_PAIRS/pairs ]] || return 0
    if current=$(link_pair_current); then keep[$current]=1; fi
    for file in "$LINK_PAIRS"/hold.*; do
        [[ -e $file ]] || continue
        pid=${file##*.}
        if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            while IFS= read -r id; do [[ -n $id ]] && keep[$id]=1; done <"$file"
        else
            rm -f -- "$file"
        fi
    done
    for dir in "$LINK_PAIRS"/pairs/*; do
        [[ -d $dir ]] || continue
        id=${dir##*/}
        [[ -v keep[$id] ]] || rm -rf -- "$dir"
    done
}
link_pair_name() {
    # link_pair_name <path> <target>: one rename makes path point at target, once.
    [[ $(readlink "$1" 2>/dev/null) == "$2" ]] && return 0
    rm -f -- "$1.new"
    ln -s "$2" "$1.new" && mv -fT -- "$1.new" "$1" || { rm -f -- "$1.new"; return 1; }
}
link_pair_switch() {
    # link_pair_switch <id>: one rename puts the pair in use. The names the link service opens point through it.
    local temp=$LINK_PAIRS/.current.new
    rm -f -- "$temp"
    ln -s "pairs/$1" "$temp" && mv -fT -- "$temp" "$LINK_PAIRS/current" || { rm -f -- "$temp"; return 1; }
    link_pair_name "$LINK_KEY" link-cert/current/privkey.pem \
        && link_pair_name "$LINK_CERT" link-cert/current/fullchain.pem \
        && link_pair_name "$LINK_CERT_SOURCE" link-cert/current/origin
}
link_pair_discard() {
    # link_pair_discard <dir>: a pair that failed goes, unless it was already put in use.
    [[ $(link_pair_current 2>/dev/null) == "${1##*/}" ]] || rm -rf -- "$1"
}
link_pair_new() {
    # An empty folder for a pair, which nothing uses until link_pair_switch.
    install -d -m 700 "$LINK_PAIRS" "$LINK_PAIRS/pairs" || return 1
    mktemp -d "$LINK_PAIRS/pairs/XXXXXXXX"
}
link_pair_install() {
    # link_pair_install <kind> <cert> <key> [host] [origin cert] [origin key]: a copy of the pair in a folder of its
    # own, checked there as a pair, and for host when one is given, then put in use. A renewal elsewhere between the
    # two copies gives a pair that does not match, which is refused. On failure the pair in use is unchanged.
    local kind=$1 cert=$2 key=$3 host=${4:-} dir
    link_pair_migrate
    dir=$(link_pair_new) || return 1
    if cp -L -- "$cert" "$dir/fullchain.pem" && cp -L -- "$key" "$dir/privkey.pem" \
        && chmod 600 "$dir/fullchain.pem" "$dir/privkey.pem" \
        && cert_key_matches "$dir/fullchain.pem" "$dir/privkey.pem" \
        && { [[ -z $host ]] || [[ -z $(cert_problem "$dir/fullchain.pem" "$dir/privkey.pem" "$host") ]]; } \
        && printf '%s\n' "$kind" >"$dir/kind" \
        && { [[ -z ${5:-} ]] || printf '%s\n%s\n' "$5" "$6" >"$dir/origin"; } \
        && link_pair_hold "${dir##*/}" && link_pair_switch "${dir##*/}"; then
        return 0
    fi
    link_pair_discard "$dir"
    return 1
}
link_pair_migrate() {
    # A pair from before v1.0.0, two files or two links into /etc/letsencrypt, gets a folder of its own once. One
    # that cannot be read as a pair is left for the next install to replace.
    local kind origin_cert='' origin_key='' dir
    rm -f -- "$CONFIG_DIR/.link-cert.prev" "$CONFIG_DIR/.link-key.prev" "$CONFIG_DIR/.link-cert.source.prev"
    link_pair_layout && return 0
    [[ -s $LINK_CERT && -s $LINK_KEY ]] || return 0
    if [[ -s $LINK_CERT_SOURCE ]]; then
        kind=copied
        { IFS= read -r origin_cert; IFS= read -r origin_key; } <"$LINK_CERT_SOURCE" || true
    elif [[ -L $LINK_CERT ]]; then
        kind=letsencrypt
    else
        kind=self-signed
    fi
    dir=$(link_pair_new) || return 0
    if cp -L -- "$LINK_CERT" "$dir/fullchain.pem" && cp -L -- "$LINK_KEY" "$dir/privkey.pem" \
        && chmod 600 "$dir/fullchain.pem" "$dir/privkey.pem" \
        && cert_key_matches "$dir/fullchain.pem" "$dir/privkey.pem" \
        && printf '%s\n' "$kind" >"$dir/kind" \
        && { [[ -z $origin_cert ]] || printf '%s\n%s\n' "$origin_cert" "$origin_key" >"$dir/origin"; } \
        && link_pair_hold "${dir##*/}" && link_pair_switch "${dir##*/}"; then
        return 0
    fi
    link_pair_discard "$dir"
    return 0
}
link_pair_self_signed() {
    # link_pair_self_signed <host>: made in a folder of its own and then put in use.
    local host=$1 san dir
    if host_is_ip "$host"; then san=IP:$host; else san=DNS:$host; fi
    link_pair_migrate
    dir=$(link_pair_new) || return 1
    if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" \
        -days 90 -subj "/CN=$host" -addext "subjectAltName=$san" >/dev/null 2>&1 \
        && chmod 600 "$dir/privkey.pem" "$dir/fullchain.pem" \
        && printf 'self-signed\n' >"$dir/kind" \
        && link_pair_hold "${dir##*/}" && link_pair_switch "${dir##*/}"; then
        return 0
    fi
    link_pair_discard "$dir"
    return 1
}

# ---------- a certificate that is already on this server ----------
cert_covers() {
    # cert_covers <cert> <host>: the certificate names this hostname or IP address.
    local check
    if host_is_ip "$2"; then check=-checkip; else check=-checkhost; fi
    openssl x509 -in "$1" -noout "$check" "$2" 2>/dev/null | grep 'does match' >/dev/null
}
cert_key_matches() {
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "$2" -pubout 2>/dev/null) || return 1
    [[ -n $cert_pub && $cert_pub == "$key_pub" ]]
}
cert_publicly_trusted() {
    # The first certificate in the file, checked against the system's trusted authorities with the rest of
    # the file as its chain: what a browser would accept from this file.
    local dir rc=0
    dir=$(mktemp -d) || return 1
    awk -v d="$dir" '/-----BEGIN CERTIFICATE-----/ {n++} n {print > (d (n == 1 ? "/leaf.pem" : "/chain.pem"))}' "$1" 2>/dev/null || rc=1
    if (( rc == 0 )) && [[ -s $dir/leaf.pem ]]; then
        if [[ -s $dir/chain.pem ]]; then
            openssl verify -purpose sslserver -CAfile "$SYSTEM_CA_FILE" -untrusted "$dir/chain.pem" "$dir/leaf.pem" >/dev/null 2>&1 || rc=1
        else
            openssl verify -purpose sslserver -CAfile "$SYSTEM_CA_FILE" "$dir/leaf.pem" >/dev/null 2>&1 || rc=1
        fi
    else
        rc=1
    fi
    rm -rf -- "$dir"
    return "$rc"
}
cert_is_cloudflare_origin() { openssl x509 -in "$1" -noout -issuer 2>/dev/null | grep -i 'cloudflare origin' >/dev/null; }
cert_end_date() { date -u -d "$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2)" +%Y-%m-%d 2>/dev/null; }
cert_start_date() { date -u -d "$(openssl x509 -in "$1" -noout -startdate 2>/dev/null | cut -d= -f2)" +%Y-%m-%d 2>/dev/null; }
existing_cert_pairs() {
    # Certificate and key pairs where other tools keep them: certbot, panels such as 3x-ui, and acme.sh.
    local root dir name
    for root in $CERT_SEARCH_DIRS; do
        for dir in "$root"/*/; do
            [[ -d $dir ]] || continue
            dir=${dir%/}
            name=${dir##*/}
            [[ $name == "$CERT_NAME" ]] && continue
            if [[ -s $dir/fullchain.pem && -s $dir/privkey.pem ]]; then
                printf '%s\t%s\n' "$dir/fullchain.pem" "$dir/privkey.pem"
            elif [[ -s $dir/fullchain.cer && -s $dir/${name%_ecc}.key ]]; then
                printf '%s\t%s\n' "$dir/fullchain.cer" "$dir/${name%_ecc}.key"
            fi
        done
    done
}
cert_problem() {
    # cert_problem <cert> <key> <host> [seconds]: why this pair cannot serve links, or nothing when it can. It must
    # stay valid that many seconds longer, a day and an hour by default.
    if [[ ! -s $1 ]]; then printf 'There is no certificate file at %s.\n' "$1"; return; fi
    if [[ ! -s $2 ]]; then printf 'There is no key file at %s.\n' "$2"; return; fi
    if ! openssl x509 -in "$1" -noout >/dev/null 2>&1; then printf '%s is not a PEM certificate.\n' "$1"; return; fi
    if ! cert_covers "$1" "$3"; then printf 'The certificate in %s is not for %s.\n' "$1" "$3"; return; fi
    if ! cert_key_matches "$1" "$2"; then printf 'The key in %s does not belong to that certificate.\n' "$2"; return; fi
    local seconds=${4:-90000} asked=${4:+1}
    if ! openssl x509 -in "$1" -noout -checkend "$seconds" >/dev/null 2>&1; then
        if [[ -z $asked ]]; then
            printf 'The certificate in %s ends within a day.\n' "$1"
        else
            printf 'The certificate in %s ends in less than %s hours, sooner than a link may last.\n' "$1" "$(( seconds / 3600 ))"
        fi
        return
    fi
    if cert_is_cloudflare_origin "$1"; then
        printf '%s\n' "The certificate in $1 is a Cloudflare Origin certificate. Browsers trust it only through Cloudflare's proxy, and the VPN address cannot go through that proxy, because OpenVPN uses UDP. The browser would still warn."
        return
    fi
    if ! openssl x509 -in "$1" -noout -purpose 2>/dev/null | grep -x 'SSL server : Yes' >/dev/null; then
        printf 'The certificate in %s is not made for a server, only to identify a client, so browsers would refuse it.\n' "$1"
        return
    fi
    if ! cert_publicly_trusted "$1"; then printf 'Browsers would not trust the certificate in %s: it is self-signed, or its file lacks the intermediate certificates.\n' "$1"; fi
}
find_existing_cert() {
    # Prints "cert<TAB>key<TAB>end date" of the trusted pair for this host that lasts longest.
    local host=$1 cert key end best='' best_end=''
    while IFS=$'\t' read -r cert key; do
        [[ -n $cert ]] || continue
        [[ -z $(cert_problem "$cert" "$key" "$host") ]] || continue
        end=$(cert_end_date "$cert") || continue
        if [[ -z $best || $end > $best_end ]]; then best="$cert"$'\t'"$key"$'\t'"$end"; best_end=$end; fi
    done < <(existing_cert_pairs)
    [[ -n $best ]] && printf '%s\n' "$best"
}
explain_untrusted_certs() {
    # A certificate for this host that cannot be used is named, so nobody wonders why it was passed over.
    local host=$1 cert key problem
    while IFS=$'\t' read -r cert key; do
        [[ -n $cert ]] && cert_covers "$cert" "$host" || continue
        problem=$(cert_problem "$cert" "$key" "$host")
        if [[ -n $problem ]]; then info "$problem"; fi
    done < <(existing_cert_pairs)
}
copy_cert_pair() {
    # copy_cert_pair <cert> <key> <host>: both files are copied into a folder of their own and checked there as a
    # pair, then put in use. A failure leaves the current pair as it was.
    with_link_lock link_pair_install copied "$1" "$2" "$3" "$1" "$2"
}
use_existing_cert() {
    # A copy, not a link: the link service cannot read /root. Each new link copies it again after a renewal.
    local cert=$1 key=$2 host
    host=$(domain)
    copy_cert_pair "$cert" "$key" "$host" || { fail "Could not take the certificate from $(safe_text "$cert"); the current one stays."; return 1; }
    audit "link certificate taken from $cert"
    ok "Links use the trusted certificate from $(safe_text "$cert"). When it is renewed there, the next link takes the new one."
}
refresh_link_pair() {
    # refresh_link_pair <host>: the links hold a copy, so a renewal where it came from is copied again: certbot's for
    # this tool's own certificate, another tool's for one taken from it. Returns 1 when the renewed pair could not
    # be taken, and the current one stays.
    local host=$1 cert='' key='' label
    case $(link_cert_source) in
        letsencrypt)
            # A link into /etc/letsencrypt from before v1.0.0 follows the renewal by itself, until its first change.
            link_pair_layout || return 0
            cert=$LE_DIR/live/$CERT_NAME/fullchain.pem key=$LE_DIR/live/$CERT_NAME/privkey.pem label="Let's Encrypt" ;;
        copied)
            [[ -r $LINK_CERT_SOURCE ]] && { IFS= read -r cert; IFS= read -r key; } <"$LINK_CERT_SOURCE"
            label=$(safe_text "$cert") ;;
        *) return 0 ;;
    esac
    [[ -n $cert && -n $key && -s $cert && -s $key ]] || return 0
    if cmp -s -- "$cert" "$LINK_CERT" && cmp -s -- "$key" "$LINK_KEY"; then return 0; fi
    if [[ $(link_cert_source) == letsencrypt ]]; then
        with_link_lock link_pair_install letsencrypt "$cert" "$key" || return 1
    else
        [[ -z $(cert_problem "$cert" "$key" "$host") ]] && copy_cert_pair "$cert" "$key" "$host" || return 1
    fi
    info "The link certificate was renewed in $label; links use the new one."
}
offer_trusted_cert() {
    # A trusted certificate already on this server comes first, then Let's Encrypt. Returns 1 when neither.
    local host=$1 found cert key end
    # The one this tool got before, kept through a removal: taken back without a question or a new request.
    if own_cert_usable "$host"; then use_own_cert; return; fi
    if own_cert_renewable "$host"; then
        info "The Let's Encrypt certificate kept on this server for $host ends sooner than a link may last. Renewing it${S_ELL}"
        get_trusted_cert "$host" asked
        return
    fi
    explain_kept_cert "$host"
    if found=$(find_existing_cert "$host"); then
        IFS=$'\t' read -r cert key end <<<"$found"
        say
        info "This server already has a trusted certificate for $host, in $(safe_text "$cert"), valid until $end."
        choose_one 'Which certificate should links use?' 'The one already on this server' "A new one from Let's Encrypt" 'A self-signed one (browser warning)' || return 1
        case $CHOSEN in
            1) use_existing_cert "$cert" "$key"; return ;;
            2) get_trusted_cert "$host" asked; return ;;
            *) return 1 ;;
        esac
    fi
    explain_untrusted_certs "$host"
    get_trusted_cert "$host"
}
set_link_renew_hook() {
    # set_link_renew_hook <present|absent>: certbot's renewal file of this tool's own certificate names this tool's
    # deploy hook, or does not. A hook someone else set there stays. An older hook, the one that restarted the link
    # service and so ended a download in progress, is moved to the reload.
    local conf=$LE_DIR/renewal/$CERT_NAME.conf
    [[ -e $conf ]] || return 0
    darban_renew_hook "$1" "$conf" "$SBIN_DIR/darban reload-links" "$DARBAN_RENEW_HOOK_OLD" && return 0
    warn "Could not change certbot's renewal file $conf, so it stays as it was. It should say: renew_hook = $SBIN_DIR/darban reload-links"
    return 1
}
reload_links_now() {
    # certbot's deploy hook: the renewed certificate is copied for the links, and reaches open links without ending
    # a download in progress. A link service from before v1.0.0-rc.9 would end on a reload, so it is restarted.
    local before='' rc=0
    with_link_lock link_pair_migrate || true
    before=$(link_pair_current) || before=''
    if [[ -n $before ]]; then link_pair_hold "$before" || true; fi
    refresh_link_pair "$(domain)" || true
    if systemctl is-active --quiet darban-links.service 2>/dev/null; then
        if [[ $(link_pair_current 2>/dev/null) != "$before" ]]; then
            put_link_cert_in_service "$before" || rc=1
        elif link_service_reloadable; then
            systemctl reload darban-links.service || rc=1
        else
            systemctl restart darban-links.service || rc=1
        fi
    fi
    with_link_lock link_pair_settle || true
    return "$rc"
}
ensure_link_cert() {
    # A usable certificate for a new link. The pairs this replaced go once it is done.
    local rc=0
    set_link_renew_hook present || true
    with_link_lock link_pair_migrate || true
    choose_link_cert "$1" || rc=$?
    with_link_lock link_pair_settle || true
    return "$rc"
}
choose_link_cert() {
    local host=$1 ends
    refresh_link_pair "$host" || true
    if link_cert_usable "$host"; then
        # A self-signed certificate is no reason to stop offering a trusted one: the question returns with each
        # link, and No keeps the current certificate.
        link_cert_is_trusted "$host" || offer_trusted_cert "$host" || true
        return 0
    fi
    if offer_trusted_cert "$host"; then return 0; fi
    # A trusted certificate that still works is kept, so open links do not change to a self-signed one.
    if link_cert_is_trusted "$host" && link_cert_usable "$host" 0; then
        ends=$(openssl x509 -in "$LINK_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
        warn "The current trusted certificate stays. It ends ${ends:-soon}; a link that lasts longer stops opening then."
        return 0
    fi
    make_self_signed_cert "$host"
}
link_cert_source_label() {
    case $(link_cert_source) in
        letsencrypt) printf "Let's Encrypt\n" ;;
        copied) printf 'from %s\n' "$(head -n 1 "$LINK_CERT_SOURCE")" ;;
        self-signed) printf 'self-signed\n' ;;
        *) printf 'none\n' ;;
    esac
}
link_cert_summary() {
    # The Settings line: whether browsers trust it now, then where it came from. Trust comes from the certificate
    # itself, never from its kind of file.
    local problem end days
    [[ -s $LINK_CERT ]] || { printf 'none yet\n'; return; }
    problem=$(link_cert_problem)
    if [[ -z $problem ]]; then
        end=$(openssl x509 -in "$LINK_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
        days=$(( ( $(date -u -d "$end" +%s 2>/dev/null || date -u +%s) - $(date -u +%s) ) / 86400 ))
        printf 'trusted, %s, %s days left\n' "$(link_cert_source_label)" "$days"
    elif [[ $(link_cert_source) == self-signed ]]; then
        printf 'self-signed, browser warning\n'
    else
        printf 'browser warning: %s\n' "$problem"
    fi
}
certbot_timer_active() { systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null || systemctl is-active --quiet certbot.timer 2>/dev/null; }
show_link_cert_details() {
    local host=$1 new renewed unknown
    kv Current "$(safe_text "$(link_cert_summary)")"
    if [[ -s $LINK_CERT ]]; then
        kv Valid "from $(cert_start_date "$LINK_CERT") until $(cert_end_date "$LINK_CERT")"
        case $(link_cert_source) in
            letsencrypt) kv Source "Let's Encrypt, in $LE_DIR/live/$CERT_NAME" ;;
            copied) kv Source "a copy of $(safe_text "$(head -n 1 "$LINK_CERT_SOURCE")")" ;;
            *) kv Source 'made on this server' ;;
        esac
        kv SHA-256 "$(cert_fingerprint "$LINK_CERT")"
    fi
    if [[ $(link_cert_source) == letsencrypt ]]; then
        if certbot_timer_active; then
            kv Renewal "certbot's timer is active; a link also renews it when needed"
        else
            kv Renewal "no certbot timer is active; a link renews it when needed"
        fi
    fi
    if ! { host_is_ip "$host" && is_private_ip "$host"; }; then
        read -r new renewed unknown <<<"$(issue_counts "$host")"
        kv Recorded "$new new, $renewed renewed$( (( unknown > 0 )) && printf ', %s of unknown kind' "$unknown") in the last 7 days, by this tool for $host"
        info "Let's Encrypt keeps the real count: 5 new certificates a week for one address, one more every 34 hours. Renewals by certbot's own timer are not recorded here."
    fi
    info 'The browser shows the same SHA-256 value in the certificate details of the link page.'
}
link_cert_renewal_line() {
    # One line for the main screen: how the certificate stays valid, only for this tool's Let's Encrypt one.
    [[ $(link_cert_source) == letsencrypt ]] || return 1
    if certbot_timer_active; then printf 'automatic\n'; else printf 'when a link needs it\n'; fi
}
change_link_cert() {
    # Two lines of state and four choices; everything else is one level down.
    local host renewal
    local -a labels=() actions=()
    host=$(domain)
    [[ -n $host ]] && valid_endpoint "$host" || { warn "Set the server address first: Settings $S_CRUMB 1."; return 1; }
    kv Current "$(safe_text "$(link_cert_summary)")"
    if renewal=$(link_cert_renewal_line); then kv Renewal "$renewal"; fi
    say
    labels+=('Keep it'); actions+=(keep)
    # Let's Encrypt cannot check a private address, so it is not offered there.
    if ! { host_is_ip "$host" && is_private_ip "$host"; }; then
        if own_cert_renewable "$host"; then labels+=('Renew now'); else labels+=('Get a trusted one'); fi
        actions+=(letsencrypt)
    fi
    labels+=('Use another certificate' 'Details'); actions+=(another details)
    choose_one 'What do you want to do?' "${labels[@]}" || { cancelled; return 0; }
    case ${actions[CHOSEN - 1]} in
        keep) info 'The current certificate stays.' ;;
        letsencrypt) change_link_cert_to "$host" letsencrypt ;;
        another) choose_another_cert "$host" ;;
        details) show_link_cert_details "$host" ;;
    esac
}
choose_another_cert() {
    local host=$1
    choose_one 'Which certificate should links use?' \
        'One another tool got (certbot, 3x-ui, acme.sh)' \
        'My own certificate files (fullchain and key)' \
        'A self-signed one (browser warning)' \
        'Back' || { cancelled; return 0; }
    case $CHOSEN in
        1) change_link_cert_to "$host" tool ;;
        2) change_link_cert_to "$host" files ;;
        3) change_link_cert_to "$host" self ;;
        *) info 'The current certificate stays.' ;;
    esac
}
change_link_cert_to() {
    # change_link_cert_to <host> <choice>: the change, then the running service takes it. 0: changed and served, or
    # nothing changed; 1: the change failed, or the service did not take it and the previous pair was put back.
    local host=$1 before='' rc=0
    with_link_lock link_pair_migrate || true
    before=$(link_pair_current) || before=''
    if [[ -n $before ]]; then link_pair_hold "$before" || { fail 'Could not keep the current certificate; nothing changed.'; return 1; }; fi
    change_link_cert_choice "$host" "$2" || rc=$?
    if [[ $(link_pair_current 2>/dev/null) != "$before" ]]; then put_link_cert_in_service "$before" || rc=1; fi
    with_link_lock link_pair_settle || true
    return "$rc"
}
change_link_cert_choice() {
    local host=$1 cert key guess problem found end
    case $2 in
        letsencrypt)
            # What it costs is said once it is chosen, not on the list.
            if own_cert_renewable "$host"; then
                info "certbot renews this tool's certificate only when it is due, and tells Let's Encrypt which one it replaces."
            else
                info "This asks Let's Encrypt for a new certificate for $host: one of the 5 it gives a week for one address."
            fi
            get_trusted_cert "$host" asked || warn "The current certificate stays$([[ -s $LINK_CERT ]] && printf ', valid until %s' "$(cert_end_date "$LINK_CERT")")." ;;
        tool)
            info "Looking where certbot, panels such as 3x-ui, and acme.sh keep certificates for $host${S_ELL}"
            if found=$(find_existing_cert "$host"); then
                IFS=$'\t' read -r cert key end <<<"$found"
                info "Found: $(safe_text "$cert"), valid until $end."
                use_existing_cert "$cert" "$key"
            else
                info "No trusted certificate for $host was found there. Nothing changed."
                explain_untrusted_certs "$host"
            fi ;;
        files)
            info 'Two files: the certificate with its chain (fullchain), and its private key. They are copied, so the originals stay where they are.'
            prompt_valid 'Certificate file (Enter = cancel): ' valid_abs_path 'Enter a full path that starts with /.' || return 0
            cert=$REPLY
            guess=''
            if [[ -s ${cert%/*}/privkey.pem ]]; then guess=${cert%/*}/privkey.pem; elif [[ -s ${cert%.*}.key ]]; then guess=${cert%.*}.key; fi
            if [[ -n $guess ]]; then
                ask "Key file [$guess]: " || { cancelled; return 0; }
                key=${REPLY:-$guess}
            else
                prompt_valid 'Key file (Enter = cancel): ' valid_abs_path 'Enter a full path that starts with /.' || return 0
                key=$REPLY
            fi
            problem=$(cert_problem "$cert" "$key" "$host")
            if [[ -n $problem ]]; then warn "$problem Nothing changed."; return 1; fi
            use_existing_cert "$cert" "$key" ;;
        self)
            info 'A self-signed certificate needs nothing from outside, but the browser warns about every link, and the person has to choose to continue.'
            confirm_choice 'Switch the links to a self-signed certificate?' 'No, keep the current one' 'Switch to self-signed' caution || { info 'The current certificate stays.'; return 0; }
            # A Let's Encrypt certificate this tool got stays in /etc/letsencrypt, so it can be taken back later.
            make_self_signed_cert "$host" && ok "Links use a self-signed certificate for $host, valid until $(cert_end_date "$LINK_CERT")." ;;
    esac
}
valid_abs_path() { [[ $1 == /* && $1 != *$'\n'* ]]; }

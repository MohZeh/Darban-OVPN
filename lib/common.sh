#!/usr/bin/env bash
# Shared internal checks for Darban OVPN.
# This file is sourced by root-owned manager/maintenance executables.

DARBAN_LIB=/usr/local/lib/darban
DARBAN_PKI=/root/pki
DARBAN_EASYRSA=/usr/share/easy-rsa/easyrsa
DARBAN_SERVER_DIR=/etc/openvpn/server
DARBAN_SERVER_CONF=$DARBAN_SERVER_DIR/server.conf
DARBAN_CRL=$DARBAN_SERVER_DIR/crl.pem
DARBAN_UNIT=openvpn-server@server.service
# Root-owned /run, not the world-writable /run/lock, so other users cannot pre-create or redirect it.
DARBAN_LOCK=/run/darban.lock
DARBAN_TMP_FILES=()
# Only 'darban-crl-maintain --renew --allow-crl-shrink' sets this; it is never read from the environment.
DARBAN_ALLOW_CRL_SHRINK=0

darban_error() { printf 'ERROR: %s\n' "$*" >&2 || true; }
darban_require_root() { (( EUID == 0 )) || { darban_error 'Run with sudo/root.'; return 1; }; }
darban_lock() {
    local wait=${1:-15}
    exec 9>>"$DARBAN_LOCK"
    flock -n 9 && return 0
    printf 'Another Darban OpenVPN operation (e.g. the CRL timer) is running; waiting up to %ss...\n' "$wait" >&2 || true
    flock -w "$wait" 9 || { darban_error 'Another Darban OpenVPN operation is still running. Retry in a minute.'; return 1; }
}
# Temp files registered here are removed by an EXIT trap even after Ctrl+C or an aborted step.
darban_tmp_register() { DARBAN_TMP_FILES+=("$1"); }
darban_tmp_cleanup() {
    local file
    for file in "${DARBAN_TMP_FILES[@]}"; do rm -f -- "$file" || true; done
    DARBAN_TMP_FILES=()
}
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }
valid_domain() {
    local d=$1 label
    [[ ${#d} -le 253 && $d == *.* && $d != .* && $d != *. && $d != *..* && $d =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<<"$d"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}
valid_ipv4() {
    local octet
    local -a octets
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$1"
    for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}
valid_endpoint() { if [[ $1 =~ ^[0-9.]+$ ]]; then valid_ipv4 "$1"; else valid_domain "$1"; fi; }
ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%d\n' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}
is_private_ip() { [[ $1 =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }
valid_subnet() { valid_ipv4 "$1" && [[ $1 == *.0 ]] && is_private_ip "$1" && [[ $1 != 127.* && $1 != 100.* ]]; }
subnet_conflict() {
    # Prints the first route overlapping this /24: clients could not reach it through the VPN.
    local start route addr bits other_size other_start
    start=$(ip_to_int "$1")
    while IFS= read -r route; do
        [[ $route =~ ^([0-9.]+)(/([0-9]+))?$ ]] || continue
        addr=${BASH_REMATCH[1]}
        bits=${BASH_REMATCH[3]:-32}
        other_size=$(( 1 << (32 - 10#$bits) ))
        other_start=$(( $(ip_to_int "$addr") & ~(other_size - 1) ))
        if (( start < other_start + other_size && other_start < start + 256 )); then
            printf '%s\n' "$route"
            return 0
        fi
    done < <(ip -4 route show | awk '$1!="default" {print $1}')
    return 1
}
valid_dns() {
    # Sets DNS_LIST from one or two IPv4 addresses, separated by spaces or commas.
    local item
    local -a items
    read -r -a items <<<"${1//,/ }"
    (( ${#items[@]} >= 1 && ${#items[@]} <= 2 )) || return 1
    for item in "${items[@]}"; do valid_ipv4 "$item" || return 1; done
    DNS_LIST=${items[*]}
}
darban_norm_serial() {
    local serial=${1^^}
    serial=${serial//:/}
    while [[ ${#serial} -gt 1 && $serial == 0* ]]; do serial=${serial:1}; done
    [[ $serial =~ ^[A-F0-9]+$ ]] || return 1
    printf '%s\n' "$serial"
}
darban_conf_single() {
    # Value of a directive that must appear exactly once. Exit 1 = absent, 2 = repeated/empty.
    awk -v k="$1" '$1==k {n++; v=$2} END {if(n==0) exit 1; if(n>1 || v=="") exit 2; print v}' "$DARBAN_SERVER_CONF"
}
darban_conf_path() {
    # openvpn-server@.service runs in the server directory, so relative paths resolve there.
    if [[ $1 == /* ]]; then printf '%s\n' "$1"; else printf '%s\n' "$DARBAN_SERVER_DIR/$1"; fi
}
darban_server_cert_pem() {
    # The certificate OpenVPN actually serves: the 'cert' file, or an inline <cert> block.
    local path rc=0
    path=$(darban_conf_single cert) || rc=$?
    if (( rc == 0 )); then
        openssl x509 -in "$(darban_conf_path "$path")" -outform PEM 2>/dev/null
    elif (( rc == 1 )); then
        awk '/^[[:space:]]*<cert>/ {b=1; next} /^[[:space:]]*<\/cert>/ {b=0} b' "$DARBAN_SERVER_CONF" |
          openssl x509 -outform PEM 2>/dev/null
    else
        return 1
    fi
}
darban_server_serial() {
    local serial
    serial=$(darban_server_cert_pem | openssl x509 -noout -serial 2>/dev/null) || return 1
    darban_norm_serial "${serial#serial=}"
}
darban_cert_is_client_only() {
    # False for unreadable certificates and for any certificate usable as a TLS server.
    local text
    text=$(openssl x509 -in "$1" -noout -text 2>/dev/null) || return 1
    [[ $text != *'TLS Web Server Authentication'* ]]
}
darban_preflight() {
    local cmd
    for cmd in openssl awk grep date mktemp flock install mv sort; do
        command -v "$cmd" >/dev/null || { darban_error "Missing dependency: $cmd"; return 1; }
    done
    [[ -x $DARBAN_EASYRSA && -s $DARBAN_PKI/ca.crt && -s $DARBAN_PKI/private/ca.key && -f $DARBAN_PKI/index.txt && -s $DARBAN_SERVER_CONF ]] || {
        darban_error 'Existing Easy-RSA CA or OpenVPN server configuration is missing.'; return 1;
    }
    # The timer cannot unlock a password-protected CA. This also verifies the key parses.
    openssl pkey -in "$DARBAN_PKI/private/ca.key" -passin pass: -noout >/dev/null 2>&1 || {
        darban_error 'CA key is encrypted or invalid. Unattended CRL maintenance is not available.'; return 1;
    }
    # Ensure the existing CA private key really belongs to the existing CA certificate.
    local key_public cert_public
    key_public=$(openssl pkey -in "$DARBAN_PKI/private/ca.key" -passin pass: -pubout -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    cert_public=$(openssl x509 -in "$DARBAN_PKI/ca.crt" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    [[ $key_public == "$cert_public" ]] || { darban_error 'CA private key and CA certificate do not match.'; return 1; }
}
darban_crl_configured() {
    # Confirm the effective directive points to the one expected CRL file.
    awk -v target="$DARBAN_CRL" '
        $1=="crl-verify" {
            n++
            if ($2!=target || (NF>2 && $3 !~ /^#/)) bad=1
        }
        END {exit !(n==1 && !bad)}
    ' "$DARBAN_SERVER_CONF"
}
darban_crl_expiry_epoch() {
    local line
    line=$(openssl crl -in "$1" -noout -nextupdate 2>/dev/null) || return 1
    [[ $line == nextUpdate=* ]] || return 1
    date -u -d "${line#nextUpdate=}" +%s
}
darban_crl_this_epoch() {
    local line
    line=$(openssl crl -in "$1" -noout -lastupdate 2>/dev/null) || return 1
    [[ $line == lastUpdate=* ]] || return 1
    date -u -d "${line#lastUpdate=}" +%s
}
darban_index_expiry_epoch() {
    # OpenSSL CA index records use ASN.1 UTCTime or GeneralizedTime.
    local value=$1 year month day hour minute second
    if [[ $value =~ ^([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then
        year=${BASH_REMATCH[1]}
        if (( 10#$year < 50 )); then year="20$year"; else year="19$year"; fi
        month=${BASH_REMATCH[2]}; day=${BASH_REMATCH[3]}
        hour=${BASH_REMATCH[4]}; minute=${BASH_REMATCH[5]}; second=${BASH_REMATCH[6]}
    elif [[ $value =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then
        year=${BASH_REMATCH[1]}; month=${BASH_REMATCH[2]}; day=${BASH_REMATCH[3]}
        hour=${BASH_REMATCH[4]}; minute=${BASH_REMATCH[5]}; second=${BASH_REMATCH[6]}
    else
        return 1
    fi
    date -u -d "$year-$month-$day $hour:$minute:$second UTC" +%s
}
darban_crl_serials() {
    openssl crl -in "$1" -noout -text 2>/dev/null | \
      awk '/^[[:space:]]*Serial Number:/ {print $3}'
}
darban_crl_has_serial() {
    local file=$1 sought current
    sought=$(darban_norm_serial "$2") || return 1
    while IFS= read -r current; do
        current=$(darban_norm_serial "$current") || return 1
        [[ $current == "$sought" ]] && return 0
    done < <(darban_crl_serials "$file")
    return 1
}
darban_crl_signature_ok() {
    # Only a CRL really signed by this CA counts as evidence of what was revoked; its dates may have passed.
    [[ -s $1 ]] && openssl crl -in "$1" -noout -verify -CAfile "$DARBAN_PKI/ca.crt" >/dev/null 2>&1
}
darban_index_rows() {
    # Prints state<TAB>expiry<TAB>serial for each CA record. Fails on an unreadable or malformed database;
    # callers must capture this with $(...) and check it: a process substitution would hide the failure.
    local index=$DARBAN_PKI/index.txt rc=0
    [[ -r $index ]] || { darban_error "CA database is missing or unreadable: $index"; return 1; }
    awk -F '\t' 'NF<6 || $1 !~ /^[VRES]$/ || $2=="" || $4 !~ /^[0-9A-Fa-f]+$/ {exit 3}
        {printf "%s\t%s\t%s\n", $1, $2, $4}' "$index" || rc=$?
    case $rc in
        0) ;;
        3) darban_error "CA database has a malformed record: $index"; return 1 ;;
        *) darban_error "Could not read the CA database: $index"; return 1 ;;
    esac
}
darban_index_load() {
    # Fills the caller's associative arrays row_state and row_expiry, keyed by normalized serial.
    local rows state expiry serial norm
    rows=$(darban_index_rows) || return 1
    while IFS=$'\t' read -r state expiry serial; do
        [[ -n $serial ]] || continue
        norm=$(darban_norm_serial "$serial") || { darban_error 'Malformed serial in CA database.'; return 1; }
        row_state["$norm"]=$state
        row_expiry["$norm"]=$expiry
    done <<<"$rows"
}
darban_index_row_expired() {
    # True only when the caller's row_expiry knows this serial and its certificate has already expired.
    local epoch
    [[ -v row_expiry[$1] ]] || return 1
    epoch=$(darban_index_expiry_epoch "${row_expiry[$1]}" 2>/dev/null) || return 1
    (( epoch <= $2 ))
}
darban_crl_unknown_serials() {
    # Serials this CRL revokes although the CA database does not say so, unless the certificate has expired.
    # Any output means the database is older than the CRL, e.g. a restored index.txt.
    local file=$1 list serial norm now
    local -A row_state=() row_expiry=()
    darban_index_load || return 1
    list=$(darban_crl_serials "$file") || { darban_error 'Could not read the serials of the CRL.'; return 1; }
    now=$(date -u +%s)
    while IFS= read -r serial; do
        [[ -n $serial ]] || continue
        norm=$(darban_norm_serial "$serial") || { darban_error 'Malformed serial in CRL.'; return 1; }
        [[ ${row_state[$norm]:-} == R ]] && continue
        darban_index_row_expired "$norm" "$now" && continue
        printf '%s\n' "$norm"
    done <<<"$list"
}
darban_crl_dropped_serials() {
    # Serials the published CRL revokes but the new CRL no longer does, unless the certificate has expired.
    # A published file this CA did not sign is no evidence, so it can never block a repair.
    local new=$1 current kept serial norm now
    local -A row_state=() row_expiry=() included=()
    darban_crl_signature_ok "$DARBAN_CRL" || return 0
    current=$(darban_crl_serials "$DARBAN_CRL") || return 1
    kept=$(darban_crl_serials "$new") || return 1
    darban_index_load || return 1
    now=$(date -u +%s)
    while IFS= read -r serial; do
        [[ -n $serial ]] || continue
        norm=$(darban_norm_serial "$serial") || return 1
        included["$norm"]=1
    done <<<"$kept"
    while IFS= read -r serial; do
        [[ -n $serial ]] || continue
        norm=$(darban_norm_serial "$serial") || return 1
        [[ -v included[$norm] ]] && continue
        darban_index_row_expired "$norm" "$now" && continue
        printf '%s\n' "$norm"
    done <<<"$current"
}
darban_rollback_hint() {
    printf 'The CA database looks older than the published CRL (restored backup?). Restore the current %s. Only if un-revoking is really intended: darban-crl-maintain --renew --allow-crl-shrink\n' "$DARBAN_PKI/index.txt"
}
darban_verify_crl() {
    local file=$1 now exp start serial serial_norm list rows server_serial state unknown indexed_expiry indexed_date
    [[ -s $file ]] || { darban_error "CRL missing: $file"; return 1; }
    darban_crl_signature_ok "$file" || { darban_error 'CRL signature verification failed.'; return 1; }
    exp=$(darban_crl_expiry_epoch "$file") || { darban_error 'Unreadable CRL nextUpdate.'; return 1; }
    start=$(darban_crl_this_epoch "$file") || { darban_error 'Unreadable CRL lastUpdate.'; return 1; }
    now=$(date -u +%s)
    (( exp > now && start <= now + 300 && start < exp )) || {
        darban_error 'CRL is expired, not yet valid, or has an inconsistent validity window.'; return 1;
    }
    # A CRL cannot be called complete against a database that is unreadable, empty or from another CA:
    # a real CA database always holds the certificate this server is running with.
    rows=$(darban_index_rows) || return 1
    server_serial=$(darban_server_serial) || { darban_error 'Cannot read the server certificate from server.conf.'; return 1; }
    local -A row_state=() row_expiry=() included=()
    darban_index_load || return 1
    [[ -v row_state[$server_serial] ]] || {
        darban_error "CA database does not contain the server certificate (serial $server_serial): it is empty, restored from an old backup, or from another CA."; return 1;
    }
    # A signed CRL may still be outdated. Every R entry in the CA index must be present.
    # Fail closed if even one revoked serial is absent.
    list=$(darban_crl_serials "$file") || { darban_error 'Could not read the serials of the CRL.'; return 1; }
    while IFS= read -r serial; do
        [[ -n $serial ]] || continue
        serial_norm=$(darban_norm_serial "$serial") || { darban_error 'Malformed serial in CRL.'; return 1; }
        included["$serial_norm"]=1
    done <<<"$list"
    # An expired revoked certificate cannot authenticate and may legally be
    # omitted from future CRLs. Enforce every NOT-YET-EXPIRED revoked entry.
    while IFS=$'\t' read -r state indexed_date serial; do
        [[ $state == R ]] || continue
        serial_norm=$(darban_norm_serial "$serial") || { darban_error 'Malformed revoked serial in CA database.'; return 1; }
        indexed_expiry=$(darban_index_expiry_epoch "$indexed_date") || {
            darban_error "Malformed expiry for revoked CA serial: $serial_norm"; return 1;
        }
        if (( indexed_expiry > now )); then
            [[ -v included[$serial_norm] ]] || { darban_error "CRL is missing revoked CA serial: $serial_norm"; return 1; }
        fi
    done <<<"$rows"
    # The opposite direction: the CRL revokes something the database does not know was revoked.
    unknown=$(darban_crl_unknown_serials "$file") || return 1
    if [[ -n $unknown ]]; then
        darban_error "CRL revokes serial(s) the CA database does not: ${unknown//$'\n'/ }. $(darban_rollback_hint)"
        return 1
    fi
}
darban_publish_crl() {
    local file=$1 temp dropped
    darban_verify_crl "$file" || return 1
    # The new CRL agrees with the database, so only the published CRL can reveal a database rollback.
    dropped=$(darban_crl_dropped_serials "$file") || { darban_error 'Could not compare the new CRL with the published CRL; not publishing.'; return 1; }
    if [[ -n $dropped ]]; then
        if (( DARBAN_ALLOW_CRL_SHRINK != 1 )); then
            darban_error "Refusing to publish: the new CRL would un-revoke serial(s) ${dropped//$'\n'/ }. $(darban_rollback_hint)"
            return 1
        fi
        printf 'WARNING: explicitly un-revoking serial(s): %s\n' "${dropped//$'\n'/ }" >&2 || true
        logger -t darban -p authpriv.warning -- "CRL shrink allowed by operator; un-revoked serial(s): ${dropped//$'\n'/ }" 2>/dev/null || true
    fi
    temp=$(mktemp "$DARBAN_SERVER_DIR/.darban-crl.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    if ! install -o root -g root -m 644 "$file" "$temp" || ! mv -f -- "$temp" "$DARBAN_CRL"; then
        rm -f -- "$temp"
        darban_error 'Failed to publish CRL. Previously active CRL is unchanged if rename did not occur.'
        return 1
    fi
    darban_verify_crl "$DARBAN_CRL" || { darban_error 'Published CRL failed post-publication verification.'; return 1; }
}

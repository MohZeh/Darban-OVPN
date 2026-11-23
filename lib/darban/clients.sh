#!/usr/bin/env bash
# The clients: the CA index, profiles and downloads, the list, and creating a client.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- CA index ----------
core_index() {
    # core_index <view> [options]: what darban-core reads from the CA index, its certificates and the CRL, as
    # tab-separated records (cmd/darban-core). It fails, and says why, on an index it cannot read whole.
    [[ -x $DARBAN_CORE ]] || { darban_error "$DARBAN_CORE is missing. Install this version again: sudo bash -c 'curl -fsSL $DARBAN_URL/releases/download/v$DARBAN_VERSION/get.sh | bash -s -- --version v$DARBAN_VERSION'"; return 1; }
    "$DARBAN_CORE" index --pki "$DARBAN_PKI" --view "$@"
}
client_index_rows() {
    # Never parse tab-separated CA records with shell read: empty fields cause shifts.
    awk -F '\t' 'NF>=6 && $6 ~ /\/CN=/ {
        cn=$6; sub(/^.*\/CN=/,"",cn); sub(/\/.*/,"",cn);
        printf "%s\t%s\t%s\t%s\n",cn,$1,$2,$4
    }' "$DARBAN_PKI/index.txt"
}
client_effective_rows() {
    # One row per name, sorted: the single valid record of a reissued name, otherwise its newest record.
    client_index_rows | awk -F '\t' '
        !($1 in seen) {seen[$1]=1; order[++n]=$1}
        $2=="V" {valid[$1]=1; row[$1]=$0}
        $2!="V" && !($1 in valid) {row[$1]=$0}
        END {for (i=1; i<=n; i++) print row[order[i]]}' | sort -t $'\t' -k1,1
}
client_index_count() {
    DARBAN_TARGET=$1 awk -F '\t' 'NF>=6 {cn=$6; sub(/^.*\/CN=/,"",cn); sub(/\/.*/,"",cn); if($6 ~ /\/CN=/ && cn==ENVIRON["DARBAN_TARGET"]) n++} END {print n+0}' "$DARBAN_PKI/index.txt"
}
client_index_lookup() {
    # "state<TAB>serial" for a name. Revoked and expired history of a reissued name does not make it
    # ambiguous: only more than one VALID record does, and then the output is just "AMBIGUOUS".
    DARBAN_TARGET=$1 awk -F '\t' '
        NF>=6 && $6 ~ /\/CN=/ {
            cn=$6; sub(/^.*\/CN=/,"",cn); sub(/\/.*/,"",cn)
            if (cn==ENVIRON["DARBAN_TARGET"]) {
                n++; state=$1; serial=$4
                if ($1=="V") {valid++; valid_serial=$4}
            }
        }
        END {
            if (valid>1) print "AMBIGUOUS"
            else if (valid==1) printf "V\t%s\n", valid_serial
            else if (n>0) printf "%s\t%s\n", state, serial
        }' "$DARBAN_PKI/index.txt"
}
client_index_status() { local row; row=$(client_index_lookup "$1"); printf '%s\n' "${row%%$'\t'*}"; }
client_index_serial() { local row; row=$(client_index_lookup "$1"); [[ $row != *$'\t'* ]] || printf '%s\n' "${row#*$'\t'}"; }
index_state_of_serial() {
    # State of one exact certificate, which a reissued name's status cannot tell.
    local want rows state expiry serial
    want=$(darban_norm_serial "$1") || return 1
    rows=$(darban_index_rows) || return 1
    while IFS=$'\t' read -r state expiry serial; do
        if [[ $(darban_norm_serial "$serial") == "$want" ]]; then printf '%s\n' "$state"; return 0; fi
    done <<<"$rows"
    return 1
}
is_server_serial() { [[ $(darban_norm_serial "$1" 2>/dev/null) == "$SERVER_SERIAL" ]]; }
safe_text() { printf '%s' "${1//[^[:print:]]/?}"; }
join_lines() { sort -u | awk '{s = s (s == "" ? "" : ", ") $0} END {print s}'; }
client_cert_safe() {
    # The server's own certificate (whatever its CN) and any server-capable certificate
    # must never be exported into a client profile or revoked from this menu.
    local crt=$DARBAN_PKI/issued/$1.crt serial
    serial=$(openssl x509 -in "$crt" -noout -serial 2>/dev/null) || return 1
    ! is_server_serial "${serial#serial=}" && darban_cert_is_client_only "$crt"
}
revoke_block_reason() {
    # Why a certificate the CA still counts as valid cannot be revoked here. Empty when it can be,
    # and for names with no valid certificate, where the question does not arise.
    local name=$1 state serial file_serial crt=$DARBAN_PKI/issued/$1.crt
    state=$(client_index_status "$name")
    case $state in
        V) ;;
        AMBIGUOUS) revoke_reason_text ambiguous; return 0 ;;
        *) return 0 ;;
    esac
    if ! valid_existing_name "$name"; then revoke_reason_text name; return 0; fi
    serial=$(client_index_serial "$name")
    if [[ ! -s $crt ]]; then revoke_reason_text missing "$name" "$serial"; return 0; fi
    if ! file_serial=$(openssl x509 -in "$crt" -noout -serial 2>/dev/null); then revoke_reason_text unreadable "$name"; return 0; fi
    if [[ $(darban_norm_serial "${file_serial#serial=}") != "$(darban_norm_serial "$serial")" ]]; then
        revoke_reason_text mismatch "$name" "$serial"; return 0
    fi
    if ! client_cert_safe "$name"; then revoke_reason_text server; fi
}
revoke_reason_text() {
    # revoke_reason_text <reason> [name] [serial]: the words for a reason of revoke_block_reason. darban-core gives
    # the list the same reasons by these names.
    case $1 in
        ambiguous) printf 'several valid certificates share this name; this tool will not guess which one to revoke\n' ;;
        name) printf 'this tool cannot manage this name safely\n' ;;
        missing) printf 'pki/issued/%s.crt is missing; restore it from pki/certs_by_serial/%s.pem\n' "$2" "$3" ;;
        unreadable) printf 'pki/issued/%s.crt is unreadable\n' "$2" ;;
        mismatch) printf 'pki/issued/%s.crt is not the certificate the CA lists as valid (serial %s)\n' "$2" "$3" ;;
        server) printf 'this certificate can act as a server, so this menu will not touch it\n' ;;
    esac
}
export_block_reason() {
    # Why a valid certificate cannot be put into a profile; empty when it can be.
    local name=$1 reason key=$DARBAN_PKI/private/$1.key crt=$DARBAN_PKI/issued/$1.crt key_hash cert_hash
    reason=$(revoke_block_reason "$name")
    if [[ -n $reason ]]; then printf '%s\n' "$reason"; return 0; fi
    [[ $(client_index_status "$name") == V ]] || return 0
    if ! openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then printf 'the certificate has expired\n'; return 0; fi
    if [[ ! -s $key ]]; then printf 'its private key pki/private/%s.key is missing\n' "$name"; return 0; fi
    key_hash=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | openssl dgst -sha256) || key_hash=''
    cert_hash=$(openssl x509 -in "$crt" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256) || cert_hash=''
    if [[ -z $key_hash || $key_hash != "$cert_hash" ]]; then printf 'its private key does not match the certificate\n'; fi
}
client_valid() { [[ $(client_index_status "$1") == V && -z $(export_block_reason "$1") ]]; }
name_taken() {
    [[ $(client_index_count "$1") != 0 || -e $DARBAN_PKI/issued/$1.crt || -e $DARBAN_PKI/private/$1.key || -e $OUT_DIR/$1.ovpn ]]
}
similar_names() {
    # Clients with a valid certificate whose name differs only in letter case ("Ali" vs "ali"), comma-separated.
    client_index_rows | awk -F '\t' -v t="$1" '$2=="V" && tolower($1)==tolower(t) && $1!=t {print $1}' | join_lines
}
revocation_pending_names() {
    # Revoked, unexpired clients the active CRL does not list: revoked in the CA, not yet blocked by OpenVPN. Only a
    # CRL this CA signed counts as evidence; without one, every such client is pending. An unreadable date counts as
    # not expired. darban-core reads the index and the CRL once.
    local data kind name
    local -a crl=()
    if darban_crl_signature_ok "$DARBAN_CRL"; then crl=(--crl "$DARBAN_CRL"); fi
    data=$(core_index pending --now "$(date -u +%s)" "${crl[@]}") || return 1
    while IFS=$'\t' read -r kind name; do
        if [[ $kind == pending ]]; then printf '%s\n' "$name"; fi
    done <<<"$data"
}
client_stats() {
    # Prints: valid revoked expired expiring-soon. An index darban-core cannot read counts nothing; it says why.
    local data kind valid=0 revoked=0 expired=0 soon=0
    if data=$(core_index stats --now "$(date -u +%s)" --server-serial "$SERVER_SERIAL" --warn-days "$EXPIRY_WARN_DAYS"); then
        IFS=$'\t' read -r kind valid revoked expired soon <<<"$data"
    fi
    printf '%d %d %d %d\n' "$valid" "$revoked" "$expired" "$soon"
}
profile_path() {
    local name=$1
    [[ -s $OUT_DIR/$name.ovpn ]] || return 1
    printf '%s\n' "$OUT_DIR/$name.ovpn"
}
# Predicates deciding which clients each picker offers.
can_reexport() { client_valid "$1"; }
can_delete_export() { profile_path "$1" >/dev/null; }
show_blocked() {
    # show_blocked "<name>: <reason>"...: certificates this action cannot use, and why.
    local line
    (( $# > 0 )) || return 0
    say
    say 'Valid, but not available for this action:'
    for line in "$@"; do bullet "$line"; done
}
can_revoke() { [[ $(client_index_status "$1") == V && -z $(revoke_block_reason "$1") ]]; }
pick_client() {
    # pick_client <question> <predicate> [reason-function]: numbered list of matching clients;
    # sets PICKED to a name. Returns 1 when cancelled or when nothing matches.
    # Clients the reason function explains are listed apart, so a valid certificate never just vanishes.
    local question=$1 predicate=$2 explain=${3:-} cn status expiry serial e i extra reason
    local -a names=() notes=() blocked=()
    while IFS=$'\t' read -r cn status expiry serial; do
        if is_server_serial "$serial"; then continue; fi
        if ! "$predicate" "$cn"; then
            reason=''
            if [[ -n $explain ]]; then reason=$("$explain" "$cn") || reason=''; fi
            if [[ -n $reason ]]; then blocked+=("$(safe_text "$cn"): $reason"); fi
            continue
        fi
        e=$(darban_index_expiry_epoch "$expiry" 2>/dev/null || echo 0)
        extra=''
        if (( e > 0 )); then extra="expires $(describe_expiry "$e")"; fi
        if profile_path "$cn" >/dev/null; then extra+=" $S_SEP profile on server"; fi
        names+=("$cn"); notes+=("$extra")
    done < <(client_effective_rows)
    if (( ${#names[@]} == 0 )); then
        info 'No clients are available for this action.'
        show_blocked "${blocked[@]}"
        return 1
    fi
    say "$question"
    for i in "${!names[@]}"; do
        printf '  %s%3d%s  %-24s %s%s%s\n' "$C_KEY" $((i + 1)) "$C_RESET" "${names[i]}" "$C_HINT" "${notes[i]}" "$C_RESET"
    done
    show_blocked "${blocked[@]}"
    say
    while :; do
        if ! ask 'Number or name (Enter = cancel): ' || [[ -z $REPLY ]]; then cancelled; return 1; fi
        # The exact name first: an older client may be called just "2".
        for cn in "${names[@]}"; do
            if [[ $cn == "$REPLY" ]]; then PICKED=$cn; return 0; fi
        done
        if [[ $REPLY =~ ^[0-9]+$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= ${#names[@]} )); then
            PICKED=${names[10#$REPLY - 1]}; return 0
        fi
        warn "\"$REPLY\" is not in the list above. Enter its number or exact name."
    done
}

# ---------- profiles and downloads ----------
server_endpoints() {
    # server_endpoints <host>: where a new profile points, one "HOST PORT udp|tcp" a line, in the order a client
    # tries them: UDP first. The only place the remotes of a profile come from, so a list of endpoints can take its
    # place later.
    local host=$1 listeners proto port
    listeners=$(server_listeners) || return 1
    while read -r proto port; do
        printf '%s %s %s\n' "$host" "$port" "$proto"
    done <<<"$listeners"
}
profile_transport() {
    # profile_transport <endpoints>: the lines of a profile that say where and how it connects. One endpoint: its
    # proto and one remote. More: a remote each, with its protocol, and 5 seconds for each before the next.
    # explicit-exit-notify with any UDP remote, so a client that stops ends its session at once; TCP has its own end.
    # Nothing but checked endpoints reaches the file: no newline, no control character.
    local endpoints=$1 count host port proto udp=0 line
    count=$(grep -c . <<<"$endpoints")
    (( count >= 1 )) || return 1
    while IFS= read -r line; do
        [[ $line =~ $ENDPOINT_RE ]] || return 1
        read -r host port proto <<<"$line"
        valid_endpoint "$host" && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
        if [[ $proto == udp ]]; then udp=1; fi
        if (( count == 1 )); then
            printf 'proto %s4\nremote %s %s\n' "$proto" "$host" "$((10#$port))" || return 1
        else
            printf 'remote %s %s %s4\n' "$host" "$((10#$port))" "$proto" || return 1
        fi
    done <<<"$endpoints"
    if (( count > 1 )); then printf 'server-poll-timeout 5\n' || return 1; fi
    if (( udp )); then printf 'explicit-exit-notify 1\n' || return 1; fi
}
endpoints_record() {
    # endpoints_record <endpoints>: the "remote" field of a share record, "remote HOST PORT udp|tcp" joined by ";".
    awk 'NF == 3 {printf "%sremote %s %s %s", (n++ ? ";" : ""), $1, $2, $3} END {print ""}' <<<"$1"
}
record_endpoints() {
    # record_endpoints <remote field>: the endpoints of a record. A record from before TCP has "remote HOST PORT",
    # which is UDP.
    awk -v RS=';' '{sub(/\n$/, "")} $1 == "remote" && (NF == 3 || NF == 4) {
            p = (NF == 4 ? $4 : "udp"); sub(/4$/, "", p); sub(/-client$/, "", p)
            if (p == "udp" || p == "tcp") print $2, $3 + 0, p }' <<<"$1"
}
endpoints_label() {
    # endpoints_label <endpoints>: "host:1543/UDP", or "host:1543/UDP + 443/TCP".
    awk '{printf "%s%s%s/%s", (NR > 1 ? " + " : ""), ($1 != h ? $1 ":" : ""), $2, toupper($3); h = $1} END {print ""}' <<<"$1"
}
assemble_profile() {
    # assemble_profile <name> <endpoints> <ciphers> [share]. Every step is checked explicitly: callers use this from
    # an if, where errexit does not apply.
    local name=$1 endpoints=$2 ciphers=$3 share=${4:-} transport
    transport=$(profile_transport "$endpoints") || return 1
    cat <<EOF || return 1
client
dev tun
$transport
resolv-retry infinite
nobind
remote-cert-tls server
tls-version-min 1.2
data-ciphers $ciphers
auth-nocache
persist-tun
verb 3
# The name OpenVPN Connect shows for this profile, instead of the server address. Other clients ignore it.
setenv FRIENDLY_NAME "$name"
EOF
    # Which share this copy is, sent to the server at each connection: a connection of another copy of the same
    # client then leaves this one. Only with SHARE_ID_IN_PROFILE=yes.
    if [[ -n $share ]]; then printf 'setenv UV_DARBAN_SHARE %s\npush-peer-info\n' "$share" || return 1; fi
    cat <<EOF || return 1

<ca>
EOF
    openssl x509 -in "$DARBAN_PKI/ca.crt" -outform PEM || return 1
    printf '</ca>\n<cert>\n' || return 1
    openssl x509 -in "$DARBAN_PKI/issued/$name.crt" -outform PEM || return 1
    printf '</cert>\n<key>\n' || return 1
    if [[ -n $PROFILE_PASSWORD ]]; then
        # PBKDF2 with 600000 rounds: the password is short, so guessing it from a stolen file must be slow.
        openssl pkcs8 -topk8 -in "$DARBAN_PKI/private/$name.key" -v2 aes-256-cbc -v2prf hmacWithSHA256 -iter 600000 \
            -passout stdin <<<"$PROFILE_PASSWORD" || return 1
    else
        cat -- "$DARBAN_PKI/private/$name.key" || return 1
    fi
    printf '</key>\n<tls-crypt>\n' || return 1
    cat -- "$TLS_KEY" || return 1
    printf '</tls-crypt>\n'
}
profile_complete() {
    awk '/^<(ca|cert|key|tls-crypt)>$/ {o[$0]++} /^<\/(ca|cert|key|tls-crypt)>$/ {c[$0]++}
        END {exit !(o["<ca>"]==1 && o["<cert>"]==1 && o["<key>"]==1 && o["<tls-crypt>"]==1 &&
                    c["</ca>"]==1 && c["</cert>"]==1 && c["</key>"]==1 && c["</tls-crypt>"]==1)}' "$1"
}
write_profile() {
    # write_profile <name> [replace]: under the CA lock. The file is a new share, kept on the server until its time
    # is up or the client connects, and its record says so.
    local name=$1 replace=${2:-no} host endpoints ciphers outfile tmp share serial uv='' old=''
    client_valid "$name" || { warn 'The client certificate/key is missing, expired, server-capable or does not match.'; return 1; }
    profile_preconditions || return 1
    host=$(domain)
    endpoints=$(server_endpoints "$host") || return 1
    ciphers=$(server_data_ciphers) || return 1
    outfile="$OUT_DIR/$name.ovpn"
    if [[ -e $outfile && $replace != yes ]]; then warn "Profile exists and will not be replaced: $outfile"; return 1; fi
    share=$(openssl rand -hex 8) || return 1
    serial=$(openssl x509 -in "$DARBAN_PKI/issued/$name.crt" -noout -serial 2>/dev/null | sed 's/^serial=//')
    serial=$(darban_norm_serial "$serial") || serial=''
    if [[ $SHARE_ID_IN_PROFILE == yes ]]; then uv=$share; fi
    tmp=$(mktemp "$OUT_DIR/.profile.XXXXXXXX") || return 1
    darban_tmp_register "$tmp"
    if ! assemble_profile "$name" "$endpoints" "$ciphers" "$uv" >"$tmp" || ! profile_complete "$tmp"; then
        rm -f -- "$tmp"; warn 'Could not assemble profile.'; return 1
    fi
    chmod 600 "$tmp" || return 1
    if share_record_read "$outfile"; then old=$SR_ID; fi
    # The old record goes first: for a moment the file has none, which can only make it last longer.
    rm -f -- "$OUT_DIR/$name.share"
    if ! mv -f -- "$tmp" "$outfile"; then rm -f -- "$tmp"; return 1; fi
    # A file written again is a new share: the copy of the one before ends with it.
    home_copy_end_share "$old" 'shared again' || true
    home_copy_report
    share_record_write "$name" "$share" "$serial" "$(endpoints_record "$endpoints")" || { warn "Could not record when $outfile is deleted; the five-minute check gives it $(hours_label "$(link_hours)")."; return 0; }
    expire_schedule || warn "The timer that deletes $outfile on time could not be set; the five-minute check deletes it once its time is up."
}
security_note() {
    printf '%s%s This file contains a private key; do not share or publish it.%s\n' "$C_YELLOW" "$S_WARN" "$C_RESET" || true
}
download_panel() {
    # download_panel <file> <title> [windows|unix|sftp]. Commands are printed uncolored, unindented and one
    # per line, so copying them from the terminal never picks up escape codes or frame characters.
    local file=$1 title=$2 only=${3:-all} name filename current_remote='' expected cert_exp fetch=${DOWNLOAD_FILE:-$1}
    filename=${file##*/}
    name=${filename%.ovpn}
    ok "$title"
    hr
    # From the record of the file, never from the file itself: a read is what "file read" shows. Without a record,
    # where it points is not known.
    if share_record_read "$file"; then current_remote=$(record_endpoints "$SR_REMOTE"); fi
    kv File "$fetch"
    if [[ -n $current_remote ]]; then
        kv Server "$(endpoints_label "$current_remote")"
    else
        kv Server unknown
    fi
    if cert_exp=$(cert_end_epoch "$DARBAN_PKI/issued/$name.crt"); then kv 'Valid to' "$(describe_expiry "$cert_exp")"; fi
    # Every remote is compared, in order: a file that lacks the TCP remote of a server with both is old too.
    expected=$(server_endpoints "$(domain)" 2>/dev/null) || expected=''
    if [[ -n $current_remote && $current_remote != "$expected" ]]; then
        warn "This file points to $(endpoints_label "$current_remote") but the server is now $(if [[ -n $expected ]]; then endpoints_label "$expected"; else printf 'in a form this tool cannot read'; fi). Share it again (menu 5) first."
    fi
    say
    if [[ -z $DOWNLOAD_SSH_HOST ]]; then
        warn "Download commands unavailable: set DOWNLOAD_SSH_HOST (and DOWNLOAD_SSH_PORT/USER) in $CONFIG_FILE."
    else
        if [[ $only == all || $only == windows ]]; then
            say '  Windows (PowerShell):'
            printf '%s%s%s\n' "$C_CMD" "$(download_command windows "$file")" "$C_RESET" || true
            say
        fi
        if [[ $only == all || $only == unix ]]; then
            say '  macOS / Linux:'
            printf '%s%s%s\n' "$C_CMD" "$(download_command unix "$file")" "$C_RESET" || true
            say
        fi
        if [[ $only == all || $only == sftp ]]; then
            say '  WinSCP / FileZilla (SFTP):'
            printf '%s%s%s\n' "$C_LINK" "$(download_command sftp "$file")" "$C_RESET" || true
            say
        fi
    fi
    security_note
    hr
}
download_command() {
    # download_command <windows|unix|sftp> <file>: the plain text of one way to fetch the file, for the panel
    # and for the clipboard alike.
    local fetch=${DOWNLOAD_FILE:-$2} target=$DOWNLOAD_SSH_USER@$DOWNLOAD_SSH_HOST
    case $1 in
        windows) printf 'scp -P %s %s:%s "$env:USERPROFILE\\Downloads\\%s"' "$DOWNLOAD_SSH_PORT" "$target" "$fetch" "${2##*/}" ;;
        unix) printf 'scp -P %s %s:%s ~/Downloads/' "$DOWNLOAD_SSH_PORT" "$target" "$fetch" ;;
        sftp) printf 'sftp://%s:%s%s' "$target" "$DOWNLOAD_SSH_PORT" "$fetch" ;;
    esac
}
list_clients() {
    # darban-core reads the index, the certificates and the records of when each client was seen, once; this lays
    # out the table. Its rows come in the order of index.txt and are sorted here, in this locale, as before.
    local kind cn label e day state us rank days name_w=6 out line cell color profile shown reason pending data
    local valid=0 revoked=0 expired=0 soon=0 hidden=0 online='' events=0 seen code serial now
    local -a rows=() blocks=() options=()
    now=$(date -u +%s)
    # Who is connected now, when the server can say: one look, not one per client.
    if mgmt_available; then online=$'\n'$(connected_rows 2>/dev/null | cut -f1)$'\n'; fi
    # When each was last seen, from its connection events; never means not since they were turned on.
    if events_lines_on; then events=1; fi
    options=(--now "$now" --server-serial "$SERVER_SERIAL" --ledger "$LEDGER_DIR")
    if (( LIST_ALL )); then options+=(--all); fi
    data=$(core_index list "${options[@]}") || return 1
    while IFS=$'\t' read -r kind rank cn label e day state us; do
        case $kind in
            row)
                rows+=("$rank"$'\t'"$cn"$'\t'"$label"$'\t'"$e"$'\t'"$day"$'\t'"$state"$'\t'"$us")
                if (( ${#cn} > name_w )); then name_w=${#cn}; fi ;;
            hidden) hidden=$rank ;;
            # block <name> <reason> <serial>
            block) blocks+=("$rank"$'\t'"$cn"$'\t'"$label") ;;
        esac
    done <<<"$data"
    LIST_HIDDEN=$hidden
    revoked=$hidden
    if (( ${#rows[@]} == 0 && hidden == 0 )); then info 'No clients yet. Create one with menu 1.'; return 0; fi
    (( name_w <= 32 )) || name_w=32
    if (( ${#rows[@]} > 0 )); then
        printf -v out '  %s%-*s  %-8s  %-10s  %5s  %-10s  %s%s\n' "$C_BOLD" "$name_w" CLIENT STATUS EXPIRES DAYS 'LAST SEEN' PROFILE "$C_RESET"
    else
        out=$'  No active clients.\n'
    fi
    while IFS=$'\t' read -r rank cn label e day state us; do
        [[ -n $cn ]] || continue
        # safe_text, without a subshell for each row.
        shown=${cn//[^[:print:]]/?}
        if (( ${#shown} > name_w )); then shown="${shown:0:name_w-1}$S_ELL"; fi
        case $label in VALID) color=$C_GREEN ;; REVOKED) color=$C_DIM ;; *) color=$C_RED ;; esac
        printf -v cell '%-8s' "$label"
        printf -v line '  %-*s  %s%s%s  ' "$name_w" "$shown" "$color" "$cell" "$C_RESET"
        if (( e > 0 )); then line+=$day; else line+='?         '; fi
        if [[ $label == VALID ]]; then
            days=$(( (e - now) / 86400 ))
            if (( days <= EXPIRY_WARN_DAYS )); then
                soon=$((soon + 1)); printf -v cell '%5d' "$days"; line+="  $C_YELLOW$cell$C_RESET"
            else
                printf -v cell '%5d' "$days"; line+="  $cell"
            fi
            valid=$((valid + 1))
        else
            line+="      -"
            if [[ $label == REVOKED ]]; then revoked=$((revoked + 1)); else expired=$((expired + 1)); fi
        fi
        seen='-'
        if [[ $label == VALID ]]; then last_seen_label seen "$cn" "$online" "$events" "$us" "$now"; fi
        printf -v cell '%-10s' "$seen"
        line+="  $cell"
        # The server copy belongs to a reissued name's valid certificate, not to its revoked history.
        profile='-'
        if { [[ $label == VALID ]] || [[ $state != V ]]; } && profile_path "$cn" >/dev/null; then profile="$S_OK on server"; fi
        if [[ $label == VALID && $online == *$'\n'"$cn"$'\n'* ]]; then profile+="  $C_GREEN$S_DOT connected$C_RESET"; fi
        out+="$line  $profile"$'\n'
    done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1n -k2,2)
    printf -v line '\n  %d valid %s %d revoked %s %d expired' "$valid" "$S_SEP" "$revoked" "$S_SEP" "$expired"
    out+=$line
    if (( soon > 0 )); then out+=" $S_SEP $C_YELLOW$soon expiring within $EXPIRY_WARN_DAYS days$C_RESET"; fi
    if (( LIST_ALL )); then
        out+=$'\n'"  ${C_DIM}Revoked clients stay in the CA index because the CRL depends on them.${C_RESET}"$'\n'
    elif (( hidden > 0 )); then
        out+=$'\n'"  ${C_DIM}Revoked clients are hidden. To see them: sudo darban list --all${C_RESET}"$'\n'
    else
        out+=$'\n'
    fi
    # By name, as the names were sorted before.
    if (( ${#blocks[@]} > 0 )); then
        while IFS=$'\t' read -r cn code serial; do
            reason=$(revoke_reason_text "$code" "$cn" "$serial")
            if [[ -n $reason ]]; then out+=$'\n'"  $C_YELLOW$S_WARN$C_RESET $(safe_text "$cn") cannot be revoked here: $reason"; fi
        done < <(printf '%s\n' "${blocks[@]}" | sort -t $'\t' -k1,1)
    fi
    pending=$(revocation_pending_names | join_lines) || pending=''
    if [[ -n $pending ]]; then out+=$'\n'"  $C_RED$S_WARN$C_RESET Revoked but NOT blocked yet: $(safe_text "$pending") $S_ARROW Maintenance $S_CRUMB 2"; fi
    out+=$'\n'
    emit "$out"
}
name_reuse_block_reason() {
    # Why a name already in the CA history cannot get a new certificate; empty when it safely can.
    # OpenVPN rejects the old certificate by serial, so the old one must be proven blocked first.
    local name=$1 state serial file rows
    state=$(client_index_status "$name")
    case $state in
        V|AMBIGUOUS) printf 'it still has a valid certificate.\n'; return 0 ;;
    esac
    serial=$(client_index_serial "$name")
    if [[ -n $serial ]] && is_server_serial "$serial"; then printf 'it belongs to the server certificate.\n'; return 0; fi
    if ! darban_verify_crl "$DARBAN_CRL" >/dev/null 2>&1; then printf 'the published CRL has a problem; fix it first: Maintenance %s 2.\n' "$S_CRUMB"; return 0; fi
    # A link or file of an earlier certificate would leave two of them in use under one name.
    rows=$(share_rows 2>/dev/null) || rows=''
    if share_names revoked "$rows" | grep -Fx -- "$name" >/dev/null; then printf 'its revocation is unfinished; finish it first: Maintenance %s 2.\n' "$S_CRUMB"; return 0; fi
    if share_names unknown "$rows" | grep -Fx -- "$name" >/dev/null; then printf 'a link or file of it holds a certificate this tool cannot identify; check it, then delete it in Links and files (menu 6).\n'; return 0; fi
    # Each of these would make Easy-RSA refuse, or would pair the new certificate with an old file.
    for file in "issued/$name.crt" "private/$name.key" "reqs/$name.req"; do
        if [[ -e $DARBAN_PKI/$file ]]; then printf 'pki/%s is still there.\n' "$file"; return 0; fi
    done
    if [[ -e $OUT_DIR/$name.ovpn ]]; then printf '%s is still there.\n' "$OUT_DIR/$name.ovpn"; fi
}
client_settings_file() {
    # The per-client server settings OpenVPN would apply to this name (fixed IP, routes), if any.
    local dir
    dir=$(darban_conf_single client-config-dir 2>/dev/null) || return 1
    dir=$(darban_conf_path "$dir")
    [[ -f $dir/$1 ]] || return 1
    printf '%s\n' "$dir/$1"
}
confirm_name_reuse() {
    # The old certificate is already proven blocked, so reusing the name is routine. The one thing
    # that silently carries over is the per-client server configuration, and only that is asked about.
    local name=$1 file
    if ! file=$(client_settings_file "$name"); then
        info "\"$name\" was revoked before. Its old .ovpn files stay blocked; only the new file will connect."
        return 0
    fi
    say
    warn "Server settings for this name exist in $file and will apply to the new certificate."
    confirm_choice "Issue a new certificate for $name with those settings?" 'No, choose another name' 'Yes, issue it' caution "$name"
}
create_client() {
    # create_client [suggested name]: with a suggestion, Enter takes it; without one, Enter cancels.
    local suggested=${1:-} name similar reason reused=0 rc=0
    local hint='Use 1-64 letters, digits, _ or -, starting with a letter or digit. It cannot be "server" or only digits.'
    profile_preconditions || return 1
    info 'A name for this person or device, such as ali-phone. Letters, digits, _ and - only.'
    if [[ -n $suggested ]]; then info "Press Enter to use $suggested, or type a name and press Enter."; fi
    say
    while :; do
        if [[ -n $suggested ]]; then
            ask "Client name [$suggested]: " || { cancelled; return 0; }
            REPLY=${REPLY:-$suggested}
            if ! valid_name "$REPLY"; then warn "$hint"; continue; fi
        else
            prompt_valid 'New client name (Enter = cancel): ' valid_name "$hint" || return 0
        fi
        name=$REPLY
        reused=0
        if name_taken "$name"; then
            reason=$(name_reuse_block_reason "$name")
            if [[ -n $reason ]]; then
                warn "\"$name\" cannot be used: $reason"
                continue
            fi
            confirm_name_reuse "$name" || { say; continue; }
            reused=1
        fi
        break
    done
    similar=$(similar_names "$name")
    if [[ -n $similar ]]; then
        warn "Existing name(s) differing only in letter case: $similar"
        confirm_choice "Create \"$name\" anyway?" 'No, do not create it' "Create $name" caution || { cancelled; return 0; }
    fi
    ca_lock || return 1
    # Another administrator may have taken the name while this one was being typed.
    if (( ! reused )) && name_taken "$name"; then warn "\"$name\" was created by another session just now. Choose another name."; return 1; fi
    info "Issuing a certificate and unencrypted private key for $name${S_ELL}"
    critical_begin
    if [[ -n $CLIENT_CERT_DAYS ]]; then
        EASYRSA_CERT_EXPIRE=$CLIENT_CERT_DAYS run_easyrsa build-client-full "$name" nopass || rc=$?
    else
        run_easyrsa build-client-full "$name" nopass || rc=$?
    fi
    critical_end
    if (( rc != 0 )); then fail 'Certificate issuance failed. Inspect the PKI state before trying again.'; return 1; fi
    if (( reused )); then audit "client created again with a used name: $name"; else audit "client created: $name"; fi
    # When the name was last seen belonged to the certificate it had before: the new one has not been seen yet.
    rm -f -- "$LEDGER_DIR/$name"
    info "Building the .ovpn profile${S_ELL}"
    if ! write_profile "$name" no; then
        fail 'The certificate was issued but the .ovpn export failed. Use Share (menu 5) instead of creating it again.'; return 1
    fi
    backup_auto "client created: $name"
    ca_unlock
    backup_hooks_start
    say
    if (( ! UI_TTY )); then
        # A script has nobody to answer the sharing questions.
        download_panel "$OUT_DIR/$name.ovpn" "Client \"$name\" created and verified"
        no_pause
    fi
    ok "Client \"$name\" created and verified"
    say
    share_client "$name"
    if ! { (( SHARED )) && wait_for_connection "$name"; }; then pause; fi
    no_pause
}

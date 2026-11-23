#!/usr/bin/env bash
# The configuration and the facts of the server, for bin/darban, which sources it right after lib/darban/paths.sh.
# It also gives every global of the other modules its starting value: only this module and paths.sh assign
# globals outside a function (scripts/check-modules.py).

# ---------- the starting values of the state and constants of each part ----------
# lib/darban/core.sh
CRITICAL_DEPTH=0
# lib/darban/shares.sh
HC_ENTRY='' HC_NAME='' HC_SERIAL='' HC_PATH='' HC_FILE='' HC_SHARE='' HC_USER='' HC_KEPT_AT='' HC_DONE='' HC_KEPT=''
# Writes the copy only through its folder, opened without following a link, and only as a new file: never over
# anything already there, a link or another file of the same name included. What fails after the file was made
# removes it. Exit 3: no folder of that user's own; exit 4: the name is taken.
HOME_COPY_PY='
import os, sys
src, home, name, uid, gid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
try:
    folder = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError:
    sys.exit(3)
if os.geteuid() == 0 and os.fstat(folder).st_uid != uid:
    sys.exit(3)
with open(src, "rb") as handle:
    data = handle.read()
try:
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=folder)
except FileExistsError:
    sys.exit(4)
try:
    if os.geteuid() == 0:
        os.fchown(fd, uid, gid)
    os.fchmod(fd, 0o600)
    view = memoryview(data)
    if os.environ.get("DARBAN_TEST_COPY_FAIL") == "write":
        os.write(fd, view[:len(view) // 2])
        raise OSError(28, "No space left on device, as the test asked")
    while view:
        view = view[os.write(fd, view):]
    os.fsync(fd)
except BaseException:
    # A copy only begun is no copy: it goes, so nothing half written stays in that home.
    try:
        os.unlink(name, dir_fd=folder)
    except OSError:
        pass
    raise
finally:
    os.close(fd)
'
# lib/darban/clients.sh: one endpoint of a profile, "HOST PORT udp|tcp".
ENDPOINT_RE='^[A-Za-z0-9.-]{1,253} [0-9]{1,5} (udp|tcp)$'
# lib/darban/certs.sh
CERT_NAME=darban-ovpn-links
# Let's Encrypt issues IP address certificates from Certbot 5.3 on; a hostname works with any version.
CERTBOT_IP_MIN=5.3
LINK_PAIRS=$CONFIG_DIR/link-cert
# lib/darban/shares.sh
SR_ID='' SR_SERIAL='' SR_CREATED='' SR_BOOT='' SR_CS='' SR_US='' SR_EXPIRES='' SR_REMOTE='' SR_FILE='' SR_HOME='' SR_HOME_FILE=''
# lib/darban/sessions.sh
# Seconds the management interface may take to answer; the five-minute check waits 3 at most.
MGMT_TIMEOUT=10
# lib/darban/events.sh
EVENT_RE='^darban-event 1 (connect|disconnect) ([A-Za-z0-9][A-Za-z0-9._@+-]{0,127}) ([0-9a-f-]{36}) ([0-9]{1,12}) ([0-9]{16}) ([0-9A-Fa-f.:]{2,45}|-) ([0-9A-Fa-f:]{1,64}|-) ([0-9]{1,20}|-) ([0-9]{1,20}|-) ([0-9]{1,10}|-) ([0-9]{1,12}|-)( [0-9a-f]{16})?$'
EVENT_RUN='' EVENT_SEQ=0 EVENT_TAKEN=0 EVENT_WHY='' EVENT_REJECTED=0 EVENT_REJECT_WHY=''
EVENT_DONE=0 EVENT_LEFT=0 EVENT_DEADLINE=0 EXPIRE_DIRTY=0
EVENT_FIELDS=()
# A mark the worker leaves in new/ when it stopped at its limit with work left: the path unit then starts it again.
EVENT_RERUN=.darban-rerun
LM_NAME='' LM_EXPIRES='' LM_CREATED='' LM_BOOT='' LM_CS='' LM_US='' LM_SHARE=''
# The lock of the queue itself: one worker at a time, as each run reads every entry in work/, those another run
# took as well. In the folder of the queue, which only root can write to, not in new/ of OpenVPN's user.
EVENT_WORKER_LOCK=.worker.lock
# lib/darban/network.sh
PRESETS=() PICKED_PORT=
# lib/darban/blocked.sh
GEO_WHY=''
UNBLOCK_COUNT=0
# lib/darban/dns.sh
DNS_WHY=''
# lib/darban/names.sh
NAMES_WHY=''
OWN_COUNT=0
# lib/darban/backup.sh and lib/darban/restore.sh
BACKUP_MADE='' BACKUP_WHY='' RESTORE_WHY='' RESTORE_RENAMES=0 RESTORE_NEW_CRL=0 RESTORE_KEPT='' RESTORE_NAT_FAILED=0
RESTORE_SAME_CA=no RESTORE_HISTORY=unknown RESTORE_UNDONE='' RESTORE_UNDONE_SERIALS='' RESTORE_REVOKED=''


# ---------- configuration and server facts ----------
load_config() {
    local key value old_iran='' old_direct='' direct=''
    # The defaults first: the menu reads the file again after each action, and a setting returned to its
    # default has no line left in the file.
    DOWNLOAD_SSH_HOST='' DOWNLOAD_SSH_PORT=22 DOWNLOAD_SSH_USER=root CLIENT_CERT_DAYS='' LINK_PORT='' LINK_HOURS=''
    UPDATE_CHECK=yes SHARE_ID_IN_PROFILE=no BLOCK_COUNTRIES='' BLOCK_EXTRA='' COUNTRY_DIRECT=no
    DNS_SERVER=no DNS_UPSTREAM='' DNS_TLS=no DNS_FORCE=yes DNS_DNSSEC=yes NAME_LISTS='' NAMES_BLOCK='' NAMES_ALLOW=''
    TCP_MSS=''
    CONFIG_ISSUES=()
    [[ -f $CONFIG_FILE ]] || { CONFIG_ISSUES+=("$CONFIG_FILE is missing; download commands are disabled."); return 0; }
    # Parsed as data, never sourced.
    while IFS='=' read -r key value || [[ -n $key ]]; do
        [[ $key =~ ^[[:space:]]*(#|$) ]] && continue
        case $key in
            DOWNLOAD_SSH_HOST) DOWNLOAD_SSH_HOST=$value ;;
            DOWNLOAD_SSH_PORT) DOWNLOAD_SSH_PORT=$value ;;
            DOWNLOAD_SSH_USER) DOWNLOAD_SSH_USER=$value ;;
            CLIENT_CERT_DAYS) CLIENT_CERT_DAYS=$value ;;
            LINK_PORT) LINK_PORT=$value ;;
            LINK_HOURS) LINK_HOURS=$value ;;
            UPDATE_CHECK) UPDATE_CHECK=$value ;;
            SHARE_ID_IN_PROFILE) SHARE_ID_IN_PROFILE=$value ;;
            BLOCK_COUNTRIES) BLOCK_COUNTRIES=$value ;;
            BLOCK_EXTRA) BLOCK_EXTRA=$value ;;
            COUNTRY_DIRECT) direct=$value ;;
            BLOCK_IRAN) old_iran=$value ;;
            DNS_SERVER) DNS_SERVER=$value ;;
            DNS_UPSTREAM) DNS_UPSTREAM=$value ;;
            DNS_TLS) DNS_TLS=$value ;;
            DNS_FORCE) DNS_FORCE=$value ;;
            DNS_DNSSEC) DNS_DNSSEC=$value ;;
            NAME_LISTS) NAME_LISTS=$value ;;
            NAMES_BLOCK) NAMES_BLOCK=$value ;;
            NAMES_ALLOW) NAMES_ALLOW=$value ;;
            TCP_MSS) TCP_MSS=$value ;;
            IRAN_DIRECT) old_direct=$value ;;
            *) CONFIG_ISSUES+=("Unknown setting ignored in $CONFIG_FILE: $key") ;;
        esac
    done <"$CONFIG_FILE"
    if [[ -n $DOWNLOAD_SSH_HOST ]] && ! valid_ipv4 "$DOWNLOAD_SSH_HOST" && ! valid_domain "$DOWNLOAD_SSH_HOST"; then
        CONFIG_ISSUES+=("Invalid DOWNLOAD_SSH_HOST in $CONFIG_FILE."); DOWNLOAD_SSH_HOST=''
    fi
    if ! [[ $DOWNLOAD_SSH_PORT =~ ^[0-9]{1,5}$ ]] || (( 10#$DOWNLOAD_SSH_PORT < 1 || 10#$DOWNLOAD_SSH_PORT > 65535 )); then
        CONFIG_ISSUES+=("Invalid DOWNLOAD_SSH_PORT in $CONFIG_FILE."); DOWNLOAD_SSH_HOST=''
    fi
    if ! [[ $DOWNLOAD_SSH_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        CONFIG_ISSUES+=("Invalid DOWNLOAD_SSH_USER in $CONFIG_FILE."); DOWNLOAD_SSH_HOST=''
    fi
    if [[ -n $CLIENT_CERT_DAYS ]] && ! valid_client_days "$CLIENT_CERT_DAYS"; then
        CONFIG_ISSUES+=("Invalid CLIENT_CERT_DAYS in $CONFIG_FILE; using the default."); CLIENT_CERT_DAYS=''
    fi
    if [[ $UPDATE_CHECK != yes && $UPDATE_CHECK != no ]]; then
        CONFIG_ISSUES+=("Invalid UPDATE_CHECK in $CONFIG_FILE; using yes."); UPDATE_CHECK=yes
    fi
    if [[ -n $LINK_PORT ]] && ! valid_link_port "$LINK_PORT"; then
        CONFIG_ISSUES+=("Invalid LINK_PORT in $CONFIG_FILE; choosing a free port."); LINK_PORT=''
    fi
    if [[ -n $LINK_HOURS ]] && ! valid_link_hours "$LINK_HOURS"; then
        CONFIG_ISSUES+=("Invalid LINK_HOURS in $CONFIG_FILE; shares expire after 24 hours."); LINK_HOURS=''
    fi
    if [[ -n $LINK_HOURS ]]; then LINK_HOURS=$((10#$LINK_HOURS)); fi
    if [[ $SHARE_ID_IN_PROFILE != yes && $SHARE_ID_IN_PROFILE != no ]]; then
        CONFIG_ISSUES+=("Invalid SHARE_ID_IN_PROFILE in $CONFIG_FILE; using no."); SHARE_ID_IN_PROFILE=no
    fi
    # The names from before other countries came, until the next save writes the new ones.
    if [[ -z $BLOCK_COUNTRIES && $old_iran == yes ]]; then BLOCK_COUNTRIES=ir; fi
    COUNTRY_DIRECT=${direct:-${old_direct:-no}}
    if [[ -n $BLOCK_COUNTRIES && ! $BLOCK_COUNTRIES =~ ^[a-z]{2}(\ [a-z]{2}){0,9}$ ]]; then
        CONFIG_ISSUES+=("Invalid BLOCK_COUNTRIES in $CONFIG_FILE; no country is blocked."); BLOCK_COUNTRIES=''
    fi
    if [[ $COUNTRY_DIRECT != yes && $COUNTRY_DIRECT != no && $COUNTRY_DIRECT != no-android ]]; then
        CONFIG_ISSUES+=("Invalid COUNTRY_DIRECT in $CONFIG_FILE; using no."); COUNTRY_DIRECT=no
    fi
    if [[ $DNS_SERVER != yes && $DNS_SERVER != no ]]; then CONFIG_ISSUES+=("Invalid DNS_SERVER in $CONFIG_FILE; using no."); DNS_SERVER=no; fi
    if [[ $DNS_TLS != yes && $DNS_TLS != no ]]; then CONFIG_ISSUES+=("Invalid DNS_TLS in $CONFIG_FILE; using no."); DNS_TLS=no; fi
    if [[ $DNS_FORCE != yes && $DNS_FORCE != no ]]; then CONFIG_ISSUES+=("Invalid DNS_FORCE in $CONFIG_FILE; using yes."); DNS_FORCE=yes; fi
    if [[ $DNS_DNSSEC != yes && $DNS_DNSSEC != no ]]; then CONFIG_ISSUES+=("Invalid DNS_DNSSEC in $CONFIG_FILE; using yes."); DNS_DNSSEC=yes; fi
    if [[ -n $DNS_UPSTREAM ]] && ! valid_dns "$DNS_UPSTREAM"; then
        CONFIG_ISSUES+=("Invalid DNS_UPSTREAM in $CONFIG_FILE; using the default."); DNS_UPSTREAM=''
    fi
    if [[ -n $NAME_LISTS && ! $NAME_LISTS =~ ^(abroad|ads|malware)(\ (abroad|ads|malware)){0,2}$ ]]; then
        CONFIG_ISSUES+=("Invalid NAME_LISTS in $CONFIG_FILE; no list is used."); NAME_LISTS=''
    fi
    # Only the form is checked here; geolist.py checks each name when the zone is written.
    if [[ -n $NAMES_BLOCK && ! $NAMES_BLOCK =~ ^[a-z0-9._-]+(\ [a-z0-9._-]+)*$ ]]; then
        CONFIG_ISSUES+=("Invalid NAMES_BLOCK in $CONFIG_FILE; it is not used."); NAMES_BLOCK=''
    fi
    if [[ -n $NAMES_ALLOW && ! $NAMES_ALLOW =~ ^[a-z0-9._-]+(\ [a-z0-9._-]+)*$ ]]; then
        CONFIG_ISSUES+=("Invalid NAMES_ALLOW in $CONFIG_FILE; it is not used."); NAMES_ALLOW=''
    fi
    # Only the form of a range is checked here; geolist.py checks what each one is when the rules are written.
    if [[ -n $BLOCK_EXTRA && ! $BLOCK_EXTRA =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2})(\ [0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2})*$ ]]; then
        CONFIG_ISSUES+=("Invalid BLOCK_EXTRA in $CONFIG_FILE; it is not used."); BLOCK_EXTRA=''
    fi
    if [[ -n $TCP_MSS ]] && ! darban_valid_mss "$TCP_MSS"; then
        CONFIG_ISSUES+=("Invalid TCP_MSS in $CONFIG_FILE; using $DARBAN_MSS_DEFAULT."); TCP_MSS=''
    fi
    if [[ -n $TCP_MSS ]]; then TCP_MSS=$((10#$TCP_MSS)); fi
    if [[ -z $DOWNLOAD_SSH_HOST ]] && (( ${#CONFIG_ISSUES[@]} == 0 )); then
        CONFIG_ISSUES+=("DOWNLOAD_SSH_HOST is not set in $CONFIG_FILE; download commands are disabled.")
    fi
}
setup() {
    local cmd
    darban_require_root
    for cmd in systemctl ss find cp chmod chown timeout; do command -v "$cmd" >/dev/null || { darban_error "Missing dependency: $cmd"; return 1; }; done
    install -d -o root -g root -m 700 "$CONFIG_DIR" "$OUT_DIR"
    load_config
    SERVER_PROBLEM=$(server_problem)
    if [[ -z $SERVER_PROBLEM ]]; then SERVER_SERIAL=$(darban_server_serial); fi
}
server_problem() {
    # Prints why this server cannot be managed; nothing when it can.
    if [[ -f $DARBAN_RESTORE_JOURNAL ]]; then
        if restore_committed; then
            printf 'A restore is done, but its cleanup is unfinished. Finish it: sudo darban restore --resume\n'
        elif [[ $(journal_value state) == undoing ]]; then
            printf 'A rollback of a restore is unfinished. Finish it: sudo darban restore --rollback\n'
        elif [[ $(journal_value state) == starting ]]; then
            printf 'A restore is unfinished: OpenVPN may be running with the restored files, and is not enabled at boot. Finish it: sudo darban restore --resume, or undo it: sudo darban restore --rollback\n'
        else
            printf 'A restore is unfinished, so OpenVPN stays off. Finish it: sudo darban restore --resume, or undo it: sudo darban restore --rollback\n'
        fi
        return 0
    fi
    server_files_problem
}
server_files_problem() {
    # Prints what in the CA or the server files keeps OpenVPN from running; nothing when they are whole.
    local out
    out=$(C_RED='' C_RESET='' darban_preflight 2>&1) || { printf '%s\n' "${out##*ERROR: }"; return 0; }
    if [[ ! -s $TLS_KEY ]]; then printf 'OpenVPN tls-crypt.key is missing.\n'; return 0; fi
    if ! darban_server_serial >/dev/null 2>&1; then
        printf "Cannot read the server certificate from server.conf (one 'cert' directive or an inline <cert> block).\n"
    fi
}
server_listeners() {
    # server_listeners [server.conf]: what OpenVPN listens on, one line each, "udp N" or "tcp N", UDP first. The mode
    # is read from server.conf alone, in one of three forms: one "port" and one "proto udp4" (UDP only), one "port"
    # and one "proto tcp4-server" (TCP only), or exactly two lines "local * N udp" and "local * M tcp" with no "port"
    # and no "proto" (both). Any other shape fails, and nothing is printed.
    awk '
        $1 == "port" { np++; port = $2; if (NF != 2 || $2 !~ /^[0-9][0-9]?[0-9]?[0-9]?[0-9]?$/) bad = 1 }
        $1 == "proto" { npr++; proto = $2; if (NF != 2) bad = 1 }
        $1 == "local" {
            nl++
            if (NF != 4 || $2 != "*" || $3 !~ /^[0-9][0-9]?[0-9]?[0-9]?[0-9]?$/ || ($4 != "udp" && $4 != "tcp")) bad = 1
            else { at[$4] = $3 + 0; seen[$4]++ }
        }
        function fits(n) { return n >= 1 && n <= 65535 }
        END {
            if (bad) exit 1
            if (nl == 0) {
                if (np != 1 || npr != 1 || !fits(port + 0)) exit 1
                if (proto == "udp4") print "udp " port + 0
                else if (proto == "tcp4-server") print "tcp " port + 0
                else exit 1
            } else {
                if (np || npr || nl != 2 || seen["udp"] != 1 || seen["tcp"] != 1 || !fits(at["udp"]) || !fits(at["tcp"])) exit 1
                print "udp " at["udp"]
                print "tcp " at["tcp"]
            }
        }' "${1:-$DARBAN_SERVER_CONF}"
}
listener_port() {
    # listener_port <udp|tcp> [server.conf]: the port OpenVPN listens on with that protocol; fails when it does not.
    local out
    out=$(server_listeners "${2:-}") || return 1
    awk -v p="$1" '$1 == p {print $2; found = 1} END {exit !found}' <<<"$out"
}
server_mode() {
    # udp, tcp or both.
    local out
    out=$(server_listeners "${1:-}") || return 1
    case $(awk '{printf "%s%s", (NR > 1 ? "+" : ""), $1}' <<<"$out") in
        udp) printf 'udp\n' ;; tcp) printf 'tcp\n' ;; udp+tcp) printf 'both\n' ;; *) return 1 ;;
    esac
}
server_port() {
    # For callers that know one port only: the UDP port, or the only one.
    local out
    out=$(server_listeners "${1:-}") || return 1
    awk 'NR == 1 {print $2}' <<<"$out"
}
listeners_label() {
    # listeners_label [server.conf]: "UDP 1543", "TCP 443" or "UDP 1543 + TCP 443"; "?" when server.conf has no form
    # this tool knows.
    local out
    out=$(server_listeners "${1:-}") || { printf '?\n'; return 1; }
    awk '{printf "%s%s %s", (NR > 1 ? " + " : ""), toupper($1), $2} END {print ""}' <<<"$out"
}
endpoint_label() {
    # endpoint_label <host>: "host:1543/UDP", "host:443/TCP" or "host:1543/UDP + 443/TCP".
    local out
    out=$(server_listeners) || { printf '%s:?\n' "$1"; return 1; }
    awk -v h="$1" '{printf "%s%s/%s", (NR > 1 ? " + " : h ":"), $2, toupper($1)} END {print ""}' <<<"$out"
}
openvpn_version() { { openvpn --version 2>/dev/null || true; } | awk 'NR == 1 && $1 == "OpenVPN" && $2 ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?/ {sub(/[^0-9.].*$/, "", $2); print $2}'; }
openvpn_at_least() {
    # openvpn_at_least <version>: the OpenVPN here is that version or newer. Unknown counts as older.
    local have
    have=$(openvpn_version) || return 1
    [[ -n $have && $(printf '%s\n%s\n' "$1" "$have" | sort -V | head -n 1) == "$1" ]]
}
server_tls_ok() {
    # Profiles embed $TLS_KEY in a <tls-crypt> block, so the server must use exactly that mode and key.
    local path
    awk '$1=="tls-auth" || $1=="tls-crypt-v2" || $1 ~ /^<(tls-auth|tls-crypt|tls-crypt-v2)>/ {bad=1} END {exit bad}' "$DARBAN_SERVER_CONF" || return 1
    path=$(darban_conf_single tls-crypt) || return 1
    [[ $(darban_conf_path "$path") -ef $TLS_KEY ]]
}
server_data_ciphers() {
    # Mirror the server's negotiable list so profiles cannot drift from it.
    local value rc=0
    value=$(darban_conf_single data-ciphers) || rc=$?
    if (( rc == 1 )); then value=$DEFAULT_DATA_CIPHERS; elif (( rc != 0 )); then return 1; fi
    [[ $value =~ ^[A-Za-z0-9_:-]+$ ]] || return 1
    printf '%s\n' "$value"
}
profile_preconditions() {
    valid_domain "$(domain)" || { warn "The server address is not set yet. Set it first: Settings ${S_CRUMB} 1."; return 1; }
    server_listeners >/dev/null || { warn "server.conf has no listener form this tool knows: one 'port' with 'proto udp4' or 'proto tcp4-server', or the two 'local' lines of both."; return 1; }
    server_tls_ok || {
        warn "server.conf must contain exactly one 'tls-crypt' directive using $TLS_KEY (no tls-auth, tls-crypt-v2 or inline keys)."; return 1;
    }
    server_data_ciphers >/dev/null || { warn 'server.conf data-ciphers is repeated or malformed.'; return 1; }
}
domain() { [[ -s $DOMAIN_FILE ]] && head -n 1 "$DOMAIN_FILE" || true; }
own_public_ipv4() {
    # The public IPv4 addresses on this server's own interfaces, one a line. Behind NAT there are none: the address
    # the internet sees is not on any of them.
    local ip
    while IFS= read -r ip; do
        if valid_ipv4 "$ip" && ! is_private_ip "$ip"; then printf '%s\n' "$ip"; fi
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' || true)
}
address_elsewhere() {
    # address_elsewhere <host>: prints this server's own public IPv4 when <host> is a public IPv4, or a name of one,
    # that is not one of them. Silent and false when that cannot be told: a private address, a name that does not
    # resolve, or a server behind NAT.
    local host=$1 resolved mine
    resolved=$host
    if ! valid_ipv4 "$host"; then resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true); fi
    valid_ipv4 "$resolved" && ! is_private_ip "$resolved" || return 1
    mine=$(own_public_ipv4)
    [[ -n $mine ]] || return 1
    if grep -qxF -- "$resolved" <<<"$mine"; then return 1; fi
    printf '%s\n' "${mine%%$'\n'*}"
}
save_config() {
    # Unknown lines are kept; only the settings this tool owns are rewritten.
    local temp held=$CA_LOCKED
    ca_lock || return 1
    temp=$(mktemp "$CONFIG_DIR/.config.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    if [[ -f $CONFIG_FILE ]]; then
        awk -F= '$1!="DOWNLOAD_SSH_HOST" && $1!="DOWNLOAD_SSH_PORT" && $1!="DOWNLOAD_SSH_USER" && $1!="CLIENT_CERT_DAYS" && $1!="LINK_PORT" && $1!="LINK_HOURS" && $1!="UPDATE_CHECK" && $1!="BLOCK_IRAN" && $1!="BLOCK_EXTRA" && $1!="IRAN_DIRECT" && $1!="BLOCK_COUNTRIES" && $1!="COUNTRY_DIRECT" && $1!="DNS_SERVER" && $1!="DNS_UPSTREAM" && $1!="DNS_TLS" && $1!="DNS_FORCE" && $1!="DNS_DNSSEC" && $1!="NAME_LISTS" && $1!="NAMES_BLOCK" && $1!="NAMES_ALLOW" && $1!="TCP_MSS"' "$CONFIG_FILE" >"$temp" || return 1
    fi
    printf 'DOWNLOAD_SSH_HOST=%s\nDOWNLOAD_SSH_PORT=%s\nDOWNLOAD_SSH_USER=%s\n' "$DOWNLOAD_SSH_HOST" "$DOWNLOAD_SSH_PORT" "$DOWNLOAD_SSH_USER" >>"$temp" || return 1
    if [[ -n $CLIENT_CERT_DAYS ]]; then printf 'CLIENT_CERT_DAYS=%s\n' "$CLIENT_CERT_DAYS" >>"$temp" || return 1; fi
    if [[ -n $LINK_PORT ]]; then printf 'LINK_PORT=%s\n' "$LINK_PORT" >>"$temp" || return 1; fi
    if [[ -n $LINK_HOURS ]]; then printf 'LINK_HOURS=%s\n' "$LINK_HOURS" >>"$temp" || return 1; fi
    if [[ $UPDATE_CHECK == no ]]; then printf 'UPDATE_CHECK=no\n' >>"$temp" || return 1; fi
    if [[ -n $BLOCK_COUNTRIES ]]; then printf 'BLOCK_COUNTRIES=%s\n' "$BLOCK_COUNTRIES" >>"$temp" || return 1; fi
    if [[ -n $BLOCK_EXTRA ]]; then printf 'BLOCK_EXTRA=%s\n' "$BLOCK_EXTRA" >>"$temp" || return 1; fi
    if [[ $COUNTRY_DIRECT != no ]]; then printf 'COUNTRY_DIRECT=%s\n' "$COUNTRY_DIRECT" >>"$temp" || return 1; fi
    if [[ $DNS_SERVER == yes ]]; then printf 'DNS_SERVER=yes\n' >>"$temp" || return 1; fi
    if [[ -n $DNS_UPSTREAM ]]; then printf 'DNS_UPSTREAM=%s\n' "$DNS_UPSTREAM" >>"$temp" || return 1; fi
    if [[ $DNS_TLS == yes ]]; then printf 'DNS_TLS=yes\n' >>"$temp" || return 1; fi
    if [[ $DNS_FORCE == no ]]; then printf 'DNS_FORCE=no\n' >>"$temp" || return 1; fi
    if [[ $DNS_DNSSEC == no ]]; then printf 'DNS_DNSSEC=no\n' >>"$temp" || return 1; fi
    if [[ -n $NAME_LISTS ]]; then printf 'NAME_LISTS=%s\n' "$NAME_LISTS" >>"$temp" || return 1; fi
    if [[ -n $NAMES_BLOCK ]]; then printf 'NAMES_BLOCK=%s\n' "$NAMES_BLOCK" >>"$temp" || return 1; fi
    if [[ -n $NAMES_ALLOW ]]; then printf 'NAMES_ALLOW=%s\n' "$NAMES_ALLOW" >>"$temp" || return 1; fi
    # Only a checked whole number reaches the file, and from there the NAT rules.
    if [[ -n $TCP_MSS ]]; then
        darban_valid_mss "$TCP_MSS" || return 1
        printf 'TCP_MSS=%d\n' "$((10#$TCP_MSS))" >>"$temp" || return 1
    fi
    chmod 600 "$temp" && mv -f -- "$temp" "$CONFIG_FILE" || return 1
    if (( ! held )); then ca_unlock; fi
}

#!/usr/bin/env bash
# Facts about OpenVPN 2.7 with a UDP and a TCP socket in one process, F1 to F6 of issue #115, written to the run's
# summary for the design of UDP, TCP or both (T1). For a disposable machine where the acceptance setup installed
# OpenVPN 2.7 ONLY: run as root; it refuses without --i-know. A temporary OpenVPN of its own, with its own CA, port,
# devices and network, is started and stopped here; the installed server is not touched, and that is checked.
# Every fact is written as it was seen, "does not work" and errors included: a fact never fails the run. The run
# fails only when the installed server changed, or when this script could not make its CA.
set -Euo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This starts a temporary OpenVPN. Use only on a disposable machine: openvpn-facts-ci.sh --i-know' >&2; exit 2; }
command -v openvpn >/dev/null || { echo 'OpenVPN is not installed: run this after the acceptance setup.' >&2; exit 2; }

W=$(mktemp -d /tmp/darban-facts.XXXXXXXX)
chmod 755 "$W"
RUN=$W/run
install -d -o nobody -g nogroup -m 755 "$RUN" "$RUN/env"
install -d -o nobody -g nogroup -m 700 "$W/ps"
SUM=$W/summary.md
PORT=11940
SHARED=18443
SDEV=dfs0
UNIT=openvpn-server@server.service
CIPHERS=AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

# ---------- the installed server, as it is before ----------
installed_state() {
    printf 'conf %s\n' "$(sha256sum /etc/openvpn/server/server.conf 2>/dev/null | cut -d' ' -f1)"
    printf 'active %s\n' "$(systemctl is-active "$UNIT" 2>/dev/null)"
    systemctl show -p MainPID -p NRestarts "$UNIT" 2>/dev/null
}
installed_state >"$W/installed.before"

# ---------- the summary ----------
say() { printf '%s\n' "$*" >>"$SUM"; }
# fenced: the lines read on stdin, in a code block of the summary, or "(nothing)".
fenced() {
    local text
    text=$(cat)
    printf '```\n%s\n```\n' "${text:-(nothing)}" >>"$SUM"
}
# lines <file> <regex> [max]: the lines of an OpenVPN log that match, without the date and time OpenVPN puts first.
lines() { grep -aiE -- "$2" "$1" 2>/dev/null | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} //' | head -n "${3:-12}"; }

finish() {
    local name pid
    for pidfile in "$W"/*.pid; do
        [[ -s $pidfile ]] || continue
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pidfile in "$W"/*.pid; do
        [[ -s $pidfile ]] || continue
        kill -9 "$(cat "$pidfile")" 2>/dev/null || true
    done
    nft delete table inet darbanfacts 2>/dev/null || true
    for name in "$SDEV" dfc0 dfc1; do ip link del "$name" 2>/dev/null || true; done
    # The whole logs of the temporary OpenVPN, in the job's log, for anyone checking a fact.
    for name in "$W"/*.log "$W"/*.err; do
        [[ -s $name ]] || continue
        echo "===== ${name##*/}"
        cat -- "$name"
    done
    echo '===== summary'
    cat -- "$SUM" 2>/dev/null || true
    if [[ -n ${GITHUB_STEP_SUMMARY:-} && -s $SUM ]]; then cat -- "$SUM" >>"$GITHUB_STEP_SUMMARY"; fi
}
trap finish EXIT

say "### OpenVPN 2.7 with UDP and TCP sockets together: facts F1 to F6 (#115)"
say
. /etc/os-release
say "Ubuntu $VERSION_ID, $(uname -m), kernel $(uname -r). $(openvpn --version | head -n 1)."
if modinfo -k "$(uname -r)" ovpn >/dev/null 2>&1; then
    KERNEL_DCO="the running kernel has the ovpn module, so DCO can be measured here"
elif modinfo ovpn-dco-v2 >/dev/null 2>&1; then
    KERNEL_DCO="the running kernel has no in-kernel ovpn module, but ovpn-dco-v2 (DKMS) is there"
else
    KERNEL_DCO="the running kernel has no ovpn module, so no DCO can be measured on this runner (a kernel the setup installed is not running before a reboot)"
fi
say "DCO: $KERNEL_DCO."
say
say "A temporary OpenVPN of this test, with its own CA, on 127.0.0.1 port $PORT, devices $SDEV, dfc0 and dfc1; the installed server is not touched. Its settings follow server.conf: tls-crypt, AEAD ciphers only, user nobody."
say

# ---------- a CA of its own ----------
cat >"$W/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = darban-facts
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
[client]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF
make_pki() {
    local name kind
    openssl req -x509 -config "$W/openssl.cnf" -extensions ca -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$W/ca.key" -out "$W/ca.crt" -days 3 -subj /CN=darban-facts-ca || return 1
    for name in server c1 c2; do
        kind=client
        if [[ $name == server ]]; then kind=server; fi
        openssl req -new -config "$W/openssl.cnf" -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "$W/$name.key" -out "$W/$name.csr" -subj "/CN=$name" || return 1
        openssl x509 -req -in "$W/$name.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" -set_serial "0x$(openssl rand -hex 8)" \
            -days 3 -extfile "$W/openssl.cnf" -extensions "$kind" -out "$W/$name.crt" || return 1
    done
    openvpn --genkey secret "$W/tc.key" || return 1
    chmod 600 "$W"/*.key
}
if ! make_pki >"$W/pki.out" 2>&1; then
    cat "$W/pki.out"
    say "**Not measured: this test could not make its own CA.**"
    exit 1
fi

cat >"$W/server-base.conf" <<EOF
dev $SDEV
dev-type tun
topology subnet
server 10.198.77.0 255.255.255.0
ca $W/ca.crt
cert $W/server.crt
key $W/server.key
tls-crypt $W/tc.key
dh none
tls-version-min 1.2
data-ciphers $CIPHERS
keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup
verb 3
EOF
cat >"$W/client-base.conf" <<EOF
client
dev-type tun
nobind
remote-cert-tls server
tls-version-min 1.2
data-ciphers $CIPHERS
ca $W/ca.crt
tls-crypt $W/tc.key
route-nopull
verb 3
EOF
# The client-connect hook writes what OpenVPN gives it about the client's address and socket, nothing else.
cat >"$W/connect.sh" <<EOF
#!/bin/sh
env | grep -E '^(common_name|trusted_|untrusted_|proto|local|remote_port|ifconfig_pool_remote_ip)' | sort >"$RUN/env/\$common_name.env"
exit 0
EOF
chmod 755 "$W/connect.sh"

# ---------- starting and stopping ----------
alive() { [[ -s $W/$1.pid ]] && kill -0 "$(cat "$W/$1.pid")" 2>/dev/null; }
# server <name> <lines...>: writes the server's configuration, the base and these lines.
server() {
    local name=$1
    shift
    { cat "$W/server-base.conf"; printf '%s\n' "$@"; } >"$W/$name.conf"
}
# start_server <name>: 0 once it says Initialization Sequence Completed, within 15 seconds.
start_server() {
    local name=$1 i
    rm -f "$W/$name.log" "$W/$name.err"
    openvpn --config "$W/$name.conf" --log "$W/$name.log" >"$W/$name.err" 2>&1 &
    echo $! >"$W/$name.pid"
    for i in $(seq 1 30); do
        if grep -aq 'Initialization Sequence Completed' "$W/$name.log" 2>/dev/null; then return 0; fi
        alive "$name" || return 1
        sleep 0.5
    done
    return 1
}
stop() {
    local name=$1 dev=${2:-} pid i
    if [[ -s $W/$name.pid ]]; then
        pid=$(cat "$W/$name.pid")
        kill "$pid" 2>/dev/null || true
        for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$W/$name.pid"
    fi
    # Running as nobody, OpenVPN may not be able to delete its own DCO device.
    if [[ -n $dev ]]; then ip link del "$dev" 2>/dev/null || true; fi
}
# why <name>: why a server or client did not start, from what it printed.
why() { { cat "$W/$1.err" 2>/dev/null; lines "$W/$1.log" 'error|options|fatal|warn|exiting|cannot|not supported|unknown|unrecognized' 8; } | head -n 10; }
# listeners <name>: the sockets the process holds, as protocol and address.
listeners() {
    local pid
    pid=$(cat "$W/$1.pid" 2>/dev/null) || return 0
    ss -H -ltunp 2>/dev/null | awk -v p="pid=$pid," 'index($0, p) {print $1, $5}' | sort -u
}
# devkind <dev>: DCO when the device is an ovpn one, the kernel's way, or a tun device.
devkind() {
    local info
    if ! info=$(ip -d link show dev "$1" 2>/dev/null); then echo 'no device'; return; fi
    if grep -Eq '(^|[[:space:]])ovpn(-dco)?([[:space:]]|$)' <<<"$info"; then echo 'ovpn (DCO on)'
    elif grep -Eq '(^|[[:space:]])tun([[:space:]]|$)' <<<"$info"; then echo 'tun (DCO off)'
    else echo "other: $(sed -n 3p <<<"$info" | xargs)"; fi
}
# client <name> <dev> <cert> <lines...>: writes a client's configuration.
client() {
    local name=$1 dev=$2 cert=$3
    shift 3
    { cat "$W/client-base.conf"; printf 'dev %s\ncert %s\nkey %s\n' "$dev" "$W/$cert.crt" "$W/$cert.key"; printf '%s\n' "$@"; } >"$W/$name.conf"
}
# start_client <name> [seconds]: 0 once connected. ELAPSED is the time it took, in seconds with one decimal, or
# what happened instead. Not to be called in a subshell.
ELAPSED=''
start_client() {
    local name=$1 limit=${2:-20} start now
    rm -f "$W/$name.log" "$W/$name.err"
    start=$(date +%s%N)
    openvpn --config "$W/$name.conf" --log "$W/$name.log" >"$W/$name.err" 2>&1 &
    echo $! >"$W/$name.pid"
    while :; do
        now=$(date +%s%N)
        if grep -aq 'Initialization Sequence Completed' "$W/$name.log" 2>/dev/null; then
            ELAPSED=$(awk -v d=$(( (now - start) / 1000000 )) 'BEGIN {printf "%.1f", d / 1000}')
            return 0
        fi
        if ! alive "$name"; then ELAPSED='the client stopped'; return 1; fi
        if (( (now - start) / 1000000000 >= limit )); then ELAPSED="not connected in $limit s"; return 1; fi
        sleep 0.2
    done
}
# over <client>: the transport the client's log says it connected over.
over() {
    if grep -aq 'TCP connection established' "$W/$1.log" 2>/dev/null; then echo TCP
    elif grep -aqE 'UDPv[46] link remote|UDP link remote' "$W/$1.log" 2>/dev/null; then echo UDP
    else echo 'unknown'; fi
}
# new_lines <file> <from line>: what a log gained since that line.
new_lines() { tail -n "+$(( $2 + 1 ))" "$1" 2>/dev/null | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} //' | head -n 10; }
count() { wc -l <"$1" 2>/dev/null || echo 0; }
# connect_report <client> <what>: connects one client and says how it went, in a summary line.
connect_report() {
    if start_client "$1"; then say "- $2: connected in $ELAPSED s, over $(over "$1"); client device $(devkind "$(awk '$1=="dev" {print $2}' "$W/$1.conf")")."
    else say "- $2: **did not connect** ($ELAPSED)."; lines "$W/$1.log" 'error|fatal|warn|failed|refused|exiting' 6 | fenced; fi
}

# ---------- F1: the form of two local lines ----------
say '#### F1: two `local` lines, one UDP and one TCP'
say
declare -A FORM=(
    [A]="local 127.0.0.1 $PORT udp|local 127.0.0.1 $PORT tcp"
    [B]="local 127.0.0.1 $PORT udp4|local 127.0.0.1 $PORT tcp4-server"
    [C]="proto udp4|port $PORT|local 127.0.0.1 $PORT udp|local 127.0.0.1 $PORT tcp"
    [D]="proto tcp-server|port $PORT|local 127.0.0.1 $PORT udp|local 127.0.0.1 $PORT tcp"
    [E]="local * $PORT udp|local * $PORT tcp"
)
declare -A FORM_NOTE=([A]='no proto, no port' [B]='4-suffixed protocols, no proto, no port' [C]='with proto udp4 and port' [D]='with proto tcp-server and port' [E]='any address, no proto, no port')
BOTH=''
both_ok=0
for key in A B C D E; do
    IFS='|' read -r -a extra <<<"${FORM[$key]}"
    server "f1$key" "${extra[@]}"
    say "Form $key, ${FORM_NOTE[$key]}: \`$(printf '%s; ' "${extra[@]}" | sed 's/; $//')\`"
    say
    if start_server "f1$key"; then
        found=$(listeners "f1$key")
        say "- Started. Sockets it holds: $(tr '\n' ',' <<<"$found" | sed 's/,$//; s/,/, /g')."
        if [[ -z $BOTH ]] && grep -q '^udp' <<<"$found" && grep -q '^tcp' <<<"$found"; then BOTH=$key; fi
        lines "$W/f1$key.log" 'warn|deprecat|ignor|local|listen|socket' 8 | fenced
    else
        say "- **Did not start.** What it said:"
        why "f1$key" | fenced
    fi
    stop "f1$key" "$SDEV"
    say
done
if [[ -z $BOTH ]]; then
    say "**No form opened a UDP and a TCP socket in one process.** The facts that need both sockets are not measured below."
    BOTH_LINES=()
    TCP_LINES=("proto tcp-server" "local 127.0.0.1" "port $PORT")
    UDP_LINES=("proto udp4" "local 127.0.0.1" "port $PORT")
else
    IFS='|' read -r -a BOTH_LINES <<<"${FORM[$BOTH]}"
    # The same form, with its UDP line or its TCP line alone.
    TCP_LINES=()
    UDP_LINES=()
    for line in "${BOTH_LINES[@]}"; do
        case $line in
            "local "*" udp"*) UDP_LINES+=("$line") ;;
            "local "*" tcp"*) TCP_LINES+=("$line") ;;
            *) UDP_LINES+=("$line"); TCP_LINES+=("$line") ;;
        esac
    done
    say "The first form that opened both sockets, $BOTH, is the one used below. With one socket, the same form keeps only its UDP or its TCP line."
fi
say

UDP_REMOTE="remote 127.0.0.1 $PORT udp"
TCP_REMOTE="remote 127.0.0.1 $PORT tcp"
client cu dfc0 c1 "$UDP_REMOTE"
client ct dfc1 c2 "$TCP_REMOTE"

# ---------- F2 and F5: both sockets, then TCP alone, then UDP alone ----------
if (( ${#BOTH_LINES[@]} )); then
    server both "${BOTH_LINES[@]}" "status $RUN/both.status 1" "status-version 3" "management $RUN/mgmt.sock unix" \
        "script-security 2" "client-connect $W/connect.sh"
    both_ok=0
    if start_server both; then both_ok=1; fi
fi

say '#### F2: DCO with both sockets, and with TCP alone'
say
if (( ${#BOTH_LINES[@]} )) && (( both_ok )); then
    say "Both sockets, form $BOTH:"
    connect_report cu 'A UDP client'
    connect_report ct 'A TCP client, at the same time'
    say "- Server device: $(devkind "$SDEV")."
    lines "$W/both.log" 'dco|data channel offload|ovpn' 8 | fenced
elif (( ${#BOTH_LINES[@]} )); then
    say "- Both sockets: **the server did not start**:"
    why both | fenced
else
    say "- Both sockets: not measured, since no form of F1 opened both."
fi

say '#### F5: the real address of a TCP client'
say
if (( ${#BOTH_LINES[@]} )) && (( both_ok )); then
    sleep 2
    say "The status file, \`status-version 3\`, with a UDP client (c1) and a TCP client (c2); a | stands for a tab:"
    grep -aE '^(HEADER.CLIENT_LIST|CLIENT_LIST|HEADER.ROUTING_TABLE|ROUTING_TABLE)' "$RUN/both.status" 2>/dev/null | tr '\t' '|' | fenced
    say "The management command \`status 3\`, the one darban reads:"
    python3 -I - "$RUN/mgmt.sock" >"$W/mgmt.out" 2>&1 <<'EOF'
import socket
import sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
s.connect(sys.argv[1])
s.sendall(b'status 3\n')
data = b''
while b'\nEND' not in data:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
s.sendall(b'quit\n')
print(data.decode(errors='replace'))
EOF
    grep -aE '^(HEADER.CLIENT_LIST|CLIENT_LIST)|rror' "$W/mgmt.out" | tr '\t' '|' | fenced
    for name in c1 c2; do
        say "What \`client-connect\` gets for $name ($( [[ $name == c1 ]] && echo UDP || echo TCP)):"
        if [[ -s $RUN/env/$name.env ]]; then fenced <"$RUN/env/$name.env"; else echo '(no file: the hook did not run for it)' | fenced; fi
    done
else
    say "- Not measured: the server with both sockets did not run."
fi
stop cu dfc0; stop ct dfc1; stop both "$SDEV"
say

# F2, continued: TCP alone, and UDP alone as the reference.
for mode in tcp udp; do
    if [[ $mode == tcp ]]; then server only-tcp "${TCP_LINES[@]}"; else server only-udp "${UDP_LINES[@]}"; fi
    say "$( [[ $mode == tcp ]] && echo 'TCP alone' || echo 'UDP alone, for comparison'): \`$( if [[ $mode == tcp ]]; then printf '%s; ' "${TCP_LINES[@]}"; else printf '%s; ' "${UDP_LINES[@]}"; fi | sed 's/; $//')\`"
    if start_server "only-$mode"; then
        if [[ $mode == tcp ]]; then connect_report ct 'A TCP client'; else connect_report cu 'A UDP client'; fi
        say "- Server device: $(devkind "$SDEV")."
        lines "$W/only-$mode.log" 'dco|data channel offload|ovpn' 8 | fenced
    else
        say "- **The server did not start**:"
        why "only-$mode" | fenced
    fi
    stop cu dfc0; stop ct dfc1; stop "only-$mode" "$SDEV"
    say
done

# ---------- F3: explicit-exit-notify 1 ----------
say '#### F3: `explicit-exit-notify 1` with TCP alone and with both'
say
client ct-een dfc1 c2 "$TCP_REMOTE" 'explicit-exit-notify 1'
client cu-een dfc0 c1 "$UDP_REMOTE" 'explicit-exit-notify 1'
server een-tcp "${TCP_LINES[@]}" 'explicit-exit-notify 1'
say "Server, TCP alone:"
if start_server een-tcp; then
    say "- Started. What it says about it:"
    lines "$W/een-tcp.log" 'exit-notify|exit notif|warn|ignor' 8 | fenced
    say "Client side, a TCP client with \`explicit-exit-notify 1\`:"
    connect_report ct-een 'The TCP client'
    lines "$W/ct-een.log" 'exit-notify|exit notif|warn|ignor' 8 | fenced
else
    say "- **Did not start**:"
    why een-tcp | fenced
fi
stop ct-een dfc1; stop een-tcp "$SDEV"
say
if (( ${#BOTH_LINES[@]} )); then
    server een-both "${BOTH_LINES[@]}" 'explicit-exit-notify 1'
    say "Server, both sockets:"
    if start_server een-both; then
        say "- Started. What it says about it:"
        lines "$W/een-both.log" 'exit-notify|exit notif|warn|ignor' 8 | fenced
        connect_report cu-een 'A UDP client with explicit-exit-notify 1'
        connect_report ct-een 'A TCP client with explicit-exit-notify 1'
        lines "$W/ct-een.log" 'exit-notify|exit notif|warn|ignor' 8 | fenced
        for name in cu-een ct-een; do
            from=$(count "$W/een-both.log")
            stop "$name" "$( [[ $name == cu-een ]] && echo dfc0 || echo dfc1)"
            sleep 3
            say "What the server logged when the $( [[ $name == cu-een ]] && echo UDP || echo TCP) client stopped:"
            new_lines "$W/een-both.log" "$from" | fenced
        done
        # The server's side of it: what each client sees when the server stops.
        start_client cu-een || true
        start_client ct-een || true
        from_u=$(count "$W/cu-een.log"); from_t=$(count "$W/ct-een.log")
        stop een-both "$SDEV"
        sleep 3
        say "What the UDP client logged when this server stopped:"
        new_lines "$W/cu-een.log" "$from_u" | fenced
        say "What the TCP client logged when this server stopped:"
        new_lines "$W/ct-een.log" "$from_t" | fenced
    else
        say "- **Did not start**:"
        why een-both | fenced
    fi
    stop cu-een dfc0; stop ct-een dfc1; stop een-both "$SDEV"
else
    say "- Both sockets: not measured, since no form of F1 opened both."
fi
say

# ---------- F4: a client with a UDP and a TCP remote, when UDP is silently dropped ----------
say '#### F4: from UDP to TCP when UDP is silently dropped, `server-poll-timeout 5`'
say
if (( ${#BOTH_LINES[@]} )); then
    client two dfc0 c1 "$UDP_REMOTE" "$TCP_REMOTE" 'server-poll-timeout 5'
    say "The client: \`$UDP_REMOTE\`, then \`$TCP_REMOTE\`, \`server-poll-timeout 5\`, the other timers at their defaults. $(openvpn --version | head -n 1 | cut -d' ' -f1-2) as the client."
    server f4 "${BOTH_LINES[@]}"
    if start_server f4; then
        if start_client two 30; then say "- UDP not dropped, for comparison: connected in $ELAPSED s, over $(over two)."
        else say "- UDP not dropped, for comparison: **did not connect** ($ELAPSED)."; fi
        stop two dfc0
        # Dropped where the server receives, so the client's sending sees no error: as a network that drops UDP.
        nft -f - <<EOF
table inet darbanfacts {
    chain input {
        type filter hook input priority -10; policy accept;
        iif "lo" udp dport $PORT drop
    }
}
EOF
        if start_client two 150; then say "- **UDP dropped: connected in $ELAPSED s, over $(over two).**"
        else say "- **UDP dropped: did not connect** ($ELAPSED)."; fi
        say "The client's log on the way, with its times:"
        grep -aE 'link remote|Attempting to establish TCP|TCP connection established|poll|timeout|Restart pause|SIGUSR1|Initialization Sequence Completed|TLS key negotiation failed' "$W/two.log" | head -n 20 | fenced
        nft delete table inet darbanfacts 2>/dev/null || true
        stop two dfc0
    else
        say "- **The server with both sockets did not start**:"
        why f4 | fenced
    fi
    stop f4 "$SDEV"
else
    say "- Not measured: no form of F1 opened both sockets."
fi
say

# ---------- F6: port-share ----------
say '#### F6: `port-share` with TCP alone and with both'
say
python3 -I - "$W/server.crt" "$W/server.key" "$SHARED" "$W/shared-peers.txt" >"$W/shared.err" 2>&1 <<'EOF' &
import socket
import ssl
import sys
import threading

cert, key, port, peers = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv = socket.create_server(('127.0.0.1', port))


def serve(conn, peer):
    try:
        with ctx.wrap_socket(conn, server_side=True) as tls:
            tls.settimeout(20)
            tls.recv(4096)
            tls.sendall(f'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nreached the shared service, from {peer[0]}:{peer[1]}\n'.encode())
    except Exception as exc:  # what went wrong goes to the peers file; the service keeps serving
        with open(peers, 'a', encoding='utf-8') as out:
            out.write(f'{peer[0]}:{peer[1]} error {type(exc).__name__}: {exc}\n')


while True:
    conn, peer = srv.accept()
    with open(peers, 'a', encoding='utf-8') as out:
        out.write(f'{peer[0]}:{peer[1]}\n')
    threading.Thread(target=serve, args=(conn, peer), daemon=True).start()
EOF
echo $! >"$W/shared.pid"
cat >"$W/probe.py" <<'EOF'
import socket
import ssl
import sys
import time

host, port, hold = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection((host, port), timeout=15) as raw:
        with ctx.wrap_socket(raw, server_hostname='localhost') as tls:
            time.sleep(hold)
            tls.sendall(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n')
            data = b''
            while True:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
except Exception as exc:  # the fact is what happened, so it is printed, not raised
    print(f'{type(exc).__name__}: {exc}')
    sys.exit(1)
text = data.decode(errors='replace').strip()
print(text.splitlines()[-1] if text else 'an empty answer')
sys.exit(0 if 'reached the shared service' in text else 1)
EOF
sleep 1
if ! python3 -I "$W/probe.py" 127.0.0.1 "$SHARED" 0 >"$W/probe-direct.out" 2>&1; then
    say "- The shared service of this test did not answer by itself: $(cat "$W/probe-direct.out"). F6 is not measured."
else
    say "A TLS service on 127.0.0.1:$SHARED stands for the shared local service. \`port-share 127.0.0.1 $SHARED $W/ps\`, the directory owned by nobody."
    say
    for mode in tcp both; do
        if [[ $mode == both ]] && (( ! ${#BOTH_LINES[@]} )); then say "- Both sockets: not measured, since no form of F1 opened both."; continue; fi
        if [[ $mode == tcp ]]; then server "ps-$mode" "${TCP_LINES[@]}" "port-share 127.0.0.1 $SHARED $W/ps"
        else server "ps-$mode" "${BOTH_LINES[@]}" "port-share 127.0.0.1 $SHARED $W/ps"; fi
        say "$( [[ $mode == tcp ]] && echo 'TCP alone' || echo 'Both sockets'):"
        if start_server "ps-$mode"; then
            say "- Started. Server device: $(devkind "$SDEV"). What it says about port-share and DCO:"
            lines "$W/ps-$mode.log" 'port.share|proxy|dco|warn' 8 | fenced
            : >"$W/shared-peers.txt"
            python3 -I "$W/probe.py" 127.0.0.1 "$PORT" 4 >"$W/probe-$mode.out" 2>&1 &
            probe=$!
            sleep 2
            say "- What \`dir\` holds while a proxied connection is open (file: contents):"
            for file in "$W"/ps/*; do
                [[ -e $file ]] || continue
                printf '%s: %s (owner %s, mode %s)\n' "${file##*/}" "$(cat -- "$file")" "$(stat -c %U -- "$file")" "$(stat -c %a -- "$file")"
            done | fenced
            if wait "$probe"; then say "- **A TLS connection that is not OpenVPN reached the shared service**: $(cat "$W/probe-$mode.out")"
            else say "- **A TLS connection that is not OpenVPN did not reach the shared service**: $(cat "$W/probe-$mode.out")"; fi
            say "- The shared service saw it from: $(tr '\n' ' ' <"$W/shared-peers.txt" 2>/dev/null)"
            say "- What \`dir\` holds after it closed: $(find "$W/ps" -mindepth 1 -printf '%f ' 2>/dev/null | sed 's/ $//')"
            connect_report ct 'Then an OpenVPN TCP client on the same port'
            if [[ $mode == both ]]; then connect_report cu 'And an OpenVPN UDP client'; fi
            say "- Server device with the clients on: $(devkind "$SDEV")."
            lines "$W/ps-$mode.log" 'port.share|proxy|dco' 8 | fenced
        else
            say "- **Did not start**:"
            why "ps-$mode" | fenced
        fi
        stop cu dfc0; stop ct dfc1; stop "ps-$mode" "$SDEV"
        say
    done
fi
stop shared

# ---------- the installed server must be as it was ----------
installed_state >"$W/installed.after"
if ! cmp -s "$W/installed.before" "$W/installed.after"; then
    say "**FAIL: the installed server changed during this test.**"
    diff "$W/installed.before" "$W/installed.after" | fenced
    echo 'FAIL: the installed server changed during the facts test.'
    exit 1
fi
say "The installed server is as it was before: the same server.conf, the same process, no restart."
echo 'PASS: the OpenVPN facts F1 to F6 are in the summary, and the installed server was not touched.'

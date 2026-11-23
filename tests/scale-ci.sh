#!/usr/bin/env bash
# How long the everyday commands take on a server with many clients, for a disposable Ubuntu 24.04 or 26.04
# machine ONLY, such as a CI runner: it runs the real setup, then fills the real CA with fake clients. Run as root;
# it refuses without --i-know. It measures, and changes nothing in the tool: later changes are judged by its numbers.
#   scale-ci.sh --i-know <valid clients> <part> [folder for the results]
# The CA index then holds 10,000 rows: the server, the valid clients, and revoked clients for the rest, as a
# server that has revoked many clients keeps them in its index for the CRL. The times go to the CI summary, and
# as tab-separated lines to scale.tsv in the results folder. The measurements come in three parts, so CI runs each
# on a runner of its own, every one after the same setup and data:
#   commands  darban list and darban status
#   menu      opening the menu, and creating one client
#   crl       gen-crl and publishing the CRL, the connection events, and the client-connect script
set -Eeuo pipefail
[[ ${1:-} == --i-know && ${2:-} =~ ^[0-9]+$ && -n ${3:-} ]] || { echo 'This reconfigures the machine. Use only on a disposable one: scale-ci.sh --i-know <valid clients> commands|menu|crl [results folder]' >&2; exit 2; }
CLIENTS=$2
PART=$3
[[ $PART == commands || $PART == menu || $PART == crl ]] || { echo "No such part: $PART. The parts are commands, menu and crl." >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 2; }
ROWS=10000
# A server's VPN network is a /24: at most 253 clients are connected at once, so a restart brings back 253.
CONNECTED=253
(( CLIENTS >= CONNECTED && CLIENTS < ROWS )) || { echo "From $CONNECTED to $((ROWS - 2)) valid clients." >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
RESULTS=${4:-$(mktemp -d)}
mkdir -p "$RESULTS"
WORK=$(mktemp -d)
# What OpenVPN's user reads, the list of fake connections, in a folder of its own: it cannot enter $WORK.
SHARED=$(mktemp -d)
chmod 755 "$SHARED"
PKI=/root/pki
EASYRSA=/usr/share/easy-rsa/easyrsa
UNIT=openvpn-server@server.service
EVENT_SCRIPT=/usr/local/libexec/darban-ovpn-event
EVENTS=/run/darban-events
LEDGER=/var/lib/darban/clients
CRL=/etc/openvpn/server/crl.pem
# One command that takes longer than this is stopped, and its time is given as more than this.
LIMIT=1200
TSV=$RESULTS/scale.tsv
. /etc/os-release
printf 'key\twhat\tseconds\truns\n' >"$TSV"
ROWS_MD=''
NOTES=''

summary() {
    # Whatever was measured, also when a later step failed.
    local text
    text=$(printf '### Scale: Ubuntu %s, %s valid clients, %s\n\n%s\n\n| Measured | Seconds | Runs |\n|---|---:|---:|\n%s\n' \
        "$VERSION_ID" "$CLIENTS" "$PART" "${NOTES:-No data was made.}" "${ROWS_MD:-| nothing measured | | |}")
    printf '%s\n' "$text"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '%s\n\n' "$text" >>"$GITHUB_STEP_SUMMARY"; fi
}
dump() {
    journalctl -u "$UNIT" -n 30 --no-pager || true
    journalctl -u 'darban-events*' -n 30 --no-pager || true
    tail -n 40 /var/log/darban-setup.log 2>/dev/null || true
}
trap 'echo "FAILED at line $LINENO"; dump' ERR
trap 'summary; rm -rf -- "$WORK" "$SHARED"' EXIT

now_us() { printf '%s\n' "${EPOCHREALTIME//[!0-9]/}"; }
seconds() { printf '%d.%03d' $(( $1 / 1000000 )) $(( $1 / 1000 % 1000 )); }
median() { printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END {print v[int((NR + 1) / 2)]}'; }
record() {
    # record <key> <what> <microseconds or text> <runs>
    local shown=$3
    if [[ $3 =~ ^[0-9]+$ ]]; then shown=$(seconds "$3"); fi
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$shown" "$4" >>"$TSV"
    ROWS_MD+="| $2 | $shown | $4 |"$'\n'
    echo "TIME: $2: $shown s ($4 runs)"
}
measure() {
    # measure <key> <what> <most runs> <shell command>: the median of up to <most runs> runs. One that takes 20
    # seconds or more is not run again: it already shows what it costs. A command that fails stops the whole test.
    local key=$1 what=$2 most=$3 command=$4 run start took rc
    local -a runs=()
    for (( run = 1; run <= most; run++ )); do
        rc=0
        start=$(now_us)
        timeout "$LIMIT" bash -c "$command" >"$WORK/$key.$run.log" 2>&1 </dev/null || rc=$?
        took=$(( $(now_us) - start ))
        if (( rc == 124 )); then record "$key" "$what" "over $LIMIT" "$run"; return 0; fi
        if (( rc != 0 )); then echo "FAIL: $what exited with status $rc:"; tail -n 40 "$WORK/$key.$run.log"; return 1; fi
        runs+=("$took")
        (( took < 20000000 )) || break
    done
    record "$key" "$what" "$(median "${runs[@]}")" "${#runs[@]}"
}
queue_empty() {
    local entry
    for entry in "$EVENTS"/new/* "$EVENTS"/work/*; do [[ -e $entry ]] && return 1; done
    return 0
}
wait_queue_empty() {
    # wait_queue_empty <seconds>
    local end=$(( SECONDS + $1 ))
    until queue_empty; do
        (( SECONDS < end )) || { echo "FAIL: the event queue was not empty after $1 seconds."; ls -la "$EVENTS/new" "$EVENTS/work"; return 1; }
        sleep 0.05
    done
}
write_events() {
    # write_events <first client number>: one connection of each of $CONNECTED clients, written by the real
    # script as OpenVPN's user, as OpenVPN runs it when each client connects.
    runuser -u nobody -- env -i PATH=/usr/bin:/bin SCRIPT="$EVENT_SCRIPT" LIST="$SHARED/connections" FIRST="$1" COUNT="$CONNECTED" bash -c '
        file=$(mktemp)
        n=0
        while read -r name serial; do
            n=$(( n + 1 ))
            (( n >= FIRST )) || continue
            (( n < FIRST + COUNT )) || break
            script_type=client-connect common_name=$name trusted_ip=198.51.100.$(( n % 250 + 1 )) \
                tls_serial_hex_0=$serial IV_VER=2.6.12 IV_PLAT=linux "$SCRIPT" "$file"
        done <"$LIST"
        rm -f -- "$file"'
}
ledger_after() {
    # ledger_after <microseconds> <first client number>: every client of write_events has a connection recorded
    # at or after that moment.
    local name serial value n=0 missing=0
    while read -r name serial; do
        n=$(( n + 1 ))
        (( n >= $2 )) || continue
        (( n < $2 + CONNECTED )) || break
        value=$(awk -F= '$1=="last_connect" {print $2}' "$LEDGER/$name" 2>/dev/null) || value=''
        if [[ ! $value =~ ^[0-9]{16}$ ]] || (( 10#$value < $1 )); then missing=$(( missing + 1 )); fi
    done <"$SHARED/connections"
    (( missing == 0 )) || { echo "FAIL: $missing of $CONNECTED connections did not reach the client records."; return 1; }
}
menu_open() {
    # The menu in a real terminal: from starting darban until it asks "Choose [0-9]", then 0 to leave.
    local took
    took=$(SCREEN_LOG=$WORK/menu.screen python3 tests/time-to-text.py "$LIMIT" 'Choose [0-9]' '0\r' -- darban) || return 1
    printf '%s\n' "$took" >"$WORK/menu.seconds"
}

# ---------- the real setup ----------
echo "Ubuntu $VERSION_ID, kernel $(uname -r): setup, then the $PART part"
start=$(now_us)
bash setup/server-setup.sh --yes --host 127.0.0.1 --port 1194
bash setup/install.sh
echo "Setup took $(seconds $(( $(now_us) - start ))) s"
darban status >/dev/null
systemctl is-active --quiet darban-events.path
# The update check reaches GitHub at most once an hour, in the background: off, so no number waits on the network.
sed -i '/^UPDATE_CHECK=/d' /etc/darban/config
printf 'UPDATE_CHECK=no\n' >>/etc/darban/config

# ---------- nft_quota, which counting each client's traffic needs ----------
kernel=$(uname -r)
if modprobe nft_quota 2>/dev/null && grep -q '^nft_quota ' /proc/modules; then
    quota_form='a module, loaded'
elif grep -q '/nft_quota\.ko' "/lib/modules/$kernel/modules.builtin" 2>/dev/null; then
    quota_form='built into the kernel'
else
    echo "FAIL: kernel $kernel has no nft_quota."
    exit 1
fi
# The kernel takes a quota only with the module: a named one, one in a rule, and a rule that names one.
nft -f - <<'EOF'
table inet darban_scale_probe {
    quota probe { over 1 mbytes }
    chain probe {
        ip daddr 192.0.2.1 quota over 1 mbytes counter
        ip daddr 192.0.2.2 quota name "probe"
    }
}
EOF
nft list quota inet darban_scale_probe probe | grep 'over 1 mbytes' >/dev/null
nft delete table inet darban_scale_probe
# Each other kernel installed, such as the one the setup adds for the next boot, has it too.
others=''
for dir in /lib/modules/*/; do
    dir=${dir%/}
    other=${dir##*/}
    [[ $other != "$kernel" ]] || continue
    if ! modinfo -k "$other" nft_quota >/dev/null 2>&1 && ! grep -q '/nft_quota\.ko' "$dir/modules.builtin" 2>/dev/null; then
        echo "FAIL: the installed kernel $other has no nft_quota."
        exit 1
    fi
    others+=" $other"
done
quota_note="nft_quota works on kernel $kernel ($quota_form)"
if [[ -n $others ]]; then quota_note+=", and is in the installed kernel$others"; fi
echo "PASS: $quota_note."

# ---------- the fake clients ----------
# Real certificates and keys from the server's own CA, made with openssl directly: Easy-RSA would take many
# minutes for a thousand. Each is what Easy-RSA's build-client-full makes, in the same places, with its row in
# index.txt.
start=$(now_us)
cat >"$WORK/client.ext" <<'EOF'
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
extendedKeyUsage = clientAuth
keyUsage = digitalSignature
EOF
: >"$SHARED/connections"
for (( n = 1; n <= CLIENTS; n++ )); do
    printf -v name 'scale-%04d' "$n"
    printf -v serial 'C0%030X' "$n"
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$PKI/private/$name.key" -subj "/CN=$name" 2>/dev/null |
        openssl x509 -req -CA "$PKI/ca.crt" -CAkey "$PKI/private/ca.key" -set_serial "0x$serial" -days 825 -sha256 \
            -extfile "$WORK/client.ext" -out "$PKI/issued/$name.crt" 2>/dev/null
    chmod 600 "$PKI/private/$name.key"
    end=$(openssl x509 -in "$PKI/issued/$name.crt" -noout -enddate)
    printf 'V\t%s\t\t%s\tunknown\t/CN=%s\n' "$(date -u -d "${end#notAfter=}" +%y%m%d%H%M%SZ)" "$serial" "$name" >>"$PKI/index.txt"
    # OpenVPN gives the serial in lower case, a colon between each two digits.
    colons=$(sed 's/../&:/g; s/:$//' <<<"${serial,,}")
    printf '%s %s\n' "$name" "$colons" >>"$SHARED/connections"
done
chmod 644 "$SHARED/connections"
# Revoked clients fill the index to its 10,000 rows. Their certificates have not expired, so the CRL lists each.
revoked=$(( ROWS - $(wc -l <"$PKI/index.txt") ))
awk -v count="$revoked" -v expires="$(date -u -d '+700 days' +%y%m%d%H%M%SZ)" -v revoked_at="$(date -u -d '-30 days' +%y%m%d%H%M%SZ)" \
    'BEGIN {for (n = 1; n <= count; n++) printf "R\t%s\t%s\tDE%030X\tunknown\t/CN=gone-%05d\n", expires, revoked_at, n, n}' >>"$PKI/index.txt"
[[ $(wc -l <"$PKI/index.txt") == "$ROWS" ]]
echo "Made $CLIENTS valid and $revoked revoked clients in $(seconds $(( $(now_us) - start ))) s."
NOTES="Part: $PART. index.txt: $ROWS rows: $CLIENTS valid clients, $revoked revoked, and the server. Kernel $kernel. $quota_note. The update check is off, so no time waits on the network. A time is the median of up to 3 runs; a command that took 20 s or more ran once."

# ---------- the CRL ----------
# The revoked clients are blocked, as on a real server: a CRL that lists them all. The crl part publishes it the
# tool's own way, and times that. The other parts install the same file where the tool publishes it, with the same
# owner and mode, without the minutes its checks take: the diagnostics and the menu then find a CRL that agrees
# with the index.
GEN_CRL="env EASYRSA_PKI=$PKI EASYRSA_BATCH=1 $EASYRSA gen-crl"
PUBLISH_CRL="source /usr/local/lib/darban/common.sh && darban_publish_crl $PKI/crl.pem"
if [[ $PART == crl ]]; then
    measure gen-crl "gen-crl (Easy-RSA, $revoked revoked)" 3 "$GEN_CRL"
    measure publish-crl 'publish the new CRL (verify and install it)' 3 "$PUBLISH_CRL"
else
    bash -c "$GEN_CRL" >/dev/null 2>&1
    temp=$(mktemp "${CRL%/*}/.darban-crl.XXXXXXXX")
    install -o root -g root -m 644 "$PKI/crl.pem" "$temp"
    mv -f -- "$temp" "$CRL"
fi

# ---------- connection events after a restart ----------
# OpenVPN restarts, and its 253 clients connect again: each connection leaves an event, and the path unit starts
# the worker that applies them. Measured from the first event written until the queue is empty and every client
# record has its connection. Every part does this, so the client records hold real connections; only the crl part
# records its times. The five-minute check also applies the queue, and when it runs beside the path unit's worker,
# one of them can find an event the other just applied and deleted, and set it aside as unreadable: it stays off
# meanwhile, so the numbers are those of the worker alone and bad/ stays empty.
systemctl stop darban-sweep.timer
for attempt in $(seq 1 60); do
    if ! systemctl is-active --quiet darban-sweep.service; then break; fi
    sleep 1
done
systemctl restart "$UNIT"
for attempt in $(seq 1 30); do
    if darban connected >/dev/null 2>&1; then break; fi
    sleep 1
done
darban connected >/dev/null
rm -f -- "$EVENTS"/bad/*
start=$(now_us)
write_events 1
written=$(( $(now_us) - start ))
wait_queue_empty 600
took=$(( $(now_us) - start ))
ledger_after "$start" 1
[[ -z $(ls -A "$EVENTS/bad") ]] || { cat "$EVENTS"/bad/*.why | sort | uniq -c; echo 'FAIL: connection events were set aside as malformed.'; exit 1; }

if [[ $PART == crl ]]; then
    record events-written "$CONNECTED connection events written by the client-connect script" "$written" 1
    record events-applied "$CONNECTED connection events after a restart, from the first written to all applied" "$took" 1
    # The worker alone, on 253 events already waiting in the queue: the path unit stays off meanwhile, as the
    # five-minute check still does.
    systemctl stop darban-events.path
    start=$(now_us)
    write_events 1
    measure events-worker "darban events applying $CONNECTED waiting events" 1 'darban events'
    queue_empty || { echo 'FAIL: darban events left events in the queue.'; exit 1; }
    ledger_after "$start" 1
    systemctl start darban-events.path

    # One run of the client-connect script, as OpenVPN runs it, as its own user, timed inside that user's shell
    # so starting runuser does not count: the first run, and the average of 100 more.
    runuser -u nobody -- env -i PATH=/usr/bin:/bin SCRIPT="$EVENT_SCRIPT" LIST="$SHARED/connections" bash -c '
        read -r name serial <"$LIST"
        file=$(mktemp)
        run() { script_type=client-connect common_name=$name trusted_ip=198.51.100.7 tls_serial_hex_0=$serial IV_VER=2.6.12 IV_PLAT=linux "$SCRIPT" "$file"; }
        start=${EPOCHREALTIME/./}; run; first=$(( ${EPOCHREALTIME/./} - start ))
        start=${EPOCHREALTIME/./}; for (( n = 0; n < 100; n++ )); do run; done; rest=$(( (${EPOCHREALTIME/./} - start) / 100 ))
        rm -f -- "$file"
        printf "%s %s\n" "$first" "$rest"' >"$WORK/connect-script.txt"
    read -r first rest <"$WORK/connect-script.txt"
    record connect-script "one run of the client-connect script" "$first" 1
    record connect-script-mean "one run of the client-connect script, the average of 100" "$rest" 100
    wait_queue_empty 120
fi
systemctl start darban-sweep.timer

# ---------- the menu, and one more client ----------
if [[ $PART == menu ]]; then
    runs=()
    for run in 1 2 3; do
        menu_open || { echo 'FAIL: the menu did not open.'; tail -n 30 "$WORK/menu.screen"; exit 1; }
        us=$(awk '{printf "%d", $1 * 1000000}' "$WORK/menu.seconds")
        runs+=("$us")
        (( us < 20000000 )) || break
    done
    record menu "open the menu, until it asks \"Choose [0-9]\"" "$(median "${runs[@]}")" "${#runs[@]}"
    # From a script, as tests/vm-reboot.sh creates one: the menu opens, takes the name, and closes.
    measure create 'create one client, from opening the menu to leaving it' 1 "printf '1\\nscale-new\\n0\\n' | darban"
    [[ -s /root/openvpn-clients/scale-new.ovpn ]] || { echo 'FAIL: the new client has no profile.'; exit 1; }
    # Read from the index itself: a darban list would take minutes and measure nothing.
    valid=$(awk -F '\t' '$1 == "V" && $6 ~ /\/CN=scale-/ {n++} $1 == "V" && $6 ~ /\/CN=scale-new$/ {new++} END {printf "%d %d\n", n, new}' "$PKI/index.txt")
    [[ $valid == "$(( CLIENTS + 1 )) 1" ]] || { echo "FAIL: index.txt has valid clients and rows of scale-new: $valid, not $(( CLIENTS + 1 )) 1."; exit 1; }
fi

# ---------- the list and the diagnostics ----------
if [[ $PART == commands ]]; then
    measure list 'darban list' 3 'darban list'
    # The fake clients are what the tool sees: the list counts them, and the diagnostics, which fail on any problem, pass.
    grep "$CLIENTS valid" "$WORK/list.1.log" >/dev/null || { tail -n 5 "$WORK/list.1.log"; echo "FAIL: the list does not show $CLIENTS valid clients."; exit 1; }
    grep "$revoked revoked" "$WORK/list.1.log" >/dev/null || { tail -n 5 "$WORK/list.1.log"; echo "FAIL: the list does not show $revoked revoked clients."; exit 1; }
    measure status 'darban status' 3 'darban status'
    echo "PASS: the list shows $CLIENTS valid and $revoked revoked clients, and the diagnostics pass."
fi
echo "PASS: every measurement of the $PART part ran."

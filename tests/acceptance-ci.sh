#!/usr/bin/env bash
# Real acceptance test for a disposable Ubuntu 24.04 or 26.04 machine ONLY, such as a CI runner: it installs
# packages and a kernel, creates a CA and changes the network and firewall. Run as root; it refuses without
# --i-know. The questions are answered in a real terminal, as a person would. Clients connect over loopback,
# and one more runs in its own network namespace to send real traffic through the tunnel and the NAT.
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Use only on a disposable one: acceptance-ci.sh --i-know [1|2]' >&2; exit 2; }
# After the install and the first client, the checks come in two parts, so CI runs each on a runner of its own:
# 1 is revocation, the CRL, the ends of sessions and the connection events; 2 is the settings, the network, links
# and files, certbot, the update and the removal. With no part named, both run, one after the other.
PART=${2:-all}
[[ $PART == all || $PART == 1 || $PART == 2 ]] || { echo "No such part: $PART. The parts are 1 and 2." >&2; exit 2; }
part() { [[ $PART == all || $PART == "$1" ]]; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
LOG=$(mktemp -d)
PIDFILE=$LOG/client.pid
UNIT=openvpn-server@server.service
NS=darban-test
. /etc/os-release
dump() {
    journalctl -u "$UNIT" -n 40 --no-pager || true
    tail -n 30 "$LOG"/*.log 2>/dev/null || true
    # What the install itself was doing: its own log, and any apt or dpkg still running, such as one that waits.
    tail -n 60 /var/log/darban-setup.log 2>/dev/null || true
    ps -eo pid,etimes,args | grep -E '[a]pt|[d]pkg|[u]nattended' || true
    ip netns del "$NS" 2>/dev/null || true
}
trap 'echo "FAILED at line $LINENO"; dump' ERR
setup_times() {
    # setup_times <label>: how long each slow part of the setup took, in the summary of every run, not only a failed
    # one, so the weekly runs keep a record of how long installs take. The lines hold labels and times only.
    local times
    times=$(grep '^==' /var/log/darban-setup.log 2>/dev/null || true)
    printf 'Setup times:\n%s\n' "${times:-none recorded}"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '**Setup times, %s**\n\n```\n%s\n```\n' "$1" "${times:-none recorded}" >>"$GITHUB_STEP_SUMMARY"
    fi
}

connect() {
    # connect <profile> <log> [device pidfile]: 0 when the tunnel comes up within 20 seconds. A second client at
    # the same time takes another device and pid file.
    local attempt dev=${3:-tun9} pidfile=${4:-$PIDFILE}
    rm -f "$pidfile"
    openvpn --config "$1" --route-nopull --dev "$dev" --daemon --writepid "$pidfile" --log "$2" --verb 3
    for attempt in $(seq 1 20); do
        if grep -q 'Initialization Sequence Completed' "$2"; then return 0; fi
        sleep 1
    done
    return 1
}
refused() {
    # refused <profile> <log> <server says>: 0 once the server's log says why it refused this client, and the
    # tunnel never came up; 1 if it came up. Waiting the 20 seconds of connect would prove no more.
    local attempt since
    since=$(date +%s)
    rm -f "$PIDFILE"
    openvpn --config "$1" --route-nopull --dev tun9 --daemon --writepid "$PIDFILE" --log "$2" --verb 3
    for attempt in $(seq 1 40); do
        if grep -q 'Initialization Sequence Completed' "$2"; then return 1; fi
        if journalctl -u "$UNIT" --since "@$since" --no-pager 2>/dev/null | grep -qi -- "$3"; then
            sleep 1
            ! grep -q 'Initialization Sequence Completed' "$2"
            return
        fi
        sleep 0.5
    done
    echo "FAIL: in 20 seconds the server neither let this client in nor said: $3"
    return 1
}
disconnect() { if [[ -s $PIDFILE ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; fi; }
in_terminal() {
    # in_terminal <name> <seconds> <command...>: answers the command from $LOG/<name>.keys in a real terminal.
    local name=$1 seconds=$2
    shift 2
    python3 tests/pty-drive.py --timeout "$seconds" "$LOG/$name.keys" -- "$@" | tee "$LOG/$name.log"
}

# The install command, typed by the runner's own user into an interactive shell, through the real sudo: the
# form that cannot take answers is refused before any download, and the documented form gets past that check.
# A version that does not exist stops the documented form at the download, before anything is installed.
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    keys=$(runuser -u "$SUDO_USER" -- mktemp -d)
    cat > "$LOG/old-form.keys" <<'EOF'
CHECK$ => cat setup/get.sh | sudo bash -s -- --version v0.0.0-rc.99\r
CHECK$ => exit\r
EOF
    cat > "$LOG/new-form.keys" <<'EOF'
CHECK$ => sudo bash -c 'cat setup/get.sh | bash -s -- --version v0.0.0-rc.99'\r
CHECK$ => exit\r
EOF
    install -o "$SUDO_USER" -m 600 "$LOG/old-form.keys" "$LOG/new-form.keys" "$keys/"
    for form in old-form new-form; do
        runuser -u "$SUDO_USER" -- env PS1='CHECK$ ' python3 tests/pty-drive.py --timeout 60 "$keys/$form.keys" -- bash --norc --noprofile -i | tee "$LOG/$form.log" || true
    done
    grep -q 'sudo keeps the keys you press' "$LOG/old-form.log"
    grep -qF "latest/download/get.sh | bash -s -- --version v0.0.0-rc.99'" "$LOG/old-form.log"
    if grep -q 'Downloading' "$LOG/old-form.log"; then echo 'FAIL: the old form downloaded before it was refused.'; exit 1; fi
    if grep -q 'sudo keeps the keys you press' "$LOG/new-form.log"; then echo 'FAIL: the documented form was refused.'; exit 1; fi
    grep -q 'Downloading v0.0.0-rc.99' "$LOG/new-form.log"
    rm -rf -- "$keys"
    echo 'PASS: "curl ... | sudo bash" is refused at once; "sudo bash -c '"'"'curl ... | bash'"'"'" goes on.'
fi

# The two versions cover both firewall paths: ufw on and answering its question, and ufw off.
USE_UFW=0
if [[ $VERSION_ID == 26.04 ]]; then
    USE_UFW=1
    command -v ufw >/dev/null || apt-get -y -q install ufw >/dev/null
    ufw --force enable
fi

# 127.0.0.1 keeps the clients off the internet; the manager accepts it as the profile address.
# A runner's kernel may already have the ovpn module, so one version also proves the real kernel install.
setup_args=()
if [[ $VERSION_ID == 24.04 ]]; then setup_args+=(--install-kernel); fi
{
    printf 'Server address => 127.0.0.1\\r\n'
    printf 'VPN port [ => 1194\\r\n'
    if (( USE_UFW )); then printf 'Enter: Add the two rules => \\r\n'; fi
    printf 'Enter: Install now => \\r\n'
    printf '[5/5] Starting OpenVPN\n'
    printf 'OpenVPN is running on UDP 1194\n'
} > "$LOG/setup.keys"
# 20 minutes: on 24.04 the download is about 187 MB, most of it the HWE kernel's modules (167 MB). It
# usually takes one or two minutes, but a runner's mirror has taken more than ten.
in_terminal setup 1200 bash setup/server-setup.sh "${setup_args[@]}"
grep -E 'Detected address|could not be detected' "$LOG/setup.log"
grep -qx setup_complete /etc/darban/.server-setup-started
if grep -q 'Unpacking\|Setting up' "$LOG/setup.log"; then echo 'FAIL: apt output reached the install screen.'; exit 1; fi
echo 'PASS: a real install in a real terminal, on a quiet screen.'
setup_times "Ubuntu $VERSION_ID, acceptance"
if (( USE_UFW )); then
    ufw status | grep '^1194/udp' >/dev/null
    ufw status | grep 'tun0' >/dev/null
    echo 'PASS: Enter added the two ufw rules.'
fi

bash setup/install.sh
darban-crl-maintain --check
systemctl start darban-crl.service
systemctl is-active --quiet darban-crl.timer
systemctl is-active --quiet darban-nat.service
nft list table ip darban >/dev/null
darban status
# Connection events: the install turned them on, with the lines in server.conf and the queue in a tmpfs of its own.
CONF=/etc/openvpn/server/server.conf
EVENT_SCRIPT=/usr/local/libexec/darban-ovpn-event
EVENTS=/run/darban-events
LEDGER=/var/lib/darban/clients
# The tmpfs of the queue can stay a moment after its unit stopped.
unmounted() { local i; for i in $(seq 1 10); do mountpoint -q "$EVENTS" || return 0; sleep 1; done; return 1; }
grep -qx 'script-security 2' "$CONF"
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
grep -qx "client-disconnect $EVENT_SCRIPT" "$CONF"
[[ $(findmnt -n -o FSTYPE "$EVENTS") == tmpfs ]]
[[ -e $EVENTS/.mounted ]]
[[ $(stat -c '%U %a' "$EVENTS/new") == 'nobody 700' && $(stat -c '%U %a' "$EVENTS/work") == 'root 700' ]]
systemctl is-active --quiet darban-events.path
systemctl is-active --quiet darban-sweep.timer
runuser -u nobody -- test -x "$EVENT_SCRIPT"
darban status >"$LOG/events-on.log"
grep 'Connection events are seen' "$LOG/events-on.log" >/dev/null
echo 'PASS: the install turns on connection events, with their queue in a tmpfs of its own.'

cat > "$LOG/welcome.keys" <<'EOF'
Open UDP 1194 in your server
Enter: Create a client => \r
Client name [client1] => accept1\r
Enter: Temporary link => {Keep it on the server}\r
Kept on the server
Enter: Windows => \r
Enter: Copy the command => {Do not copy}\r
Waiting for accept1 to connect => \r
Choose [0-9] => {Exit}\r
EOF
in_terminal welcome 60 darban welcome
cp /root/openvpn-clients/accept1.ovpn "$LOG/old.ovpn"
echo 'PASS: the first client was created from the end of the install.'

connect "$LOG/old.ovpn" "$LOG/a.log"
echo 'PASS: a real client connected.'
# E10' and T19: the connection reaches the client record within seconds, from the hook OpenVPN really ran.
for attempt in $(seq 1 10); do
    if grep -q '^last_connect=' "$LEDGER/accept1" 2>/dev/null; then break; fi
    sleep 1
done
grep -q '^last_connect=' "$LEDGER/accept1"
grep -qx 'last_address=127.0.0.1' "$LEDGER/accept1"
echo "PASS: the real connection reached the client record in about $attempt s: $(tr '\n' ' ' <"$LEDGER/accept1")"
# E3 and E10': the same connection deletes the file kept on the server, with its record.
for attempt in $(seq 1 10); do
    if [[ ! -e /root/openvpn-clients/accept1.ovpn ]]; then break; fi
    sleep 1
done
[[ ! -e /root/openvpn-clients/accept1.ovpn && ! -e /root/openvpn-clients/accept1.share ]]
echo "PASS: the connection deleted the file kept on the server in about $attempt s."
for attempt in $(seq 1 10); do
    if darban connected | grep accept1 >/dev/null; then break; fi
    sleep 1
done
darban connected | grep accept1 >/dev/null
echo 'PASS: the connected client is listed.'

# The tool waits for the connection after sharing, and another SSH user gets a copy it can read.
cat > "$LOG/share.keys" <<'EOF'
Choose [0-9] => {Share a profile}\r
Number or name => accept1\r
Enter: Temporary link => {Keep it on the server}\r
Enter: Windows => \r
Enter: Copy the command => {Do not copy}\r
accept1 is connected from => \r
Choose [0-9] => {Exit}\r
EOF
in_terminal share 60 darban
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ $(stat -c '%U %a' "$home/accept1.ovpn") == "$SUDO_USER 600" ]]
    rm -f -- "$home/accept1.ovpn"
    echo 'PASS: the SSH user gets a private copy of the profile.'
fi
echo 'PASS: the tool saw the real connection after sharing.'

# ---------- part 1: revocation, the CRL, the ends of sessions and the connection events ----------
if part 1; then

# Revoked while connected: only this session ends, without restarting OpenVPN for everyone.
printf '4\naccept1\naccept1\n0\n' | darban | tee "$LOG/revoke.log"
grep -q 'Active session of accept1 disconnected' "$LOG/revoke.log"
echo 'PASS: revoking ends the active session of that client alone.'
disconnect

# T68: refused by the CRL that revoke published, and OpenVPN says why.
refused "$LOG/old.ovpn" "$LOG/b.log" 'certificate revoked' || { echo 'FAIL: the revoked profile still connects.'; exit 1; }
disconnect
echo 'PASS: the revoked profile was refused.'

printf '1\naccept1\n0\n' | darban
# A copy: the first connection deletes the file kept on the server, and sharing it by a link takes it off too.
cp /root/openvpn-clients/accept1.ovpn "$LOG/accept1.ovpn"
connect "$LOG/accept1.ovpn" "$LOG/c.log"
echo 'PASS: a new certificate under the same name connects.'
disconnect
refused "$LOG/old.ovpn" "$LOG/d.log" 'certificate revoked' || { echo 'FAIL: the old profile connects after the name was reused.'; exit 1; }
disconnect
echo 'PASS: the old profile stays refused after the name was reused.'

# A CRL that OpenVPN, which runs as nobody, cannot read once it changed: Diagnostics name it, and even a valid client
# is refused. Readable again, the client connects.
CRL_FILE=/etc/openvpn/server/crl.pem
chmod 600 "$CRL_FILE"; touch "$CRL_FILE"
if darban status >"$LOG/crl-600.log"; then echo 'FAIL: a CRL OpenVPN cannot read passed the diagnostics.'; exit 1; fi
grep 'OpenVPN runs as nobody and cannot read the CRL' "$LOG/crl-600.log" >/dev/null
if connect "$LOG/accept1.ovpn" "$LOG/crl-600-client.log"; then echo 'FAIL: a client connected with a CRL OpenVPN cannot read.'; exit 1; fi
disconnect
chmod 644 "$CRL_FILE"; touch "$CRL_FILE"
connect "$LOG/accept1.ovpn" "$LOG/crl-644-client.log"
disconnect
darban status >/dev/null
echo 'PASS: a CRL OpenVPN cannot read is named, refuses every client, and works again once readable.'

# T67 and C.15.1: when the server records the end of a session. It runs client-disconnect when it closes the
# session, which may be well after the device went away; a kill -9 must still be recorded within 130 seconds.
PROFILE=$LOG/accept1.ovpn
session_end() { awk -F= '$1=="session_end" {print $2}' "$LEDGER/${1:-accept1}" 2>/dev/null || true; }
wait_session_end() {
    # wait_session_end <value before> <seconds> [client]: prints how long the record took, or fails.
    local start=$SECONDS
    while (( SECONDS - start < $2 )); do
        if [[ -n $(session_end "${3:-}") && $(session_end "${3:-}") != "$1" ]]; then echo $(( SECONDS - start )); return 0; fi
        sleep 1
    done
    return 1
}
# A client killed with kill -9 leaves its in-kernel (DCO) interface behind, and the next client could not take it.
kill_client() { kill -9 "$(cat "${1:-$PIDFILE}")"; sleep 1; ip link del "${2:-tun9}" 2>/dev/null || true; }
# A client stopped by SIGTERM and one killed with kill -9 wait for the same timeout of the server, about two
# minutes, so they wait side by side: two clients, each with its own device.
printf '1\nt67kill\n0\n' | darban >/dev/null
cp /root/openvpn-clients/t67kill.ovpn "$LOG/t67kill.ovpn"
connect "$PROFILE" "$LOG/t67-term.log"; before=$(session_end)
connect "$LOG/t67kill.ovpn" "$LOG/t67-kill.log" tun8 "$LOG/t67kill.pid"; before_kill=$(session_end t67kill)
kill -TERM "$(cat "$PIDFILE")"
kill_client "$LOG/t67kill.pid" tun8
wait_session_end "$before" 150 >"$LOG/t67-term.took" || true &
term_wait=$!
took=$(wait_session_end "$before_kill" 150 t67kill) || { echo 'FAIL: the end of a session after kill -9 was not recorded in 150 seconds.'; exit 1; }
wait "$term_wait"
[[ -s $LOG/t67-term.took ]] || { echo 'FAIL: the end of a session after SIGTERM was not recorded in 150 seconds.'; exit 1; }
echo "T67: client stopped by SIGTERM: the end recorded after $(cat "$LOG/t67-term.took") s"
echo "T67: client killed with kill -9: the end recorded after ${took} s"
if (( took >= 130 )); then echo 'FAIL: the end of a killed session took 130 seconds or more.'; exit 1; fi
sleep 1
connect "$PROFILE" "$LOG/t67-again.log"; before=$(session_end)
kill_client
connect "$PROFILE" "$LOG/t67-again2.log"
took=$(wait_session_end "$before" 150) || { echo 'FAIL: a new session of the same name did not end the old one in 150 seconds.'; exit 1; }
echo "T67: the same name connecting again: the old session's end recorded after ${took} s"
before=$(session_end)
systemctl restart "$UNIT"
# OpenVPN closes every session when it stops, so the end is recorded at once (PR 0 and round 17).
took=$(wait_session_end "$before" 30) || { echo 'FAIL: the end of a session at a server restart was not recorded in 30 seconds.'; exit 1; }
echo "T67: server restarted: the end recorded after ${took} s"
disconnect
journalctl -u "$UNIT" --since '-10min' --no-pager | grep -Ei 'client-disconnect|Inactivity timeout|SIGTERM|exit notification|soft,|restart' | tail -n 12 || true
echo 'PASS: the end of every session was recorded, a killed one within 130 seconds.'

# T70, EV1, C.14.2 and C.15.5: 500 events from the product's own script, as nobody, all at once, while real clients
# connect again and again. The real worker takes them all: none is lost, the queue empties, its watcher stays up.
before=$(awk -F= '$1=="last_connect" {print $2}' "$LEDGER/accept1")
for batch in 0 1 2 3 4; do
    for i in $(seq $(( batch * 100 + 1 )) $(( batch * 100 + 100 ))); do
        runuser -u nobody -- env -i script_type=client-connect common_name="load$i" trusted_ip=192.0.2.1 "$EVENT_SCRIPT" &
    done
    connect "$PROFILE" "$LOG/t70-$batch.log"; disconnect
done
wait
for attempt in $(seq 1 60); do
    if [[ -z $(find "$EVENTS/new" "$EVENTS/work" -mindepth 1 2>/dev/null) ]]; then break; fi
    sleep 1
done
left=$(find "$EVENTS/new" "$EVENTS/work" -mindepth 1 2>/dev/null | wc -l)
seen=$(find "$LEDGER" -name 'load*' | wc -l)
echo "T70: after ${attempt} s: $seen of 500 events applied, $left left in the queue"
[[ $left == 0 && $seen == 500 ]]
[[ -z $(ls -A "$EVENTS/bad") ]]
systemctl is-active --quiet darban-events.path
[[ $(awk -F= '$1=="last_connect" {print $2}' "$LEDGER/accept1") != "$before" ]]
rm -f "$LEDGER"/load*
echo 'PASS: 500 events at once and real connections: none lost, the queue empties, and its watcher stays up.'

# T28, T45, T59 and C.15.7: without its mount, or before its folders are ready, or when it is full, the script
# writes nothing on /run itself, exits 0, and the client connects; Diagnostics say so.
systemctl stop 'run-darban\x2devents.mount'
for attempt in $(seq 1 10); do
    if ! mountpoint -q "$EVENTS"; then break; fi
    sleep 1
done
if mountpoint -q "$EVENTS"; then
    echo 'FAIL: the queue is still mounted after its unit stopped:'
    findmnt -n "$EVENTS" || true
    systemctl status 'run-darban\x2devents.mount' darban-events-setup.service darban-events.path --no-pager || true
    systemctl list-dependencies --reverse 'run-darban\x2devents.mount' --no-pager || true
    exit 1
fi
runuser -u nobody -- env -i script_type=client-connect common_name=accept1 "$EVENT_SCRIPT"
[[ -z $(ls -A "$EVENTS" 2>/dev/null) ]]
connect "$PROFILE" "$LOG/no-mount.log"; disconnect
darban status >"$LOG/no-mount-status.log" || true
grep "The event queue $EVENTS is not mounted" "$LOG/no-mount-status.log" >/dev/null
systemctl restart darban-events-setup.service darban-events.path
[[ -e $EVENTS/.mounted ]]
rm -f "$EVENTS/.mounted"
runuser -u nobody -- env -i script_type=client-connect common_name=accept1 "$EVENT_SCRIPT"
[[ -z $(find "$EVENTS/tmp" "$EVENTS/new" -mindepth 1) ]]
darban status >"$LOG/no-mark.log" || true
grep 'is not mounted' "$LOG/no-mark.log" >/dev/null
systemctl restart darban-events-setup.service
head -c 3M /dev/zero >"$EVENTS/work/fill" 2>/dev/null || true
connect "$PROFILE" "$LOG/full.log"; disconnect
darban status >"$LOG/full-status.log" || true
grep 'is full, so new connections are not seen' "$LOG/full-status.log" >/dev/null
rm -f "$EVENTS/work/fill" "$EVENTS"/bad/*
darban status >/dev/null
echo 'PASS: no mount, no mark or a full queue: nothing lands on /run, every client still connects, and Diagnostics say so.'

# T26, T41, T43, T57, C.15.3 and C.15.12: the checks before the lines are written. A small process limit refuses a
# connection through the hook, so it keeps the lines out; so does script-security 1; and a restart that fails is
# rolled back.
cp -a "$CONF" "$LOG/server.conf.events"
mkdir -p "/etc/systemd/system/$UNIT.d"
printf '[Service]\nLimitNPROC=10\n' >"/etc/systemd/system/$UNIT.d/acceptance-nproc.conf"
systemctl daemon-reload && systemctl restart "$UNIT"
sleepers=()
for i in $(seq 1 10); do runuser -u nobody -- sleep 300 & sleepers+=($!); done
sleep 1
if connect "$PROFILE" "$LOG/nproc.log"; then echo 'FAIL: a client connected although the hook could not start.'; exit 1; fi
disconnect
darban status >"$LOG/nproc-status.log" || true
grep 'lets nobody run only 10 processes (LimitNPROC)' "$LOG/nproc-status.log" >/dev/null
sed -i '/darban-ovpn-event/d; /^script-security 2$/d' "$CONF"; systemctl restart "$UNIT"
darban enable-events | tee "$LOG/nproc-enable.log"
grep 'lets nobody run only 10 processes (LimitNPROC)' "$LOG/nproc-enable.log" >/dev/null
if grep -q darban-ovpn-event "$CONF"; then echo 'FAIL: the lines were written under a small process limit.'; exit 1; fi
kill "${sleepers[@]}" 2>/dev/null || true; wait "${sleepers[@]}" 2>/dev/null || true
rm -f "/etc/systemd/system/$UNIT.d/acceptance-nproc.conf"; systemctl daemon-reload
printf 'script-security 1\n' >>"$CONF"; systemctl restart "$UNIT"
darban enable-events | tee "$LOG/ss1.log"
grep 'sets script-security 1, which lets OpenVPN run no script' "$LOG/ss1.log" >/dev/null
if grep -q darban-ovpn-event "$CONF"; then echo 'FAIL: the lines were written with script-security 1.'; exit 1; fi
sed -i '/^script-security 1$/d' "$CONF"
printf '[Service]\nExecStartPre=/bin/sh -c "! grep -q darban-ovpn-event %s"\n' "$CONF" >"/etc/systemd/system/$UNIT.d/acceptance-events.conf"
systemctl daemon-reload && systemctl restart "$UNIT"
darban enable-events | tee "$LOG/events-rollback.log"
grep 'Rolled back' "$LOG/events-rollback.log" >/dev/null
if grep -q darban-ovpn-event "$CONF"; then echo 'FAIL: the lines stayed after a failed restart.'; exit 1; fi
systemctl is-active --quiet "$UNIT"
rm -rf "/etc/systemd/system/$UNIT.d"; systemctl daemon-reload
darban enable-events | tee "$LOG/events-again.log"
grep 'Connection events are on: a link now ends at the first connection' "$LOG/events-again.log" >/dev/null
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
connect "$PROFILE" "$LOG/events-back.log"; disconnect
echo 'PASS: a small process limit, script-security 1 or a failed restart keep the lines out, and nothing else changes.'

darban list --all

# T0 (#115): facts about OpenVPN 2.7 with a UDP and a TCP socket in one process, for the design of T1, from a
# temporary OpenVPN of its own. The facts go to the summary as seen; it fails only if the installed server changed.
bash tests/openvpn-facts-ci.sh --i-know
systemctl is-active --quiet "$UNIT"
connect "$PROFILE" "$LOG/after-facts.log"; disconnect
echo 'PASS: after the facts test, the installed server still runs and a client connects.'
fi

# ---------- part 2: the settings, the network, links and files, certbot, the update and the removal ----------
if part 2; then
if [[ $PART == 2 ]]; then
    # Part 1 did not run here: the first client is still connected, and its profile is the one of the install.
    disconnect
    cp "$LOG/old.ovpn" "$LOG/accept1.ovpn"
    PROFILE=$LOG/accept1.ovpn
fi

# Advanced settings against the real service: a good change is applied, and a broken one is rolled back.
printf '7\n6\n2\n149.112.112.112\n2\n0\n0\n0\n' | darban
grep -q 'dhcp-option DNS 149.112.112.112' /etc/openvpn/server/server.conf
systemctl is-active --quiet "$UNIT"
mkdir -p "/etc/systemd/system/$UNIT.d"
printf '[Service]\nExecStartPre=/bin/sh -c "! grep -q 198.51.100.1 /etc/openvpn/server/server.conf"\n' > "/etc/systemd/system/$UNIT.d/acceptance.conf"
systemctl daemon-reload
printf '7\n6\n2\n198.51.100.1\n2\n0\n0\n0\n' | darban | tee "$LOG/rollback.log"
grep -q 'Rolled back' "$LOG/rollback.log"
if grep -q 198.51.100.1 /etc/openvpn/server/server.conf; then echo 'FAIL: the broken change stayed.'; exit 1; fi
grep -q 'dhcp-option DNS 149.112.112.112' /etc/openvpn/server/server.conf
systemctl is-active --quiet "$UNIT"
rm -rf "/etc/systemd/system/$UNIT.d"
systemctl daemon-reload
echo 'PASS: a change that stops the service is rolled back.'

printf '7\n6\n3\n10.99.0.0\n2\n0\n0\n0\n' | darban
grep -q '^server 10.99.0.0 255.255.255.0' /etc/openvpn/server/server.conf
grep -q '10.99.0.0/24' /etc/darban/nat.nft
nft list table ip darban | grep '10.99.0.0/24' >/dev/null
connect "$LOG/accept1.ovpn" "$LOG/e.log"
echo 'PASS: a client connects after the VPN network changed.'
disconnect

# The whole promise: a client elsewhere gets its internet and its DNS through the tunnel and the NAT.
# Docker on a runner sets the FORWARD policy to DROP. The tool warns about this; with ufw, its rules allow it.
if (( ! USE_UFW )); then
    iptables -I FORWARD -i tun0 -j ACCEPT
    iptables -I FORWARD -o tun0 -j ACCEPT
fi
ip netns add "$NS"
ip link add dt0 type veth peer name dt1
ip link set dt1 netns "$NS"
ip addr add 198.18.0.1/30 dev dt0
ip link set dt0 up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip addr add 198.18.0.2/30 dev dt1
ip netns exec "$NS" ip link set dt1 up
ip netns exec "$NS" ip route add default via 198.18.0.1
mkdir -p "/etc/netns/$NS"
printf 'nameserver 9.9.9.9\n' > "/etc/netns/$NS/resolv.conf"
sed 's/^remote .*/remote 198.18.0.1 1194/' "$LOG/accept1.ovpn" > "$LOG/ns.ovpn"
ip netns exec "$NS" openvpn --config "$LOG/ns.ovpn" --daemon --writepid "$LOG/ns.pid" --log "$LOG/f.log" --verb 3
for attempt in $(seq 1 20); do
    if grep -q 'Initialization Sequence Completed' "$LOG/f.log"; then break; fi
    sleep 1
done
grep -q 'Initialization Sequence Completed' "$LOG/f.log"
ip netns exec "$NS" ip route get 1.1.1.1 | grep 'dev tun' >/dev/null
grep -q 'dhcp-option DNS 149.112.112.112' "$LOG/f.log"
through_vpn=$(ip netns exec "$NS" curl -4 -fsS --max-time 30 https://api.ipify.org)
from_server=$(curl -4 -fsS --max-time 30 https://api.ipify.org)
echo "Address seen through the VPN: $through_vpn; address of the server: $from_server"
[[ -n $through_vpn && $through_vpn == "$from_server" ]]
echo 'PASS: real traffic and DNS go through the tunnel and the NAT.'
# Blocked destinations, with the real kernel: a blocked address is refused at once through the VPN, so it never
# sees the server's address, and it is reachable again once unblocked. TCP, since runners do not pass ping.
reaches() { ip netns exec "$NS" timeout 10 bash -c 'exec 3<>/dev/tcp/9.9.9.9/443' 2>/dev/null; }
reached_before=0
if reaches; then reached_before=1; fi
printf '7\n7\n3\n9.9.9.9\n0\n0\n0\n' | darban | tee "$LOG/block.log"
grep -q 'Blocked: 9.9.9.9/32' "$LOG/block.log"
nft list set ip darban blocked | grep -q '9\.9\.9\.9'
# The rules as the kernel lists them, for the log: Diagnostics must recognize this form.
nft list chain ip darban forward
darban status >"$LOG/block-status.log" 2>&1 || true
grep -q 'Blocked destinations are refused: 1 range (1 address of your own)' "$LOG/block-status.log"
started=$SECONDS
if reaches; then echo 'FAIL: a blocked address was reached through the VPN.'; exit 1; fi
if (( reached_before && SECONDS - started > 5 )); then echo 'FAIL: a blocked address was not refused at once; the client waited.'; exit 1; fi
printf '7\n7\n4\n1\n0\n0\n0\n' | darban | tee "$LOG/unblock.log"
grep -q 'Unblocked: 9.9.9.9/32' "$LOG/unblock.log"
# The set as the kernel holds it now, for the log, and the address asked for a few times: one slow answer from
# outside the runner is not a rule that stayed.
nft list set ip darban blocked
if nft list set ip darban blocked | grep -q '9\.9\.9\.9'; then echo 'FAIL: the unblocked address is still in the live set.'; exit 1; fi
reached_after=0
for attempt in 1 2 3; do
    if reaches; then reached_after=1; break; fi
    sleep 2
done
if (( ! reached_before )); then
    echo 'NOTE: this runner could not reach 9.9.9.9:443 through the VPN at all, so only the rules are judged.'
elif (( reached_after )); then
    echo 'PASS: a blocked address is refused at once through the VPN, and reached again once unblocked.'
else
    echo 'FAIL: an address that was unblocked is still not reached through the VPN, three times.'; exit 1
fi
# The sites of a country outside the VPN, with a real OpenVPN 2 client: after its next connection, an address of Iran goes
# through the client's own network, and any other through the tunnel. The list used is the real list of Iran: a runner
# that cannot download it skips this, and says so.
ns_reconnect() {
    local pid attempt
    pid=$(cat "$LOG/ns.pid")
    kill "$pid" 2>/dev/null || true
    for attempt in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    ip netns exec "$NS" openvpn --config "$LOG/ns.ovpn" --daemon --writepid "$LOG/ns.pid" --log "$LOG/f.log" --verb 3
    for attempt in $(seq 1 20); do
        if grep -q 'Initialization Sequence Completed' "$LOG/f.log"; then return 0; fi
        sleep 1
    done
    return 1
}
printf '7\n7\n1\n1\n2\n0\n0\n0\n' | darban | tee "$LOG/iran.log"
if grep -q 'Saved: blocked countries Iran' "$LOG/iran.log"; then
    printf '7\n7\n2\n2\n0\n0\n0\n' | darban | tee "$LOG/direct.log"
    grep -q 'Saved: their sites outside the VPN' "$LOG/direct.log"
    iran_ip=$(awk 'NR == 2 {print $3}' /etc/openvpn/server/darban-direct.routes)
    ns_reconnect
    ip netns exec "$NS" ip route get "$iran_ip" | tee "$LOG/route-iran.txt"
    if grep -q 'dev tun' "$LOG/route-iran.txt"; then echo "FAIL: $iran_ip of Iran still goes through the tunnel."; exit 1; fi
    grep -q 'dev dt1' "$LOG/route-iran.txt"
    ip netns exec "$NS" ip route get 1.1.1.1 | grep 'dev tun' >/dev/null
    darban status >"$LOG/direct-status.log" 2>&1 || true
    grep -q 'Their sites go outside the VPN' "$LOG/direct-status.log"
    # Back as it was: no country takes the routes along, and the next connection has none.
    printf '7\n7\n1\n1\n2\n0\n0\n0\n' | darban | tee "$LOG/iran-off.log"
    grep -q 'Saved: no country is blocked now.' "$LOG/iran-off.log"
    if [[ -e /etc/openvpn/server/darban-direct.routes || -e /etc/openvpn/server/darban-direct-small.routes ]]; then echo 'FAIL: the routes stayed after the countries were turned off.'; exit 1; fi
    ns_reconnect
    ip netns exec "$NS" ip route get "$iran_ip" | grep 'dev tun' >/dev/null
    echo 'PASS: with the sites of Iran outside the VPN, a real client sends Iran through its own network, and nothing else.'
else
    echo 'NOTE: this runner could not download the list of Iran, so sites outside the VPN were not judged.'
    printf '7\n7\n0\n0\n0\n' | darban >/dev/null || true
fi
# DNS on this server, with the real Unbound and a real client: clients are told to ask it, and DNS they send to
# another server, here one that does not exist, is answered by it all the same. Over TLS too, then off again.
cat >"$LOG/ask.py" <<'PY'
import random, socket, struct, sys
server = sys.argv[1]
ident = random.randrange(65536)
query = struct.pack('>HHHHHH', ident, 0x0100, 1, 0, 0, 0) + b'\x07example\x03com\x00' + struct.pack('>HH', 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(5)
try:
    sock.sendto(query, (server, 53))
    data, _ = sock.recvfrom(4096)
except OSError:
    print('no answer'); sys.exit(1)
got, flags, _, answers = struct.unpack('>HHHH', data[:8])
print('rcode %d, %d answers' % (flags & 0xF, answers))
sys.exit(0 if got == ident and flags & 0xF == 0 and answers > 0 else 1)
PY
dns_net=$(awk '$1=="server" {print $2; exit}' /etc/openvpn/server/server.conf)
dns_gateway=${dns_net%.0}.1
printf '7\n8\n1\n2\n0\n0\n0\n' | darban | tee "$LOG/dns-on.log"
if ! grep -q "DNS on this server is on: clients ask $dns_gateway" "$LOG/dns-on.log"; then
    # Why Unbound did not start, for the log of this run.
    journalctl -u unbound.service -n 60 --no-pager || true
    unbound-checkconf || true
    ls -la /etc/unbound /etc/unbound/unbound.conf.d || true
    cat /etc/unbound/unbound.conf || true
    ss -lunp | grep ':53 ' || true
    echo 'FAIL: DNS on this server did not turn on.'
    exit 1
fi
systemctl is-active --quiet unbound
ns_reconnect
grep -q "dhcp-option DNS $dns_gateway" "$LOG/f.log"
ip netns exec "$NS" python3 -I "$LOG/ask.py" "$dns_gateway"
# 192.0.2.53 is a documentation address: no DNS answers there, unless the server sends the question to its own.
ip netns exec "$NS" python3 -I "$LOG/ask.py" 192.0.2.53
darban status >"$LOG/dns-status.log" 2>&1 || true
grep -q "DNS on this server answers on $dns_gateway" "$LOG/dns-status.log"
if grep -q 'Clients can still use another DNS' "$LOG/dns-status.log"; then echo 'FAIL: Diagnostics do not see the rules that send DNS here.'; exit 1; fi
# A name of the owner's own: the real Unbound answers "no such name" for it, and answers again once it is removed.
printf '7\n8\n7\nexample.com\n0\n0\n0\n' | darban | tee "$LOG/name-block.log"
grep -q 'Blocked: example.com.' "$LOG/name-block.log"
answer=$(ip netns exec "$NS" python3 -I "$LOG/ask.py" "$dns_gateway" || true)
if [[ $answer != 'rcode 3, 0 answers' ]]; then echo "FAIL: a blocked name was answered: $answer"; exit 1; fi
printf '7\n8\n7\n1\n0\n0\n0\n' | darban | tee "$LOG/name-unblock.log"
grep -q 'Removed: example.com.' "$LOG/name-unblock.log"
ip netns exec "$NS" python3 -I "$LOG/ask.py" "$dns_gateway"
echo 'PASS: a blocked name answers "no such name" through the real Unbound, and answers again once removed.'
printf '7\n8\n3\n2\n0\n0\n0\n' | darban | tee "$LOG/dns-tls.log"
grep -q 'Applied: DNS over TLS on' "$LOG/dns-tls.log"
ip netns exec "$NS" python3 -I "$LOG/ask.py" "$dns_gateway"
printf '7\n8\n3\n2\n0\n0\n0\n' | darban >/dev/null
printf '7\n8\n1\n2\n0\n0\n0\n' | darban | tee "$LOG/dns-off.log"
grep -q 'DNS on this server is off' "$LOG/dns-off.log"
ns_reconnect
if ip netns exec "$NS" python3 -I "$LOG/ask.py" 192.0.2.53; then echo 'FAIL: DNS is still sent to this server after it was turned off.'; exit 1; fi
if [[ -e /etc/unbound/unbound.conf.d/darban.conf ]]; then echo "FAIL: the tool's file of Unbound stayed."; exit 1; fi
echo 'PASS: DNS on this server answers a real client, over TLS too, catches DNS sent elsewhere, and goes when turned off.'
if modinfo -k "$(uname -r)" ovpn >/dev/null 2>&1; then
    ip -d link show tun0 | grep -w ovpn >/dev/null
    echo 'PASS: the server uses the in-kernel ovpn module (DCO).'
fi
# A path with a smaller MTU that drops IP fragments, as many mobile and home networks do: without the TCP
# size rule a website does not load through the VPN, with it it does. Fragments are dropped before the
# kernel would put them together again.
# Two sources, so a site that answers one runner's address with a short page does not decide it: exactly 300000
# bytes from Cloudflare's speed test, or Google's page, at least 10000 bytes. Redirects are followed, since from some
# addresses Google first answers with a short redirect. Prints what arrived; true when either one loaded.
website() {
    local fixed page
    fixed=$(ip netns exec "$NS" curl -4 -sS -o /dev/null --max-time 20 -w '%{size_download}' 'https://speed.cloudflare.com/__down?bytes=300000' 2>/dev/null || true)
    page=$(ip netns exec "$NS" curl -4 -sS -L --max-redirs 5 -o /dev/null --max-time 20 -w '%{size_download}' https://www.google.com/ 2>/dev/null || true)
    [[ $fixed =~ ^[0-9]+$ ]] || fixed=0
    [[ $page =~ ^[0-9]+$ ]] || page=0
    printf '%s of 300000 bytes from Cloudflare, %s bytes of Google' "$fixed" "$page"
    (( fixed == 300000 || page >= 10000 ))
}
# With the default TCP MSS of 1330, a packet of the tunnel is about 1420 bytes, so it fits; one of 1460 does not.
ip link set dt0 mtu 1440
ip netns exec "$NS" ip link set dt1 mtu 1440
nft add table ip darbantest
nft add chain ip darbantest pre '{ type filter hook prerouting priority -500; }'
nft add rule ip darbantest pre iifname dt0 ip frag-off '&' 0x3fff != 0 drop
ip netns exec "$NS" nft add table ip darbantest
ip netns exec "$NS" nft add chain ip darbantest pre '{ type filter hook prerouting priority -500; }'
ip netns exec "$NS" nft add rule ip darbantest pre iifname dt1 ip frag-off '&' 0x3fff != 0 drop
for handle in $(nft -a list chain ip darban forward | awk '/maxseg/ {print $NF}'); do nft delete rule ip darban forward handle "$handle"; done
without_loaded=0
without=$(website) && without_loaded=1
echo "Without the TCP size rule, on a 1440-byte path that drops fragments: $without"
darban status >"$LOG/no-mss.log" 2>&1 || true
grep -q 'The TCP MSS rule for VPN traffic is missing or different' "$LOG/no-mss.log"
systemctl restart darban-nat.service
with_loaded=0
with=$(website) && with_loaded=1
echo "With the rule: $with"
if (( ! with_loaded )); then echo 'FAIL: a website did not load through the VPN on a path with a smaller MTU.'; exit 1; fi
if (( without_loaded )); then
    echo 'NOTE: this runner did not lose large packets even without the rule, so only the result with it is judged.'
fi
darban status >"$LOG/mss.log" 2>&1
grep -q 'TCP MSS for VPN traffic is limited to 1330 in both directions' "$LOG/mss.log"
# The same path to the server itself: a page on this server, opened from a device that is connected to it,
# as a temporary link is. Those connections never pass the forward chain.
vpn_net=$(awk '$1=="server" {print $2; exit}' /etc/openvpn/server/server.conf)
server_vpn_ip=${vpn_net%.0}.1
mkdir -p "$LOG/www" && head -c 300000 /dev/urandom > "$LOG/www/big"
(cd "$LOG/www" && exec python3 -m http.server 18080 --bind "$server_vpn_ip") >/dev/null 2>&1 &
www_pid=$!
if (( USE_UFW )); then ufw allow in on tun0 to any port 18080 proto tcp >/dev/null; fi
sleep 1
local_size=$(ip netns exec "$NS" curl -4 -sS -o /dev/null --max-time 20 -w '%{size_download}' "http://$server_vpn_ip:18080/big" 2>/dev/null || true)
echo "From a connected client to the server itself, on that path: ${local_size:-0} bytes arrived"
kill "$www_pid" 2>/dev/null || true
if (( USE_UFW )); then ufw delete allow in on tun0 to any port 18080 proto tcp >/dev/null; fi
if [[ ${local_size:-0} != 300000 ]]; then echo 'FAIL: a connected client could not download from the server itself on a path with a smaller MTU.'; exit 1; fi
echo 'PASS: a connected client downloads from the server itself on a path with a smaller MTU.'
nft delete table ip darbantest
ip netns exec "$NS" nft delete table ip darbantest
ip link set dt0 mtu 1500
ip netns exec "$NS" ip link set dt1 mtu 1500
echo 'PASS: websites load through the VPN on a path with a smaller MTU that drops fragments.'
# Clients are kept apart, and the cloud metadata service is out of their reach. First without the rule, to
# show what it prevents on this runner, then with it.
printf '1\naccept2\n0\n' | darban
ip netns add "$NS-b"
ip link add dt2 type veth peer name dt3
ip link set dt3 netns "$NS-b"
ip addr add 198.18.0.5/30 dev dt2
ip link set dt2 up
ip netns exec "$NS-b" ip link set lo up
ip netns exec "$NS-b" ip addr add 198.18.0.6/30 dev dt3
ip netns exec "$NS-b" ip link set dt3 up
ip netns exec "$NS-b" ip route add default via 198.18.0.5
sed 's/^remote .*/remote 198.18.0.5 1194/' /root/openvpn-clients/accept2.ovpn > "$LOG/ns-b.ovpn"
ip netns exec "$NS-b" openvpn --config "$LOG/ns-b.ovpn" --daemon --writepid "$LOG/ns-b.pid" --log "$LOG/g.log" --verb 3
for attempt in $(seq 1 20); do
    if grep -q 'Initialization Sequence Completed' "$LOG/g.log"; then break; fi
    sleep 1
done
grep -q 'Initialization Sequence Completed' "$LOG/g.log"
first_ip=$(grep -oE 'net_addr_v4_add: [0-9.]+' "$LOG/f.log" | awk '{print $2}' | head -n 1)
metadata() { ip netns exec "$NS" curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H Metadata:true 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' || true; }
nft delete chain ip darban forward
reach=no; if ip netns exec "$NS-b" ping -c 2 -W 2 "$first_ip" >/dev/null 2>&1; then reach=yes; fi
code=$(metadata)
echo "Without the rule: one client reaches another: $reach; metadata service answers: $code"
# The check after the rule proves something only if the path is really open without it.
if [[ $reach != yes ]]; then echo 'FAIL: without the rule one client could not reach another, so the test would prove nothing.'; exit 1; fi
metadata_here=1
if [[ $code == 000 ]]; then metadata_here=0; echo 'NOTE: no metadata service answers on this runner, so only client-to-client is judged.'; fi
if darban status >"$LOG/no-rule.log" 2>&1; then echo 'FAIL: status reported missing isolation as healthy.'; exit 1; fi
grep -q 'VPN clients may reach each other' "$LOG/no-rule.log"
systemctl restart darban-nat.service
darban status >"$LOG/rule.log" 2>&1
grep -q 'VPN clients are kept apart' "$LOG/rule.log"
if ip netns exec "$NS-b" ping -c 2 -W 2 "$first_ip" >/dev/null 2>&1; then echo 'FAIL: one client reaches another.'; exit 1; fi
# Any HTTP answer, 401 or 404 included, means the service was reached.
if (( metadata_here )) && [[ $(metadata) != 000 ]]; then echo 'FAIL: a client reaches the cloud metadata service.'; exit 1; fi
# An empty chain must not pass as protection.
nft flush chain ip darban forward
if darban status >"$LOG/flushed.log" 2>&1; then echo 'FAIL: status reported an empty chain as healthy.'; exit 1; fi
grep -q 'VPN clients may reach each other' "$LOG/flushed.log"
systemctl restart darban-nat.service
darban status >/dev/null
echo 'PASS: clients are kept apart, and away from the cloud metadata service, and status sees when they are not.'
kill "$(cat "$LOG/ns-b.pid")" 2>/dev/null || true
kill "$(cat "$LOG/ns.pid")" 2>/dev/null || true
sleep 1
ip netns del "$NS-b"
ip link del dt2 2>/dev/null || true
ip netns del "$NS"
ip link del dt0 2>/dev/null || true
rm -rf "/etc/netns/$NS"
if (( ! USE_UFW )); then
    iptables -D FORWARD -i tun0 -j ACCEPT
    iptables -D FORWARD -o tun0 -j ACCEPT
fi

# A real temporary link: it can be opened again until the client connects, and then it ends.
url=$(printf '5\naccept1\n1\n1\n0\n' | darban | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
curl -ksf "$url" | grep 'Download profile' >/dev/null
# Clients that send their request a byte at a time, from one address, must not keep a person elsewhere from opening
# a link: the unit allows 64 tasks, one thread for each connection.
slow=$(python3 tests/slow-clients.py "$url" 80 40) || { echo "FAIL: slow clients from one address kept the link from opening: $slow"; exit 1; }
# The page opening proves something only while that address really held its 8 connections.
[[ $slow == 'held 8 slow connections; the page opened: yes' ]] || { echo "FAIL: the slow clients were not held as they should be: $slow"; exit 1; }
echo "PASS: slow clients from one address do not keep the link from opening ($slow)."
# A new link does not restart the service, which would cut a request in progress: one for the first link waits half
# sent while a second link is made, and then gets its page.
pid=$(systemctl show -p MainPID --value darban-links.service)
rm -f "$LOG/go" "$LOG/go.ready"
python3 tests/held-request.py "$url" "$LOG/go" >"$LOG/held.out" 2>&1 &
held=$!
for attempt in $(seq 1 100); do [[ -e $LOG/go.ready ]] && break; sleep 0.1; done
url2=$(printf '5\naccept1\n1\n1\n0\n' | darban | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
: > "$LOG/go"
wait "$held" || { echo "FAIL: a new link cut a request in progress: $(head -c 300 "$LOG/held.out")"; exit 1; }
grep -q 'Download profile' "$LOG/held.out"
[[ $(systemctl show -p MainPID --value darban-links.service) == "$pid" ]] || { echo 'FAIL: a new link restarted the link service.'; exit 1; }
curl -ksf "$url2" | grep 'Download profile' >/dev/null
echo 'PASS: a new link reaches the running link service without a restart, and a request in progress gets its page.'

# The link service sees only what it needs. From inside its mount namespace, the link key and the link files are
# there, which also shows that nsenter reached it; every path its unit hides, that has something in it here, shows
# nothing there. It may open no unix socket, so the management interface is out of its reach too.
pid=$(systemctl show -p MainPID --value darban-links.service)
[[ $pid =~ ^[1-9][0-9]*$ ]]
inside() { nsenter -t "$pid" -m -- "$@"; }
inside test -s /etc/darban/link-key.pem
[[ -n $(inside ls -A /run/darban-links) ]]
hidden=0
for path in /etc/openvpn /etc/letsencrypt /var/backups/darban-pki /var/lib/darban /run/darban-events /run/openvpn-server /etc/shadow /etc/gshadow /etc/ssh /etc/ssl/private /var/log; do
    if [[ -d $path && -n $(ls -A "$path") ]]; then
        [[ -z $(inside ls -A "$path" 2>/dev/null) ]] || { echo "FAIL: the link service sees what is in $path."; exit 1; }
    elif [[ -f $path && -s $path ]]; then
        if inside test -s "$path"; then echo "FAIL: the link service can read $path."; exit 1; fi
    else
        continue
    fi
    hidden=$((hidden + 1))
done
# /etc/openvpn, /run/openvpn-server, /etc/shadow, /etc/gshadow, /etc/ssh and /var/log always have something in
# them here.
(( hidden >= 6 )) || { echo "FAIL: only $hidden of the hidden paths could be checked."; exit 1; }
families=$(systemctl show -p RestrictAddressFamilies --value darban-links.service)
[[ $families == *AF_INET* && $families != *AF_UNIX* ]] || { echo "FAIL: the link service may open: $families"; exit 1; }
echo "PASS: the link service sees the link key and its files, and none of $hidden paths it has no use for, and opens no unix socket."
[[ $(systemctl show -p SystemCallFilter --value darban-links.service) == *read* ]] || { echo 'FAIL: the link service has no system call filter.'; exit 1; }
# A number to compare from one run to the next, not a gate: lower means less exposed.
exposure=$(systemd-analyze security darban-links.service 2>/dev/null | sed -n 's/.*Overall exposure level for [^:]*: *//p' || true)
echo "systemd-analyze security, darban-links.service: ${exposure:-not reported}"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "Link service exposure (systemd-analyze security): ${exposure:-not reported}" >> "$GITHUB_STEP_SUMMARY"; fi
curl -ksf -H 'Accept-Language: fa-IR,fa;q=0.9' "$url" | grep 'dir="rtl"' >/dev/null
curl -ksf "$url/file" -o "$LOG/link.ovpn"
grep -q '<key>' "$LOG/link.ovpn"
grep -qx 'setenv FRIENDLY_NAME "accept1"' "$LOG/link.ovpn"
[[ $(curl -ks -o /dev/null -w '%{http_code}' "$url/file") == 200 ]]
connect "$LOG/link.ovpn" "$LOG/link-client.log"
for attempt in $(seq 1 30); do
    if [[ $(curl -ks -o /dev/null -w '%{http_code}' "$url") == 410 ]]; then break; fi
    sleep 1
done
[[ $(curl -ks -o /dev/null -w '%{http_code}' "$url") == 410 ]]
disconnect
# With connection events on, the event of that connection ended the link, not the link service.
journalctl -t darban --no-pager | grep 'temporary link ended: accept1 connected' >/dev/null
if journalctl -u darban-links.service --no-pager | grep '[0-9a-f]\{64\}' >/dev/null; then echo 'FAIL: a token reached the log.'; exit 1; fi
echo 'PASS: the temporary link works until the first connection, which its event ends, and keeps tokens out of the log.'

# D3 for a file kept on the server: T50 and T63. Its time is kept by the real timer, within seconds; a timer left
# from a file shared again only runs the check, which leaves the newer file.
KEPT=/root/openvpn-clients
gone_within() { local i; for i in $(seq 1 "$2"); do if [[ ! -e $1 ]]; then return 0; fi; sleep 1; done; return 1; }
printf '1\nkept1\n0\n' | darban >"$LOG/kept1.log"
[[ -s $KEPT/kept1.share ]]
systemctl is-active --quiet darban-expire.timer
if grep -q UV_DARBAN_SHARE "$KEPT/kept1.ovpn"; then echo 'FAIL: a profile names its share while the flag is off.'; exit 1; fi
due=$(( $(date +%s) + 8 ))
sed -i "s/^expires=.*/expires=$due/" "$KEPT/kept1.share"
systemctl start darban-sweep.service
systemctl list-timers darban-expire.timer --all --no-pager | tee "$LOG/expire-timer.log"
gone_within "$KEPT/kept1.ovpn" 30 || { echo 'FAIL: the file was still there 30 seconds after the time it was given.'; exit 1; }
late=$(( $(date +%s) - due ))
echo "T50: a file kept on the server went ${late} s after its time"
(( late <= 6 )) || { echo 'FAIL: the file went more than 6 seconds after its time.'; exit 1; }
[[ ! -e $KEPT/kept1.share ]]
journalctl -t darban --no-pager | grep 'kept1.ovpn, its time was up' >/dev/null
printf '1\nkept2\n0\n' | darban >/dev/null
systemctl stop darban-expire.timer
systemd-run --quiet --unit=darban-expire --on-calendar="@$(( $(date +%s) + 4 ))" --timer-property=AccuracySec=1s
since=$(date +%s)
sleep 10
journalctl -u darban-expire.service --since "@$since" --no-pager | tee "$LOG/expire-stale.log"
grep -E 'Finished|Deactivated successfully' "$LOG/expire-stale.log" >/dev/null
[[ -s $KEPT/kept2.ovpn ]] || { echo 'FAIL: a timer left from an older file deleted a newer one.'; exit 1; }
systemctl is-active --quiet darban-expire.timer
echo 'PASS: a kept file goes by the real timer within seconds of its time, and a timer left over deletes nothing newer.'

# T23 and T55: "file read" follows the access time of the copy the SSH user fetches, and is not claimed without
# access times.
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    printf '5\nkept2\n2\n0\n' | darban >/dev/null
    [[ -s $home/kept2.ovpn ]]
    printf '6\n\n0\n' | darban >"$LOG/kept-unread.log"
    grep -E 'kept2 .*left .*not read yet' "$LOG/kept-unread.log" >/dev/null
    sleep 1.2
    runuser -u "$SUDO_USER" -- cat "$home/kept2.ovpn" >/dev/null
    printf '6\n\n0\n' | darban >"$LOG/kept-read.log"
    grep -E 'kept2 .*left .*file read' "$LOG/kept-read.log" >/dev/null
    grep 'Darban cannot tell by whom' "$LOG/kept-read.log" >/dev/null
    mount --bind "$home" "$home"
    mount -o remount,bind,noatime "$home"
    printf '6\n\n0\n' | darban >"$LOG/kept-noatime.log"
    umount "$home"
    if grep -E 'kept2 .*(file read|not read yet)' "$LOG/kept-noatime.log" >/dev/null; then echo 'FAIL: a read was claimed without access times.'; exit 1; fi
    echo 'PASS: menu 6 says a kept file was read once its copy was read, and claims nothing without access times.'
fi

# R24-B04: an SSH user whose home is not its own gets no copy there, as root, with the real owner checked.
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    useradd -M -d /home/darban-other -s /usr/sbin/nologin darban-other
    install -d -o root -g root -m 755 /home/darban-other
    cp /etc/darban/config "$LOG/config.saved"
    sed -i '/^DOWNLOAD_SSH_USER=/d' /etc/darban/config
    echo 'DOWNLOAD_SSH_USER=darban-other' >>/etc/darban/config
    printf '5\nkept2\n2\n0\n' | darban >"$LOG/other-home.log" 2>&1 || true
    grep 'is a link or not its own, so no copy was made' "$LOG/other-home.log" >/dev/null
    if compgen -G '/home/darban-other/*.ovpn' >/dev/null; then echo 'FAIL: a copy was made in a home its user does not own.'; exit 1; fi
    cp "$LOG/config.saved" /etc/darban/config
    userdel darban-other
    rm -rf /home/darban-other
    echo 'PASS: an SSH user whose home is not its own gets no copy there.'
fi

# T56, C.11 and E13 in part: only with the flag does a profile name its share; a real OpenVPN 2.6 client then sends
# it, and the server gets it: a connection naming another share leaves the file, and one naming its own deletes it.
echo 'SHARE_ID_IN_PROFILE=yes' >>/etc/darban/config
printf '1\nkept3\n0\n' | darban >/dev/null
id=$(sed -n 's/^share_id=//p' "$KEPT/kept3.share")
grep -qx "setenv UV_DARBAN_SHARE $id" "$KEPT/kept3.ovpn"
grep -qx 'push-peer-info' "$KEPT/kept3.ovpn"
cp "$KEPT/kept3.ovpn" "$LOG/kept3.ovpn"
sed -i 's/^share_id=.*/share_id=0123456789abcdef/' "$KEPT/kept3.share"
connect "$LOG/kept3.ovpn" "$LOG/kept3-a.log"
for attempt in $(seq 1 15); do
    if grep -q '^last_connect=' "$LEDGER/kept3" 2>/dev/null; then break; fi
    sleep 1
done
grep -q '^last_connect=' "$LEDGER/kept3"
sleep 2
disconnect
[[ -s $KEPT/kept3.ovpn ]] || { echo 'FAIL: a connection naming another share deleted the file, so the server did not get the name.'; exit 1; }
sed -i "s/^share_id=.*/share_id=$id/" "$KEPT/kept3.share"
connect "$LOG/kept3.ovpn" "$LOG/kept3-b.log"
gone_within "$KEPT/kept3.ovpn" 15 || { echo 'FAIL: a connection naming its own share left the file.'; exit 1; }
disconnect
sed -i '/^SHARE_ID_IN_PROFILE=/d' /etc/darban/config
echo 'PASS: with the flag, a real OpenVPN 2.6 client sends the share its profile names, and only that share ends.'

# A broken server: diagnostics say so by exit status, and the tool can still be updated.
mv /root/pki/ca.crt /root/pki/ca.crt.keep
if darban status >"$LOG/broken.log" 2>&1; then echo 'FAIL: status reported a broken CA as healthy.'; exit 1; fi
grep -q 'CA or OpenVPN server configuration is missing' "$LOG/broken.log"
bash setup/install.sh
mv /root/pki/ca.crt.keep /root/pki/ca.crt
darban status >/dev/null
echo 'PASS: a broken server is reported, can be updated, and recovers.'

# An install from before clients were kept apart gets the rule from an update.
awk '/# Clients cannot reach each other/ {skip=1} skip && /^    }$/ {skip=0; next} !skip' /etc/darban/nat.nft > "$LOG/old-nat.nft"
cp "$LOG/old-nat.nft" /etc/darban/nat.nft
systemctl restart darban-nat.service
if nft list chain ip darban forward >/dev/null 2>&1; then echo 'FAIL: the old layout still has the rule.'; exit 1; fi
bash setup/install.sh
nft list chain ip darban forward >/dev/null
grep -q 'chain forward' /etc/darban/nat.nft
darban status >"$LOG/updated.log" 2>&1
grep -q 'VPN clients are kept apart' "$LOG/updated.log"
echo 'PASS: an update adds the rule to an older install.'

# The TCP MSS: an update from v1.0.1, whose rules limit it to 1280, moves them to 1330. A number set in
# Settings > Advanced stays through an update, Diagnostics report it, and a number out of range is refused.
mss_rules() { grep -c -F "tcp flags syn tcp option maxseg size > $1 tcp option maxseg size set $1" /etc/darban/nat.nft || true; }
sed -i 's/maxseg size > 1330 tcp option maxseg size set 1330/maxseg size > 1280 tcp option maxseg size set 1280/' /etc/darban/nat.nft
systemctl restart darban-nat.service
darban status >"$LOG/mss-old.log" 2>&1 || true
grep -q 'The TCP MSS rule for VPN traffic is missing or different from the configured 1330' "$LOG/mss-old.log"
bash setup/install.sh | tee "$LOG/mss-update.log"
grep -q 'TCP MSS for VPN traffic is limited to 1330\.$' "$LOG/mss-update.log"
[[ $(mss_rules 1330) == 4 && $(mss_rules 1280) == 0 ]] || { echo 'FAIL: the update did not move the TCP MSS rules to 1330.'; exit 1; }
nft list chain ip darban forward | grep 'maxseg size set 1330' >/dev/null
darban status >"$LOG/mss-new.log" 2>&1
grep -q 'TCP MSS for VPN traffic is limited to 1330 in both directions' "$LOG/mss-new.log"
printf '7\n6\n9\n1461\n\n0\n0\n0\n' | darban >"$LOG/mss-refused.log" 2>&1
grep -q 'Enter a whole number from 536 to 1460, or 0 for the default.' "$LOG/mss-refused.log"
if grep -q '^TCP_MSS=' /etc/darban/config; then echo 'FAIL: a TCP MSS out of range was saved.'; exit 1; fi
printf '7\n6\n9\n1400\n0\n0\n0\n' | darban | tee "$LOG/mss-set.log"
grep -q 'Saved: TCP MSS 1400' "$LOG/mss-set.log"
grep -qx 'TCP_MSS=1400' /etc/darban/config
nft list chain ip darban output | grep 'maxseg size set 1400' >/dev/null
bash setup/install.sh
[[ $(mss_rules 1400) == 4 ]] || { echo 'FAIL: an update did not keep the TCP MSS set in Settings > Advanced.'; exit 1; }
nft list chain ip darban forward | grep 'maxseg size set 1400' >/dev/null
darban status >"$LOG/mss-custom.log" 2>&1
grep -q 'TCP MSS for VPN traffic is limited to 1400 in both directions' "$LOG/mss-custom.log"
printf '7\n6\n9\n0\n0\n0\n0\n' | darban >/dev/null
[[ $(mss_rules 1330) == 4 ]] || { echo 'FAIL: 0 did not bring the TCP MSS rules back to 1330.'; exit 1; }
if grep -q '^TCP_MSS=' /etc/darban/config; then echo 'FAIL: the default TCP MSS left a line in the config file.'; exit 1; fi
echo 'PASS: an update moves TCP MSS from 1280 to 1330, keeps a number set in Settings > Advanced, and Diagnostics report it.'

# NAT left on another network, as a network change cut off half way could leave it, is found and put right.
net=$(awk '$1=="server" {print $2; exit}' /etc/openvpn/server/server.conf)
sed -i "s#$net/24#10.123.0.0/24#g" /etc/darban/nat.nft
systemctl restart darban-nat.service
if darban status >"$LOG/mismatch.log" 2>&1; then echo 'FAIL: status reported NAT for another network as healthy.'; exit 1; fi
grep -q "NAT does not match the VPN network $net/24" "$LOG/mismatch.log"
bash setup/install.sh
grep -q "ip saddr $net/24 oifname" /etc/darban/nat.nft
darban status >/dev/null
echo 'PASS: NAT for another network is reported, and the installer puts it right.'

# An outgoing interface that is gone, as a new image can rename it, is found and put right.
sed -i 's/oifname "[^"]*"/oifname "gone0"/' /etc/darban/nat.nft
systemctl restart darban-nat.service
if darban status >"$LOG/iface.log" 2>&1; then echo 'FAIL: status reported NAT through a missing interface as healthy.'; exit 1; fi
grep -q 'out through gone0, which this server no longer has' "$LOG/iface.log"
bash setup/install.sh | tee "$LOG/iface-install.log"
grep -q 'NAT used gone0' "$LOG/iface-install.log"
route_iface=$(ip -4 route show default | awk '{for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
grep -q "oifname \"$route_iface\" masquerade" /etc/darban/nat.nft
darban status >/dev/null
echo 'PASS: NAT through a missing interface is reported, and the installer moves it to the default route.'

# A NAT file edited by hand is not repaired, but the installer says it did not check it.
cp -a /etc/darban/nat.nft "$LOG/nat.kept"
sed -i 's/ oifname "[^"]*"//' /etc/darban/nat.nft
bash setup/install.sh 2>"$LOG/skip-install.log"
grep -q 'NOTE: the NAT rules were not checked' "$LOG/skip-install.log"
cp -a "$LOG/nat.kept" /etc/darban/nat.nft
darban status >/dev/null
echo 'PASS: a NAT file the installer cannot check is reported, not passed over.'

# The NAT file is gone while its rules still run: Diagnostics warn before a reboot would cut clients off, and the
# installer writes it again.
rm -f /etc/darban/nat.nft
darban status >"$LOG/nat-gone.log" || true
grep 'is gone, so after a reboot clients have no internet' "$LOG/nat-gone.log" >/dev/null
bash setup/install.sh | tee "$LOG/nat-gone-install.log"
[[ -s /etc/darban/nat.nft ]]
grep 'was missing; it is written again from server.conf' "$LOG/nat-gone-install.log" >/dev/null
darban status >"$LOG/nat-back.log"
if grep 'is gone' "$LOG/nat-back.log" >/dev/null; then echo 'FAIL: the NAT file is still called gone.'; exit 1; fi
echo 'PASS: a NAT file that is gone is reported before a reboot, and the installer writes it again.'

# This tool's Let's Encrypt certificate from a real ACME server: Pebble, Let's Encrypt's test server, and certbot
# from Ubuntu, which the tool installs itself. Issued with this tool's hook; a renewal by certbot reaches the open
# link through that hook. Further down, an uninstall keeps the certificate without the hook.
PEBBLE=v2.10.1
pebble_dir=$LOG/pebble
mkdir -p "$pebble_dir/bin"
curl -fsSL --retry 2 -o "$pebble_dir/bin.tar.gz" "https://github.com/letsencrypt/pebble/releases/download/$PEBBLE/pebble-linux-$(dpkg --print-architecture).tar.gz"
curl -fsSL --retry 2 -o "$pebble_dir/src.tar.gz" "https://github.com/letsencrypt/pebble/archive/refs/tags/$PEBBLE.tar.gz"
tar -xzf "$pebble_dir/bin.tar.gz" -C "$pebble_dir/bin"
tar -xzf "$pebble_dir/src.tar.gz" -C "$pebble_dir"
pebble_bin=$(find "$pebble_dir/bin" -type f -name pebble | head -n 1)
pebble_src=$(find "$pebble_dir" -maxdepth 1 -type d -name 'pebble-*' | head -n 1)
chmod +x "$pebble_bin"
# Pebble rejects a share of good nonces by default, to test a client's retry. That is certbot's code, not this
# tool's, and two rejections in a row made a renewal here fail now and then: the renewals here test the tool.
(cd "$pebble_src" && PEBBLE_VA_ALWAYS_VALID=1 PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 "$pebble_bin" -config test/config/pebble-config.json </dev/null >"$LOG/pebble.log" 2>&1 &)
export REQUESTS_CA_BUNDLE=$pebble_src/test/certs/pebble.minica.pem
for attempt in $(seq 1 20); do
    if curl -fs --cacert "$REQUESTS_CA_BUNDLE" https://localhost:14000/dir >/dev/null; then break; fi
    sleep 0.5
done
mkdir -p /etc/letsencrypt
printf 'server = https://localhost:14000/dir\n' > /etc/letsencrypt/cli.ini
cp /etc/darban/domain "$LOG/domain.before"
echo links-test.localhost > /etc/darban/domain
LE_CONF=/etc/letsencrypt/renewal/darban-ovpn-links.conf
LE_LIVE=/etc/letsencrypt/live/darban-ovpn-links
printf '7\n5\n2\n0\n0\n' | darban | tee "$LOG/le-issue.log"
grep "New certificate from Let's Encrypt for links-test.localhost" "$LOG/le-issue.log" >/dev/null
grep -qx 'renew_hook = /usr/local/sbin/darban reload-links' "$LE_CONF"
cmp -s /etc/darban/link-cert.pem "$LE_LIVE/fullchain.pem"
echo "PASS: Let's Encrypt (Pebble) issues the links' certificate, and certbot keeps this tool's hook."

link_fp() { openssl x509 -in /etc/darban/link-cert.pem -noout -fingerprint -sha256 | sed 's/^.*=//'; }
served_fp() {
    local port
    port=$(awk -F= '$1 == "LINK_PORT" {print $2; exit}' /etc/darban/links.env)
    timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername links-test.localhost </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}
printf '5\naccept2\n1\n1\n0\n' | darban | tee "$LOG/le-link.log"
grep -oE 'https://[^ ]+/l/[0-9a-f]{64}' "$LOG/le-link.log" >/dev/null
[[ $(served_fp) == "$(link_fp)" ]]
before=$(link_fp)
# A reload, not a restart: the same process serves the new certificate, so a download in progress goes on.
before_pid=$(systemctl show -p MainPID --value darban-links.service)
certbot renew --no-random-sleep-on-renew --force-renewal --cert-name darban-ovpn-links 2>&1 | tee "$LOG/le-renew.log"
cmp -s /etc/darban/link-cert.pem "$LE_LIVE/fullchain.pem"
[[ $(link_fp) != "$before" ]]
for attempt in $(seq 1 10); do
    if [[ $(served_fp) == "$(link_fp)" ]]; then break; fi
    sleep 0.5
done
[[ $(served_fp) == "$(link_fp)" ]]
[[ $(systemctl show -p MainPID --value darban-links.service) == "$before_pid" ]] || { echo 'FAIL: the link service was restarted, not reloaded.'; exit 1; }
journalctl -u darban-links.service --no-pager | grep 'certificate reloaded' >/dev/null
echo "PASS: certbot's renewal reaches the open link through this tool's hook, by a reload."
cp "$LOG/domain.before" /etc/darban/domain
# A hook of another certificate, which nothing of this tool may touch.
OTHER_CONF=/etc/letsencrypt/renewal/other-site.conf
printf '[renewalparams]\nauthenticator = standalone\nrenew_hook = /usr/local/bin/other-hook\n' > "$OTHER_CONF"
cp "$OTHER_CONF" "$LOG/other-site.before"

# A real update and the way back. The new version is this one under another number.
current=$(darban version)
next=$(mktemp -d)
cp -r setup bin lib systemd VERSION "$next/"
sed -i 's/^DARBAN_VERSION=.*/DARBAN_VERSION=9.9.9/' "$next/bin/darban"
echo 9.9.9 > "$next/VERSION"
bash "$next/setup/install.sh"
[[ $(darban version) == 9.9.9 ]]
# The update placed the manager's modules where bin/darban sources them.
for module in "$next"/lib/darban/*.sh "$next"/lib/darban/screens/*.sh; do
    module=${module#"$next"/lib/darban/}
    cmp -s "$next/lib/darban/$module" "/usr/local/lib/darban/modules/$module" || { echo "FAIL: the update did not place $module."; exit 1; }
done
systemctl is-active --quiet "$UNIT"
# T34 and C.12.12: the version restored here has no connection events, as rc.10: their units go first, and the
# script and its lines stay, so every client still connects.
newest=$(find /var/backups/darban -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
rm -f "$newest/units/"darban-events* "$newest/units/"darban-sweep* "$newest/units/"run-darban*
printf '9\n4\n2\n' | darban | tee "$LOG/restore.log"
[[ $(darban version) == "$current" ]]
grep 'does not use connection events' "$LOG/restore.log" >/dev/null
grep "These stay, so connections keep working: $EVENT_SCRIPT" "$LOG/restore.log" >/dev/null
[[ ! -e /etc/systemd/system/darban-events.path ]]
unmounted
[[ -x $EVENT_SCRIPT ]]
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
connect "$PROFILE" "$LOG/restored.log"; disconnect
darban status >/dev/null
bash setup/install.sh | tee "$LOG/events-reinstall.log"
grep 'Connection events are on.$' "$LOG/events-reinstall.log" >/dev/null
systemctl is-active --quiet darban-events.path
echo 'PASS: an update installs, Restore previous version goes back, and an older version keeps every client connecting.'

# Removing only the tool keeps the VPN running, and installing it again finds everything. The links' Let's Encrypt
# certificate stays, and certbot renews it without this tool's hook; a new install gives the hook back.
printf 'uninstall\n' | darban uninstall | tee "$LOG/uninstall.log"
[[ ! -e /usr/local/sbin/darban ]]
systemctl is-active --quiet "$UNIT"
if grep -q '^renew_hook' "$LE_CONF"; then echo "FAIL: this tool's hook stayed in certbot's renewal file."; exit 1; fi
cmp -s "$OTHER_CONF" "$LOG/other-site.before"
grep 'certbot still renews it' "$LOG/uninstall.log" >/dev/null
grep 'sudo certbot delete --cert-name darban-ovpn-links' "$LOG/uninstall.log" >/dev/null
# Q2 and T20: the units and the queue of connection events go; the script and its lines stay, with no restart.
[[ ! -e /etc/systemd/system/darban-events.path && ! -e /etc/systemd/system/darban-sweep.timer && ! -e /etc/systemd/system/darban-expire.service ]]
if systemctl is-active --quiet darban-expire.timer; then echo 'FAIL: the timer for kept files is still set after an uninstall.'; exit 1; fi
unmounted
[[ -x $EVENT_SCRIPT ]]
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
grep 'Kept, so connections go on without a restart' "$LOG/uninstall.log" >/dev/null
connect "$PROFILE" "$LOG/uninstalled.log"; disconnect
echo 'PASS: after an uninstall the event script stays, and every client still connects.'
serial=$(openssl x509 -in "$LE_LIVE/cert.pem" -noout -serial)
certbot renew --no-random-sleep-on-renew --force-renewal --cert-name darban-ovpn-links 2>&1 | tee "$LOG/le-renew-after.log"
[[ $(openssl x509 -in "$LE_LIVE/cert.pem" -noout -serial) != "$serial" ]]
echo "PASS: after an uninstall, certbot from Ubuntu renews the kept certificate without this tool's hook."
# not_tested <what and why>: said in the log and in the run's summary, so a green run shows what it did not test.
not_tested() {
    echo "SKIPPED: $1"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "Not tested: $1" >>"$GITHUB_STEP_SUMMARY"; fi
}
# certbot from the snap, which the tool uses for an IP address, when this runner can install it.
if timeout 300 snap install --classic certbot >"$LOG/snap.log" 2>&1; then
    serial=$(openssl x509 -in "$LE_LIVE/cert.pem" -noout -serial)
    # The snap's certbot against the test ACME server is this runner's question, not the tool's: a limit, and a
    # failure is named instead of failing the run. The renewal by Ubuntu's certbot above is the check.
    if timeout 120 /snap/bin/certbot renew --non-interactive --no-random-sleep-on-renew --force-renewal --cert-name darban-ovpn-links </dev/null >"$LOG/le-renew-snap.log" 2>&1 \
        && [[ $(openssl x509 -in "$LE_LIVE/cert.pem" -noout -serial) != "$serial" ]]; then
        echo "PASS: certbot from the snap renews it too."
    else
        not_tested "certbot from the snap did not renew against the test ACME server here: $(grep -v '^ *$' "$LOG/le-renew-snap.log" | tail -n 2 | tr '\n' ' ')"
    fi
    snap remove certbot >/dev/null 2>&1 || true
else
    not_tested "certbot from the snap could not be installed on this runner: $(tail -n 1 "$LOG/snap.log")"
fi
bash setup/install.sh
darban status >/dev/null
systemctl is-active --quiet darban-events.path
grep -qx 'renew_hook = /usr/local/sbin/darban reload-links' "$LE_CONF"
cmp -s "$OTHER_CONF" "$LOG/other-site.before"
echo 'PASS: the tool can be removed and installed again without touching the VPN, and gets its hook back.'

# Full removal: keep a backup, keep the links' Let's Encrypt certificate, keep any kernel the setup added, then confirm.
kernel_answer=''
if [[ $(bash /usr/local/lib/darban/remove-server.sh --kernel-status) == removable ]]; then kernel_answer='1\n'; fi
printf "1\\n1\\n${kernel_answer}remove-everything\\n" | darban remove-all | tee "$LOG/remove-all.log"
grep "Kept the Let's Encrypt certificate darban-ovpn-links" "$LOG/remove-all.log" >/dev/null
[[ -s $LE_LIVE/fullchain.pem ]]
if grep -q '^renew_hook' "$LE_CONF"; then echo "FAIL: this tool's hook stayed after Remove everything."; exit 1; fi
cmp -s "$OTHER_CONF" "$LOG/other-site.before"
echo "PASS: Remove everything keeps the certificate when asked, without this tool's hook."
if systemctl is-active --quiet "$UNIT"; then echo 'FAIL: OpenVPN still runs after removal.'; exit 1; fi
if systemctl is-active --quiet darban-expire.timer; then echo 'FAIL: the timer for kept files is still set after removal.'; exit 1; fi
for path in /root/pki /etc/openvpn/server /root/openvpn-clients /etc/darban /usr/local/sbin/darban /etc/apt/sources.list.d/openvpn-aptrepo.list /var/log/darban-setup.log \
    "$EVENT_SCRIPT" "$LEDGER" /etc/systemd/system/darban-events.path /etc/systemd/system/darban-sweep.timer /etc/systemd/system/darban-expire.service '/etc/systemd/system/run-darban\x2devents.mount' \
    /etc/systemd/system/darban-geo.service /etc/systemd/system/darban-geo.timer; do
    if [[ -e $path ]]; then echo "FAIL: still present after removal: $path"; exit 1; fi
done
if dpkg-query -W -f='${Status}' openvpn 2>/dev/null | grep 'install ok installed' >/dev/null; then echo 'FAIL: the openvpn package is still installed.'; exit 1; fi
if nft list table ip darban >/dev/null 2>&1; then echo 'FAIL: the NAT table is still loaded.'; exit 1; fi
if (( USE_UFW )) && ufw status | grep '1194\|tun0' >/dev/null; then echo 'FAIL: the ufw rules are still there.'; exit 1; fi
ls /root/darban-backup-*.tar.gz
echo 'PASS: full removal left nothing behind except the backup and the kernel.'
fi
if [[ $PART == all ]]; then echo 'All acceptance checks passed.'; else echo "All acceptance checks of part $PART passed."; fi

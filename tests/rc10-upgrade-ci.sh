#!/usr/bin/env bash
# The way from the last release, v1.0.0-rc.10, to this code and back, on a disposable machine such as a CI runner.
# rc.10 sets up the server from its own release; this code updates it, which turns connection events on with one
# restart of OpenVPN; Restore previous version goes back to the real rc.10, whose own uninstall then runs; this
# code is installed again. A client connects after every step: no step may refuse one because of the event script.
#   rc10-upgrade-ci.sh --i-know
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Usage: rc10-upgrade-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
RC=v1.0.0-rc.10
LOG=$(mktemp -d)
PIDFILE=$LOG/client.pid
UNIT=openvpn-server@server.service
CONF=/etc/openvpn/server/server.conf
EVENT_SCRIPT=/usr/local/libexec/darban-ovpn-event
EVENTS=/run/darban-events
LEDGER=/var/lib/darban/clients
trap 'echo "FAILED at line $LINENO"; journalctl -u "$UNIT" -n 30 --no-pager || true; tail -n 20 "$LOG"/*.log 2>/dev/null || true' ERR

connect() {
    # connect <profile> <log>: 0 when the tunnel comes up within 20 seconds.
    local attempt
    rm -f "$PIDFILE"
    openvpn --config "$1" --route-nopull --dev tun9 --daemon --writepid "$PIDFILE" --log "$2" --verb 3
    for attempt in $(seq 1 20); do
        if grep -q 'Initialization Sequence Completed' "$2"; then return 0; fi
        sleep 1
    done
    return 1
}
disconnect() { if [[ -s $PIDFILE ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; fi; }
# How many times OpenVPN started since <epoch>.
starts_since() { journalctl -u "$UNIT" --since "@$1" --no-pager | grep -c 'Initialization Sequence Completed' || true; }
link_of() { printf '5\n%s\n1\n1\n0\n' "$1" | darban | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}'; }
gone_within() {
    # gone_within <url> <seconds>: the link answers 410 within that time.
    local attempt
    for attempt in $(seq 1 "$2"); do
        if [[ $(curl -ks -o /dev/null -w '%{http_code}' "$1") == 410 ]]; then return 0; fi
        sleep 1
    done
    return 1
}
unmounted() { local attempt; for attempt in $(seq 1 10); do mountpoint -q "$EVENTS" || return 0; sleep 1; done; return 1; }
last_connect() { awk -F= '$1=="last_connect" {print $2}' "$LEDGER/up1" 2>/dev/null || true; }

# The release itself, checked against its own checksums.
curl -fsSL --retry 3 -o "$LOG/darban-ovpn.tar.gz" "https://github.com/MohZeh/Darban-OVPN/releases/download/$RC/darban-ovpn.tar.gz"
curl -fsSL --retry 3 -o "$LOG/SHA256SUMS" "https://github.com/MohZeh/Darban-OVPN/releases/download/$RC/SHA256SUMS"
(cd "$LOG" && grep ' darban-ovpn.tar.gz$' SHA256SUMS | sha256sum -c -)
mkdir "$LOG/rc"
tar -xzf "$LOG/darban-ovpn.tar.gz" -C "$LOG/rc"
(cd "$LOG/rc" && bash setup/server-setup.sh --yes --host 127.0.0.1 --port 1194) >"$LOG/setup.log" 2>&1
(cd "$LOG/rc" && bash setup/install.sh)
[[ $(darban version) == 1.0.0-rc.10 ]]
if grep -q darban-ovpn-event "$CONF"; then echo 'FAIL: rc.10 wrote event lines.'; exit 1; fi
printf '1\nup1\n0\n' | darban >/dev/null
cp /root/openvpn-clients/up1.ovpn "$LOG/up1.ovpn"
connect "$LOG/up1.ovpn" "$LOG/rc10.log"; disconnect
# A file rc.10 keeps on the server, which knows nothing of records.
printf '1\nup2\n0\n' | darban >/dev/null
cp /root/openvpn-clients/up2.ovpn "$LOG/up2.ovpn"
echo "PASS: $RC from its release sets up the server, and a client connects."

# E11: updating turns connection events on, with one restart of OpenVPN, and a link then ends by the event.
grep 'maxseg size set 1280' /etc/darban/nat.nft >/dev/null
start=$(date +%s); sleep 1
bash setup/install.sh | tee "$LOG/upgrade.log"
# rc.10, like v1.0.1, limits TCP MSS to 1280; the update moves every rule to 1330, the default now.
grep 'TCP MSS for VPN traffic is limited to 1330\.$' "$LOG/upgrade.log" >/dev/null
[[ $(grep -c -F 'tcp option maxseg size > 1330 tcp option maxseg size set 1330' /etc/darban/nat.nft) == 4 ]]
if grep 'maxseg size set 1280' /etc/darban/nat.nft >/dev/null; then echo 'FAIL: the update left a TCP MSS rule of 1280.'; exit 1; fi
nft list chain ip darban forward | grep 'maxseg size set 1330' >/dev/null
grep 'Turning on connection events: OpenVPN restarts once' "$LOG/upgrade.log" >/dev/null
grep 'Connection events are on: a link now ends at the first connection' "$LOG/upgrade.log" >/dev/null
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
starts=$(starts_since "$start")
echo "OpenVPN started $starts time(s) during the update"
[[ $starts == 1 ]]
url=$(link_of up1)
connect "$LOG/up1.ovpn" "$LOG/updated.log"
gone_within "$url" 30
disconnect
grep -q '^last_connect=' "$LEDGER/up1"
journalctl -t darban --no-pager | grep 'temporary link ended: up1 connected' >/dev/null
echo 'PASS: the update from rc.10 restarts OpenVPN once, turns connection events on, and the event ends the link.'

# L1 and T31: the file rc.10 kept gets a record at the first check, with the whole time from then, and its first
# connection after that deletes it.
systemctl start darban-sweep.service
[[ -s /root/openvpn-clients/up2.share ]]
expires=$(sed -n 's/^expires=//p' /root/openvpn-clients/up2.share)
(( expires > $(date +%s) + 86400 - 600 ))
journalctl -t darban --no-pager | grep 'profile kept on the server from before: /root/openvpn-clients/up2.ovpn' >/dev/null
connect "$LOG/up2.ovpn" "$LOG/up2.log"
for attempt in $(seq 1 15); do
    if [[ ! -e /root/openvpn-clients/up2.ovpn ]]; then break; fi
    sleep 1
done
disconnect
[[ ! -e /root/openvpn-clients/up2.ovpn ]] || { echo 'FAIL: the connection left the file kept from rc.10.'; exit 1; }
echo 'PASS: a file rc.10 kept gets its whole time after the update, and its first connection then deletes it.'

# T34, L11 and C.12.12: Restore previous version goes back to the real rc.10. This code removes the units of
# connection events first; the script and its lines stay; rc.10's link service ends a link by asking OpenVPN.
printf '9\n4\n2\n' | darban | tee "$LOG/restore.log"
[[ $(darban version) == 1.0.0-rc.10 ]]
grep 'does not use connection events' "$LOG/restore.log" >/dev/null
[[ ! -e /etc/systemd/system/darban-events.path && ! -e /etc/systemd/system/darban-sweep.timer ]]
unmounted
[[ -x $EVENT_SCRIPT ]]
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
url=$(link_of up1)
connect "$LOG/up1.ovpn" "$LOG/restored.log"
gone_within "$url" 40
disconnect
journalctl -u darban-links.service --no-pager | grep 'link ended: up1 connected' >/dev/null
echo 'PASS: back on the real rc.10, every client connects, and its link service ends a link at the connection.'

# T54 and T20: rc.10's own uninstall does not know the event script or its lines, and leaves both.
printf 'uninstall\n' | darban uninstall | tee "$LOG/uninstall.log"
[[ ! -e /usr/local/sbin/darban ]]
[[ -x $EVENT_SCRIPT ]]
grep -qx "client-connect $EVENT_SCRIPT" "$CONF"
systemctl is-active --quiet "$UNIT"
connect "$LOG/up1.ovpn" "$LOG/uninstalled.log"; disconnect
echo "PASS: after rc.10's own uninstall, the script and its lines stay, and a client connects."

# T66: this code installed again finds its lines, needs no restart, and sees connections again.
before=$(last_connect)
start=$(date +%s); sleep 1
bash setup/install.sh | tee "$LOG/reinstall.log"
grep 'Connection events are on\.$' "$LOG/reinstall.log" >/dev/null
[[ $(starts_since "$start") == 0 ]]
systemctl is-active --quiet darban-events.path
connect "$LOG/up1.ovpn" "$LOG/reinstalled.log"
for attempt in $(seq 1 10); do
    if [[ $(last_connect) != "$before" ]]; then break; fi
    sleep 1
done
[[ $(last_connect) != "$before" ]]
disconnect
darban status >/dev/null
echo 'PASS: installed again, it needs no restart, and the connection reaches the client record.'

# T1 (#116): a UDP server from v1.0.1, the release before TCP, keeps its server.conf byte for byte when this code
# updates it, and its profiles keep connecting.
REL=v1.0.1
bash /usr/local/lib/darban/remove-server.sh --yes >"$LOG/remove.log" 2>&1
curl -fsSL --retry 3 -o "$LOG/rel.tar.gz" "https://github.com/MohZeh/Darban-OVPN/releases/download/$REL/darban-ovpn.tar.gz"
curl -fsSL --retry 3 -o "$LOG/REL-SHA256SUMS" "https://github.com/MohZeh/Darban-OVPN/releases/download/$REL/SHA256SUMS"
(cd "$LOG" && grep ' darban-ovpn.tar.gz$' REL-SHA256SUMS | sed 's/darban-ovpn.tar.gz$/rel.tar.gz/' | sha256sum -c -)
mkdir "$LOG/rel"
tar -xzf "$LOG/rel.tar.gz" -C "$LOG/rel"
(cd "$LOG/rel" && bash setup/server-setup.sh --yes --host 127.0.0.1 --port 1194) >"$LOG/rel-setup.log" 2>&1
(cd "$LOG/rel" && bash setup/install.sh) >"$LOG/rel-install.log" 2>&1
[[ $(darban version) == "${REL#v}" ]]
printf '1\nrel1\n0\n' | darban >/dev/null
cp /root/openvpn-clients/rel1.ovpn "$LOG/rel1.ovpn"
cp "$CONF" "$LOG/rel-server.conf"
bash setup/install.sh | tee "$LOG/rel-update.log"
cmp "$LOG/rel-server.conf" "$CONF" || { echo "FAIL: the update changed server.conf of a UDP server from $REL."; diff "$LOG/rel-server.conf" "$CONF" || true; exit 1; }
darban status >"$LOG/rel-status.log" 2>&1 || true
grep 'Listening on UDP 1194' "$LOG/rel-status.log" >/dev/null
connect "$LOG/rel1.ovpn" "$LOG/rel1.log"; disconnect
echo "PASS: after an update from $REL, server.conf of a UDP server is unchanged, and its profile connects."
echo 'All rc.10 checks passed.'

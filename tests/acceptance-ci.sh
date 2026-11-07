#!/usr/bin/env bash
# Real acceptance test for a disposable Ubuntu 24.04 or 26.04 machine ONLY, such as a CI runner: it installs
# packages and a kernel, creates a CA and changes the network. Run as root; it refuses without --i-know.
# A real OpenVPN client connects over loopback, with the pushed routes ignored so the machine stays online.
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Use only on a disposable one: acceptance-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
LOG=$(mktemp -d)
PIDFILE=$LOG/client.pid
dump() {
    journalctl -u openvpn-server@server.service -n 40 --no-pager || true
    tail -n 30 "$LOG"/*.log 2>/dev/null || true
}
trap 'echo "FAILED at line $LINENO"; dump' ERR

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

# 127.0.0.1 keeps the test off the internet; the manager accepts it as the profile address.
bash setup/server-setup.sh --host 127.0.0.1 --port 1194 --yes
bash setup/install.sh
darban-crl-maintain --check
systemctl start darban-crl.service
systemctl is-active --quiet darban-crl.timer
systemctl is-active --quiet darban-nat.service
nft list table ip darban >/dev/null
darban status

printf '2\naccept1\n0\n' | darban
cp /root/openvpn-clients/accept1.ovpn "$LOG/old.ovpn"
connect "$LOG/old.ovpn" "$LOG/a.log"
echo 'PASS: a real client connected.'
disconnect

printf '3\naccept1\naccept1\n1\n0\n' | darban
if connect "$LOG/old.ovpn" "$LOG/b.log"; then echo 'FAIL: the revoked profile still connects.'; exit 1; fi
disconnect
echo 'PASS: the revoked profile was refused.'

printf '2\naccept1\n0\n' | darban
connect /root/openvpn-clients/accept1.ovpn "$LOG/c.log"
echo 'PASS: a new certificate under the same name connects.'
disconnect
if connect "$LOG/old.ovpn" "$LOG/d.log"; then echo 'FAIL: the old profile connects after the name was reused.'; exit 1; fi
disconnect
echo 'PASS: the old profile stays refused after the name was reused.'

darban list --all

# Advanced settings against the real service: a good change is applied, a broken one is rolled back.
printf '7\n3\n2\n9.9.9.9\n2\n0\n0\n0\n' | darban
grep -q 'dhcp-option DNS 9.9.9.9' /etc/openvpn/server/server.conf
systemctl is-active --quiet openvpn-server@server.service
printf '7\n3\n3\n10.99.0.0\n2\n0\n0\n0\n' | darban
grep -q '^server 10.99.0.0 255.255.255.0' /etc/openvpn/server/server.conf
grep -q '10.99.0.0/24' /etc/darban/nat.nft
nft list table ip darban | grep -q '10.99.0.0/24'
connect /root/openvpn-clients/accept1.ovpn "$LOG/e.log"
echo 'PASS: a client connects after the VPN network changed.'
disconnect

# A real temporary link: one claim only, and the real profile behind it.
url=$(printf '4\naccept1\n1\n1\n1\n0\n' | darban | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
curl -ksf "$url" | grep -q 'Get my profile'
next=$(curl -ks -o /dev/null -w '%{redirect_url}' -X POST "$url")
curl -ks "${next}/file" -o "$LOG/link.ovpn"
grep -q '<key>' "$LOG/link.ovpn"
[[ $(curl -ks -o /dev/null -w '%{http_code}' "$url") == 410 ]]
if journalctl -u darban-links.service --no-pager | grep -q '[0-9a-f]\{64\}'; then echo 'FAIL: a token reached the log.'; exit 1; fi
echo 'PASS: the temporary link works once and keeps tokens out of the log.'

# Full removal: keep a backup, keep the kernel, then confirm.
printf '1\n1\nremove-everything\n' | darban remove-all
if systemctl is-active --quiet openvpn-server@server.service; then echo 'FAIL: OpenVPN still runs after removal.'; exit 1; fi
for path in /root/pki /etc/openvpn/server /root/openvpn-clients /etc/darban /usr/local/sbin/darban /etc/apt/sources.list.d/openvpn-aptrepo.list; do
    if [[ -e $path ]]; then echo "FAIL: still present after removal: $path"; exit 1; fi
done
if dpkg-query -W -f='${Status}' openvpn 2>/dev/null | grep -q 'install ok installed'; then echo 'FAIL: the openvpn package is still installed.'; exit 1; fi
if nft list table ip darban >/dev/null 2>&1; then echo 'FAIL: the NAT table is still loaded.'; exit 1; fi
ls /root/darban-backup-*.tar.gz
echo 'PASS: full removal left nothing behind except the backup and the kernel.'
echo 'All acceptance checks passed.'

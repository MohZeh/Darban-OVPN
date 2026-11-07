#!/usr/bin/env bash
# Real acceptance test for a disposable Ubuntu 24.04 or 26.04 machine ONLY, such as a CI runner: it installs
# packages and a kernel, creates a CA and changes the network and firewall. Run as root; it refuses without
# --i-know. The questions are answered in a real terminal, as a person would. Clients connect over loopback,
# and one more runs in its own network namespace to send real traffic through the tunnel and the NAT.
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Use only on a disposable one: acceptance-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
LOG=$(mktemp -d)
PIDFILE=$LOG/client.pid
UNIT=openvpn-server@server.service
NS=darban-test
. /etc/os-release
dump() {
    journalctl -u "$UNIT" -n 40 --no-pager || true
    tail -n 30 "$LOG"/*.log 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
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
in_terminal() {
    # in_terminal <name> <seconds> <command...>: answers the command from $LOG/<name>.keys in a real terminal.
    local name=$1 seconds=$2
    shift 2
    python3 tests/pty-drive.py --timeout "$seconds" "$LOG/$name.keys" -- "$@" | tee "$LOG/$name.log"
}

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
    printf 'VPN port [1194] => \\r\n'
    if (( USE_UFW )); then printf 'Enter: Add the two rules => \\r\n'; fi
    printf 'Enter: Install now => \\r\n'
    printf '[5/5] Starting OpenVPN\n'
    printf 'OpenVPN is running on UDP 1194\n'
} > "$LOG/setup.keys"
in_terminal setup 600 bash setup/server-setup.sh "${setup_args[@]}"
grep -E 'Detected address|could not be detected' "$LOG/setup.log"
grep -qx setup_complete /etc/darban/.server-setup-started
if grep -q 'Unpacking\|Setting up' "$LOG/setup.log"; then echo 'FAIL: apt output reached the install screen.'; exit 1; fi
echo 'PASS: a real install in a real terminal, on a quiet screen.'
if (( USE_UFW )); then
    ufw status | grep -q '^1194/udp'
    ufw status | grep -q 'tun0'
    echo 'PASS: Enter added the two ufw rules.'
fi

bash setup/install.sh
darban-crl-maintain --check
systemctl start darban-crl.service
systemctl is-active --quiet darban-crl.timer
systemctl is-active --quiet darban-nat.service
nft list table ip darban >/dev/null
darban status

cat > "$LOG/welcome.keys" <<'EOF'
Open UDP 1194 in your server
Enter: Create a client => \r
Client name [client1] => accept1\r
Enter: Temporary link => 4\r
Kept on the server
Press Enter to return => \r
Choose [0-9] => 0\r
EOF
in_terminal welcome 60 darban welcome
cp /root/openvpn-clients/accept1.ovpn "$LOG/old.ovpn"
echo 'PASS: the first client was created from the end of the install.'

connect "$LOG/old.ovpn" "$LOG/a.log"
echo 'PASS: a real client connected.'
for attempt in $(seq 1 10); do
    if darban connected | grep -q accept1; then break; fi
    sleep 1
done
darban connected | grep -q accept1
echo 'PASS: the connected client is listed.'

# The tool waits for the connection after sharing, and another SSH user gets a copy it can read.
cat > "$LOG/share.keys" <<'EOF'
Choose [0-9] => 4\r
Number or name => accept1\r
Enter: Temporary link => 3\r
Enter: No password => \r
Enter: Windows => \r
Enter: Keep it and return => \r
accept1 is connected from => \r
Choose [0-9] => 0\r
EOF
in_terminal share 60 darban
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ $(stat -c '%U %a' "$home/accept1.ovpn") == "$SUDO_USER 600" ]]
    rm -f -- "$home/accept1.ovpn"
    echo 'PASS: the SSH user gets a private copy of the profile.'
fi
echo 'PASS: the tool saw the real connection after sharing.'

# Revoked while connected: only this session ends, without restarting OpenVPN for everyone.
printf '3\naccept1\naccept1\n0\n' | darban | tee "$LOG/revoke.log"
grep -q 'Active session of accept1 disconnected' "$LOG/revoke.log"
echo 'PASS: revoking ends the active session of that client alone.'
disconnect

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

# Advanced settings against the real service: a good change is applied, and a broken one is rolled back.
printf '7\n3\n2\n9.9.9.9\n2\n0\n0\n0\n' | darban
grep -q 'dhcp-option DNS 9.9.9.9' /etc/openvpn/server/server.conf
systemctl is-active --quiet "$UNIT"
mkdir -p "/etc/systemd/system/$UNIT.d"
printf '[Service]\nExecStartPre=/bin/sh -c "! grep -q 198.51.100.1 /etc/openvpn/server/server.conf"\n' > "/etc/systemd/system/$UNIT.d/acceptance.conf"
systemctl daemon-reload
printf '7\n3\n2\n198.51.100.1\n2\n0\n0\n0\n' | darban | tee "$LOG/rollback.log"
grep -q 'Rolled back' "$LOG/rollback.log"
if grep -q 198.51.100.1 /etc/openvpn/server/server.conf; then echo 'FAIL: the broken change stayed.'; exit 1; fi
grep -q 'dhcp-option DNS 9.9.9.9' /etc/openvpn/server/server.conf
systemctl is-active --quiet "$UNIT"
rm -rf "/etc/systemd/system/$UNIT.d"
systemctl daemon-reload
echo 'PASS: a change that stops the service is rolled back.'

printf '7\n3\n3\n10.99.0.0\n2\n0\n0\n0\n' | darban
grep -q '^server 10.99.0.0 255.255.255.0' /etc/openvpn/server/server.conf
grep -q '10.99.0.0/24' /etc/darban/nat.nft
nft list table ip darban | grep -q '10.99.0.0/24'
connect /root/openvpn-clients/accept1.ovpn "$LOG/e.log"
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
sed 's/^remote .*/remote 198.18.0.1 1194/' /root/openvpn-clients/accept1.ovpn > "$LOG/ns.ovpn"
ip netns exec "$NS" openvpn --config "$LOG/ns.ovpn" --daemon --writepid "$LOG/ns.pid" --log "$LOG/f.log" --verb 3
for attempt in $(seq 1 20); do
    if grep -q 'Initialization Sequence Completed' "$LOG/f.log"; then break; fi
    sleep 1
done
grep -q 'Initialization Sequence Completed' "$LOG/f.log"
ip netns exec "$NS" ip route get 1.1.1.1 | grep -q 'dev tun'
grep -q 'dhcp-option DNS 9.9.9.9' "$LOG/f.log"
through_vpn=$(ip netns exec "$NS" curl -4 -fsS --max-time 30 https://api.ipify.org)
from_server=$(curl -4 -fsS --max-time 30 https://api.ipify.org)
echo "Address seen through the VPN: $through_vpn; address of the server: $from_server"
[[ -n $through_vpn && $through_vpn == "$from_server" ]]
echo 'PASS: real traffic and DNS go through the tunnel and the NAT.'
if modinfo -k "$(uname -r)" ovpn >/dev/null 2>&1; then
    ip -d link show tun0 | grep -qw ovpn
    echo 'PASS: the server uses the in-kernel ovpn module (DCO).'
fi
# Clients are kept apart, and the cloud metadata service is out of their reach. First without the rule, to
# show what it prevents on this runner, then with it.
printf '2\naccept2\n0\n' | darban
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
echo "Without the rule: one client reaches another: $reach; metadata service answers: $(metadata)"
systemctl restart darban-nat.service
nft list chain ip darban forward >/dev/null
if ip netns exec "$NS-b" ping -c 2 -W 2 "$first_ip" >/dev/null 2>&1; then echo 'FAIL: one client reaches another.'; exit 1; fi
if [[ $(metadata) == 200 ]]; then echo 'FAIL: a client reaches the cloud metadata service.'; exit 1; fi
echo 'PASS: clients are kept apart, and away from the cloud metadata service.'
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

# A real temporary link: one claim only, and the real profile behind it.
url=$(printf '4\naccept1\n1\n1\n1\n0\n' | darban | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
curl -ksf "$url" | grep -q 'Get my profile'
next=$(curl -ks -o /dev/null -w '%{redirect_url}' -X POST "$url")
curl -ks "${next}/file" -o "$LOG/link.ovpn"
grep -q '<key>' "$LOG/link.ovpn"
[[ $(curl -ks -o /dev/null -w '%{http_code}' "$url") == 410 ]]
if journalctl -u darban-links.service --no-pager | grep -q '[0-9a-f]\{64\}'; then echo 'FAIL: a token reached the log.'; exit 1; fi
echo 'PASS: the temporary link works once and keeps tokens out of the log.'

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
echo 'PASS: an update adds the rule to an older install.'

# A real update and the way back. The new version is this one under another number.
current=$(darban version)
next=$(mktemp -d)
cp -r setup bin lib systemd VERSION "$next/"
sed -i 's/^DARBAN_VERSION=.*/DARBAN_VERSION=9.9.9/' "$next/bin/darban"
echo 9.9.9 > "$next/VERSION"
bash "$next/setup/install.sh"
[[ $(darban version) == 9.9.9 ]]
systemctl is-active --quiet "$UNIT"
printf '9\n2\n2\n' | darban
[[ $(darban version) == "$current" ]]
darban status >/dev/null
echo 'PASS: an update installs, and Restore previous version goes back.'

# Removing only the tool keeps the VPN running, and installing it again finds everything.
printf 'uninstall\n' | darban uninstall
[[ ! -e /usr/local/sbin/darban ]]
systemctl is-active --quiet "$UNIT"
bash setup/install.sh
darban status >/dev/null
echo 'PASS: the tool can be removed and installed again without touching the VPN.'

# Full removal: keep a backup, keep any kernel the setup added, then confirm.
kernel_answer=''
if [[ $(bash /usr/local/lib/darban/remove-server.sh --kernel-status) == removable ]]; then kernel_answer='1\n'; fi
printf "1\\n${kernel_answer}remove-everything\\n" | darban remove-all
if systemctl is-active --quiet "$UNIT"; then echo 'FAIL: OpenVPN still runs after removal.'; exit 1; fi
for path in /root/pki /etc/openvpn/server /root/openvpn-clients /etc/darban /usr/local/sbin/darban /etc/apt/sources.list.d/openvpn-aptrepo.list /var/log/darban-setup.log; do
    if [[ -e $path ]]; then echo "FAIL: still present after removal: $path"; exit 1; fi
done
if dpkg-query -W -f='${Status}' openvpn 2>/dev/null | grep -q 'install ok installed'; then echo 'FAIL: the openvpn package is still installed.'; exit 1; fi
if nft list table ip darban >/dev/null 2>&1; then echo 'FAIL: the NAT table is still loaded.'; exit 1; fi
if (( USE_UFW )) && ufw status | grep -q '1194\|tun0'; then echo 'FAIL: the ufw rules are still there.'; exit 1; fi
ls /root/darban-backup-*.tar.gz
echo 'PASS: full removal left nothing behind except the backup and the kernel.'
echo 'All acceptance checks passed.'

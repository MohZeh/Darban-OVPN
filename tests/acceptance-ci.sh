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
Enter: Temporary link => 2\r
Kept on the server
Enter: Copy the Windows command => 4\r
Waiting for accept1 to connect => \r
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
Choose [0-9] => 5\r
Number or name => accept1\r
Enter: Temporary link => 2\r
Enter: Copy the Windows command => 4\r
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
printf '4\naccept1\naccept1\n0\n' | darban | tee "$LOG/revoke.log"
grep -q 'Active session of accept1 disconnected' "$LOG/revoke.log"
echo 'PASS: revoking ends the active session of that client alone.'
disconnect

if connect "$LOG/old.ovpn" "$LOG/b.log"; then echo 'FAIL: the revoked profile still connects.'; exit 1; fi
disconnect
echo 'PASS: the revoked profile was refused.'

printf '1\naccept1\n0\n' | darban
connect /root/openvpn-clients/accept1.ovpn "$LOG/c.log"
echo 'PASS: a new certificate under the same name connects.'
disconnect
if connect "$LOG/old.ovpn" "$LOG/d.log"; then echo 'FAIL: the old profile connects after the name was reused.'; exit 1; fi
disconnect
echo 'PASS: the old profile stays refused after the name was reused.'

darban list --all

# Advanced settings against the real service: a good change is applied, and a broken one is rolled back.
printf '7\n6\n2\n9.9.9.9\n2\n0\n0\n0\n' | darban
grep -q 'dhcp-option DNS 9.9.9.9' /etc/openvpn/server/server.conf
systemctl is-active --quiet "$UNIT"
mkdir -p "/etc/systemd/system/$UNIT.d"
printf '[Service]\nExecStartPre=/bin/sh -c "! grep -q 198.51.100.1 /etc/openvpn/server/server.conf"\n' > "/etc/systemd/system/$UNIT.d/acceptance.conf"
systemctl daemon-reload
printf '7\n6\n2\n198.51.100.1\n2\n0\n0\n0\n' | darban | tee "$LOG/rollback.log"
grep -q 'Rolled back' "$LOG/rollback.log"
if grep -q 198.51.100.1 /etc/openvpn/server/server.conf; then echo 'FAIL: the broken change stayed.'; exit 1; fi
grep -q 'dhcp-option DNS 9.9.9.9' /etc/openvpn/server/server.conf
systemctl is-active --quiet "$UNIT"
rm -rf "/etc/systemd/system/$UNIT.d"
systemctl daemon-reload
echo 'PASS: a change that stops the service is rolled back.'

printf '7\n6\n3\n10.99.0.0\n2\n0\n0\n0\n' | darban
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
# A path with a smaller MTU that drops IP fragments, as many mobile and home networks do: without the TCP
# size rule a website does not load through the VPN, with it it does. Fragments are dropped before the
# kernel would put them together again.
website() { ip netns exec "$NS" curl -4 -sS -o /dev/null --max-time 20 -w '%{size_download}' https://www.google.com/ 2>/dev/null || true; }
ip link set dt0 mtu 1400
ip netns exec "$NS" ip link set dt1 mtu 1400
nft add table ip darbantest
nft add chain ip darbantest pre '{ type filter hook prerouting priority -500; }'
nft add rule ip darbantest pre iifname dt0 ip frag-off '&' 0x3fff != 0 drop
ip netns exec "$NS" nft add table ip darbantest
ip netns exec "$NS" nft add chain ip darbantest pre '{ type filter hook prerouting priority -500; }'
ip netns exec "$NS" nft add rule ip darbantest pre iifname dt1 ip frag-off '&' 0x3fff != 0 drop
for handle in $(nft -a list chain ip darban forward | awk '/maxseg/ {print $NF}'); do nft delete rule ip darban forward handle "$handle"; done
without=$(website)
echo "Without the TCP size rule, on a 1400-byte path that drops fragments: ${without:-0} bytes of a website arrived"
darban status >"$LOG/no-mss.log" 2>&1 || true
grep -q 'The TCP MSS rule for VPN traffic is missing or different' "$LOG/no-mss.log"
systemctl restart darban-nat.service
with=$(website)
echo "With the rule: ${with:-0} bytes arrived"
if [[ ! ${with:-0} =~ ^[0-9]+$ ]] || (( ${with:-0} < 10000 )); then echo 'FAIL: a website did not load through the VPN on a path with a smaller MTU.'; exit 1; fi
if [[ ${without:-0} =~ ^[0-9]+$ ]] && (( ${without:-0} >= 10000 )); then
    echo 'NOTE: this runner did not lose large packets even without the rule, so only the result with it is judged.'
fi
darban status >"$LOG/mss.log" 2>&1
grep -q 'TCP MSS for VPN traffic is limited to 1280 in both directions' "$LOG/mss.log"
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

# A real temporary link: it can be opened again until the client connects, and then it ends. The link
# service asks the real management interface, from inside its sandbox.
url=$(printf '5\naccept1\n1\n1\n0\n' | darban | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
curl -ksf "$url" | grep -q 'Download profile'
curl -ksf -H 'Accept-Language: fa-IR,fa;q=0.9' "$url" | grep -q 'dir="rtl"'
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
journalctl -u darban-links.service --no-pager | grep -q 'link ended: accept1 connected'
if journalctl -u darban-links.service --no-pager | grep -q '[0-9a-f]\{64\}'; then echo 'FAIL: a token reached the log.'; exit 1; fi
echo 'PASS: the temporary link works until the first connection, and keeps tokens out of the log.'

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

# A real update and the way back. The new version is this one under another number.
current=$(darban version)
next=$(mktemp -d)
cp -r setup bin lib systemd VERSION "$next/"
sed -i 's/^DARBAN_VERSION=.*/DARBAN_VERSION=9.9.9/' "$next/bin/darban"
echo 9.9.9 > "$next/VERSION"
bash "$next/setup/install.sh"
[[ $(darban version) == 9.9.9 ]]
systemctl is-active --quiet "$UNIT"
printf '9\n4\n2\n' | darban
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

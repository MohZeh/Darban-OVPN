#!/usr/bin/env bash
# Real reboot test: sets up a server inside a fresh Ubuntu cloud image, reboots it, and connects a real client
# from outside. Needs root, KVM, qemu and an OpenVPN client on this machine.
#   vm-reboot.sh --i-know 24.04|26.04
set -Eeuo pipefail
[[ ${1:-} == --i-know && -n ${2:-} ]] || { echo 'Usage: vm-reboot.sh --i-know 24.04|26.04' >&2; exit 2; }
version=$2
case $version in
    24.04) suite=noble ;;
    26.04) suite=resolute ;;
    *) echo "Unknown version: $version" >&2; exit 2 ;;
esac
[[ -c /dev/kvm ]] || { echo 'This test needs KVM.' >&2; exit 1; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

WORK=$(mktemp -d)
IMAGE=ubuntu-$version-server-cloudimg-amd64.img
URL=https://cloud-images.ubuntu.com/releases/$suite/release
SSH_PORT=2222
UDP_PORT=11194
QEMU_PID=''
CLIENT_PID=$WORK/client.pid

in_vm() {
    ssh -i "$WORK/key" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR ubuntu@127.0.0.1 "$@"
}
finish() {
    local rc=$?
    if (( rc != 0 )); then
        echo "FAILED with status $rc"
        in_vm 'sudo journalctl -u openvpn-server@server -n 30 --no-pager; sudo tail -n 30 /var/log/darban-setup.log' 2>/dev/null || true
        tail -n 40 "$WORK/console.log" 2>/dev/null || true
        tail -n 20 "$WORK/client.log" 2>/dev/null || true
    fi
    if [[ -s $CLIENT_PID ]]; then kill "$(cat "$CLIENT_PID")" 2>/dev/null || true; fi
    if [[ -s $WORK/qemu.pid ]]; then kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true; fi
    rm -rf -- "$WORK"
}
trap finish EXIT
wait_for_ssh() {
    local attempt
    for attempt in $(seq 1 90); do
        if in_vm true 2>/dev/null; then return 0; fi
        sleep 5
    done
    echo 'The virtual machine did not answer SSH.' >&2
    return 1
}

echo "Fresh Ubuntu $version image"
curl -fsSL --retry 3 --max-time 600 -o "$WORK/$IMAGE" "$URL/$IMAGE"
curl -fsSL --retry 3 --max-time 60 -o "$WORK/SHA256SUMS" "$URL/SHA256SUMS"
(cd "$WORK" && grep -E " \*?$IMAGE\$" SHA256SUMS | sha256sum -c -)
qemu-img create -q -f qcow2 -b "$WORK/$IMAGE" -F qcow2 "$WORK/disk.qcow2" 12G
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
cat > "$WORK/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$WORK/key.pub")
EOF
cloud-localds "$WORK/seed.img" "$WORK/user-data"
qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -display none -daemonize -pidfile "$WORK/qemu.pid" \
    -serial "file:$WORK/console.log" \
    -drive "file=$WORK/disk.qcow2,if=virtio" -drive "file=$WORK/seed.img,if=virtio,format=raw" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=udp:127.0.0.1:$UDP_PORT-:1194" \
    -device virtio-net-pci,netdev=n0
wait_for_ssh
in_vm 'cloud-init status --wait >/dev/null 2>&1 || true'

git ls-files -z | tar --null -T - -czf "$WORK/repo.tar.gz"
in_vm 'mkdir -p repo && tar -xzf - -C repo' < "$WORK/repo.tar.gz"

before=$(in_vm 'uname -r')
in_vm 'cd repo && sudo bash setup/server-setup.sh --yes --host 127.0.0.1 --port 1194 && sudo bash setup/install.sh'
kernel_added=0
if in_vm "sudo grep -q '^kernel ' /etc/darban/.server-setup-started"; then kernel_added=1; fi
if (( kernel_added )); then
    in_vm 'sudo darban welcome </dev/null' | grep 'Reboot once' >/dev/null
    echo "PASS: kernel $before had no ovpn module, so a kernel was added and a reboot is asked for."
else
    in_vm 'sudo modinfo -k "$(uname -r)" ovpn >/dev/null'
    if in_vm 'sudo darban welcome </dev/null' | grep 'Reboot once' >/dev/null; then echo 'FAIL: a reboot was asked for without a need.'; exit 1; fi
    echo "PASS: kernel $before already has the ovpn module, so nothing was added and no reboot is asked for."
fi
in_vm "printf '1\nvmclient\n0\n' | sudo darban" >/dev/null
in_vm 'sudo cat /root/openvpn-clients/vmclient.ovpn' | sed "s/^remote .*/remote 127.0.0.1 $UDP_PORT/" > "$WORK/client.ovpn"

in_vm 'sudo reboot' || true
sleep 15
wait_for_ssh
in_vm 'cloud-init status --wait >/dev/null 2>&1 || true'
after=$(in_vm 'uname -r')
echo "Kernel before the reboot: $before; after: $after"
if (( kernel_added )); then [[ $after != "$before" ]]; fi
for attempt in $(seq 1 30); do
    if in_vm 'systemctl is-active --quiet openvpn-server@server.service'; then break; fi
    sleep 2
done
in_vm 'systemctl is-active --quiet openvpn-server@server.service'
in_vm 'systemctl is-active --quiet darban-nat.service'
in_vm 'systemctl is-active --quiet darban-crl.timer'
in_vm 'sudo nft list table ip darban >/dev/null'
in_vm 'test "$(sysctl -n net.ipv4.ip_forward)" = 1'
# The expiry timer is transient. The first sweep (one minute after boot, with 10 s accuracy) rebuilds it from
# the kept files. SSH and OpenVPN can be ready before that sweep; wait for its result before checking health.
for attempt in $(seq 1 45); do
    if in_vm 'systemctl is-active --quiet darban-expire.timer'; then break; fi
    sleep 2
done
in_vm 'systemctl is-active --quiet darban-expire.timer'
echo 'PASS: the first sweep after the reboot restores the expiry timer for the kept file.'
in_vm 'sudo darban status' | tee "$WORK/status.log"
grep -q 'DCO kernel module: ovpn' "$WORK/status.log"
in_vm 'ip -d link show tun0' | grep -w ovpn >/dev/null
echo 'PASS: after the reboot the service, NAT, timer and forwarding are back, and the server uses DCO.'
# T27 and T59: the queue of connection events is a tmpfs again, made ready at boot, and its jobs run.
in_vm 'test "$(findmnt -n -o FSTYPE /run/darban-events)" = tmpfs && test -e /run/darban-events/.mounted'
in_vm 'systemctl is-active --quiet darban-events.path && systemctl is-active --quiet darban-sweep.timer'
grep -q 'Connection events are seen' "$WORK/status.log"
echo 'PASS: after the reboot the queue of connection events is mounted again, and its jobs run.'

openvpn --config "$WORK/client.ovpn" --route-nopull --dev tun9 --daemon --writepid "$CLIENT_PID" --log "$WORK/client.log" --verb 3
for attempt in $(seq 1 30); do
    if grep -q 'Initialization Sequence Completed' "$WORK/client.log"; then break; fi
    sleep 1
done
grep -q 'Initialization Sequence Completed' "$WORK/client.log"
in_vm 'sudo darban connected' | grep vmclient >/dev/null
for attempt in $(seq 1 10); do
    if in_vm 'sudo grep -q ^last_connect= /var/lib/darban/clients/vmclient'; then break; fi
    sleep 1
done
in_vm 'sudo grep -q ^last_connect= /var/lib/darban/clients/vmclient'
# The file kept on the server was made in the boot before, so this first connection deletes it.
for attempt in $(seq 1 10); do
    if ! in_vm 'sudo test -e /root/openvpn-clients/vmclient.ovpn'; then break; fi
    sleep 1
done
if in_vm 'sudo test -e /root/openvpn-clients/vmclient.ovpn'; then echo 'FAIL: the first connection after the reboot left the kept file.'; exit 1; fi
ping -c 3 -W 5 -I tun9 10.8.0.1 >/dev/null
echo 'PASS: a profile made before the reboot connects from outside, and data flows through the tunnel.'
kill "$(cat "$CLIENT_PID")" 2>/dev/null || true
sleep 1
ip link del tun9 2>/dev/null || true

# T65 and C.15.8: a restore stopped after each of its four renames, then a real reboot: OpenVPN stays off after the
# boot, and the next run of the tool finishes the restore.
in_vm 'sudo apt-get -o Acquire::Retries=3 -qq update && sudo apt-get -o Acquire::Retries=3 -y -q install age >/dev/null'
in_vm 'age-keygen -o owner.key 2>/dev/null && age-keygen -y owner.key > owner.pub'
in_vm 'printf "8\n4\n%s\n0\n0\n" "$(cat owner.pub)" | sudo darban >/dev/null'
in_vm 'sudo age -d -i owner.key -o backup.tar "$(sudo readlink -f /var/backups/darban-pki/latest.tar.age)"'
fp=$(in_vm "sudo openssl x509 -in /root/pki/ca.crt -noout -fingerprint -sha256 | sed 's/^[^=]*=//'")
for step in 1 2 3 4; do
    in_vm "printf '2\n' | sudo DARBAN_TEST_RESTORE_STOP=$step darban restore backup.tar --ca-fingerprint '$fp' >/dev/null 2>&1" || true
    in_vm 'sudo test -s /var/lib/darban/restore.journal'
    in_vm 'sudo reboot' || true
    sleep 15
    wait_for_ssh
    in_vm 'cloud-init status --wait >/dev/null 2>&1 || true'
    sleep 10
    if in_vm 'systemctl is-active --quiet openvpn-server@server.service'; then echo "FAIL: OpenVPN started at boot during a restore stopped after rename $step."; exit 1; fi
    in_vm 'sudo darban status || true' | grep 'A restore is unfinished' >/dev/null
    in_vm 'sudo darban restore --resume </dev/null'
    in_vm 'systemctl is-active --quiet openvpn-server@server.service && systemctl is-enabled --quiet openvpn-server@server.service'
    in_vm 'sudo test ! -e /var/lib/darban/restore.journal'
    echo "T65: stopped after rename $step, then a reboot: OpenVPN stayed off, and the resume finished the restore."
done
openvpn --config "$WORK/client.ovpn" --route-nopull --dev tun9 --daemon --writepid "$CLIENT_PID" --log "$WORK/client2.log" --verb 3
for attempt in $(seq 1 30); do
    if grep -q 'Initialization Sequence Completed' "$WORK/client2.log"; then break; fi
    sleep 1
done
grep -q 'Initialization Sequence Completed' "$WORK/client2.log"
ping -c 3 -W 5 -I tun9 10.8.0.1 >/dev/null
echo 'PASS: after every stopped restore and reboot, OpenVPN stays off until the resume, and the profile connects after it.'
echo 'All reboot checks passed.'

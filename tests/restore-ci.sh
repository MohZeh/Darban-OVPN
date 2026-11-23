#!/usr/bin/env bash
# D5 on a disposable machine, such as a CI runner: a real backup encrypted with age, a restore refused for a client
# revoked since, an archive changed to run a program refused before any change, and the way back from a lost server:
# everything removed, a new server with a new CA, the backup restored, and the profiles made before connecting.
#   restore-ci.sh --i-know
set -Eeuo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Usage: restore-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
LOG=$(mktemp -d)
PIDFILE=$LOG/client.pid
UNIT=openvpn-server@server.service
CONF=/etc/openvpn/server/server.conf
KEPT=/root/openvpn-clients
BACKUPS=/var/backups/darban-pki
trap 'echo "FAILED at line $LINENO"; journalctl -u "$UNIT" -n 30 --no-pager || true; tail -n 30 "$LOG"/*.log 2>/dev/null || true' ERR

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
disconnect() { if [[ -s $PIDFILE ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; ip link del tun9 2>/dev/null || true; fi; }
fingerprint() { openssl x509 -in /root/pki/ca.crt -noout -fingerprint -sha256 | sed 's/^[^=]*=//'; }
state() { sha256sum /root/pki/index.txt /root/pki/ca.crt "$CONF" /etc/openvpn/server/crl.pem; }

apt-get -o Acquire::Retries=3 -qq update
apt-get -o Acquire::Retries=3 -y -q install age >/dev/null
bash setup/server-setup.sh --yes --host 127.0.0.1 --port 1194 >"$LOG/setup.log" 2>&1
bash setup/install.sh >"$LOG/install.log" 2>&1
age-keygen -o "$LOG/owner.key" 2>/dev/null
recipient=$(age-keygen -y "$LOG/owner.key")
for name in a1 b1; do printf '1\n%s\n0\n' "$name" | darban >/dev/null; cp "$KEPT/$name.ovpn" "$LOG/$name.ovpn"; done
printf '4\nb1\nb1\n0\n' | darban >/dev/null
# A TCP MSS set in Settings > Advanced goes into the backup with the tool's settings.
printf '7\n6\n9\n1400\n0\n0\n0\n' | darban >/dev/null
grep -qx 'TCP_MSS=1400' /etc/darban/config
# T1 (#116): the server listens on UDP and TCP when the backup is made, so the restore on a new server below brings
# both back. a1's profile, pointed at the TCP port, proves the TCP listener after it.
printf '7\n2\n3\n4443\n2\n0\n0\n0\n' | darban >"$LOG/both.log" 2>&1
grep -qx 'local \* 1194 udp' "$CONF" && grep -qx 'local \* 4443 tcp' "$CONF"
sed -e 's/^proto udp4$/proto tcp4/' -e 's/^remote 127.0.0.1 1194$/remote 127.0.0.1 4443/' "$LOG/a1.ovpn" >"$LOG/a1-tcp.ovpn"
grep -qx 'remote 127.0.0.1 4443' "$LOG/a1-tcp.ovpn"
connect "$LOG/a1-tcp.ovpn" "$LOG/a1-tcp-before.log"; disconnect

# D5: Backup now with the owner's public key. The server encrypts it, and only the owner's key opens it.
printf '8\n4\n%s\n0\n0\n' "$recipient" | darban | tee "$LOG/backup.log"
grep 'Backup made:' "$LOG/backup.log" >/dev/null
grep 'This copy is on this server' "$LOG/backup.log" >/dev/null
fp=$(fingerprint)
grep -F "$fp" "$LOG/backup.log" >/dev/null
archive=$(readlink -f "$BACKUPS/latest.tar.age")
[[ $(stat -c '%U %a' "$BACKUPS") == 'root 700' && $(stat -c '%a' "$archive") == 600 ]]
if tar -tf "$archive" >/dev/null 2>&1; then echo 'FAIL: the backup can be read without the key.'; exit 1; fi
age -d -i "$LOG/owner.key" -o "$LOG/backup.tar" "$archive"
tar -tf "$LOG/backup.tar" | tee "$LOG/members.log"
grep -qx 'pki/private/ca.key' "$LOG/members.log"
if grep -q 'nat.nft\|backup.conf\|\.ovpn$' "$LOG/members.log"; then echo 'FAIL: the backup holds a file outside its list.'; exit 1; fi
python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); assert m["schema"] == 1 and m["clients"] == {"valid": 2, "revoked": 1}, m' "${archive%.tar.age}.manifest.json"
echo 'PASS: Backup now makes an archive only the owner can open, with the closed list and a manifest.'

# R18-11 and C.16.3: the daily backup comes after the CRL job. Starting darban-crl.service runs darban-backup.service
# once it succeeds; that makes a backup when something changed, and none when nothing did.
backups() { find "$BACKUPS" -maxdepth 1 -name 'darban-pki-*.tar.age' | wc -l; }
daily_backup_after_crl_job() {
    # Starts the CRL job, and waits until the backup it starts has really run, and ended: a unit that never ran
    # reports success too, so its invocation must be a new one.
    local before attempt
    before=$(systemctl show -p InvocationID --value darban-backup.service)
    systemctl start darban-crl.service
    for attempt in $(seq 1 60); do
        if [[ $(systemctl show -p InvocationID --value darban-backup.service) != "$before" ]] \
            && ! systemctl is-active --quiet darban-backup.service; then
            [[ $(systemctl show -p Result --value darban-backup.service) == success ]]
            return
        fi
        sleep 1
    done
    echo 'FAIL: the CRL job did not start the daily backup.'
    return 1
}
count=$(backups)
daily_backup_after_crl_job
[[ $(backups) == "$count" ]]
mkdir -p /var/lib/darban/clients
printf 'first_seen=1\n' > /var/lib/darban/clients/zz-ci
daily_backup_after_crl_job
[[ $(backups) == $((count + 1)) ]]
rm -f /var/lib/darban/clients/zz-ci
echo 'PASS: a successful CRL job runs the daily backup, which makes one only when something changed.'

# T22, I13 and C.16.1: a client issued and revoked on this server after the backup is never valid again: the
# backup is older than the CA in use, so it is refused, and names it.
printf '1\nc1\n0\n' | darban >/dev/null
printf '4\nc1\nc1\n0\n' | darban >/dev/null
before=$(state)
if printf '2\n' | darban restore "$LOG/backup.tar" --ca-fingerprint "$fp" 2>&1 | tee "$LOG/revoked-since.log"; then echo 'FAIL: the restore would make c1 valid again.'; exit 1; fi
grep 'this backup is older than the CA in use here' "$LOG/revoked-since.log" >/dev/null
grep 'c1 (serial ' "$LOG/revoked-since.log" >/dev/null
[[ $(state) == "$before" ]]
systemctl is-active --quiet "$UNIT"
echo 'PASS: a restore older than the CA in use is refused, and names the client issued and revoked since.'

# T64 and C.15.9: the same archive with a line that runs a program is refused before anything changes.
python3 - "$LOG/backup.tar" "$LOG/up.tar" <<'PY'
import hashlib, io, json, sys, tarfile
src = tarfile.open(sys.argv[1])
files = {m.name: src.extractfile(m).read() for m in src.getmembers() if m.isreg()}
files['server/server.conf'] += b'up /bin/sh\n'
manifest = json.loads(files.pop('manifest.json'))
manifest['members'] = {n: {'sha256': hashlib.sha256(d).hexdigest(), 'size': len(d)} for n, d in files.items()}
with tarfile.open(sys.argv[2], 'w') as tar:
    for name, data in [('manifest.json', json.dumps(manifest).encode())] + sorted(files.items()):
        info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o600
        tar.addfile(info, io.BytesIO(data))
PY
if printf '2\n' | darban restore "$LOG/up.tar" --ca-fingerprint "$fp" 2>&1 | tee "$LOG/up.log"; then echo 'FAIL: an archive with "up /bin/sh" was restored.'; exit 1; fi
grep 'lines this tool does not restore' "$LOG/up.log" >/dev/null
grep 'Nothing on this server was changed' "$LOG/up.log" >/dev/null
[[ $(state) == "$before" && ! -e /var/lib/darban/restore.journal ]]
systemctl is-active --quiet "$UNIT"
echo 'PASS: an archive changed to run a program is refused, and nothing changes.'

# T53 and T33: the server is lost. A new one, with a new CA, gets the backup back, anchored by a profile from a
# device. Its revocations since cannot be known, and the restore says so.
bash /usr/local/lib/darban/remove-server.sh --yes >"$LOG/remove.log" 2>&1
[[ ! -e /root/pki ]]
bash setup/server-setup.sh --yes --host 127.0.0.1 --port 1194 >"$LOG/setup2.log" 2>&1
bash setup/install.sh >"$LOG/install2.log" 2>&1
[[ $(fingerprint) != "$fp" ]]
[[ $(grep -c -F 'tcp option maxseg size > 1330 tcp option maxseg size set 1330' /etc/darban/nat.nft) == 4 ]]
if connect "$LOG/a1.ovpn" "$LOG/before-restore.log"; then echo 'FAIL: a profile of the old CA connected to the new one.'; exit 1; fi
disconnect
host=$(hostname -s | tr -cd 'A-Za-z0-9.-')
printf '%s\n' "${host:-server}" | darban restore "$LOG/backup.tar" --ca-from "$LOG/a1.ovpn" 2>&1 | tee "$LOG/restore.log"
grep 'Revocations and certificates issued after' "$LOG/restore.log" >/dev/null
grep 'then deleted' "$LOG/restore.log" >/dev/null
grep 'Restored the backup of' "$LOG/restore.log" >/dev/null
[[ $(fingerprint) == "$fp" ]]
systemctl is-active --quiet "$UNIT"
systemctl is-enabled --quiet "$UNIT"
grep -qx "client-connect /usr/local/libexec/darban-ovpn-event" "$CONF"
connect "$LOG/a1.ovpn" "$LOG/after-restore.log"
disconnect
echo 'PASS: on a new server, the backup comes back, and a profile made before connects.'
grep -qx 'local \* 1194 udp' "$CONF" && grep -qx 'local \* 4443 tcp' "$CONF"
if grep -q '^port \|^proto ' "$CONF"; then echo 'FAIL: the restored server.conf of both has a port or proto line.'; exit 1; fi
grep -qx 'explicit-exit-notify 1' "$CONF"
ss -H -ltn 'sport = :4443' | grep -q LISTEN
connect "$LOG/a1-tcp.ovpn" "$LOG/a1-tcp-after.log"; disconnect
grep -q 'TCP connection established' "$LOG/a1-tcp-after.log"
echo 'PASS: a backup of a server with UDP and TCP comes back with both, and a client connects over TCP.'
grep -qx 'TCP_MSS=1400' /etc/darban/config
[[ $(grep -c -F 'tcp option maxseg size > 1400 tcp option maxseg size set 1400' /etc/darban/nat.nft) == 4 ]]
nft list chain ip darban forward | grep 'maxseg size set 1400' >/dev/null
darban status >"$LOG/mss-status.log" 2>&1 || true
grep 'TCP MSS for VPN traffic is limited to 1400 in both directions' "$LOG/mss-status.log" >/dev/null
echo 'PASS: the TCP MSS set before the backup comes back with it, in the NAT rules too, and Diagnostics report it.'
if connect "$LOG/b1.ovpn" "$LOG/revoked.log"; then echo 'FAIL: a client revoked before the backup connected.'; exit 1; fi
disconnect
journalctl -u "$UNIT" --since '-60s' --no-pager | grep -i 'certificate revoked' >/dev/null
echo 'PASS: a client revoked before the backup is still refused.'
darban status >"$LOG/status.log" || true
grep 'revocations and certificates issued after it cannot be known' "$LOG/status.log" >/dev/null
darban restore --acknowledge | grep 'Acknowledged' >/dev/null
darban status >"$LOG/status2.log" || true
if grep 'revocations and certificates issued after it cannot be known' "$LOG/status2.log" >/dev/null; then echo 'FAIL: the warning stayed after it was acknowledged.'; exit 1; fi
printf '1\nd1\n0\n' | darban >/dev/null
cp "$KEPT/d1.ovpn" "$LOG/d1.ovpn"
connect "$LOG/d1.ovpn" "$LOG/new-client.log"
disconnect
echo 'PASS: Diagnostics warn until the owner acknowledges, and the restored CA issues clients that connect.'
echo 'All restore checks passed.'

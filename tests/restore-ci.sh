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

# T22 and I13: a client revoked on this server after the backup is never valid again.
printf '1\nc1\n0\n' | darban >/dev/null
printf '4\nc1\nc1\n0\n' | darban >/dev/null
before=$(state)
if printf '2\n' | darban restore "$LOG/backup.tar" --ca-fingerprint "$fp" | tee "$LOG/revoked-since.log"; then echo 'FAIL: the restore would make c1 valid again.'; exit 1; fi
grep 'this server revoked c1 after the backup was made' "$LOG/revoked-since.log" >/dev/null
[[ $(state) == "$before" ]]
systemctl is-active --quiet "$UNIT"
echo 'PASS: a restore that would make a client revoked since valid again is refused, and names it.'

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
if printf '2\n' | darban restore "$LOG/up.tar" --ca-fingerprint "$fp" | tee "$LOG/up.log"; then echo 'FAIL: an archive with "up /bin/sh" was restored.'; exit 1; fi
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
if connect "$LOG/a1.ovpn" "$LOG/before-restore.log"; then echo 'FAIL: a profile of the old CA connected to the new one.'; exit 1; fi
disconnect
host=$(hostname -s | tr -cd 'A-Za-z0-9.-')
printf '%s\n' "${host:-server}" | darban restore "$LOG/backup.tar" --ca-from "$LOG/a1.ovpn" | tee "$LOG/restore.log"
grep 'Revocations made after' "$LOG/restore.log" >/dev/null
grep 'Restored the backup of' "$LOG/restore.log" >/dev/null
[[ $(fingerprint) == "$fp" ]]
systemctl is-active --quiet "$UNIT"
systemctl is-enabled --quiet "$UNIT"
grep -qx "client-connect /usr/local/libexec/darban-ovpn-event" "$CONF"
connect "$LOG/a1.ovpn" "$LOG/after-restore.log"
disconnect
echo 'PASS: on a new server, the backup comes back, and a profile made before connects.'
if connect "$LOG/b1.ovpn" "$LOG/revoked.log"; then echo 'FAIL: a client revoked before the backup connected.'; exit 1; fi
disconnect
journalctl -u "$UNIT" --since '-60s' --no-pager | grep -i 'certificate revoked' >/dev/null
echo 'PASS: a client revoked before the backup is still refused.'
darban status >"$LOG/status.log" || true
grep 'revocations made after it cannot be known' "$LOG/status.log" >/dev/null
darban restore --acknowledge | grep 'Acknowledged' >/dev/null
darban status >"$LOG/status2.log" || true
if grep 'revocations made after it cannot be known' "$LOG/status2.log" >/dev/null; then echo 'FAIL: the warning stayed after it was acknowledged.'; exit 1; fi
printf '1\nd1\n0\n' | darban >/dev/null
cp "$KEPT/d1.ovpn" "$LOG/d1.ovpn"
connect "$LOG/d1.ovpn" "$LOG/new-client.log"
disconnect
echo 'PASS: Diagnostics warn until the owner acknowledges, and the restored CA issues clients that connect.'
echo 'All restore checks passed.'

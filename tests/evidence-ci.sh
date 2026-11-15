#!/usr/bin/env bash
# Runtime evidence for the v1.0.0 design (D3 connection events, D5 backup), on a disposable Ubuntu 24.04 or
# 26.04 CI runner ONLY. It installs packages, sets up a real server, changes server.conf and systemd units,
# and starts extra processes as nobody. Run as root; it refuses without --i-know.
#
# It changes no product code and decides nothing: each check records what the real system did, and the table
# goes to the job summary. A check that cannot run is recorded as such; the run goes on with the next one.
set -Euo pipefail
[[ ${1:-} == --i-know ]] || { echo 'This reconfigures the machine. Use only on a disposable one: evidence-ci.sh --i-know' >&2; exit 2; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
LOG=$(mktemp -d)
OUT=${EVIDENCE_OUT:-$LOG/evidence.md}
UNIT=openvpn-server@server.service
CONF=/etc/openvpn/server/server.conf
PKI=/root/pki
EASYRSA=/usr/share/easy-rsa/easyrsa
HOOK=/usr/local/libexec/darban-evidence-hook
ENVDIR=/run/darban-evidence-env
PIDFILE=$LOG/client.pid
. /etc/os-release
ARCH=$(dpkg --print-architecture)

# ---------- recording ----------
section() { printf '\n### %s\n\n| Check | Result |\n|---|---|\n' "$1" >>"$OUT"; echo "== $1"; }
record() {
    # record <check> <result>: one row; pipes and new lines are made safe for the table.
    local value=${2//|/\\|}
    value=${value//$'\n'/<br>}
    printf '| %s | %s |\n' "$1" "$value" >>"$OUT"
    printf '  %s: %s\n' "$1" "$2"
}
note() { printf '\n%s\n' "$1" >>"$OUT"; }
printf '## Runtime evidence: Ubuntu %s (%s)\n\nCommit `%s`. Nothing here is a pass or a fail; each row is what the system did.\n' \
    "$VERSION_ID" "$ARCH" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >"$OUT"

# ---------- a client, as the acceptance test runs one ----------
connect() {
    # connect <profile> <log>: prints "connected" or "refused" (no tunnel within 15 seconds).
    local attempt
    disconnect
    rm -f "$PIDFILE" "$2"
    openvpn --config "$1" --route-nopull --dev tun9 --daemon --writepid "$PIDFILE" --log "$2" --verb 3
    for attempt in $(seq 1 15); do
        if grep -q 'Initialization Sequence Completed' "$2" 2>/dev/null; then echo connected; return 0; fi
        if grep -q 'AUTH_FAILED\|TLS Error\|VERIFY ERROR' "$2" 2>/dev/null; then break; fi
        sleep 1
    done
    echo refused
}
disconnect() { if [[ -s $PIDFILE ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 2; rm -f "$PIDFILE"; fi; }
server_says() { journalctl -u "$UNIT" --since "-${1}s" --no-pager -o cat 2>/dev/null | grep -iE "$2" | tail -n 3 | tr -s ' ' || true; }
restart_server() { systemctl restart "$UNIT" && sleep 2 && systemctl is-active --quiet "$UNIT"; }
profile_for() {
    # profile_for <name> <out>: the first client's profile with this client's certificate and key.
    python3 - "$LOG/base.ovpn" "$PKI/issued/$1.crt" "$PKI/private/$1.key" "$2" <<'PY'
import re, sys
base, crt, key, out = sys.argv[1:]
text = open(base).read()
cert = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', open(crt).read(), re.S).group(0)
text = re.sub(r'<cert>.*?</cert>', '<cert>\n' + cert + '\n</cert>', text, flags=re.S)
text = re.sub(r'<key>.*?</key>', '<key>\n' + open(key).read().strip() + '\n</key>', text, flags=re.S)
open(out, 'w').write(text)
PY
}
easyrsa() { env EASYRSA_PKI="$PKI" EASYRSA_BATCH=1 "$EASYRSA" "$@" </dev/null >>"$LOG/easyrsa.log" 2>&1; }
publish_crl() { install -o root -g root -m "${1:-644}" "$PKI/crl.pem" /etc/openvpn/server/crl.pem; }

# ---------- 1. versions ----------
section 'Versions and system facts'
apt-get -o Acquire::Retries=3 -q update >/dev/null
apt-get -o Acquire::Retries=3 -y -q install faketime >/dev/null 2>&1 || true
record 'Ubuntu, kernel' "$VERSION_ID, $(uname -r)"
record 'systemd' "$(systemctl --version | head -n 1)"
record 'bash' "${BASH_VERSION} (EPOCHREALTIME: ${EPOCHREALTIME:+yes})"
record 'coreutils mv' "$(mv --version | head -n 1)"
record 'Python' "$(python3 -c 'import sys, tarfile; print(sys.version.split()[0], "data_filter:", hasattr(tarfile, "data_filter"))')"
record 'fs.protected_hardlinks' "$(sysctl -n fs.protected_hardlinks 2>/dev/null || echo unknown)"
record 'age package' "$(apt-cache policy age 2>/dev/null | awk '/Candidate/ {print $2}' || echo unknown)"
record 'faketime' "$(command -v faketime >/dev/null && echo installed || echo 'not available')"

# ---------- 2. a real server and one client ----------
section 'Server set up the way a person does it'
{
    printf 'Server address => 127.0.0.1\\r\n'
    printf 'VPN port [ => 1194\\r\n'
    printf 'Enter: Install now => \\r\n'
    printf '[5/5] Starting OpenVPN\n'
    printf 'OpenVPN is running on UDP 1194\n'
} >"$LOG/setup.keys"
if python3 tests/pty-drive.py --timeout 600 "$LOG/setup.keys" -- bash setup/server-setup.sh >"$LOG/setup.log" 2>&1 \
    && bash setup/install.sh >"$LOG/install.log" 2>&1; then
    record 'Setup and install' 'done'
else
    record 'Setup and install' 'FAILED; the evidence below cannot be trusted'
    tail -n 40 "$LOG/setup.log" "$LOG/install.log"
    exit 1
fi
record 'OpenVPN' "$(openvpn --version | head -n 1)"
easyrsa build-client-full ev-alice nopass
easyrsa build-client-full ev-bob nopass
easyrsa build-client-full ev-carol nopass
# The base profile comes from the tool itself, so its options match the server exactly.
# The same answers as the acceptance test's first client.
cat >"$LOG/client.keys" <<'EOF'
Open UDP 1194 in your server
Enter: Create a client => \r
Client name [client1] => ev-base\r
Enter: Temporary link => 2\r
Kept on the server
Enter: Windows => \r
Enter: Copy the command => 2\r
Waiting for ev-base to connect => \r
Choose [0-9] => 0\r
EOF
python3 tests/pty-drive.py --timeout 60 "$LOG/client.keys" -- darban welcome >"$LOG/client.log" 2>&1 || true
if [[ -s /root/openvpn-clients/ev-base.ovpn ]]; then
    cp /root/openvpn-clients/ev-base.ovpn "$LOG/base.ovpn"
    record 'Base profile from the tool' 'made'
else
    record 'Base profile from the tool' "not made; see the log: $(tail -n 5 "$LOG/client.log")"
    exit 1
fi
profile_for ev-alice "$LOG/alice.ovpn"
profile_for ev-bob "$LOG/bob.ovpn"
profile_for ev-carol "$LOG/carol.ovpn"
record 'A client connects before any change' "$(connect "$LOG/alice.ovpn" "$LOG/c0.log")"
disconnect
cp "$CONF" "$LOG/server.conf.orig"

# ---------- 3. the OpenVPN unit as Ubuntu ships it ----------
section 'OpenVPN service unit (as packaged)'
record 'Unit file' "$(systemctl cat "$UNIT" 2>/dev/null | grep -E '^(LimitNPROC|TasksMax|ProtectSystem|ProtectHome|PrivateTmp|CapabilityBoundingSet|User)=' | tr '\n' ' ')"
record 'systemctl show' "$(systemctl show -p LimitNPROC,LimitNPROCSoft,TasksMax,ProtectSystem,ProtectHome "$UNIT" | tr '\n' ' ')"
pid=$(systemctl show -p MainPID --value "$UNIT")
record 'Running process: user, max processes' "$(awk '/^Uid:/ {print "uid", $2}' "/proc/$pid/status") / $(grep 'Max processes' "/proc/$pid/limits" | tr -s ' ')"

# ---------- 4. the environment each hook gets ----------
section 'Hook environment (client-connect, client-disconnect)'
install -d -o root -g root -m 0755 /usr/local/libexec
install -d -o nobody -g nogroup -m 0700 "$ENVDIR"
cat >"$HOOK" <<'EOF'
#!/bin/bash
# Evidence only: records the variables a Darban event would use, then exits 0.
dir=/run/darban-evidence-env
read -r up _ </proc/uptime 2>/dev/null || up=unreadable
read -r boot </proc/sys/kernel/random/boot_id 2>/dev/null || boot=unreadable
{
    for v in script_type common_name trusted_ip time_unix time_ascii bytes_received bytes_sent time_duration \
        tls_serial_0 tls_serial_hex_0 UV_DARBAN_SHARE IV_PLAT IV_VER; do
        printf '%s=%s\n' "$v" "${!v-<unset>}"
    done
    printf 'uid=%s\nEPOCHREALTIME=%s\nuptime=%s\nboot_id=%s\n' "$(id -u)" "${EPOCHREALTIME-<unset>}" "$up" "$boot"
} >"$dir/${script_type:-unknown}.$$.env" 2>/dev/null
exit 0
EOF
chmod 0755 "$HOOK"
set_hook() {
    # set_hook <path>: server.conf runs this file on connect and disconnect.
    cp "$LOG/server.conf.orig" "$CONF"
    printf 'script-security 2\nclient-connect %s\nclient-disconnect %s\n' "$1" "$1" >>"$CONF"
}
set_hook "$HOOK"
if restart_server; then record 'OpenVPN starts with the hook lines' 'yes'; else record 'OpenVPN starts with the hook lines' 'NO'; fi
record 'Connect with the hook' "$(connect "$LOG/alice.ovpn" "$LOG/c1.log")"
sleep 1
disconnect
sleep 2
for f in "$ENVDIR"/client-connect.*.env "$ENVDIR"/client-disconnect.*.env; do
    [[ -e $f ]] || continue
    record "$(basename "$f" | cut -d. -f1)" "$(grep -vE '^(IV_PLAT|IV_VER)=<unset>$' "$f" | tr '\n' ' ')"
done
[[ -n $(compgen -G "$ENVDIR/client-disconnect.*.env") ]] || record 'client-disconnect' 'no record written'
rm -f "$ENVDIR"/*.env
# A session that ends because the server stops.
connect "$LOG/alice.ovpn" "$LOG/c2.log" >/dev/null
systemctl stop "$UNIT"
sleep 2
record 'Server stop: client-disconnect ran' "$([[ -n $(compgen -G "$ENVDIR/client-disconnect.*.env") ]] && echo yes || echo no)"
disconnect
rm -f "$ENVDIR"/*.env
systemctl start "$UNIT"; sleep 2

# ---------- 5. a hook that cannot be run ----------
section 'Hook that OpenVPN cannot run'
install -d -o root -g root -m 0700 /usr/local/lib/darban-evidence-700
install -m 0755 "$HOOK" /usr/local/lib/darban-evidence-700/hook
set_hook /usr/local/lib/darban-evidence-700/hook
restart_server
record 'Hook inside a 0700 root directory' "$(connect "$LOG/alice.ovpn" "$LOG/c3.log") / server: $(server_says 20 'client-connect|execve|permission')"
disconnect
install -m 0644 "$HOOK" /usr/local/libexec/darban-evidence-noexec
set_hook /usr/local/libexec/darban-evidence-noexec
restart_server
record 'Hook without the execute bit' "$(connect "$LOG/alice.ovpn" "$LOG/c4.log") / server: $(server_says 20 'client-connect|execve|permission')"
disconnect
set_hook /usr/local/libexec/darban-evidence-missing
restart_server
record 'Hook file missing' "$(connect "$LOG/alice.ovpn" "$LOG/c5.log") / server: $(server_says 20 'client-connect|execve|No such')"
disconnect
cp "$LOG/server.conf.orig" "$CONF"
printf 'client-connect %s\nclient-disconnect %s\n' "$HOOK" "$HOOK" >>"$CONF"
restart_server
record 'Hook lines without script-security 2' "$(connect "$LOG/alice.ovpn" "$LOG/c6.log") / server: $(server_says 20 'script-security|external program')"
disconnect

# ---------- 6. the process limit after OpenVPN drops to nobody ----------
section 'Process limit for nobody (the fork that runs the hook)'
set_hook "$HOOK"
restart_server
sleepers=()
spawn_nobody() { local i; for (( i = 0; i < $1; i++ )); do runuser -u nobody -- sleep 900 & sleepers+=("$!"); done; sleep 1; }
kill_nobody() { kill "${sleepers[@]}" 2>/dev/null || true; pkill -u nobody -x sleep 2>/dev/null || true; sleepers=(); sleep 1; }
nobody_count() { ps -u nobody -o pid= | wc -l; }
pid=$(systemctl show -p MainPID --value "$UNIT")
limit=$(awk '/Max processes/ {print $3}' "/proc/$pid/limits")
record 'Max processes of the running OpenVPN' "$limit"
record 'Processes of nobody now' "$(nobody_count)"
if [[ $limit =~ ^[0-9]+$ ]]; then
    spawn_nobody $(( limit - $(nobody_count) ))
    record "With $(nobody_count) nobody processes (at the limit)" "$(connect "$LOG/alice.ovpn" "$LOG/c7.log") / server: $(server_says 20 'client-connect|fork|Resource')"
    disconnect
    kill_nobody
    spawn_nobody $(( limit - 2 - $(nobody_count) ))
    record "With $(nobody_count) nobody processes (two below)" "$(connect "$LOG/alice.ovpn" "$LOG/c8.log")"
    disconnect
    kill_nobody
else
    record 'Limit test' 'skipped: no numeric limit'
fi
install -d /etc/systemd/system/$UNIT.d
printf '[Service]\nLimitNPROC=infinity\nTasksMax=20\n' >"/etc/systemd/system/$UNIT.d/90-darban-evidence.conf"
systemctl daemon-reload
restart_server
pid=$(systemctl show -p MainPID --value "$UNIT")
record 'With the drop-in: max processes, TasksMax' "$(awk '/Max processes/ {print $3}' "/proc/$pid/limits"), $(systemctl show -p TasksMax --value "$UNIT")"
if [[ $limit =~ ^[0-9]+$ ]]; then
    spawn_nobody $(( limit + 2 - $(nobody_count) ))
    record "With the drop-in and $(nobody_count) nobody processes" "$(connect "$LOG/alice.ovpn" "$LOG/c9.log")"
    disconnect
    kill_nobody
fi
rm -f "/etc/systemd/system/$UNIT.d/90-darban-evidence.conf"
systemctl daemon-reload
cp "$LOG/server.conf.orig" "$CONF"
restart_server

# ---------- 7. the CRL: valid, expired, missing, unreadable ----------
section 'CRL states (ev-bob valid, ev-carol revoked)'
easyrsa revoke ev-carol
easyrsa gen-crl
publish_crl
crl_case() {
    record "$1: valid client" "$(connect "$LOG/bob.ovpn" "$LOG/crl-b.log")"
    disconnect
    record "$1: revoked client" "$(connect "$LOG/carol.ovpn" "$LOG/crl-c.log") / server: $(server_says 20 'CRL|crl')"
    disconnect
}
crl_case 'Valid CRL'
if command -v faketime >/dev/null; then
    cp "$PKI/crl.pem" "$LOG/crl.good"
    if env EASYRSA_PKI="$PKI" EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=180 faketime -f '-200d' "$EASYRSA" gen-crl </dev/null >>"$LOG/easyrsa.log" 2>&1; then
        publish_crl
        record 'Expired CRL: nextUpdate' "$(openssl crl -in /etc/openvpn/server/crl.pem -noout -nextupdate)"
        crl_case 'Expired CRL'
    else
        record 'Expired CRL' 'could not be made with faketime'
    fi
    cp "$LOG/crl.good" "$PKI/crl.pem"
    publish_crl
else
    record 'Expired CRL' 'skipped: faketime not available'
fi
mv /etc/openvpn/server/crl.pem "$LOG/crl.moved"
crl_case 'Missing CRL'
install -o root -g root -m 600 "$LOG/crl.moved" /etc/openvpn/server/crl.pem
crl_case 'CRL unreadable by nobody (600 root)'
publish_crl
record 'Diagnostics after restoring the CRL' "$(darban status 2>&1 | grep -iE 'CRL' | head -n 2 | tr -s ' ')"

# ---------- 8. systemd.path, a separate tmpfs and the claim by rename ----------
section 'Event queue mechanics (systemd.path, tmpfs, rename)'
Q=/run/darban-evidence
MOUNT_UNIT='run-darban\x2devidence.mount'
install -d -o root -g root -m 0755 "$Q"
cat >"/etc/systemd/system/$MOUNT_UNIT" <<EOF
[Mount]
What=tmpfs
Where=$Q
Type=tmpfs
Options=size=2M,nr_inodes=4096,mode=0755
EOF
cat >/etc/systemd/system/darban-evidence-setup.service <<EOF
[Unit]
RequiresMountsFor=$Q
ConditionPathIsMountPoint=$Q
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'install -d -o nobody -g nogroup -m 0700 $Q/tmp $Q/new && install -d -m 0700 $Q/work $Q/bad && touch $Q/.mounted'
EOF
cat >/usr/local/libexec/darban-evidence-worker <<EOF
#!/bin/bash
# Evidence only: claims every queued file by renaming it to a name root chooses, and counts its runs.
n=0
for f in $Q/new/*; do
    [[ -e \$f || -L \$f ]] || continue
    n=\$((n + 1))
    mv -T -- "\$f" "$Q/work/\$\$-\$n"
done
echo "run moved=\$n" >>/var/tmp/darban-evidence-worker.log
EOF
chmod 0755 /usr/local/libexec/darban-evidence-worker
cat >/etc/systemd/system/darban-evidence-worker.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/darban-evidence-worker
EOF
cat >/etc/systemd/system/darban-evidence.path <<EOF
[Path]
DirectoryNotEmpty=$Q/new
Unit=darban-evidence-worker.service
EOF
: >/var/tmp/darban-evidence-worker.log
systemctl daemon-reload
systemctl start "$MOUNT_UNIT" darban-evidence-setup.service darban-evidence.path
record 'Mount, setup and path units' "$(systemctl is-active "$MOUNT_UNIT") / $(systemctl is-active darban-evidence-setup.service) / $(systemctl is-active darban-evidence.path)"
record '.mounted marker inside the tmpfs' "$([[ -e $Q/.mounted ]] && echo yes || echo no)"
enqueue() { runuser -u nobody -- bash -c 'f=$(mktemp -p '"$Q"'/tmp); printf "connect test\n" >"$f"; mv -T -- "$f" '"$Q"'/new/"$1"' _ "$1"; }
enqueue one
sleep 2
record 'One event: left in new/, claimed into work/, worker runs' "$(find $Q/new -mindepth 1 | wc -l) / $(find $Q/work -mindepth 1 | wc -l) / $(grep -c run /var/tmp/darban-evidence-worker.log)"
for i in $(seq 1 50); do enqueue "burst$i"; done
sleep 3
record '50 events at once: left in new/, in work/, worker runs, path state' "$(find $Q/new -mindepth 1 | wc -l) / $(find $Q/work -mindepth 1 | wc -l) / $(grep -c run /var/tmp/darban-evidence-worker.log) / $(systemctl is-active darban-evidence.path)"
# W01: what a rename does when the destination exists.
runuser -u nobody -- bash -c "printf a >$Q/tmp/x"
printf b >"$Q/work/x"
mv -T -- "$Q/tmp/x" "$Q/work/x"
record 'mv -T onto an existing name (W01)' "destination now holds: $(cat "$Q/work/x")"
runuser -u nobody -- bash -c "printf c >$Q/tmp/y"
printf d >"$Q/work/y"
mv -n -T -- "$Q/tmp/y" "$Q/work/y"; rc=$?
record 'mv -n -T onto an existing name' "exit $rc, destination holds: $(cat "$Q/work/y"), source left: $([[ -e $Q/tmp/y ]] && echo yes || echo no)"
rm -f "$Q/work/x" "$Q/work/y" "$Q/tmp/y"
# Z03: a writer with the same UID fills the queue, not /run.
before=$(df --output=used /run | tail -n 1)
runuser -u nobody -- bash -c "head -c 5M /dev/zero >$Q/tmp/fill" 2>/dev/null; rc=$?
record 'Writing 5 MB as nobody' "exit $rc, written $(stat -c %s "$Q/tmp/fill" 2>/dev/null || echo 0) bytes; /run used before/after: $before / $(df --output=used /run | tail -n 1) KB"
rm -f "$Q/tmp/fill"
made=$(runuser -u nobody -- bash -c "for i in \$(seq 1 5000); do : >$Q/tmp/i\$i 2>/dev/null || { echo \$((i - 1)); exit; }; done; echo 5000")
record 'Files nobody can make in the queue (nr_inodes=4096)' "$made"
rm -f "$Q"/tmp/i*
# W02: without the mount, the queue is not there.
systemctl stop darban-evidence.path darban-evidence-setup.service "$MOUNT_UNIT"
record 'After unmount: new/ exists, .mounted exists, nobody can write in the mount point' \
    "$([[ -d $Q/new ]] && echo yes || echo no) / $([[ -e $Q/.mounted ]] && echo yes || echo no) / $(runuser -u nobody -- bash -c ": >$Q/probe" 2>/dev/null && echo yes || echo no)"

# ---------- 9. tar extraction with Python's data filter ----------
section 'tarfile data filter on a hostile archive'
python3 - "$LOG" <<'PY' >>"$LOG/tar.txt" 2>&1
import io, os, sys, tarfile
base = sys.argv[1]
cases = {
    'absolute path': lambda t: add(t, '/etc/evil', b'x'),
    'parent path': lambda t: add(t, '../evil', b'x'),
    'symlink out': lambda t: link(t, 'pki/link', '/etc/shadow', tarfile.SYMTYPE),
    'hardlink out': lambda t: link(t, 'pki/hard', '/etc/shadow', tarfile.LNKTYPE),
    'device': lambda t: dev(t),
    'plain file': lambda t: add(t, 'pki/ok', b'x'),
}
def add(t, name, data):
    i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
def link(t, name, target, kind):
    i = tarfile.TarInfo(name); i.type = kind; i.linkname = target; t.addfile(i)
def dev(t):
    i = tarfile.TarInfo('pki/dev'); i.type = tarfile.CHRTYPE; i.devmajor = 1; i.devminor = 3; t.addfile(i)
if not hasattr(tarfile, 'data_filter'):
    print('data_filter not available'); sys.exit()
for label, build in cases.items():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as t:
        build(t)
    buf.seek(0)
    dest = os.path.join(base, 'x-' + label.replace(' ', '-'))
    os.makedirs(dest)
    try:
        with tarfile.open(fileobj=buf) as t:
            t.extractall(dest, filter='data')
        print(f'{label}: extracted')
    except Exception as error:
        print(f'{label}: refused ({type(error).__name__})')
PY
while IFS= read -r line; do record "${line%%:*}" "${line#*: }"; done <"$LOG/tar.txt"

# ---------- 10. certbot with a real ACME server (Pebble), amd64 only ----------
section 'certbot deploy hook with Pebble'
if [[ $ARCH != amd64 && $ARCH != arm64 ]]; then
    record 'Pebble' "skipped on $ARCH"
else
    # Pebble is Let's Encrypt's test ACME server: a real certbot renewal, no real certificate, no rate limit.
    PEBBLE=v2.10.1
    work=$LOG/pebble
    mkdir -p "$work/bin"
    if curl -fsSL --retry 2 -o "$work/bin.tar.gz" "https://github.com/letsencrypt/pebble/releases/download/$PEBBLE/pebble-linux-$ARCH.tar.gz" \
        && curl -fsSL --retry 2 -o "$work/src.tar.gz" "https://github.com/letsencrypt/pebble/archive/refs/tags/$PEBBLE.tar.gz" \
        && tar -xzf "$work/bin.tar.gz" -C "$work/bin" && tar -xzf "$work/src.tar.gz" -C "$work" \
        && apt-get -y -q install certbot >/dev/null 2>&1; then
        binary=$(find "$work/bin" -type f -name pebble | head -n 1)
        chmod +x "$binary"
        src=$(find "$work" -maxdepth 1 -type d -name 'pebble-*' | head -n 1)
        record 'Pebble, certbot' "$PEBBLE (sha256 $(sha256sum "$binary" | cut -c1-16)…), $(certbot --version 2>&1)"
        (cd "$src" && PEBBLE_VA_ALWAYS_VALID=1 PEBBLE_VA_NOSLEEP=1 "$binary" -config test/config/pebble-config.json >"$work/pebble.log" 2>&1 &)
        sleep 3
        export REQUESTS_CA_BUNDLE=$src/test/certs/pebble.minica.pem
        ACME=https://localhost:14000/dir
        DEPLOY=/usr/local/sbin/darban-evidence-deploy
        printf '#!/bin/sh\necho "$(date +%%s) $RENEWED_LINEAGE" >>/var/tmp/darban-evidence-deploy.log\n' >"$DEPLOY"
        chmod 0755 "$DEPLOY"
        : >/var/tmp/darban-evidence-deploy.log
        cb() { certbot --server "$ACME" --non-interactive "$@" >>"$work/certbot.log" 2>&1; echo $?; }
        serial() { openssl x509 -in /etc/letsencrypt/live/evidence.localhost/cert.pem -noout -serial 2>/dev/null | cut -d= -f2; }
        rc=$(cb certonly --manual --preferred-challenges http --manual-auth-hook /bin/true --agree-tos \
            --register-unsafely-without-email -d evidence.localhost --deploy-hook "$DEPLOY")
        record 'Issue with --deploy-hook' "exit $rc, serial $(serial)"
        record 'How the renewal file keeps the hook' "$(grep -E '_hook' /etc/letsencrypt/renewal/evidence.localhost.conf 2>/dev/null | tr '\n' ' ')"
        s1=$(serial)
        rc=$(cb renew --force-renewal --cert-name evidence.localhost)
        record 'Renew, hook present' "exit $rc, renewed: $([[ $(serial) != "$s1" ]] && echo yes || echo no), hook ran: $(wc -l </var/tmp/darban-evidence-deploy.log) time(s)"
        rm -f "$DEPLOY"
        s2=$(serial)
        rc=$(cb renew --force-renewal --cert-name evidence.localhost)
        record 'Renew, hook program removed' "exit $rc, renewed: $([[ $(serial) != "$s2" ]] && echo yes || echo no), certbot said: $(grep -iE 'hook|unable to find|not found' "$work/certbot.log" | tail -n 2 | tr -s ' ')"
        if certbot --help all 2>/dev/null | grep -q -- '--run-deploy-hooks'; then
            rc=$(cb renew --dry-run --run-deploy-hooks --cert-name evidence.localhost)
            record 'Dry run with --run-deploy-hooks, hook removed' "exit $rc"
        else
            record '--run-deploy-hooks' 'not in this certbot'
        fi
    else
        record 'Pebble or certbot' 'could not be installed'
    fi
fi

note 'Not covered here: a real reboot (the reboot test machine), OpenVPN Connect on phones and Windows (gate E13, on a VPS with the owner).'
cat "$OUT"

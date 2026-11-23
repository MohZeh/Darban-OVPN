#!/usr/bin/env bash
# Builds a throwaway fake server: a real OpenSSL PKI, a fake Easy-RSA backed by real "openssl ca",
# stubbed systemd/ss/flock, and copies of the product scripts patched to use these paths.
# Synthetic data only. It never touches /root/pki, /etc/openvpn or a running service.
# Usage: fake-server.sh <repo-root> <empty-or-reusable-dir>
set -euo pipefail
SRC=$1; E=$2
rm -rf "$E"; mkdir -p "$E"
mkdir -p "$E/pki/issued" "$E/pki/private" "$E/server" "$E/clients" "$E/cfg" "$E/lib" "$E/bin" "$E/run"
P=$E/pki
cd "$P"
: > index.txt; echo 1000 > crlnumber; echo 01 > serial
cat > openssl.cnf <<CNF
[ca]
default_ca = CA_default
[CA_default]
# Relative, so the same file serves a copy of this CA, such as one a restore stages.
dir = .
database = ./index.txt
new_certs_dir = ./issued
certificate = ./ca.crt
private_key = ./private/ca.key
serial = ./serial
crlnumber = ./crlnumber
default_md = sha256
default_crl_days = 180
policy = pol
unique_subject = no
copy_extensions = none
[pol]
commonName = supplied
[client]
basicConstraints = CA:FALSE
extendedKeyUsage = clientAuth
keyUsage = digitalSignature
[server]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth
keyUsage = digitalSignature,keyEncipherment
[req]
distinguished_name = dn
[dn]
CNF
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout private/ca.key -out ca.crt -subj /CN=TestCA -days 3650 2>/dev/null
cp openssl.cnf "$E/openssl.cnf"

# Fake Easy-RSA backed by real "openssl ca". FAIL_GENCRL=1 simulates a CRL generation failure.
cat > "$E/bin/easyrsa" <<'STUB'
#!/usr/bin/env bash
set -e
cd "$EASYRSA_PKI"
# A copy of the CA has no openssl.cnf of its own; the stand-in's is relative.
if [[ ! -f openssl.cnf ]]; then cp "$(dirname "$0")/../openssl.cnf" openssl.cnf; [[ -s crlnumber ]] || echo 1000 > crlnumber; fi
issue() { # name extensions subject
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "private/$1.key" -out "$1.csr" -subj "$3" 2>/dev/null
    openssl ca -batch -config openssl.cnf -extensions "$2" -in "$1.csr" -out "issued/$1.crt.tmp" -notext -days "${EASYRSA_CERT_EXPIRE:-825}" 2>/dev/null
    openssl x509 -in "issued/$1.crt.tmp" -out "issued/$1.crt"; rm -f "issued/$1.crt.tmp" "$1.csr" issued/[0-9A-F]*.pem
}
case $1 in
  build-client-full) issue "$2" client "/CN=$2" ;;
  build-server-full) issue "$2" server "/CN=$2" ;;
  revoke)
    openssl ca -batch -config openssl.cnf -revoke "issued/$2.crt" 2>/dev/null
    mkdir -p revoked; mv "issued/$2.crt" "revoked/$2.$(date +%s%N).crt"; mv "private/$2.key" "revoked/$2.$(date +%s%N).key" ;;
  gen-crl)
    if [[ -n ${FAIL_GENCRL:-} ]]; then echo 'simulated gen-crl failure' >&2; exit 1; fi
    openssl ca -batch -config openssl.cnf -gencrl -out crl.pem 2>/dev/null ;;
  *) echo "fake easyrsa: unknown command $1" >&2; exit 1 ;;
esac
STUB

cat > "$E/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
q=0; for a; do [[ $a == --quiet ]] && q=1; done
# OpenVPN's unit remembers being stopped or disabled, as a restore checks both. FAKE_STOP_FAILS: it never stops.
# FAKE_START_FAILS: it never starts.
unit=${*: -1}
if [[ $unit == openvpn-server@* ]]; then
    state=${STUB_LOG%/*}/unit-state; mkdir -p "$state"
    case " $* " in
      *" disable "*) if [[ -n ${FAKE_STOP_FAILS:-} ]]; then exit 1; fi; : > "$state/$unit.disabled"; [[ " $* " != *" --now "* ]] || : > "$state/$unit.stopped" ;;
      *" stop "*) if [[ -n ${FAKE_STOP_FAILS:-} ]]; then exit 1; fi; : > "$state/$unit.stopped" ;;
      # FAKE_ENABLE_FAILS: enabling it at boot fails, as systemd can refuse it.
      *" enable "*) if [[ -n ${FAKE_ENABLE_FAILS:-} && " $* " != *" --now "* ]]; then exit 1; fi; rm -f "$state/$unit.disabled"; if [[ " $* " == *" --now "* ]]; then if [[ -n ${FAKE_START_FAILS:-} ]]; then exit 1; fi; rm -f "$state/$unit.stopped"; fi ;;
      *" start "*|*" restart "*) if [[ -n ${FAKE_START_FAILS:-} ]]; then exit 1; fi; [[ -n ${FAIL_RESTART:-} ]] || rm -f "$state/$unit.stopped" ;;
      *" is-active "*) if [[ -e $state/$unit.stopped ]]; then ((q)) || echo inactive; exit 3; fi ;;
      *" is-enabled "*) if [[ -e $state/$unit.disabled ]]; then echo disabled; exit 1; fi ;;
    esac
fi
case " $* " in
  *" restart "*) if [[ -n ${FAIL_RESTART:-} ]]; then exit 1; fi ;;
  # FAKE_FAILED names a unit that has failed. FAKE_LIMITNPROC is the process limit of OpenVPN's unit.
  *" is-failed "*) if [[ -n ${FAKE_FAILED:-} && " $* " == *" $FAKE_FAILED "* ]]; then ((q)) || echo failed; exit 0; fi; ((q)) || echo active; exit 1 ;;
  *" is-active "*darban-links*) ((q)) || echo inactive; exit 3 ;;
  *" is-active "*) if [[ -n ${FAKE_FAILED:-} && " $* " == *" $FAKE_FAILED "* ]]; then ((q)) || echo failed; exit 3; fi; ((q)) || echo active; exit 0 ;;
  *" is-enabled "*) echo enabled; exit 0 ;;
  *" show "*) [[ $* == *Result* ]] && echo success; [[ $* == *LimitNPROC* ]] && echo "${FAKE_LIMITNPROC:-infinity}"; [[ $* == *TasksMax* ]] && echo 20; exit 0 ;;
esac
exit 0
STUB
cat > "$E/bin/ss" <<'STUB'
#!/usr/bin/env bash
# TCP questions go to the real ss: the link service of a test really listens, and must be seen as itself.
for arg in "$@"; do [[ $arg =~ ^-[A-Za-z]*t ]] && exec /usr/bin/ss "$@"; done
last=${*: -1}; want=${last##*:}; cur=$(awk '$1=="port"{print $2}' "$SERVER_CONF")
[[ $want == "$cur" ]] && echo "UNCONN 0 0 0.0.0.0:$want 0.0.0.0:*"
exit 0
STUB
# FLOCK_HOOK runs what another session would do while this one waits for the lock. FLOCK_FAIL names the exact
# arguments of a lock that is never given, such as '-w 10 8' for the lock of the link files.
cat > "$E/bin/flock" <<'STUB'
#!/usr/bin/env bash
echo "flock $*" >> "${STUB_LOG:-/dev/null}"
if [[ -n ${FLOCK_FAIL:-} && "$*" == "$FLOCK_FAIL" ]]; then exit 1; fi
if [[ -n ${FLOCK_HOOK:-} && $1 != -u ]]; then bash -c "$FLOCK_HOOK" >/dev/null 2>&1; fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$E/bin/chown"
# runuser runs the command as the user running the tests; FAKE_RUNUSER_DENY: that user is refused, as nobody is
# by a file only root can read.
cat > "$E/bin/runuser" <<'STUB'
#!/usr/bin/env bash
if [[ -n ${FAKE_RUNUSER_DENY:-} ]]; then exit 1; fi
while (( $# )) && [[ $1 != -- ]]; do shift; done
shift
exec "$@"
STUB
# The queue of connection events counts as its own tmpfs while its folder exists; FAKE_NO_TMPFS: it is not mounted.
# findmnt -T <file> gives the mount options of that file: relatime, or FAKE_ATIME, such as noatime.
cat > "$E/bin/findmnt" <<STUB
#!/usr/bin/env bash
for arg; do if [[ \$arg == -T ]]; then echo "rw,\${FAKE_ATIME:-relatime}"; exit 0; fi; done
[[ -z \${FAKE_NO_TMPFS:-} && \${*: -1} == "$E/events" && -d "$E/events" ]] || exit 1
echo tmpfs
STUB
# systemd-run only records what it was asked; FAIL_SYSTEMD_RUN: it fails.
cat > "$E/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$STUB_LOG"
if [[ -n ${FAIL_SYSTEMD_RUN:-} ]]; then exit 1; fi
exit 0
STUB
printf '#!/usr/bin/env bash\nif [[ ${1:-} == -n ]]; then echo 1; fi\n' > "$E/bin/sysctl"
printf '#!/usr/bin/env bash\necho "logger $*" >> "$STUB_LOG"\n' > "$E/bin/logger"
printf '#!/usr/bin/env bash\nargs=(); while (($#)); do case $1 in -o|-g|-m) shift 2;; *) args+=("$1"); shift;; esac; done; exec /usr/bin/install "${args[@]}"\n' > "$E/bin/install"
# age: a stand-in that only wraps the file, so a test opens it again with "age -d". FAIL_AGE: it fails.
cat > "$E/bin/age" <<'STUB'
#!/usr/bin/env bash
echo "age $*" >> "${STUB_LOG:-/dev/null}"
[[ -z ${FAIL_AGE:-} ]] || exit 1
out='' decrypt=0 input=''
while (( $# )); do
    case $1 in -o) out=$2; shift 2 ;; -r|-i) shift 2 ;; -d) decrypt=1; shift ;; -p) shift ;; *) input=$1; shift ;; esac
done
if (( decrypt )); then tail -n +2 "$input" > "$out"; else { echo 'age-stand-in'; cat "$input"; } > "$out"; fi
STUB
chmod +x "$E/bin/"*

export EASYRSA_PKI=$P EASYRSA_BATCH=1
if [[ -n ${DARBAN_REAL_EASYRSA:-} ]]; then
    # The real Easy-RSA replaces the stand-in, which stays only as a way to simulate a gen-crl failure.
    cat > "$E/bin/easyrsa" <<STUB
#!/usr/bin/env bash
if [[ \$1 == gen-crl && -n \${FAIL_GENCRL:-} ]]; then echo 'simulated gen-crl failure' >&2; exit 1; fi
exec "$DARBAN_REAL_EASYRSA" "\$@"
STUB
    cd "$E"
    rm -rf "$P"
    "$E/bin/easyrsa" init-pki
    EASYRSA_REQ_CN=TestCA "$E/bin/easyrsa" build-ca nopass
fi
"$E/bin/easyrsa" build-server-full server_abc123 nopass
"$E/bin/easyrsa" build-client-full alice nopass
"$E/bin/easyrsa" gen-crl

head -c 256 /dev/urandom | base64 > "$E/server/tls-crypt.key"
cp "$P/crl.pem" "$E/server/crl.pem"; cp "$P/issued/server_abc123.crt" "$E/server/server.crt"
cat > "$E/server/server.conf" <<CONF
port 1194
proto udp4
dev tun
ca $P/ca.crt
cert server.crt
key $P/private/server_abc123.key
tls-crypt tls-crypt.key
data-ciphers AES-256-GCM:CHACHA20-POLY1305
crl-verify $E/server/crl.pem
CONF
echo vpn.example.com > "$E/cfg/domain"
printf 'DOWNLOAD_SSH_HOST=203.0.113.7\nDOWNLOAD_SSH_PORT=2222\nDOWNLOAD_SSH_USER=root\nUPDATE_CHECK=no\n' > "$E/cfg/config"

sed -e "s#^DARBAN_LIB=.*#DARBAN_LIB=$E/lib#" -e "s#^DARBAN_PKI=.*#DARBAN_PKI=$P#" -e "s#^DARBAN_EASYRSA=.*#DARBAN_EASYRSA=$E/bin/easyrsa#" \
    -e "s#^DARBAN_SERVER_DIR=.*#DARBAN_SERVER_DIR=$E/server#" -e "s#^DARBAN_LOCK=.*#DARBAN_LOCK=$E/run/lock#" \
    -e "s#^DARBAN_RESTORE_JOURNAL=.*#DARBAN_RESTORE_JOURNAL=$E/varlib/restore.journal#" \
    -e "s#^DARBAN_BLOCKED=.*#DARBAN_BLOCKED=$E/cfg/blocked.v4#" -e "s#^DARBAN_DNS_REDIRECT=.*#DARBAN_DNS_REDIRECT=$E/cfg/dns-redirect#" \
    -e "s#^DARBAN_CONFIG=.*#DARBAN_CONFIG=$E/cfg/config#" \
    "$SRC/lib/common.sh" > "$E/lib/common.sh"
echo 'darban_require_root() { :; }' >> "$E/lib/common.sh"
cp "$SRC/lib/ui.sh" "$E/lib/ui.sh"
# darban-core where paths.sh finds it, $DARBAN_LIB/darban-core: DARBAN_TEST_CORE, or the one scripts/build-core.sh built
# for this machine, as CI does before the tests.
core=${DARBAN_TEST_CORE:-}
if [[ -z $core ]]; then
    case $(uname -m) in
        x86_64|amd64) core=$SRC/bin/darban-core-amd64 ;;
        aarch64|arm64) core=$SRC/bin/darban-core-arm64 ;;
    esac
fi
[[ -n $core && -f $core ]] || { echo 'fake-server.sh: no darban-core for this machine. Build it first: bash scripts/build-core.sh' >&2; exit 1; }
cp "$core" "$E/lib/darban-core"
chmod 755 "$E/lib/darban-core"
cp "$SRC/lib/backup.py" "$E/lib/backup.py"
cp "$SRC/lib/geolist.py" "$E/lib/geolist.py"
# The manager's modules as install.sh places them; the test copy of paths.sh points every path into this fake server.
mkdir -p "$E/lib/modules/screens"
sed -e "s#^OUT_DIR=.*#OUT_DIR=$E/clients#" -e "s#^LINK_DIR=.*#LINK_DIR=$E/links#" -e "s#^BACKUP_ROOT=.*#BACKUP_ROOT=$E/backups-tool#" -e "s#^SBIN_DIR=.*#SBIN_DIR=$E/sbin#" -e "s#^UNIT_DIR=.*#UNIT_DIR=$E/units#" -e "s#^CONFIG_DIR=.*#CONFIG_DIR=$E/cfg#" \
    -e "s#^SYSTEM_CA_FILE=.*#SYSTEM_CA_FILE=$E/system-ca.pem#" -e "s#^CERT_SEARCH_DIRS=.*#CERT_SEARCH_DIRS='$E/le-live $E/panel-cert $E/acme'#" \
    -e "s#^LE_DIR=.*#LE_DIR=$E/le#" -e "s#^LINK_CERT_LOG=.*#LINK_CERT_LOG=$E/varlib/link-certificates.log#" \
    -e "s#^GEO_SOURCE=.*#GEO_SOURCE=file://$E/geo-src/#" -e "s#^UNBOUND_DIR=.*#UNBOUND_DIR=$E/unbound#" \
    -e "s#^UNBOUND_ROOT_KEY=.*#UNBOUND_ROOT_KEY=$E/varlib/unbound/root.key#" -e "s#^DNS_ROOT_DATA=.*#DNS_ROOT_DATA=$E/dns-root.key#" \
    -e "s#^UNBOUND_RPZ=.*#UNBOUND_RPZ=$E/unbound-zone/darban.rpz#" -e "s#^NAMES_DNS_PORT=.*#NAMES_DNS_PORT=15353#" \
    -e "s#^EVENT_SCRIPT=.*#EVENT_SCRIPT=$E/libexec/darban-ovpn-event#" -e "s#^EVENT_DIR=.*#EVENT_DIR=$E/events#" \
    -e "s#^LEDGER_DIR=.*#LEDGER_DIR=$E/varlib/clients#" \
    -e "s#^PKI_BACKUP_DIR=.*#PKI_BACKUP_DIR=$E/pki-backups#" -e "s#^RESTORE_WARN=.*#RESTORE_WARN=$E/varlib/restore-unverified#" \
    -e 's#^EVENT_MAX=.*#EVENT_MAX=${TEST_EVENT_MAX:-500}#' \
    "$SRC/lib/darban/paths.sh" > "$E/lib/modules/paths.sh"
# The screens keep their folder. The event_run_id stand-in is a function, not a path: it goes into the module that
# has it, and the build fails when no module has it.
for module in "$SRC"/lib/darban/*.sh "$SRC"/lib/darban/screens/*.sh; do
    name=${module#"$SRC"/lib/darban/}
    if [[ $name != paths.sh ]]; then
        sed -e 's#^event_run_id() {.*#event_run_id() { printf "%s\\n" "${TEST_EVENT_RUN:-$$-0}"; }#' "$module" > "$E/lib/modules/$name"
    fi
done
grep -qF 'TEST_EVENT_RUN' "$E"/lib/modules/*.sh ||{ echo 'fake-server.sh: no module has event_run_id' >&2; exit 1; }
sed -e "s#^source /usr/local/lib/darban/#source $E/lib/#" "$SRC/bin/darban" > "$E/manager.sh"
# Every file the manager sources is here, so no test runs a manager that is missing a part.
while read -r _ file; do
    [[ -f $file ]] || { echo "fake-server.sh: the manager sources $file, which is not here" >&2; exit 1; }
done < <(grep '^source ' "$E/manager.sh")
# The event script as install.sh places it, writing into this fake server's queue, and giving its routes.
mkdir -p "$E/libexec"
sed -e "s#^queue=.*#queue=$E/events#" -e "s#^direct=.*#direct=$E/server/darban-direct.routes#" -e "s#^direct_small=.*#direct_small=$E/server/darban-direct-small.routes#" "$SRC/bin/darban-ovpn-event" > "$E/libexec/darban-ovpn-event"
chmod 755 "$E/libexec/darban-ovpn-event"
sed -e "s#^source /usr/local/lib/darban/#source $E/lib/#" "$SRC/bin/darban-crl-maintain" > "$E/crl-maintain"

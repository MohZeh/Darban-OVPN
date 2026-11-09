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
dir = $P
database = $P/index.txt
new_certs_dir = $P/issued
certificate = $P/ca.crt
private_key = $P/private/ca.key
serial = $P/serial
crlnumber = $P/crlnumber
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

# Fake Easy-RSA backed by real "openssl ca". FAIL_GENCRL=1 simulates a CRL generation failure.
cat > "$E/bin/easyrsa" <<'STUB'
#!/usr/bin/env bash
set -e
cd "$EASYRSA_PKI"
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
case " $* " in
  *" restart "*) if [[ -n ${FAIL_RESTART:-} ]]; then exit 1; fi ;;
  *" is-failed "*) ((q)) || echo active; exit 1 ;;
  *" is-active "*) ((q)) || echo active; exit 0 ;;
  *" is-enabled "*) echo enabled; exit 0 ;;
  *" show "*) [[ $* == *Result* ]] && echo success; exit 0 ;;
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
# FLOCK_HOOK runs what another session would do while this one waits for the lock.
cat > "$E/bin/flock" <<'STUB'
#!/usr/bin/env bash
echo "flock $*" >> "${STUB_LOG:-/dev/null}"
if [[ -n ${FLOCK_HOOK:-} && $1 != -u ]]; then bash -c "$FLOCK_HOOK" >/dev/null 2>&1; fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$E/bin/chown"
printf '#!/usr/bin/env bash\nif [[ ${1:-} == -n ]]; then echo 1; fi\n' > "$E/bin/sysctl"
printf '#!/usr/bin/env bash\necho "logger $*" >> "$STUB_LOG"\n' > "$E/bin/logger"
printf '#!/usr/bin/env bash\nargs=(); while (($#)); do case $1 in -o|-g|-m) shift 2;; *) args+=("$1"); shift;; esac; done; exec /usr/bin/install "${args[@]}"\n' > "$E/bin/install"
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
    "$SRC/lib/common.sh" > "$E/lib/common.sh"
echo 'darban_require_root() { :; }' >> "$E/lib/common.sh"
cp "$SRC/lib/ui.sh" "$E/lib/ui.sh"
sed -e "s#^source /usr/local/lib/darban/#source $E/lib/#" -e "s#^OUT_DIR=.*#OUT_DIR=$E/clients#" -e "s#^LINK_DIR=.*#LINK_DIR=$E/links#" -e "s#^BACKUP_ROOT=.*#BACKUP_ROOT=$E/backups-tool#" -e "s#^SBIN_DIR=.*#SBIN_DIR=$E/sbin#" -e "s#^UNIT_DIR=.*#UNIT_DIR=$E/units#" -e "s#^CONFIG_DIR=.*#CONFIG_DIR=$E/cfg#" \
    "$SRC/bin/darban" > "$E/manager.sh"
sed -e "s#^source /usr/local/lib/darban/#source $E/lib/#" "$SRC/bin/darban-crl-maintain" > "$E/crl-maintain"

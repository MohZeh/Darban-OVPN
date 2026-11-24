#!/usr/bin/env bash
# Starts Pebble, Let's Encrypt's test ACME server, on https://localhost:14000/dir, for CI on a disposable machine.
#   pebble-start.sh <log folder>
# Writes the path of the CA file that checks its certificate to <log folder>/pebble-ca. It is a file, not output,
# because Pebble keeps running in the background and must not hold the pipe of a command substitution.
set -Eeuo pipefail
PEBBLE=v2.10.1
LOG=$1
pebble_dir=$LOG/pebble
mkdir -p "$pebble_dir/bin"
curl -fsSL --retry 2 -o "$pebble_dir/bin.tar.gz" "https://github.com/letsencrypt/pebble/releases/download/$PEBBLE/pebble-linux-$(dpkg --print-architecture).tar.gz"
curl -fsSL --retry 2 -o "$pebble_dir/src.tar.gz" "https://github.com/letsencrypt/pebble/archive/refs/tags/$PEBBLE.tar.gz"
tar -xzf "$pebble_dir/bin.tar.gz" -C "$pebble_dir/bin"
tar -xzf "$pebble_dir/src.tar.gz" -C "$pebble_dir"
pebble_bin=$(find "$pebble_dir/bin" -type f -name pebble | head -n 1)
pebble_src=$(find "$pebble_dir" -maxdepth 1 -type d -name 'pebble-*' | head -n 1)
chmod +x "$pebble_bin"
# Pebble rejects a share of good nonces by default, to test a client's retry. That is certbot's code, not this
# tool's, and two rejections in a row made a renewal here fail now and then: the renewals here test the tool.
(cd "$pebble_src" && PEBBLE_VA_ALWAYS_VALID=1 PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 "$pebble_bin" -config test/config/pebble-config.json </dev/null >"$LOG/pebble.log" 2>&1 3>&- &)
ca=$pebble_src/test/certs/pebble.minica.pem
for attempt in $(seq 1 20); do
    if curl -fs --cacert "$ca" https://localhost:14000/dir >/dev/null; then break; fi
    sleep 0.5
done
printf '%s\n' "$ca" >"$LOG/pebble-ca"

#!/usr/bin/env bash
# Builds the release assets into a directory: bash scripts/build-release.sh [out-dir]
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
out=${1:-dist/release}
version=$(cat VERSION)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo "Bad VERSION: $version" >&2; exit 1; }
grep -qx "DARBAN_VERSION=$version" bin/darban || { echo 'VERSION and DARBAN_VERSION in bin/darban differ.' >&2; exit 1; }

mkdir -p "$out"
tarfile=$(mktemp -d)/release.tar
common=(--force-local --format=gnu --owner=0 --group=0 --numeric-owner)
tar "${common[@]}" --mode=700 -cf "$tarfile" setup/install.sh setup/server-setup.sh setup/get.sh setup/uninstall.sh setup/remove-server.sh bin/darban bin/darban-crl-maintain
tar "${common[@]}" --mode=644 -rf "$tarfile" lib/common.sh lib/ui.sh lib/linkd.py systemd/darban-crl.service systemd/darban-crl.timer systemd/darban-links.service README.md README.fa.md CHANGELOG.md LICENSE VERSION
tar "${common[@]}" --mode=755 -rf "$tarfile" tests/fake-server.sh tests/run-tests.sh tests/run-tty-tests.py tests/acceptance-ci.sh
gzip -9n -c "$tarfile" > "$out/darban-ovpn.tar.gz"
rm -rf -- "$(dirname -- "$tarfile")"
cp setup/get.sh "$out/get.sh"
cp VERSION "$out/VERSION"
# This version's section of the changelog, shown by the tool before it updates itself.
awk -v v="## [$version]" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/./,$!d' > "$out/RELEASE-NOTES.txt"
[[ -s $out/RELEASE-NOTES.txt ]] || { echo "CHANGELOG.md has no section for $version." >&2; exit 1; }
(cd "$out" && sha256sum darban-ovpn.tar.gz get.sh VERSION RELEASE-NOTES.txt > SHA256SUMS)
cat "$out/SHA256SUMS"

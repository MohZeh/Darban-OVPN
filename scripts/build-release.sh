#!/usr/bin/env bash
# Builds the release assets into a directory: bash scripts/build-release.sh [out-dir]
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
out=${1:-dist/release}
version=$(cat VERSION)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo "Bad VERSION: $version" >&2; exit 1; }
grep -qx "DARBAN_VERSION=$version" bin/darban || { echo 'VERSION and DARBAN_VERSION in bin/darban differ.' >&2; exit 1; }

# Every file in the archive carries the time of the commit, not of the checkout, so two builds of one commit give
# the same bytes and the same checksum.
when=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct HEAD 2>/dev/null)} || true
[[ $when =~ ^[0-9]+$ ]] || { echo 'No commit time: build from a git checkout, or set SOURCE_DATE_EPOCH.' >&2; exit 1; }

mkdir -p "$out"
tarfile=$(mktemp -d)/release.tar
common=(--force-local --format=gnu --owner=0 --group=0 --numeric-owner --mtime="@$when")
tar "${common[@]}" --mode=700 -cf "$tarfile" setup/install.sh setup/server-setup.sh setup/get.sh setup/uninstall.sh setup/remove-server.sh bin/darban bin/darban-crl-maintain bin/darban-ovpn-event
tar "${common[@]}" --mode=644 -rf "$tarfile" lib/common.sh lib/ui.sh lib/linkd.py lib/backup.py lib/geolist.py systemd/darban-crl.service systemd/darban-backup.service systemd/darban-geo.service systemd/darban-geo.timer systemd/darban-crl.timer systemd/darban-links.service systemd/darban-events.mount systemd/darban-events-setup.service systemd/darban-events.path systemd/darban-events.service systemd/darban-sweep.timer systemd/darban-sweep.service systemd/darban-expire.service README.md README.fa.md CHANGELOG.md LICENSE VERSION
gzip -9n -c "$tarfile" > "$out/darban-ovpn.tar.gz"
rm -rf -- "$(dirname -- "$tarfile")"
# The published script installs its own release, so a link to any version does what it says.
sed "s/^RELEASE_TAG=.*/RELEASE_TAG=v$version/" setup/get.sh > "$out/get.sh"
grep -qx "RELEASE_TAG=v$version" "$out/get.sh" || { echo 'Could not write the version into get.sh.' >&2; exit 1; }
cp VERSION "$out/VERSION"
# This version's section of the changelog, shown by the tool before it updates itself.
awk -v v="## [$version]" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/./,$!d' > "$out/RELEASE-NOTES.txt"
[[ -s $out/RELEASE-NOTES.txt ]] || { echo "CHANGELOG.md has no section for $version." >&2; exit 1; }
(cd "$out" && sha256sum darban-ovpn.tar.gz get.sh VERSION RELEASE-NOTES.txt > SHA256SUMS)
cat "$out/SHA256SUMS"

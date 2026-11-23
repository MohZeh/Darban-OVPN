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
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# darban-core for each architecture, from the same pinned toolchain, so a second build gives the same bytes.
mkdir -p "$work/core/bin"
for arch in amd64 arm64; do
    bash scripts/build-core.sh "$arch" "$work/core/bin/darban-core-$arch" >/dev/null
done
common=(--force-local --format=gnu --owner=0 --group=0 --numeric-owner --mtime="@$when")
# The modules of the manager, its screens in lib/darban/screens included, by path in the C locale, so the order in
# the archive never depends on the machine.
mapfile -t modules < <(printf '%s
' lib/darban/*.sh lib/darban/screens/*.sh | LC_ALL=C sort)
[[ -f ${modules[0]:-} ]] || { echo 'No modules in lib/darban.' >&2; exit 1; }
pack() {
    # pack <archive> <architecture>...: the tool with darban-core for those architectures, in one fixed order.
    local archive=$1 tarfile=$work/release.tar arch
    shift
    rm -f -- "$tarfile"
    tar "${common[@]}" --mode=700 -cf "$tarfile" setup/install.sh setup/server-setup.sh setup/get.sh setup/uninstall.sh setup/remove-server.sh bin/darban bin/darban-crl-maintain bin/darban-ovpn-event
    for arch in "$@"; do
        tar "${common[@]}" --mode=700 -rf "$tarfile" -C "$work/core" "bin/darban-core-$arch"
    done
    tar "${common[@]}" --mode=644 -rf "$tarfile" lib/common.sh lib/ui.sh lib/linkd.py lib/backup.py lib/geolist.py "${modules[@]}" systemd/darban-crl.service systemd/darban-backup.service systemd/darban-geo.service systemd/darban-geo.timer systemd/darban-crl.timer systemd/darban-links.service systemd/darban-events.mount systemd/darban-events-setup.service systemd/darban-events.path systemd/darban-events.service systemd/darban-sweep.timer systemd/darban-sweep.service systemd/darban-expire.service README.md README.fa.md CHANGELOG.md LICENSE VERSION
    gzip -9n -c "$tarfile" > "$out/$archive"
}
# One archive for each architecture, which get.sh downloads; and one with both, which the get.sh of v1.0 downloads
# when a server of that version updates itself.
pack darban-ovpn-amd64.tar.gz amd64
pack darban-ovpn-arm64.tar.gz arm64
pack darban-ovpn.tar.gz amd64 arm64
# The published script installs its own release, so a link to any version does what it says.
sed "s/^RELEASE_TAG=.*/RELEASE_TAG=v$version/" setup/get.sh > "$out/get.sh"
grep -qx "RELEASE_TAG=v$version" "$out/get.sh" || { echo 'Could not write the version into get.sh.' >&2; exit 1; }
cp VERSION "$out/VERSION"
# This version's section of the changelog, shown by the tool before it updates itself.
awk -v v="## [$version]" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/./,$!d' > "$out/RELEASE-NOTES.txt"
[[ -s $out/RELEASE-NOTES.txt ]] || { echo "CHANGELOG.md has no section for $version." >&2; exit 1; }
(cd "$out" && sha256sum darban-ovpn.tar.gz darban-ovpn-amd64.tar.gz darban-ovpn-arm64.tar.gz get.sh VERSION RELEASE-NOTES.txt > SHA256SUMS)
cat "$out/SHA256SUMS"

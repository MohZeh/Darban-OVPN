#!/usr/bin/env bash
# Downloads a published release, verifies it, and runs its installer.
#
#   curl -fsSL https://github.com/MohZeh/darban-ovpn/releases/latest/download/get.sh -o get.sh
#   sudo bash get.sh [--version vX.Y.Z]
#
# The checksum comes from the same release, so it catches a damaged download, not a compromised account.
set -Eeuo pipefail
umask 077
REPO=MohZeh/darban-ovpn
ARCHIVE=darban-ovpn.tar.gz
SERVER_CONF=/etc/openvpn/server/server.conf
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

tag=''
case "$#:${1:-}" in
    0:) ;;
    2:--version) tag=$2 ;;
    *) die 'Usage: get.sh [--version vX.Y.Z]' ;;
esac
if [[ -n $tag && ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then die "Not a release version: $tag"; fi
[[ $EUID == 0 ]] || die 'Run with sudo/root.'
for cmd in curl tar sha256sum mktemp grep; do
    command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
if [[ -n $tag ]]; then
    base=https://github.com/$REPO/releases/download/$tag
else
    base=https://github.com/$REPO/releases/latest/download
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 120 -o "$work/$1" "$base/$1" || die "Could not download $1 from $base"; }

printf 'Downloading %s...\n' "${tag:-the latest release}"
fetch "$ARCHIVE"
fetch SHA256SUMS
# Exactly one line must describe the archive; nothing is unpacked or run before it matches.
expected=$(grep -E "^[0-9a-f]{64}  $ARCHIVE\$" "$work/SHA256SUMS" || true)
[[ -n $expected && $(wc -l <<<"$expected") == 1 ]] || die 'SHA256SUMS has no single entry for the archive; nothing was installed.'
(cd "$work" && sha256sum --quiet -c - <<<"$expected") || die 'Checksum mismatch; nothing was installed.'
printf 'Checksum verified.\n'

mkdir "$work/release"
tar --no-same-owner -xzf "$work/$ARCHIVE" -C "$work/release"
[[ -f $work/release/setup/install.sh ]] || die 'The archive has no setup/install.sh; nothing was installed.'
# A server without OpenVPN is set up first; an existing one is never touched by that step.
if [[ ! -e $SERVER_CONF ]]; then
    [[ -f $work/release/setup/server-setup.sh ]] || die 'The archive has no setup/server-setup.sh; nothing was installed.'
    # Prompts must read the terminal even when this script was started from a pipe.
    if [[ -t 0 ]]; then
        bash "$work/release/setup/server-setup.sh"
    else
        bash "$work/release/setup/server-setup.sh" </dev/tty
    fi
    # A cancelled setup leaves no server, and the installer has nothing to manage.
    [[ -e $SERVER_CONF ]] || exit 0
fi
bash "$work/release/setup/install.sh"

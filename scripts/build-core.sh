#!/usr/bin/env bash
# Builds darban-core for Linux on one architecture: bash scripts/build-core.sh [amd64|arm64] [out-file]
# Without an architecture, the one Go runs on; without a file, bin/darban-core-<arch>, where setup/install.sh finds
# it in a checkout. Two builds of one commit give the same bytes on any machine: the toolchain go.mod pins, no cgo,
# no file paths, no build ID or VCS stamp, and the version from the file VERSION.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# GO names the go command where PATH does not have it, as under sudo.
go=${GO:-go}
command -v "$go" >/dev/null || { echo 'Go is needed to build darban-core: the toolchain named in go.mod, such as with actions/setup-go.' >&2; exit 1; }
arch=${1:-$("$go" env GOARCH)}
case $arch in
    amd64|arm64) ;;
    *) echo "darban-core is built for amd64 and arm64 only, not: $arch" >&2; exit 1 ;;
esac
out=${2:-bin/darban-core-$arch}
version=$(cat VERSION)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || { echo "Bad VERSION: $version" >&2; exit 1; }
toolchain=$(awk '$1 == "toolchain" {print $2}' go.mod)
[[ -n $toolchain ]] || { echo 'go.mod names no toolchain.' >&2; exit 1; }
# Nothing from the environment changes the build: what is not set here is Go's own default.
export CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOAMD64=v1 GOARM64=v8.0 GOFLAGS='' GOEXPERIMENT='' GOTOOLCHAIN=$toolchain
used=$("$go" env GOVERSION)
[[ $used == "$toolchain" ]] || { echo "darban-core is built with $toolchain (go.mod), for the same bytes on every machine; this Go is $used." >&2; exit 1; }
mkdir -p -- "$(dirname -- "$out")"
"$go" build -trimpath -buildvcs=false \
    -ldflags="-s -w -buildid= -X github.com/MohZeh/Darban-OVPN/internal/buildinfo.Version=$version" \
    -o "$out" ./cmd/darban-core
chmod 755 -- "$out"
printf '%s  %s\n' "$(sha256sum <"$out" | cut -d' ' -f1)" "$out"

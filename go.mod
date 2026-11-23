module github.com/MohZeh/Darban-OVPN

// The standard library only: no go.sum, no dependency. The toolchain is pinned, so every build of a commit gives
// the same bytes (scripts/build-core.sh checks it).
go 1.27.0

toolchain go1.27.4

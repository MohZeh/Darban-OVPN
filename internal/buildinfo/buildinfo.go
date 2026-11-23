// Package buildinfo holds what the build writes into darban-core.
package buildinfo

// Version is the release darban-core belongs to. scripts/build-core.sh sets it from the file VERSION with
// -ldflags -X. A build without it says "dev", which the installer refuses, since it names no release.
var Version = "dev"

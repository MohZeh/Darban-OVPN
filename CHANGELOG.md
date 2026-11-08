# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0-rc.1] - 2026-11-08

Release candidate for `v1.0.0`, for testing on a server that is not in use.

### Changed
- Enter means no password on the key. A password, when chosen, is much slower to guess from a stolen file.
- A trusted certificate for an IP address comes from a certbot that is new enough, or from the Certbot snap; a server with neither is not offered one.
- While the link certificate is self-signed, each share by link offers a trusted certificate again. Enter still means No.
- Messages and guides say only what is shown: a connected client proves the server and the provider's firewall, not the internet on the device; the note for a self-signed link asks to go past the warning only for that link.

### Fixed
- Diagnostics check the rules that really run: both rules that keep clients apart, NAT for the current VPN network, and an ALLOW rule in `ufw`.
- An update repairs NAT left on another network, and a failed NAT rule leaves the install marked unfinished, so the same command tries again.
- Repairing an install that stopped half way no longer fails on files that were never copied.
- A trusted link certificate that still works stays when a new one cannot be had.
- Remove everything never deletes the profile folder as a whole, and removing or revoking a profile also deletes the copy made for a non-root download user.
- The Advanced menu no longer prints every shell variable.
- Diagnostics report NAT that sends traffic out through an interface the server no longer has, or through another one than the default route, and a NAT rule without masquerade. An update moves NAT from a missing interface to the one of the default route.
- A temporary link never lasts longer than its certificate; a longer time is asked again.
- The installer says when it could not check a NAT file edited by hand, and setup and guides no longer tie the browser warning to a domain name.

## [1.0.0-beta.1] - 2026-11-07

First pre-release, for testing only.

### Server
- Set up a new Ubuntu 24.04 or 26.04 server with OpenVPN from the stable project channel, and the Virtual HWE kernel only if the running kernel needs it.
- Continue a setup that stopped half way, or undo it.
- Keep clients apart from each other and from the cloud metadata service.
- Remove only what the setup added: files, `ufw` rules, repository files and certificates that were there before stay.
- Remove everything the setup added, or only the tool.

### Clients
- Create, list, revoke, and reuse a revoked name safely.

### Sharing
- One-time temporary links, QR codes and `scp`/`sftp` commands.
- Optional password on the private key.

### Reliability
- Daily CRL renewal, with protection against a restored old CA database.
- Repair of interrupted revocations.
- Advanced settings with automatic rollback.

### Maintenance
- Update notice, update, and restore of the previous version from inside the tool.

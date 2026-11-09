# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- A temporary link works until its client connects for the first time, or for at most 24 hours, 1 hour or 15 minutes; Enter means 24 hours. Until then the page and the file can be opened again, and menu `5` shows whether the file was downloaded.
- The link page is in Persian when the device's language is Persian, and in English otherwise. It no longer has a button that opens OpenVPN Connect directly, which opened the app on Android without importing the profile; the downloaded file is opened instead.
- The note to send with a link is shown in English only, because a terminal shows Persian backwards. The Persian note is in the sharing guide.
- A new server suggests a random free UDP port from 1024 to 1999 instead of 1194.
- A suggested key password is 9 characters in one piece, without dashes.
- Profiles carry the client's name for OpenVPN Connect to show, instead of the server address.
- The Setup menu lists About first, then the update entries, and the two removals last.
- The end of a new install, leaving the menu, the README and the guides say how to open the menu again: `sudo darban`.
- Links take a trusted certificate already on the server for the same address, from certbot, a panel such as 3x-ui, or acme.sh, and copy it again after a renewal there. **Settings › Link certificate** also takes a certificate file by its path. A Cloudflare Origin certificate is named and not used, because browsers trust it only through Cloudflare's proxy.
- The Let's Encrypt question lists Yes first, and Enter means Yes. The setup installs certbot on a public address, so the first link does not wait for it.

### Fixed
- Websites open through the VPN on networks that drop split packets, such as many mobile and home networks; before, only apps that send small packets worked. TCP is limited to segments that fit in one tunnel packet, an update adds the rule to an existing install, and diagnostics check it.
- The port for links, and port 80 for a certificate, count a program that listens only on the public address, and the remembered link port is checked again for each link, with the name of the program that took it.
- Check for updates no longer shows curl's 404 line while no stable release exists; it says the installed version is the newest offered.

## [1.0.0-rc.2] - 2026-11-08

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.1`, whose documented install command stopped at the first question.

### Changed
- The install command is now `sudo bash -c 'curl -fsSL .../get.sh | bash'`, with options after `bash -s --`. The README, the guides and the hints in the tool use it.

### Fixed
- The install command no longer stops at the first question. With `curl ... | sudo bash`, as `v1.0.0-rc.1` and earlier showed it, sudo on Ubuntu 24.04 and 26.04 keeps the keys from the setup questions over SSH, as a normal user and as root. That form on a new server is now refused before anything is downloaded, with the command that works.

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

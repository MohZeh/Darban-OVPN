# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0-rc.8] - 2026-11-11

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.7`, with the changes from its test on a real server: the link certificate is kept and renewed instead of requested again, and menu 6 can show a link again. A server on `v1.0.0-rc.6` or later reaches it from the menu (Setup › 2) or with `sudo darban update`.

### Changed
- Menu 6 is **Links and files (show, cancel, delete)**. It says how long a link and a file stay, groups open links and files on the server, and a chosen row opens what can be done with it: show a link again and copy it, or cancel it; show the download commands again and copy one, or delete the file after a confirmation. A number alone removes nothing. Links made before this version cannot be shown again.
- When the link certificate this tool got earlier already covers the address, it is renewed with `certbot renew` instead of requested anew. certbot tells Let's Encrypt which certificate it replaces, and such a renewal can be exempt from the weekly limit.
- **Settings › Link certificate** shows how many of the 5 new Let's Encrypt certificates a week for this address were used. When none is left, no request is sent, and the tool says when the next one can be.
- When Let's Encrypt refuses a certificate for the weekly limit, the tool shows the time it gives. Other failures point to certbot's log.

### Fixed
- **Remove everything** no longer deletes the link certificate by default. Let's Encrypt gives at most 5 new certificates a week for the same address, and each new install asked for one. It now asks, keeps the certificate unless you choose to delete it, and a new install on the same server takes it back without a question or a request.

## [1.0.0-rc.7] - 2026-11-10

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.6`, with the fixes from an audit of its code: safer link certificates, a lock shared by the link service and the menu, and exact guides. A server on `v1.0.0-rc.6` reaches it from the menu (Setup › 2) or with `sudo darban update`; an older one needs the install command.

### Removed
- The install no longer moves settings and files from the tool's earlier name, `mzx-openvpn-manager`, and the diagnostics no longer accept its NAT table, `mzx_openvpn`. No server uses that name any more.

### Fixed
- A link certificate whose key does not match it, whatever left them so, is replaced at the next link. Before, every link failed until the certificate was changed by hand.
- A new link certificate, from Let's Encrypt or self-signed, is made beside the current one and then put in place, so a failure keeps the current pair.
- Cancelling a link, revoking its client, or removing an expired link now waits for a download in progress, so the link service cannot write back the record of a link that is being removed.
- The guides say that a password the administrator chose may have spaces or symbols, and only the suggested one has none; that revoking ends the client's open connection when it can, and asks what to do when it cannot; and that opening the downloaded profile was tested on Android and Windows.

## [1.0.0-rc.6] - 2026-11-10

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.5`, with the fixes and changes from its test on a real server. A server on `v1.0.0-rc.5` or older reaches it with the install command, not with `darban update`; from this version on, `darban update` offers the next test version.

### Changed
- A test version is offered the newest release, test versions included, so `darban update` moves a release candidate to the next one and then to the final version. A final version is still offered only final versions. Up to `v1.0.0-rc.5`, a test version was offered nothing; leave it once with the install command of the newer version.
- Settings shows the link port by number, also before the first link: the port that link will take.
- The password question shows the suggested password on its own line, in the color it has with the link, and says that Enter uses it. A password of your own is a word or a short phrase of at least 9 characters, in English letters, digits, spaces or symbols, so it types the same on every device.
- Keeping the profile on the server asks no password, since the admin fetches it over SSH, and offers to copy the Windows command, the macOS or Linux command, or the SFTP address.

### Fixed
- A setting saved from the menu takes effect at once. Each action runs apart from the menu, which kept the values it had read at start: Settings showed the old link lifetime, link port, new client lifetime or download access, and the next link or client still used them, until the menu was opened again.

## [1.0.0-rc.5] - 2026-11-10

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.4`, with the changes asked for after its test on a real server: easier sharing, a link lifetime setting, and menus ordered by use. The main menu numbers changed.

### Changed
- The menus are ordered by use and grouped. The main menu: 1 Create client, 2 List clients, 3 Connected now (moved from Maintenance), 4 Revoke client, 5 Share a profile, 6 Waiting to be picked up, 7 Settings, 8 Maintenance, 9 Setup. Settings groups the server address and port, then the link lifetime, port and certificate, then Advanced; the link port moved there from Advanced.
- "Active links" and "Delete server copy" are one item, **Waiting to be picked up**: open links, with the time left and whether the file was downloaded, then profile files kept on the server. A row's number cancels the link or deletes the file.
- Sharing a profile asks one question with two answers: a temporary link, or keeping the file on the server with every command to download it, which replaces "My own computer" and "Later". The QR code is no longer a way of its own: it holds the same link, so it is an option of the link's copy question.
- How long a temporary link works is a setting, **Settings › Link lifetime**: 24 hours by default, or any whole number of hours from 1 to 72. Sharing no longer asks for it. When the link's certificate ends sooner, the link gets the whole hours left, and the tool says so.
- A temporary link is shown with its password and its note in one block, under `Link:`, `Password:` and `Note:`, with no frame or indent, so one mouse selection takes all of it. The password is bold and colored.
- After a link, Enter copies that block to the clipboard of your own computer, over SSH, where the terminal allows it (OSC 52). A second option copies it without the password, to send that another way. After a download, the password can be copied the same way.

## [1.0.0-rc.4] - 2026-11-09

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.3`, whose setup stopped on a public IP address.

### Changed
- A first link takes the first free port of 9347, 9563 and 9741 instead of 443, 8443 and 9443, which panels such as 3x-ui and tools such as Portainer often use; a link would then hold their port while it lasts. A port already saved stays as it is, and Settings › Advanced › Share link port changes it.
- TCP MSS for VPN traffic is limited to 1280 instead of 1300, for a little more room on paths with a smaller MTU.

### Fixed
- A new server on a public IP address finishes the setup again. In `v1.0.0-rc.3` the setup stopped without a word right after "OpenVPN ... installed": reading certbot's version from `apt-cache` ended early, `apt-cache` was killed by SIGPIPE, and `pipefail` turned that into a failure. The certbot step now reads to the end, and nothing that fails inside it can stop the setup.
- A temporary link opens on a device that is already connected to the same server. The TCP MSS limit covered traffic through the server, but not connections to the server itself, so the page did not load through the VPN on networks that drop split packets. The limit now also covers those, and diagnostics check it.
- Esc on the question of how long a link works says that the client was still created, and where to share or revoke it.

## [1.0.0-rc.3] - 2026-11-09

Release candidate for `v1.0.0`, for testing on a server that is not in use. It replaces `v1.0.0-rc.2`, with the fixes from its first test on a real server and from an audit of the code and the guides.

### Changed
- A temporary link works for at most 24 hours, 1 hour or 15 minutes, and ends sooner once a connection with its profile is seen; Enter means 24 hours. Until then the page and the file can be opened again, and menu `5` shows whether the file was downloaded.
- The Persian README, guides and link page are rewritten in plain, formal Persian, with the technical names kept as they are. They say only what is checked, and the English guides now carry the same additions: a split tunnel in the connection check, the self-signed certificate case, the TCP MSS term, and what not to send in a problem report.
- The link page is in Persian when the device's language is Persian, and in English otherwise. It no longer has a button that opens OpenVPN Connect directly, which opened the app on Android without importing the profile; the downloaded file is opened instead.
- The note to send with a link is shown in English only, because a terminal shows Persian backwards. The Persian note is in the sharing guide.
- A new server suggests a random free UDP port from 1024 to 1999 instead of 1194.
- A suggested key password is 9 characters in one piece, without dashes.
- Profiles carry the client's name for OpenVPN Connect to show, instead of the server address.
- The Setup menu lists About first, then the update entries, and the two removals last.
- The end of a new install, leaving the menu, the README and the guides say how to open the menu again: `sudo darban`.
- Links take a trusted certificate already on the server for the same address, from certbot, a panel such as 3x-ui, or acme.sh, and copy it again after a renewal there. **Settings › Link certificate** also takes a certificate file by its path. A Cloudflare Origin certificate is named and not used, because browsers trust it only through Cloudflare's proxy.
- Colors have one meaning each, across the menus and messages: cyan for the title and the keys to press, blue for groups and values, dim for labels and hints, magenta for what to type or do (every command, and the part after `→`), green, yellow and red for success, warnings and errors, and red for menu items that cannot be undone. Only the eight basic colors are used, so a light or dark terminal shows them in its own theme, and every message keeps its symbol and words. `NO_COLOR=1` still turns them off.
- The Let's Encrypt question lists Yes first, and Enter means Yes. The setup installs certbot on a public address, so the first link does not wait for it.

### Fixed
- Websites open through the VPN on networks that drop split packets, such as many mobile and home networks; before, only apps that send small packets worked. TCP is limited to segments that fit in one tunnel packet, an update adds the rule to an existing install, and diagnostics check it.
- The port for links, and port 80 for a certificate, count a program that listens only on the public address, and the remembered link port is checked again for each link, with the name of the program that took it.
- Check for updates no longer shows curl's 404 line while no stable release exists; it says the installed version is the newest offered.
- Esc on the question of how long a link works cancels: no link is made, no password is shown for one, and the tool does not wait for a connection.
- Messages and guides say what is really checked. Diagnostics report the TCP MSS rule, not that websites open on every network. A link ends when a connection with its profile is seen, checked every 10 seconds, and a server without a local management interface is told that its links last until their time is up. A trusted certificate for links is possible, not promised.
- Taking a certificate from another tool copies the certificate and key beside the current pair, checks them as a pair, and only then replaces it, so a failure or a renewal half way keeps the current pair.
- The link page ignores a language marked `q=0`.
- The guides show Setup's current numbers, and a test compares them with the menu.
- The backup that Remove everything makes is named as not encrypted, on screen and in the guide. The guide's command for an install without questions fails when the download fails.

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

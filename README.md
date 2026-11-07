<a href="#quick-start"><img src="docs/assets/hero.png" alt="Darban OVPN: your own OpenVPN server, run from one terminal menu. One-time links for sharing profiles, verified revocation and automatic rollback on Ubuntu 24.04 and 26.04." width="100%"></a>

<div align="center">

**Run your own OpenVPN server from one terminal menu, on a clean Ubuntu 24.04 or 26.04 VPS.**

[![CI](https://github.com/MohZeh/darban-ovpn/actions/workflows/ci.yml/badge.svg)](https://github.com/MohZeh/darban-ovpn/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/MohZeh/darban-ovpn?include_prereleases&sort=semver)](https://github.com/MohZeh/darban-ovpn/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Ubuntu 24.04 and 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)

[فارسی](README.fa.md) · [Install](docs/en/installation.md) · [Usage](docs/en/usage.md) · [Sharing](docs/en/sharing.md) · [Advanced](docs/en/advanced.md) · [Operations](docs/en/operations.md) · [Case study](docs/case-study.md)

</div>

> [!WARNING]
> **Pre-release.** This version is being tested on real servers. Try it on a disposable VPS first. See [Project status](#project-status).

Darban (دربان, "gatekeeper") installs a current OpenVPN server and then handles the daily work: creating clients, delivering their profiles safely, revoking access, and keeping the revocation list valid. Every risky change is confirmed first and, where possible, rolled back automatically if it fails.

## Why Darban

| You want to | Darban does |
|---|---|
| Set up a server without a long tutorial | Asks for an address and a port, then installs OpenVPN from the OpenVPN project's repository and the Virtual HWE kernel, without graphics or firmware packages |
| Send a profile to someone safely | Creates a one-time link that expires, and that a messenger's link preview cannot use up |
| Be sure a revoked client is really blocked | Checks the published CRL against the CA database, and warns by name until a revocation is enforced |
| Change settings without locking users out | Keeps a backup, restarts, checks the port, and restores the old configuration if the service does not return |
| Stay in control of your server | Installs nothing without showing it first, updates only after your confirmation, and can remove only what it added |

## Quick start

On a **fresh Ubuntu 24.04 or 26.04 VPS**, connected through direct SSH:

```bash
curl -fsSL https://github.com/MohZeh/darban-ovpn/releases/latest/download/get.sh -o get.sh
sudo bash get.sh
sudo darban
```

While only pre-releases exist, choose a version from [Releases](https://github.com/MohZeh/darban-ovpn/releases) and install it with `sudo bash get.sh --version vX.Y.Z-rc.N`, downloading `get.sh` from that release.

The setup asks only for the server address and UDP port. Everything else has a sensible default that you can change later under **Settings › Advanced**. On a server that already runs OpenVPN, the setup step is skipped and your configuration is not changed. Read [Installation](docs/en/installation.md) first.

## Features

**Clients**
- Create, list and revoke clients, with clear expiry information
- Issue a new certificate under a revoked name; old profiles stay blocked
- See every valid certificate, and why one cannot be managed if that is the case

**Sharing**
- One-time links valid for 15 minutes, 1 hour or 24 hours, and QR codes
- Optional password on the private key, shown only once
- `scp` and `sftp` commands for your own operating system

**Server**
- Daily CRL renewal, with protection against a restored old CA database silently un-revoking clients
- Advanced settings for routing, DNS, network, ciphers and keepalive, with automatic rollback
- Update notice in the menu, update and restore from inside the tool
- Clean removal: only what the setup itself added

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/how-it-works-dark.png">
  <img src="docs/assets/how-it-works-light.png" alt="Architecture diagram. An admin reaches the darban tool over SSH. The tool issues and revokes certificates in the Easy-RSA PKI, which produces a verified CRL in crl.pem; a daily timer renews that file. The tool also edits server.conf and rolls back on failure. OpenVPN reads both files. For sharing, the tool creates a one-time link in the link service, and the VPN user downloads the profile over HTTPS. The VPN user connects to OpenVPN through a UDP tunnel, and traffic reaches the internet through NAT." width="100%">
</picture>

Green is management, blue is profile delivery and orange is VPN traffic. The tool is written in Bash, with a small standard-library Python service that runs only while a link exists. See [the case study](docs/case-study.md) for the reasoning behind the main decisions.

## Security model

- A profile holds a private key, so links work once and expire. There are no permanent links.
- Only a hash of each link token stays on the server, and tokens never reach the logs.
- The CA key has no passphrase, because the daily CRL renewal must run unattended. **Anyone who gains root on the server can issue certificates**, so protect the server and keep an encrypted backup elsewhere.
- Updates are checked against a checksum published with the release. This detects a damaged download, not a compromised GitHub account.

Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Known limits

- Only Ubuntu 24.04 and 26.04 are supported for server setup, with one OpenVPN server, `udp4`, and the layout described in [Installation](docs/en/installation.md).
- Only IPv4 goes through the VPN. A client with its own IPv6 connection uses it directly for IPv6.
- Client, server and CA certificates are not renewed automatically; only the CRL is.
- Direct import into OpenVPN Connect from a link is still being tested. The download button always works.

## Project status

Automated tests run on every push, including a real installation, a real OpenVPN client, revocation and full removal, separately on Ubuntu 24.04 and 26.04. Reboot behavior, DCO and client apps are being checked on real servers before `v1.0.0`. Changes are listed in the [changelog](CHANGELOG.md).

## Contributing

Bug reports and focused pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md).

## Need this on your server?

I build and maintain automation for Linux servers, VPNs and integrations. For installation, hardening or custom work: **[zehtabex@gmail.com](mailto:zehtabex@gmail.com)**

## License

[MIT](LICENSE). Darban OVPN is an independent project, not affiliated with or endorsed by OpenVPN Inc. OpenVPN is a registered trademark of OpenVPN Inc.

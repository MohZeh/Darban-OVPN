# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/) and versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0-beta.1] - 2026-11-06

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

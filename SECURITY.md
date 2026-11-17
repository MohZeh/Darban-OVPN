# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it through [GitHub private vulnerability reporting](https://github.com/MohZeh/Darban-OVPN/security/advisories/new). Include the affected version, the steps to reproduce it, and its impact. Do not include real private keys, profiles or tokens.

This is a project maintained in spare time, so responses are best effort. I will acknowledge a report as soon as I can, and publish the fix and advisory together.

## Supported versions

Only the latest stable release receives security fixes. Pre-releases are for testing.

## What this tool protects, and what it does not

**In scope**
- Unauthorized access to a profile through a temporary link
- A revoked client staying able to connect without a visible warning
- Tokens, keys or passwords reaching logs
- Privilege or file-permission mistakes by the tool itself
- A tampered or damaged release being installed by accident

**Out of scope**
- An attacker who already has root on the server. The CA key has no passphrase, so that the CRL can renew unattended.
- A compromised GitHub account. Release checksums detect damage, not a malicious release.
- Vulnerabilities in OpenVPN, Easy-RSA or Ubuntu themselves. Report those to their projects.

## Advice for operators

- Keep an encrypted backup of the CA outside the server.
- Allow SSH with keys only, and keep the system updated.
- Treat every `.ovpn` file as a password.
- If a temporary link was used by someone else, revoke that client.

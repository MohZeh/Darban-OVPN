# Case study: making a VPN server safe to run by hand

[Back to README](../README.md)

## The problem

Running an OpenVPN server looks simple until something goes wrong. The tutorials cover installation, but the risky moments come later:

- A profile holds a private key, yet it often travels through a chat app.
- "Revoked" in the CA does not mean blocked. OpenVPN only enforces what is in the published CRL.
- One bad configuration change can cut off every user at once.
- Installers tend to pull in more than they need, and rarely undo it cleanly.

The goal for Darban was a tool that one person can use safely on a small VPS, with the failure cases designed first.

## Decision 1: one-time links that survive link previews

**The trap.** The obvious design is a link that deletes the file on its first request. But messengers fetch links to build previews. The link would be used up by the app before the person ever saw it, and the first real user would see "already used", which should mean a stolen profile.

**The design.** A `GET` only ever returns a page. Using the link takes a deliberate `POST` from a button, which preview bots do not send. That creates a second, short-lived address with a small download allowance, because the first attempt to open an app may fail.

**The supporting choices.**
- Only a hash of the token is on disk, and tokens are kept out of logs.
- The profile copy lives in `/run`, so it disappears on reboot.
- A used, expired and unknown link all return the same answer.
- The service runs only while a link exists.

**The trade-off.** A self-signed certificate is the only automatic option for a bare IP address, which means a browser warning. This is stated plainly to the admin rather than hidden, and a hostname gets a trusted certificate.

## Decision 2: treat the CRL as something that can silently go wrong

**The trap.** Two failure modes look like success:

1. A certificate is marked revoked, but publishing the CRL fails. The client can still connect.
2. An old `index.txt` is restored from a backup. A fresh CRL now correctly matches the database and silently un-revokes clients. Every check based on "does the CRL contain the database's revocations" still passes.

**The design.** Verification works in both directions: the CRL must contain every revocation in the database, and the database must know about every revocation in the CRL. Publishing refuses to drop an unexpired revoked certificate, including during the unattended daily run. Undoing that needs one explicit flag.

Unfinished revocations need no state file of their own, because they can be derived from the database and the published CRL. That means the warning cannot get out of step with reality, and it appears by name until the problem is fixed.

**The limit.** If the CRL is restored from the same old backup as the database, the two agree, and the tool cannot tell. The documentation says so.

## Decision 3: every risky change has a way back

**The design.** Changing the port, DNS, network or ciphers follows one path: back up, apply atomically, restart, and check the service and the listening port. If the service does not return, the old file is restored. Changing the network also moves NAT, and restores it together with the configuration.

The message reports what actually happened. If the rollback itself fails, the tool does not claim that nothing changed.

Confirmations use the same idea: the safe answer is the default, and moving to a dangerous option does nothing until Enter is pressed. Keys pressed before a question appears are discarded, so they cannot answer it.

Removal is also designed in. The setup records what it adds, so **Remove everything** takes only that, leaves packages other software needs, and never removes the running kernel.

## Installing less

The server needs one thing from the kernel: the `ovpn` module. The package file lists show that the plain `linux-image-virtual-hwe-24.04` and `linux-image-virtual-hwe-26.04` kernels include it, so no DKMS, headers, firmware or graphics packages are needed. If the running kernel already has the module, no kernel is installed at all. The setup shows apt's own simulated package list, and stops if firmware or graphics packages appear in it.

Questions follow the same rule. Installation asks only for the address and port, and everything else has a default that can be changed later.

## How it is tested

Three layers run on every code change and once a week:

| Layer | What it proves | What it cannot prove |
|---|---|---|
| Behavior tests against a stand-in server, with real OpenSSL | Failure paths: rollbacks, restored databases, refused operations, real HTTPS for links | Real Easy-RSA, systemd and packages |
| Key-press tests in a real pseudo-terminal | Arrow keys, cancel, and terminal state after `Ctrl+C` | How it looks in a given terminal |
| Acceptance test on throwaway Ubuntu 24.04 and 26.04 machines, each with its own result | Real installation, a real client connecting, revocation refused, links, full removal | Reboot, DCO, the provider's firewall, client apps |

The last column is checked by hand on a real VPS before each stable release.

## What is still open

- IPv6 is not tunneled. The server is IPv4 only, so a client with its own IPv6 uses it directly.
- Direct import into OpenVPN Connect from a link is documented for Access Server, and is being tested here.
- Certificates other than the CRL are not renewed automatically.

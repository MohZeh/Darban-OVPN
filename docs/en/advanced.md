# Advanced

[Back to README](../../README.md) · [فارسی](../fa/advanced.md)

You do not need this page for normal use.

## Read the script before running it

Download it, read it, then run it:

```bash
curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0/get.sh -o get.sh
```

```bash
sudo bash get.sh
```

The one-line command runs `curl` inside `sudo` on purpose. In the form `curl ... | sudo bash`, sudo reads the pipe and, on Ubuntu, runs the command in a terminal of its own, so the keys you press never reach the setup questions. `get.sh` notices that form on a new server and stops before it downloads anything.

`get.sh` downloads the release and checks it against `SHA256SUMS`. If they do not match, it runs nothing. The checksum comes from the same release, so it catches a damaged download, not a compromised account.

If you doubt a release, GitHub can check it with its own attestation: `gh release verify v1.0.0 --repo MohZeh/Darban-OVPN`, and for a file you downloaded, `gh release verify-asset v1.0.0 get.sh --repo MohZeh/Darban-OVPN`. The installer does not run these checks.

## Install a specific version

Use the address of that release. It installs its own version:

```bash
sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0/get.sh | bash'
```

To go back to an older version on an installed server, name it:

```bash
sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0/get.sh | bash -s -- --version v1.0.0-rc.10'
```

## Install without questions

```bash
sudo bash -c 'set -o pipefail; curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0/get.sh | bash -s -- --yes --host vpn.example.com --port 1194'
```

`set -o pipefail` makes the command fail when the download fails, so a script that runs it sees the error. Without it, a failed download still ends with status 0, although nothing is installed.

| Option | Meaning |
|---|---|
| `--yes` | Ask nothing; use the defaults |
| `--host NAME\|IP` | The address clients connect to |
| `--port N` | The UDP port |
| `--subnet A.B.C.0` | The VPN network, a private `/24` |
| `--dns "IP [IP]"` | DNS for clients |
| `--split-tunnel` | Send only VPN traffic through the server |
| `--open-ufw` | Add the `ufw` rules. With `--yes` alone, `ufw` is not changed |
| `--install-kernel` | Install the Virtual HWE kernel even if the running kernel has the `ovpn` module |

## What the install does

- Adds the OpenVPN project's apt repository (stable channel) and installs `openvpn`, `easy-rsa`, `socat` and `nftables`.
- On a public address, also installs `certbot`, so temporary links can get a Let's Encrypt certificate: Ubuntu's package for a domain name, and the Certbot project's snap for an IP address. A failed snap install is tried once more, and an install snapd is still working on is waited for. A certbot snap that was already on the server is only refreshed, and **Remove everything** leaves it there. If this fails, the VPN install goes on, and the first link tries again.
- If the running kernel has no `ovpn` module, installs `linux-image-virtual-hwe-24.04` or `linux-image-virtual-hwe-26.04`, matching the system, without recommended packages. If apt plans firmware or graphics packages, the setup stops. A container needs no kernel.
- Creates a CA in `/root/pki` and a server certificate valid for 10 years.
- Writes `/etc/openvpn/server/server.conf`, enables IPv4 forwarding, and adds NAT for the VPN only, in its own nftables table.
- Keeps clients apart: they cannot reach each other, or the cloud provider's metadata service at `169.254.169.254`, through the server. They can still reach other private networks the server reaches. A `client-to-client` line added to `server.conf` would let OpenVPN pass traffic between clients itself, past these rules, so Diagnostics report it.
- Limits TCP MSS for VPN traffic to 1280 in both directions, only for connections that announce a larger one: traffic through the server, and connections to the server itself, such as a temporary link opened on a device that is already connected.
- Starts OpenVPN, and writes details to `/var/log/darban-setup.log`.
- Turns on [connection events](#connection-events), with one more restart of OpenVPN, before any client exists.

If a kernel is added, the current one stays as a fallback and nothing reboots automatically. The VPN works at once without [DCO](glossary.md#dco).

The address comes from the network interface. Behind NAT, it is looked up with `api.ipify.org`, then `ifconfig.me`, which see this server's address.

| Default | Value |
|---|---|
| VPN port | A random free UDP port from 1024 to 1999, never 1194 |
| VPN network | First free `/24` from `10.8.0.0` |
| Routing | All client IPv4 traffic |
| Client DNS | `1.1.1.1`, `8.8.8.8` |

## A server that already runs OpenVPN

If `/etc/openvpn/server/server.conf` exists, the server setup is skipped, and the installer does not change your OpenVPN configuration or restart it. It expects:

- OpenVPN 2.7 with `udp4` and exactly one `tls-crypt` directive using `/etc/openvpn/server/tls-crypt.key`
- Easy-RSA 3 at `/usr/share/easy-rsa/easyrsa`, with its PKI in `/root/pki` and a CA key without a passphrase
- The server certificate recorded in the PKI's `index.txt`
- `crl-verify /etc/openvpn/server/crl.pem` with a valid CRL
- The unit `openvpn-server@server.service`, running

If a check fails, the installer stops before installing anything and says why. On such a server **Remove everything** is refused, and changing the VPN network is refused because this tool does not manage its NAT. [Connection events](#connection-events) stay off, because they need lines in your `server.conf`.

For single-client disconnect, add a local management socket and install `socat`. The same socket lets a temporary link end when a connection is seen; without it, links end only when their time is up:

```text
management /run/openvpn-server/darban.sock unix
```

## Connection events

With connection events, OpenVPN tells this tool when a client connects and when a session ends. A temporary link, or a file kept on the server, then ends within seconds of the first connection, and **List clients** shows when each client was last seen.

- **The script.** OpenVPN runs `/usr/local/libexec/darban-ovpn-event` as `nobody` at each connection and at the end of each session. It writes one line into a queue and always exits with 0: it never refuses or holds up a connection, even when the queue is missing or full.
- **The lines.** The install adds three lines to `server.conf`: `script-security 2`, and `client-connect` and `client-disconnect` with that script. Adding them restarts OpenVPN once, and if OpenVPN does not come back, the previous file is restored.
- **The queue.** `/run/darban-events` is a tmpfs of its own, of 2 MB, so a full queue never fills `/run`. Its path unit starts `darban events` as root, which checks each line and applies it. A malformed line is set aside in `bad/`, with its reason; one that cannot be applied now waits and is tried again, at the latest by the next five-minute check.
- **The five-minute check.** `darban-sweep.timer` runs `darban sweep` a minute after boot and every five minutes: it applies what is left, ends expired links and files kept on the server, and ends the link or file of a client that is connected although no event said so.
- **The timer for kept files.** `darban-expire.timer` runs the same check when the next file kept on the server is due, so a file goes at its time within a few seconds as a rule. The tool sets it again after each file it makes or deletes. It does not survive a reboot, and if it cannot be set the five-minute check deletes the file, at most five minutes late; **Diagnostics** then warn.
- **Which share.** When a profile names its share, OpenVPN passes the name to the script, and a connection ends only that share; another copy of the same client leaves it. Profiles do not name it yet: whether every OpenVPN Connect imports such a profile is still being tested. `SHARE_ID_IN_PROFILE=yes` in `/etc/darban/config` turns it on, for that test only. The name can only narrow what a connection ends; it never lets anyone in.

The lines are written only into a `server.conf` this tool's setup made, and only when each check passes: no other `client-connect` or `client-disconnect` script, `script-security` not set to 0 or 1, the script runs as `nobody`, OpenVPN's unit does not limit `LimitNPROC` to 64 or less, and the queue is mounted. Otherwise the install says why, nothing changes, and links end as before: when their time is up, or when the link service sees the connection. After fixing the cause, turn them on with:

```bash
sudo darban enable-events
```

**Diagnostics** show the group **Connection events**: the queue, its path unit and the five-minute check, events waiting more than 10 minutes, lines set aside, and the process limits of OpenVPN. Darban shows the faults it can see. If one connection's event is lost silently, that link stays open until it expires.

**Trust boundary.** The queue takes what OpenVPN's user, `nobody`, writes. Any other program that runs as `nobody` on this server can write there too. It can end a client's temporary link early, make **List clients** show a wrong `LAST SEEN`, or fill the queue, so that links end only when their time is up. It cannot open a link, let a client in, or touch a file outside the queue. So run no other service as `nobody` on a VPN server.

**Uninstall this tool only** stops the timer for kept files first, then removes the units and the queue, and keeps the script and its lines, so OpenVPN needs no restart and every client still connects; the script then records nothing. The summary shows the command that removes them, in this order: the lines, a restart of OpenVPN, then the script. **Remove everything** removes all of it.

## Advanced settings

Open **Settings › Advanced**. Items marked `*` (1 to 6, and the OpenVPN port in **Settings**) change `server.conf` and restart OpenVPN: connected users drop for a few seconds and reconnect by themselves. Each item first says what it changes. Where common values exist, they come as a numbered list: type the number, or type a value of your own.

| # | Setting | Notes |
|---|---|---|
| 1 | Traffic routing | **Full tunnel** sends all client IPv4 traffic through the server, and IPv6 goes directly, outside the VPN; **split tunnel** only the VPN network. Switching to full adds default DNS if none is set. The server needs NAT for the full tunnel |
| 2 | DNS for clients | One or two IPv4 addresses, or one from the list: Cloudflare, Google, Quad9 (blocks known malicious sites), AdGuard (blocks ads and trackers). Not used in a split tunnel, where clients keep their own |
| 3 | VPN network | A private `/24` ending in `.0`, not overlapping an existing route; the tool suggests a free one. NAT follows the change. Refused if this tool did not create the NAT. Fixed addresses from `client-config-dir` or `ifconfig-pool-persist` are not updated |
| 4 | Data ciphers | `AES-256-GCM`, `AES-128-GCM`, `CHACHA20-POLY1305`, separated by colons, or one of three ready lists. Others would turn DCO off. Clients with no cipher in common must get a new profile |
| 5 | Keepalive | Ping interval and timeout in seconds, or one from the list: normal `10 60`, mobile networks `20 120`, quicker `5 30`. The timeout must be at least twice the interval |
| 6 | Log detail | `0` to `6`, where `3` is normal. `4` and up are for troubleshooting and can log private details |
| 7 | New client lifetime | Days for new client certificates, such as `365` or `730`, or `0` for the Easy-RSA default of 825 days. No restart |
| 8 | Download access | SSH address, port and user shown in `scp` and `sftp` commands. No restart |

The link settings are in **Settings** itself, under **SHARING**: **Shares expire after**, which holds for files kept on the server too, **Link port** and **Link certificate**. None of them restarts OpenVPN.

**How a change is applied:** you confirm it, `server.conf` is backed up next to itself (the newest five are kept), and OpenVPN restarts. If the UDP port does not return within 5 seconds, the previous file is restored and OpenVPN restarted. If that also fails, an urgent message says so. This check is local: it cannot prove that clients reach the server from the internet.

`/etc/darban/config` holds tool settings. It is read as data and never executed.

```text
DOWNLOAD_SSH_HOST=203.0.113.10
DOWNLOAD_SSH_PORT=22
DOWNLOAD_SSH_USER=root
CLIENT_CERT_DAYS=825
LINK_PORT=9347
UPDATE_CHECK=no
```

The menu looks for a new release when it starts, at most once an hour, by asking GitHub's API, which then sees this server's address, and waits up to two seconds for the answer, so a new version shows on the first screen. After a failed check it tries again ten minutes later, or when GitHub says its limit allows. That limit counts every program on the server's address, the VPN clients' traffic included. **Setup** shows the state beside **Check for updates**: a new version, up to date with the time of the check, or why it is not known. `UPDATE_CHECK=no` turns the notice off, as does **Setup › Update notice**. The tool never installs an update by itself.

## Firewall ports

| Port | Needed for |
|---|---|
| Your chosen UDP port | VPN clients |
| 9347, 9563 or 9741 TCP | Temporary links. The first one that no other program uses on any address is chosen and kept, and checked again for each link. If another program has taken it, the tool names that program. These ports are uncommon on purpose: panels such as 3x-ui, and tools such as Portainer, often use 443, 8443 and 9443. **Settings › Link port** sets another one |
| 80 TCP, for a moment | Only for a Let's Encrypt certificate, when it is requested and at each renewal: about every 60 days for a domain name, and for each new six-day certificate of an IP address |

## The blocklist (CRL)

OpenVPN reads the CRL for each new connection. A daily timer renews it when 60 days or fewer remain, or when the published file is not valid.

```bash
sudo darban-crl-maintain --check
```

```bash
sudo journalctl -u darban-crl.service -n 20 --no-pager
```

### A revocation that did not finish

If a certificate is revoked in the CA but the CRL is not published, **that client can still connect**. The menu, the list and the diagnostics name it until this is fixed. After fixing the cause, run **Maintenance › Fix the blocklist** or `sudo darban repair-crl`. It publishes the CRL, removes the leftover profile and handles the active session.

The repair finds what is left by the certificate inside each file, not by the name: an open link, the profile kept on the server, and the copy made for the SSH user. Only those that hold a revoked certificate are deleted, so the links and files of a client created again with the same name stay. A link or file whose certificate cannot be identified, for example a damaged one or one from another CA, is not deleted. The diagnostics name it, a new client with that name cannot be created, and you can delete it yourself in **Links and files**.

### Restoring an old backup of the CA

Restoring an older `index.txt` could make revoked clients valid again. The tool treats this as an error and refuses to publish a CRL that drops an unexpired revoked certificate, even in the timer and in repair. **Restore the current `index.txt`.** Only if you really want the revocation undone:

```bash
sudo darban-crl-maintain --renew --allow-crl-shrink
```

This protection relies on the published CRL. If `index.txt` and `crl.pem` both come from the same old backup, the tool sees no contradiction, and later revocations are lost. After any restore, compare the revoked list with your own records.

## Certificates

Only the CRL renews automatically. The menu warns 30 days before the CA or server certificate expires; renewing those is manual work with Easy-RSA. A client certificate that expires needs a new client.

## Backup

**Maintenance › Back up the CA now** makes an encrypted backup of the CA. With it, a lost server comes back with its CA, every client and its blocklist, and the profiles already on devices keep working.

**What it holds:** the CA and its private key, the index of the CA, every client certificate and key, the CRL, the server certificate, key and `tls-crypt.key`, `server.conf`, the settings of this tool and when each client was last seen. It never holds profiles, the NAT file, the backup settings or any program.

**Encrypted for a key only you have.** The backup is encrypted with [age](https://age-encryption.org). On your own computer, make a key once:

```bash
age-keygen -o darban-backup.key
```

It prints a public key that starts with `age1`. Give the tool only that public key; keep the file on your computer. The server can then make backups at any time, and can never open one. With a key set, a backup is also made after each change to the CA, such as a new client or a revocation, and once a day when something changed. The daily backup runs right after the daily blocklist (CRL) check, and only when that check succeeds; when it fails, **Diagnostics** show the failed check. Without a key, **Back up the CA now** can use a passphrase instead, for that one backup.

The tool offers to install the small `age` package the first time.

**Where it is:** `/var/backups/darban-pki`, readable only by root, with a `.manifest.json` beside each backup: when it was made, on which server, the CA fingerprint, how many clients, and the checksum of the archive. The newest 14 are kept. **This copy is on this server. To recover from a lost server you need a copy elsewhere and your private key.** The tool shows an `scp` command for it. A user other than `root` gets a copy in its home folder, which is safe, since it is encrypted.

**Write the CA fingerprint down.** **Back up the CA now** and **Diagnostics** show it. A restore asks for it, or for a profile from one of your devices, because it must know the right CA from something outside the backup.

**Hooks.** After each backup, every program in `/etc/darban/backup-hooks/` gets the paths of the archive and its manifest, and nothing else. Only root's own files with mode 700 run, in a folder with mode 700, two minutes at most each; one that does not stop then is killed. A hook that fails never fails the backup; **Diagnostics** name it. Ready-made hooks for Telegram, email or cloud storage come in v1.1.

### Restore

Open the backup on your computer, copy the `.tar` to the server, and restore it:

```bash
age -d -i darban-backup.key darban-pki-<server>-<time>.tar.age > darban-pki.tar
```

```bash
sudo darban restore darban-pki.tar --ca-fingerprint <the SHA-256 fingerprint you wrote down>
```

Instead of the fingerprint, `--ca-from client.ovpn` takes the CA from a profile of one of your devices. On a new server, set the server up first as usual; the restore then replaces its new CA.

**The server address.** A backup holds the settings of the server it was made on, its address among them. When that address is not one of this server's own, the restore says so before it asks, and **Diagnostics** warn until you change it under **Settings › Server address**. Then send each profile again: one made with the old address connects to the old server. Behind NAT, where the public address of this server is on none of its interfaces, the tool cannot tell, and says nothing.

Nothing changes until every check has passed: the archive must have the manifest of a backup of this tool, and may hold only the files above, as regular files of a limited size; each must match its checksum; the CA must be the one you named, with its private key; the server certificate must come from that CA. `server.conf` is written again from the template of this tool, with only its port, network, routing, DNS, ciphers, keepalive and log detail taken from the backup; any other line, such as `up`, refuses the whole restore. A CRL that is missing, cannot be read or has expired is said so, and a new one is made with the restored CA.

**Changes after the backup.** When the server still has the same CA, the tool compares the backup with that CA's index and blocklist. A backup that does not know a certificate issued, or a revocation made, after it was made is older than the CA in use: the restore is refused, nothing changes, and the tool names each such client with its serial. Use a newer backup, or keep the CA in use. A certificate that only expired since, or one the backup has revoked, is fine.

On a new server, with another CA, or where the index of the same CA cannot be read, the tool cannot know them. It still checks what the blocklist of the same CA lists, if there is one. Then it says "Revocations and certificates issued after <time> cannot be known" and asks you to type the server name. A certificate issued after the backup would connect after the restore, and this tool could not list or revoke it. After the restore, **Diagnostics** warn until you revoke, and issue again, any client you are not sure of, and then run:

```bash
sudo darban restore --acknowledge
```

**What the end of a restore checks:** that OpenVPN is really running, its port is open, and the blocklist and **Diagnostics** are healthy. It does not connect a client.

**If a restore stops half way,** for example at a power cut, OpenVPN stays off, even after a reboot, until it is done. The next run of this tool, or of the installer, finishes it. OpenVPN is started with the restored files only once they are all in place and checked, and it is enabled at boot again only once the restore is done, so a power cut even then leaves it off after a reboot.

Until the restore is done, `--rollback` undoes it: the CA, the server files, the settings, the client records it added and OpenVPN are as they were. It says so only once each of them is back. What it could not put back is named, and the next `--rollback` goes on from there; nothing finishes that restore forward any more, the installer included, which then stops and says so. Once the restore is done, it is not undone; only its cleanup can be left, and `--resume` finishes it. A `--resume` or `--rollback` that waited for another one decides only once it holds the lock, and only on the restore it was asked for: it never acts on a restore that was finished, or undone, meanwhile, nor on another restore begun since. To finish it or undo it yourself:

```bash
sudo darban restore --resume
```

```bash
sudo darban restore --rollback
```

What the restore replaced is kept, readable only by root and **not encrypted**, in `/var/backups/darban-pki/pre-restore-<id>` for 30 days, then deleted. The last message of the restore gives the date, and **Diagnostics** warn from 7 days before. To keep it longer, copy it elsewhere first. A copy whose restore did not finish its cleanup, or whose time cannot be read, is never deleted; **Diagnostics** name it.

### The copy Remove everything offers

The backup that **Remove everything** offers is a `.tar.gz` file in `/root`, readable only by root. It holds the CA private key and is **not encrypted**. Move it off the server, and keep it encrypted. **Remove everything** keeps the encrypted backups in `/var/backups/darban-pki`.

## What removal does

| Option | Removes | Keeps |
|---|---|---|
| **Setup › Uninstall this tool only** | The tool, its timers, open links, the units and queue of connection events, and this tool's hook in certbot's renewal file | OpenVPN, PKI, CRL, `server.conf`, profiles, settings, the link certificate from Let's Encrypt, which certbot goes on renewing, and the event script with its lines in `server.conf`, so OpenVPN needs no restart |
| **Setup › Remove everything** | The tool, OpenVPN, CA, profiles, NAT, connection events and the record of when clients were seen, the repository, the packages and the certbot the setup added | The link certificate it got from Let's Encrypt, unless you choose to delete it, so a new install here uses it without a new request; the Virtual HWE kernel unless you choose otherwise, the optional backup, and what was there before: other files in the profile folder, `ufw` rules, and repository files, which are put back |

**After Uninstall, nothing renews the CRL.** Renew it yourself before it expires, or OpenVPN may refuse clients.

**After Remove everything, every `.ovpn` file stops working,** even if you install OpenVPN again. Only restoring the backup brings the old CA, and with it the old profiles, back. Copies on devices are not deleted; they just cannot connect. A backup is offered first and is the default. This option works only on a server the setup created. Packages are removed only if the setup added them and nothing else needs them. The running kernel is never removed. Closing ports in your provider's firewall is up to you.

If a setup stopped half way, undo it with:

```bash
sudo bash /usr/local/lib/darban/remove-server.sh --yes
```

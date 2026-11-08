# Advanced

[Back to README](../../README.md) · [فارسی](../fa/advanced.md)

You do not need this page for normal use.

## Read the script before running it

Download it, read it, then run it:

```bash
curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0-rc.1/get.sh -o get.sh
```

```bash
sudo bash get.sh
```

The one-line command runs `curl` inside `sudo` on purpose. In the form `curl ... | sudo bash`, sudo reads the pipe and, on Ubuntu, runs the command in a terminal of its own, so the keys you press never reach the setup questions. `get.sh` notices that form on a new server and stops before it downloads anything.

`get.sh` downloads the release and checks it against `SHA256SUMS`. If they do not match, it runs nothing. The checksum comes from the same release, so it catches a damaged download, not a compromised account.

## Install a specific version

Use the address of that release. It installs its own version:

```bash
sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0-rc.1/get.sh | bash'
```

To go back to an older version on an installed server, name it:

```bash
sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0-rc.1/get.sh | bash -s -- --version v1.0.0-beta.1'
```

## Install without questions

```bash
sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.0.0-rc.1/get.sh | bash -s -- --yes --host vpn.example.com --port 1194'
```

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
- If the running kernel has no `ovpn` module, installs `linux-image-virtual-hwe-24.04` or `linux-image-virtual-hwe-26.04`, matching the system, without recommended packages. If apt plans firmware or graphics packages, the setup stops. A container needs no kernel.
- Creates a CA in `/root/pki` and a server certificate valid for 10 years.
- Writes `/etc/openvpn/server/server.conf`, enables IPv4 forwarding, and adds NAT for the VPN only, in its own nftables table.
- Keeps clients apart: they cannot reach each other, or the cloud provider's metadata service at `169.254.169.254`, through the server. They can still reach other private networks the server reaches.
- Starts OpenVPN, and writes details to `/var/log/darban-setup.log`.

If a kernel is added, the current one stays as a fallback and nothing reboots automatically. The VPN works at once without [DCO](glossary.md#dco).

The address comes from the network interface. Behind NAT, it is looked up with `api.ipify.org`, then `ifconfig.me`, which see this server's address.

| Default | Value |
|---|---|
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

If a check fails, the installer stops before installing anything and says why. On such a server **Remove everything** is refused, and changing the VPN network is refused because this tool does not manage its NAT.

For single-client disconnect, add a local management socket and install `socat`:

```text
management /run/openvpn-server/darban.sock unix
```

## Advanced settings

Open **Settings › Advanced**. Items 1 to 6 change `server.conf` and restart OpenVPN: connected users drop for a few seconds and reconnect by themselves.

| # | Setting | Notes |
|---|---|---|
| 1 | Traffic routing | **Full tunnel** sends all client IPv4 traffic through the server; **split tunnel** only the VPN network. Switching to full adds default DNS if none is set. The server needs NAT for the full tunnel |
| 2 | DNS for clients | One or two IPv4 addresses. Not used in a split tunnel, where clients keep their own |
| 3 | VPN network | A private `/24` ending in `.0`, not overlapping an existing route. NAT follows the change. Refused if this tool did not create the NAT. Fixed addresses from `client-config-dir` or `ifconfig-pool-persist` are not updated |
| 4 | Data ciphers | `AES-256-GCM`, `AES-128-GCM`, `CHACHA20-POLY1305`, separated by colons. Others would turn DCO off. Clients with no cipher in common must get a new profile |
| 5 | Keepalive | Ping interval and timeout in seconds. The timeout must be at least twice the interval |
| 6 | Log detail | `0` to `6`, where `3` is normal. `4` and up are for troubleshooting and can log private details |
| 7 | Download access | SSH address, port and user shown in `scp` and `sftp` commands. No restart |
| 8 | New client lifetime | Days for new client certificates, or `0` for the Easy-RSA default. No restart |
| 9 | Share link port | TCP port for temporary links. No restart |

**How a change is applied:** you confirm it, `server.conf` is backed up next to itself (the newest five are kept), and OpenVPN restarts. If the UDP port does not return within 5 seconds, the previous file is restored and OpenVPN restarted. If that also fails, an urgent message says so. This check is local: it cannot prove that clients reach the server from the internet.

`/etc/darban/config` holds tool settings. It is read as data and never executed.

```text
DOWNLOAD_SSH_HOST=203.0.113.10
DOWNLOAD_SSH_PORT=22
DOWNLOAD_SSH_USER=root
CLIENT_CERT_DAYS=825
LINK_PORT=443
UPDATE_CHECK=no
```

`UPDATE_CHECK=no` turns off the daily update notice, as does **Setup › Daily update notice**. The tool never installs an update by itself.

## Firewall ports

| Port | Needed for |
|---|---|
| Your chosen UDP port | VPN clients |
| 443, 8443 or 9443 TCP | Temporary links; the first free one is kept |
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

If a certificate is revoked in the CA but the CRL is not published, **that client can still connect**. The menu, the list and the diagnostics name it until this is fixed. After fixing the cause, run **Maintenance › Repair CRL** or `sudo darban repair-crl`. It publishes the CRL, removes the leftover profile and handles the active session.

### Restoring an old backup of the CA

Restoring an older `index.txt` could make revoked clients valid again. The tool treats this as an error and refuses to publish a CRL that drops an unexpired revoked certificate, even in the timer and in repair. **Restore the current `index.txt`.** Only if you really want the revocation undone:

```bash
sudo darban-crl-maintain --renew --allow-crl-shrink
```

This protection relies on the published CRL. If `index.txt` and `crl.pem` both come from the same old backup, the tool sees no contradiction, and later revocations are lost. After any restore, compare the revoked list with your own records.

## Certificates

Only the CRL renews automatically. The menu warns 30 days before the CA or server certificate expires; renewing those is manual work with Easy-RSA. A client certificate that expires needs a new client.

## Backup

Keep an **encrypted** copy of these paths away from the server. They hold the CA private key. Never share them or put them in a repository.

```text
/root/pki
/etc/openvpn/server
/etc/darban
```

## What removal does

| Option | Removes | Keeps |
|---|---|---|
| **Setup › Uninstall this tool only** | The tool, its timer and open links | OpenVPN, PKI, CRL, `server.conf`, profiles, settings |
| **Setup › Remove everything** | The tool, OpenVPN, CA, profiles, NAT, the repository, the packages and the certbot the setup added, and the certificate it got | The Virtual HWE kernel unless you choose otherwise, the optional backup, and what was there before: other files in the profile folder, `ufw` rules, and repository files, which are put back |

**After Uninstall, nothing renews the CRL.** Renew it yourself before it expires, or OpenVPN may refuse clients.

**After Remove everything, every `.ovpn` file stops working,** even if you install OpenVPN again. Only restoring the backup brings the old CA, and with it the old profiles, back. Copies on devices are not deleted; they just cannot connect. A backup is offered first and is the default. This option works only on a server the setup created. Packages are removed only if the setup added them and nothing else needs them. The running kernel is never removed. Closing ports in your provider's firewall is up to you.

If a setup stopped half way, undo it with:

```bash
sudo bash /usr/local/lib/darban/remove-server.sh --yes
```

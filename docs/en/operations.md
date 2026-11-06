# Operations

[Back to README](../../README.md) · [فارسی](../fa/operations.md)

## Diagnostics

**Maintenance › Diagnostics**, or `sudo darban status`, checks the service, port, certificates, CRL, timer, forwarding, NAT and address.

## CRL

OpenVPN reads the CRL for each new connection. A daily timer renews it when 60 days or less remain, or when the published file is invalid.

```bash
sudo darban-crl-maintain --check
sudo journalctl -u darban-crl.service -n 20 --no-pager
```

### A revocation did not finish

If a certificate is revoked in the CA but the CRL could not be published, **that client can still connect**. The header, list and diagnostics name the client until this is fixed. After fixing the cause, run **Maintenance › Repair CRL** or:

```bash
sudo darban repair-crl
```

This publishes the CRL, deletes the leftover profile, and handles the active session.

### Restoring an old backup of the CA

Restoring an older `index.txt` could make revoked clients valid again. The tool treats that as an error: it refuses to publish a CRL that drops an unexpired revoked certificate, including from the timer and repair. **Restore the current `index.txt`.** Only if un-revoking is really what you want:

```bash
sudo darban-crl-maintain --renew --allow-crl-shrink
```

This protection relies on the published CRL. If `index.txt` and `crl.pem` are both restored from the same old backup, the tool sees no contradiction, and later revocations are lost. After any restore, compare the revoked list with your own records.

## Certificates

Only the CRL renews automatically. The header warns 30 days before the CA or server certificate expires. Renewing those is a manual Easy-RSA task.

## Backups

Keep an **encrypted** copy of these outside the server:

```text
/root/pki
/etc/openvpn/server
/etc/darban
```

They contain the CA private key. Never share them or put them in a repository.

## Updating

The menu announces a new stable release at most once a day, in the background, and installs nothing by itself. **Setup › Check for updates** or `sudo darban update` shows the release notes and asks first. Only the tool is replaced. OpenVPN is not restarted, and clients, the PKI and the CRL stay as they are.

The previous version is kept. **Setup › Restore previous version** goes back to it.

Pre-releases are never offered automatically. To install one:

```bash
sudo bash get.sh --version v1.0.0-rc.1
```

## Removing

| Option | Removes | Keeps |
|---|---|---|
| **Setup › Uninstall this tool only** | The tool, its timer and open links | OpenVPN, PKI, CRL, `server.conf`, profiles, settings |
| **Setup › Remove everything** | The tool, OpenVPN, CA, profiles, NAT, repository and packages the setup added | The Virtual HWE kernel unless you choose otherwise, and the optional backup |

**After Uninstall, nothing renews the CRL.** Renew it yourself before it expires, or OpenVPN may refuse clients.

**After Remove everything, every `.ovpn` file stops working for good**, even if OpenVPN is installed again. A backup is offered first and is the default. This option works only on a server built by `server-setup.sh`. Packages are removed only if the setup added them and nothing else needs them. The running kernel is never removed. Close the ports in your provider's firewall yourself.

If the server setup stopped halfway, run from the unpacked release:

```bash
sudo bash setup/remove-server.sh --yes
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Clients cannot connect | The UDP port in your provider's firewall, then `sudo darban status` |
| Connected, but no internet | `Maintenance › Diagnostics` for forwarding and NAT. With Docker, the `iptables` FORWARD policy may be DROP. With `ufw`, forwarding from `tun0` must be allowed |
| The link does not open | Its TCP port in your provider's firewall, then `sudo journalctl -u darban-links.service -n 30 --no-pager` |
| Browser warns about the link | The certificate is self-signed. Use a hostname and Let's Encrypt |
| "Another operation is running" | The CRL timer holds the lock. Try again in a minute |
| DCO is not loaded | Reboot into the Virtual HWE kernel. In a container, it depends on the host |

When reporting a problem, include this output, and **never** a private key or a `.ovpn` file:

```bash
sudo journalctl -u openvpn-server@server -u darban-links -n 50 --no-pager
```

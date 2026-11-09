# Troubleshooting

[Back to README](../../README.md) · [فارسی](../fa/troubleshooting.md)

Start here. It checks the service, the port, certificates, the blocklist and the network, and it names what is wrong:

```bash
sudo darban status
```

## A client cannot connect

| Possible cause | What to do |
|---|---|
| The UDP port is closed in your provider's firewall | This is the most common cause. Open the port in the provider's panel |
| `ufw` blocks it | `sudo darban status` shows the command to run |
| The server's address changed | Change it under **Settings › Server address**, and send the profile again |
| The network blocks UDP | Try another network, such as mobile data |
| The client was revoked or expired | Check with `sudo darban list --all`, and create a new client |

## A client connects but has no internet

| Possible cause | What to do |
|---|---|
| Docker or another program set the FORWARD policy to DROP | Allow traffic from `tun0` in that firewall. With `ufw`, see the line in `sudo darban status` |
| Forwarding or NAT is off | `sudo darban status` shows it under **Network** |
| Apps work, but websites do not open | One possible cause: large packets are split on the way, and the network drops the pieces. An install from before `v1.0.0-rc.3` lacks the rule that limits TCP MSS: run the install command again. `sudo darban status` then shows `TCP MSS for VPN traffic is limited to 1300`. If websites still do not open, check DNS, and compare with the internet without the VPN |

## The link does not open

| Possible cause | What to do |
|---|---|
| Its TCP port is closed in your provider's firewall | Open the port the tool showed with the link |
| The link expired, was cancelled, or the device already connected | Create a new one from menu `4` |
| The service did not start | Run the command below |

```bash
sudo journalctl -u darban-links.service -n 30 --no-pager
```

## The browser warns about the link

The server has no trusted certificate for the link. The link is still encrypted, but the browser cannot confirm whose server it is. To avoid the warning, accept the Let's Encrypt certificate the tool offers with the next link; it works for a domain name or a public IP address. See [The browser warning](sharing.md#the-browser-warning).

## The install stops at the first question

If you type an answer and nothing happens, the command was run as `curl ... | sudo bash`. With that form, sudo keeps your keys from the questions. Press Ctrl+C; if that does not stop it, close the SSH window and connect again. Then run the command from [Step 3](getting-started.md#step-3-run-the-install-command) exactly as it is. Nothing was installed, because the first question comes before anything is installed.

## The install did not finish

Run the same command again. It continues from where it stopped. To undo everything it did:

```bash
sudo bash /usr/local/lib/darban/remove-server.sh --yes
```

The details are in `/var/log/darban-setup.log`.

## The menu says the server cannot be managed

A part of the server is missing or damaged, for example the CA. The menu then offers only diagnostics, updates and removal. Restore the missing part from your [backup](advanced.md#backup), or remove everything and install again.

## The blocklist shows a problem, or a client is "not blocked yet"

A revoked client can still connect until this is fixed:

```bash
sudo darban repair-crl
```

If it refuses because of an old CA database, see [Restoring an old backup of the CA](advanced.md#restoring-an-old-backup-of-the-ca).

## "Another operation is running"

The daily blocklist check or another session holds the lock. Try again in a minute.

## The VPN is not as fast as expected

`sudo darban status` shows **DCO kernel module**. If it is not loaded, reboot if the tool asked for it. In a container, it depends on the host.

## Update says there is nothing to update to

No stable release has been published yet, so the version you have is the newest one offered. Test versions are never offered as updates. See the [Releases](https://github.com/MohZeh/Darban-OVPN/releases) page.

## Reporting a problem

Send the error text and this output. **Never** send a private key or a `.ovpn` file.

```bash
sudo journalctl -u openvpn-server@server -u darban-links -n 50 --no-pager
```

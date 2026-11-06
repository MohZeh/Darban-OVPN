# Advanced settings

[Back to README](../../README.md) · [فارسی](../fa/advanced.md)

Open **Settings › Advanced**. Items 1 to 6 change `server.conf` and restart OpenVPN: connected users drop for a few seconds and reconnect by themselves.

## How changes are applied

1. You confirm the change. The default answer is No.
2. `server.conf` is backed up next to itself. The newest five backups are kept.
3. OpenVPN restarts, and the tool waits up to 5 seconds for the UDP port.
4. If it does not return, the previous file is restored and OpenVPN restarted. If that also fails, an urgent message says so.

The tool checks the service locally. It cannot prove that clients can reach it from the internet.

## Settings

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

## Configuration file

`/etc/darban/config` holds tool settings. It is read as data and never executed.

```text
DOWNLOAD_SSH_HOST=203.0.113.10
DOWNLOAD_SSH_PORT=22
DOWNLOAD_SSH_USER=root
CLIENT_CERT_DAYS=825
LINK_PORT=443
UPDATE_CHECK=no
```

`UPDATE_CHECK=no` turns off the daily update notice. You can also switch it under **Setup › Daily update notice**.

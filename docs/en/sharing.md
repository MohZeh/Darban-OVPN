# Sharing profiles

[Back to README](../../README.md) · [فارسی](../fa/sharing.md)

A `.ovpn` profile contains a private key: whoever has it can connect as that client. After creating a client, or from menu 4, choose one method:

| Method | Use it when |
|---|---|
| Temporary link | Sending the profile to someone else |
| QR code | The user's phone is in front of you |
| My own computer | You will copy the file yourself with `scp` or `sftp` |
| Later | The file should wait on the server |

## Temporary links

Choose how long the link works: 15 minutes, 1 hour or 24 hours. Permanent links do not exist on purpose, because a link stays in chat histories.

**What the recipient sees**

1. Opening the link shows a short page, in Persian and English. This does not use up the link, so a messenger's link preview cannot burn it.
2. Pressing the button uses the link. The address from then on stays valid for 10 minutes and allows up to 3 downloads.
3. The page offers **OpenVPN Connect** and **Download .ovpn**.

If someone finds the link already used and did not use it themselves, **revoke the client and issue a new one**: someone else may hold the profile.

**How it is protected**

- Only a hash of the token stays on the server. A token that was lost cannot be shown again.
- The profile copy lives in `/run/darban-links` and disappears on reboot. The copy in the download folder is removed.
- Revoking a client removes its open links. Menu 5 cancels any link.
- The service runs only while a link exists, and stops by itself afterwards.
- Tokens are not logged. Creating and using a link is logged with the client name and IP address.

> The **OpenVPN Connect** button uses the `openvpn://import-profile/` format documented for OpenVPN Access Server. Its behavior with this server is still being tested on real apps. Use the download button if it does not open.

### Port

The first free port of 443, 8443 and 9443 is chosen and remembered. Change it under **Settings › Advanced › Share link port**. It must be open in your provider's firewall.

### Certificate

| Server address | Certificate |
|---|---|
| Hostname | A free Let's Encrypt certificate is offered. It needs TCP port 80 for a moment and installs `certbot` |
| IP address, or offer declined | Self-signed: the browser shows a warning, and direct import into the app may not work |

With a self-signed certificate, the tool shows its fingerprint.

## QR code

The QR code holds the same temporary link, because a profile is usually too large for a readable code. The small `qrencode` package is installed only after you agree.

## Password on the private key

For any method you can lock the key inside the profile. The tool generates a random password and shows it **only once**. Send it another way than the file or link, so that one leaked channel is not enough. The app asks for it when connecting. The key in the PKI is not changed.

## My own computer

The tool asks for your system and shows only that command: Windows PowerShell, macOS or Linux, or an address for WinSCP and FileZilla. These settings live under **Settings › Advanced › Download access**. Afterwards, delete the server copy when offered, or from menu 6.

## After changing the address or port

Profiles keep the address they were built with. Share them again from menu 4 after changing the hostname, port or ciphers.

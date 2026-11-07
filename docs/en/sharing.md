# Sharing a profile

[Back to README](../../README.md) · [فارسی](../fa/sharing.md)

A profile (`.ovpn` file) holds a private key: whoever has it can connect as that client. After creating a client, or from menu `4`, choose one way to send it:

| Way | Best for |
|---|---|
| **Temporary link** | Sending it to someone else. This is the usual choice |
| **QR code** | A phone in front of you |
| **My own computer** | Fetching the file yourself with `scp` or `sftp` |
| **Later** | Leaving the file on the server for now |

## Temporary link

1. Choose **Temporary link**.
2. Choose how long it works: 1 hour, 15 minutes or 24 hours.
3. Open the TCP port the tool shows in your provider's firewall.
4. Send the link, and the note if the tool shows one.

The person follows [Connect a device](connect-devices.md). There are no permanent links, because a link stays in chat histories.

**If the person finds the link already used, and did not use it:** revoke the client and create a new one, because someone else may have the profile.

To cancel a link, use menu `5`.

## QR code

Choose **QR code**, and scan it with the phone. It holds the same temporary link, because a whole profile is usually too large for a readable QR code. The tool offers to install the small `qrencode` package the first time.

## My own computer

1. Choose **My own computer**, then your operating system.
2. Copy the command the tool shows, and run it on your computer.
3. Choose to delete the server copy when you are done.

If you log in with a user other than `root`, that user gets a private copy of the file in its home folder. The address, port and user come from **Settings › Advanced › Download access**.

## A password on the key

Any way can lock the key with a password. Answer **Yes, make a password**. The tool suggests a short random password in three groups, such as `k7m-3xt-9vw`, easy to type on a phone. Press Enter to use it, or type your own of at least 9 characters. It is shown **only once**. Send it by another route than the link, for example by SMS or a call, so one leak is not enough. The app asks for it when connecting.

When a link has no trusted certificate, the suggested answer is **Yes**: even if someone took the file on the way, it is useless without the password.

## After changing the address or port

Profiles keep the address they were made with. Send them again from menu `4`.

## The browser warning

The tool offers a free certificate from Let's Encrypt, for a domain name or for a public IP address. It needs TCP port 80 open in your provider's firewall for a moment.

- **Domain name:** the certificate comes from Ubuntu's `certbot` package.
- **IP address:** Let's Encrypt gives a six-day certificate, and a new one is requested when a link needs it. This needs `certbot` 5.3 or newer, which Ubuntu does not have yet, so the tool installs it from the Certbot project as a snap, or, without snap, a fixed version from the Python Package Index.

If you decline, or the request fails, the tool makes its own certificate. The link still works and is encrypted, but the browser shows a warning, and direct import into the app may not work. The tool shows a note to send with the link, and the certificate fingerprint.

## How links are protected

- Opening a link only shows a page, so a messenger's preview cannot use it up.
- Pressing the button uses the link. The next address works for 10 minutes and allows up to 3 downloads.
- Only a hash of the link's token stays on the server, so a lost link cannot be shown again.
- The copy of the profile is kept in `/run/darban-links`, which a reboot clears.
- Revoking a client deletes its open links.
- A copy left behind by a crash is removed after a minute.
- The link service runs only while a link exists, and tokens never reach the logs. Creating and using a link is recorded with the client's name and IP address.

The **OpenVPN Connect** button uses the `openvpn://import-profile/` address documented for OpenVPN Access Server. Its behavior with this server is still being tested on real apps.

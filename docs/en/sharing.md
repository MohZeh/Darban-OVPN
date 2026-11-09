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
2. Choose the longest time it may work: 24 hours, 1 hour or 15 minutes. Enter means 24 hours.
3. Open the TCP port the tool shows in your provider's firewall.
4. Send the link, and the note if the tool shows one.

The link stops working as soon as the device connects to the VPN for the first time, or when its time is up. Until then, the person can open it and download the file again, so a mistake on the phone costs nothing. The person follows [Connect a device](connect-devices.md). There are no permanent links, because a link stays in chat histories.

**If the link stopped working before the person connected:** someone else may have connected with it. Revoke the client and create a new one.

To cancel a link, use menu `5`.

## QR code

Choose **QR code**, and scan it with the phone. It holds the same temporary link, because a whole profile is usually too large for a readable QR code. The tool offers to install the small `qrencode` package the first time.

## My own computer

1. Choose **My own computer**, then your operating system.
2. Copy the command the tool shows, and run it on your computer.
3. Choose to delete the server copy when you are done.

If you log in with a user other than `root`, that user gets a private copy of the file in its home folder. The address, port and user come from **Settings › Advanced › Download access**.

## A password on the key

Usually no password is needed, and Enter means **No password**. A password helps most when the link has no trusted certificate: the browser then cannot tell the real server from one placed in between. A password sent by another route keeps the file useless to anyone who only has the link.

Answer **Yes, make a password**, and the tool suggests a short random password of 9 characters in one piece, such as `k7m3xt9vw`, easy to type on a phone. Press Enter to use it, or type your own of at least 9 characters. It cannot be shown again later. Send it by another route than the link, for example by SMS or a call, so one leak is not enough.

The app asks for it when connecting. So that it asks only once, turn on **Save private key password** in OpenVPN Connect when importing the profile, or later in the profile's settings.

The key is locked so that each guess takes a long time, which makes a short password hard to guess from a stolen file. It is not impossible: if a link was used by someone else, revoke the client anyway.

## After changing the address or port

Profiles keep the address they were made with. Send them again from menu `4`.

## The browser warning

The tool offers a free certificate from Let's Encrypt, for a domain name or for a public IP address. It needs TCP port 80 open in your provider's firewall for a moment, when the certificate is requested and at each renewal. Until the link has a trusted certificate, the question comes back each time you share by link, and Enter still means No.

- **Domain name:** the certificate comes from Ubuntu's `certbot` package, and certbot renews it by itself. If a renewal fails, for example because port 80 is closed, the tool asks again when a link needs a new one.
- **IP address:** Let's Encrypt gives a six-day certificate, and a new one is requested when a link needs it. This needs `certbot` 5.3 or newer, which Ubuntu does not have yet, so the tool uses a certbot that is new enough, or installs it from the Certbot project as a snap. A server with neither is not offered one.

If a new certificate cannot be had while the current trusted one still works, the current one stays, and the tool says when it ends. Otherwise, if you decline, or the request fails, the tool makes its own certificate. The link still works and is encrypted, but the browser shows a warning. The tool shows a note to send with the link, and the certificate fingerprint. The note asks the person to go past the warning only for this link, which came straight from you.

The tool shows the note in English, because a terminal shows Persian backwards. In Persian, send this:

> مرورگر هشدار می‌دهد که این اتصال خصوصی نیست، چون این سرور گواهی معتبر ندارد. فقط برای همین لینک که مستقیم از من به دستت رسیده، Advanced و بعد Continue را بزن. این کار را برای سایت‌های دیگر نکن.

If you locked the key, add:

> فایل قفل است و رمز آن جداگانه به دستت می‌رسد.

## How links are protected

- Opening a link or downloading the file does not use it up, so a messenger's preview or a mistake costs nothing.
- The link ends when the client connects for the first time after the link was made. The link service asks OpenVPN about this every 10 seconds. Menu `5` shows whether the file was downloaded.
- The page is in Persian when the device's language is Persian, and in English otherwise.
- Only a hash of the link's token stays on the server, so a lost link cannot be shown again.
- The copy of the profile is kept in `/run/darban-links`, which a reboot clears.
- Revoking a client deletes its open links.
- A copy left behind by a crash is removed after a minute.
- The link service runs only while a link exists, and tokens never reach the logs. Creating a link and each download are recorded with the client's name and IP address.

The page has no button that opens the app directly. In tests on Android, OpenVPN Connect opened but did not import the profile from such a button, even with a trusted certificate. Opening the downloaded file works on every device.

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

The link stops working when its time is up, or about 10 seconds after a connection with this profile is seen, whichever comes first. Until then, the person can open it and download the file again, so a mistake on the phone costs nothing. The person follows [Connect a device](connect-devices.md). There are no permanent links, because a link stays in chat histories.

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

On a domain name or a public IP address, a link can have a trusted certificate, and the browser then shows no warning. The setup already installs `certbot` for it. Getting one can still fail, for example when TCP port 80 is closed in the provider's firewall; the tool then says so.

1. **A trusted certificate already on this server** comes first: one that certbot, a panel such as 3x-ui or x-ui, or acme.sh got for the same address. The tool asks, and Enter uses it. The link service gets a copy, and when the certificate is renewed there, the next link takes the new one. **Settings › Link certificate** also takes a certificate file you name.
2. Otherwise the tool offers a free certificate from **Let's Encrypt**, and Enter means Yes. It needs TCP port 80 open in your provider's firewall for a moment, when the certificate is requested and at each renewal.

Until the link has a trusted certificate, the question comes back each time you share by link.

A **Cloudflare Origin certificate** is not used, and the tool says so. Browsers trust it only through Cloudflare's proxy, and the VPN address cannot go through that proxy, because OpenVPN uses UDP. A Let's Encrypt certificate works for a domain whose DNS is at Cloudflare, with the proxy off for that name.

- **Domain name:** the certificate comes from Ubuntu's `certbot` package, and certbot renews it by itself. If a renewal fails, for example because port 80 is closed, the tool asks again when a link needs a new one.
- **IP address:** Let's Encrypt gives a six-day certificate, and a new one is requested when a link needs it. This needs `certbot` 5.3 or newer, which Ubuntu does not have yet, so the tool uses a certbot that is new enough, or installs it from the Certbot project as a snap. A server with neither is not offered one.

If a new certificate cannot be had while the current trusted one still works, the current one stays, and the tool says when it ends. Otherwise, if you choose No, or the request fails, the tool makes a self-signed certificate. The link is still encrypted, but the browser cannot confirm that it reaches this server, so it warns. In that case:

- The tool shows the certificate fingerprint. A person who knows how to view certificate details in the browser can compare it with a fingerprint you send another way.
- Put a password on the key, and send it separately. If the person cannot receive the profile with confidence, use **My own computer** or a trusted certificate.
- The tool shows a short note to send with the link. It asks the person to go past the warning only for this link, which came straight from you.

The tool shows the note in English, because a terminal shows Persian backwards. In Persian, send this:

> مرورگر هشدار می‌دهد که این اتصال خصوصی نیست، چون این سرور گواهی معتبر ندارد. فقط برای همین لینک که مستقیم از من به دستت رسیده، Advanced و بعد Continue را بزن. این کار را برای سایت‌های دیگر نکن.

If you locked the key, add:

> فایل قفل است و رمز آن جداگانه به دستت می‌رسد.

## How links are protected

- Opening a link or downloading the file does not use it up, so a messenger's preview or a mistake costs nothing.
- The link ends when a connection with the profile is seen after the link was made. The link service asks OpenVPN's management interface about this every 10 seconds, so a connection shorter than that can be missed. A server without a local management interface, such as one this tool did not set up, cannot see connections: its links work until their time is up, and the tool says so when it makes one. Menu `5` shows whether the file was downloaded.
- The page is in Persian when the device's language is Persian, and in English otherwise.
- Only a hash of the link's token stays on the server, so a lost link cannot be shown again.
- The copy of the profile is kept in `/run/darban-links`, which a reboot clears.
- Revoking a client deletes its open links.
- A copy left behind by a crash is removed after a minute.
- The link service runs only while a link exists, and tokens never reach the logs. Creating a link and each download are recorded with the client's name and IP address.

The page has no button that opens the app directly. In tests on Android, OpenVPN Connect opened but did not import the profile from such a button, even with a trusted certificate. Opening the downloaded file works on every device.

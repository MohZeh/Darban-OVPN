# Sharing a profile

[Back to README](../../README.md) · [فارسی](../fa/sharing.md)

A profile (`.ovpn` file) holds a private key: whoever has it can connect as that client. After creating a client, or from menu `5`, choose one way to send it:

| Way | Best for |
|---|---|
| **Temporary link** | Sending it to someone else. This is the usual choice. It can also show a QR code |
| **Keep it on the server** | Fetching the file yourself with `scp` or `sftp`, now or later |

## Temporary link

1. Choose **Temporary link**.
2. The link works for at most the time set in **Settings › Link lifetime**: 24 hours, unless you set another whole number of hours from 1 to 72. If the link's certificate ends sooner, the link gets the whole hours the certificate has left, and the tool says so.
3. Open the TCP port the tool shows in your provider's firewall.
4. Send what the tool shows under **Send this to the person**: the link, and the password and the note when there are any. Enter copies them all; see [Copying what you send](#copying-what-you-send).

The link stops working when its time is up, or about 10 seconds after a connection with this profile is seen, whichever comes first. Until then, the person can open it and download the file again, so a mistake on the phone costs nothing. The person follows [Connect a device](connect-devices.md). There are no permanent links, because a link stays in chat histories.

**If the link stopped working before the person connected:** someone else may have connected with it. Revoke the client and create a new one.

To see a link again, copy it or cancel it, use menu `6`.

### Copying what you send

The tool shows the link, the password and the note together, each under its own label:

```text
Link:
https://203.0.113.10:9347/l/…
Password:
k7m3xt9vw
Note:
Your browser will warn that this connection is not private, …
```

Then it asks **Copy it to your clipboard?**, and Enter copies all of them in this order. With a password, the second option, **Copy without the password**, leaves it out, so you can send it another way.

The text goes over SSH to the clipboard of your own computer. Windows Terminal, kitty, WezTerm and Alacritty allow it, and iTerm2 when its settings allow applications to use the clipboard. PuTTY and the macOS Terminal do not, and neither does tmux unless its `set-clipboard` option is on. The tool cannot see whether it worked. If pasting does not give the text, select the lines from `Link:` down with the mouse: they have no frame and no indent, so the selection holds only that text.

### QR code

For a phone in front of you, choose **Show a QR code** in the copy question, and scan it with the phone. It holds the same temporary link, because a whole profile is usually too large for a readable QR code. The tool offers to install the small `qrencode` package the first time. The copy question then comes back without this option.

## Keep it on the server

Use this when a link cannot be used, for example when your provider does not let you open a TCP port, or to fetch the file to your own computer over SSH.

1. Choose **Keep it on the server**.
2. The tool shows a command for Windows, one for macOS and Linux, and an address for WinSCP or FileZilla. Then it offers to copy one of them, as in [Copying what you send](#copying-what-you-send). Run the one for your computer, now or later.
3. After downloading, delete the server copy from menu `6`.

This way asks for no password: the file comes to you over SSH, which already checks that it is your server.

If you log in with a user other than `root`, that user gets a private copy of the file in its home folder. The address, port and user come from **Settings › Advanced › Download access**.

## A password on the key

Usually no password is needed, and Enter means **No password**. A password helps most when the link has no trusted certificate: the browser then cannot tell the real server from one placed in between. A password sent by another route keeps the file useless to anyone who only has the link.

A password is offered only for a temporary link. Answer **Yes, make a password**, and the tool shows a suggested password on its own line: a random one of 9 characters in one piece, such as `k7m3xt9vw`, easy to type on a phone. Press Enter to use it. Or type your own: a word or a short phrase of at least 9 characters, in English letters, digits, spaces or symbols, so it types the same on every device. It is shown with the link, and cannot be shown again later. It is safer to send it by another route than the link, for example by SMS or a call, so one leak is not enough: choose **Copy without the password**, and send the password separately.

The app asks for it when connecting. So that it asks only once, turn on **Save private key password** in OpenVPN Connect when importing the profile, or later in the profile's settings.

The key is locked so that each guess takes a long time, which makes a short password hard to guess from a stolen file. It is not impossible: if a link was used by someone else, revoke the client anyway.

## After changing the address or port

Profiles keep the address they were made with. Send them again from menu `5`.

## The browser warning

On a domain name or a public IP address, a link can have a trusted certificate, and the browser then shows no warning. The setup already installs `certbot` for it. Getting one can still fail, for example when TCP port 80 is closed in the provider's firewall; the tool then says so.

1. **A trusted certificate already on this server** comes first: one that certbot, a panel such as 3x-ui or x-ui, or acme.sh got for the same address. The tool asks, and Enter uses it. The link service gets a copy, and when the certificate is renewed there, the next link takes the new one. **Settings › Link certificate** shows the state, then asks what to do, and Enter changes nothing:

1. **Nothing, keep it.**
2. **Let's Encrypt:** renews this tool's certificate when it is due, or gets a new one; the row says which, and that a new one is one of 5 a week. A private address cannot have one.
3. **A certificate another tool got:** looks where certbot, panels such as 3x-ui, and acme.sh keep them.
4. **Your own certificate files:** the certificate with its chain (fullchain) and its private key.
5. **A self-signed certificate,** after a confirmation: the browser then warns about every link. A Let's Encrypt certificate this tool got stays in `/etc/letsencrypt`.
6. **The fingerprint,** to compare with what the browser shows.

A certificate changed there reaches open links at once: the link service reloads it, a download in progress finishes, and the tool checks that the port answers with the new certificate. If it does not, the previous one is put back and the tool says so.
2. Otherwise the tool offers a free certificate from **Let's Encrypt**, and Enter means Yes. It needs TCP port 80 open in your provider's firewall for a moment, when the certificate is requested and at each renewal.

Until the link has a trusted certificate, the question comes back each time you share by link.

A **Cloudflare Origin certificate** is not used, and the tool says so. Browsers trust it only through Cloudflare's proxy, and the VPN address cannot go through that proxy, because OpenVPN uses UDP. A Let's Encrypt certificate works for a domain whose DNS is at Cloudflare, with the proxy off for that name.

- **Domain name:** the certificate comes from Ubuntu's `certbot` package, and certbot renews it by itself. If a renewal fails, for example because port 80 is closed, the tool asks again when a link needs a new one.
- **IP address:** Let's Encrypt gives a six-day certificate, and a new one is requested when a link needs it. This needs `certbot` 5.3 or newer, which Ubuntu does not have yet, so the tool uses a certbot that is new enough, or installs it from the Certbot project as a snap. A server with neither is not offered one.

**Let's Encrypt gives at most 5 new certificates a week for the same address**, one more every 34 hours, and deleting one does not give it back. So the tool renews the certificate it got instead of asking for a new one, keeps it when you remove everything, and uses it again after a new install on the same server. When it is kept, Ubuntu's `certbot` package is removed, not purged: a purge would delete `/etc/letsencrypt`, and the certificate with it. The removal says until when the kept certificate is valid. After a new install, a kept certificate that ends sooner than a link may last is renewed without a question. When certbot renews the certificate, by its timer or for a link, the link service reloads it: open links get it at once, and a download in progress finishes. It records each certificate it asked for, as new or renewed. **Settings › Link certificate** shows:

- whether browsers trust the certificate now, checked from the certificate itself: its dates, its address, its key and who issued it;
- where it came from, and its dates (`Valid from … until …`);
- whether certbot's renewal timer is active;
- how many new and renewed certificates this tool recorded in the last 7 days.

That count is only this server's record: Let's Encrypt keeps the real one, and renewals by certbot's own timer are not in it. So when the record shows the week used up, the tool warns and asks anyway. If Let's Encrypt refuses, the tool shows the time Let's Encrypt gives, and the link uses a self-signed certificate until then.

A renewal ends one of three ways, and the tool says which: renewed, with the new end date; not due yet, so nothing was issued; or failed, and the current certificate stays. After a new install, a kept certificate that cannot be used is named with the reason, for example that it is for another address.

If a new certificate cannot be had while the current trusted one still works, the current one stays, and the tool says when it ends. Otherwise, if you choose No, or the request fails, the tool makes a self-signed certificate. The link is still encrypted, but the browser cannot confirm that it reaches this server, so it warns. In that case:

- The tool shows the certificate fingerprint. A person who knows how to view certificate details in the browser can compare it with a fingerprint you send another way.
- Put a password on the key, and send it separately. If the person cannot receive the profile with confidence, use **Keep it on the server** or a trusted certificate.
- The tool adds a short note for the person under `Note:`, and copies it with the link. It asks the person to go past the warning only for this link, which came straight from you.

The tool shows the note in English, because a terminal shows Persian backwards. In Persian, send this:

> مرورگر هشدار می‌دهد که این اتصال خصوصی نیست، چون این سرور گواهی معتبر ندارد. فقط برای همین لینک که مستقیم از من به دستت رسیده، Advanced و بعد Continue را بزن. این کار را برای سایت‌های دیگر نکن.

If you send the password separately, add:

> فایل قفل است و رمز آن جداگانه به دستت می‌رسد.

## How links are protected

- Opening a link or downloading the file does not use it up, so a messenger's preview or a mistake costs nothing.
- The link ends when a connection with the profile is seen after the link was made. The link service asks OpenVPN's management interface about this every 10 seconds, so a connection shorter than that can be missed. A server without a local management interface, such as one this tool did not set up, cannot see connections: its links work until their time is up, and the tool says so when it makes one. Menu `6` shows whether the file was downloaded.
- The page is in Persian when the device's language is Persian, and in English otherwise.
- Only a hash of the link's token stays on the server, so a lost link cannot be shown again.
- The copy of the profile is kept in `/run/darban-links`, which a reboot clears.
- Revoking a client deletes its open links.
- A copy left behind by a crash is removed after a minute.
- The link service runs only while a link exists, and tokens never reach the logs. Creating a link and each download are recorded with the client's name and IP address.

The page has no button that opens the app directly. In tests on Android, OpenVPN Connect opened but did not import the profile from such a button, even with a trusted certificate. Opening the downloaded file worked on every device tested, Android and Windows.

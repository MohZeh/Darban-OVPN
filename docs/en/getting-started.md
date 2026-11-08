# Getting started

[Back to README](../../README.md) · [فارسی](../fa/getting-started.md)

From a new server to your first connected user. Each step says what you should see, and what to do if you see something else. New words are explained in the [glossary](glossary.md).

## Step 1: Get a server

Rent a new **Ubuntu 24.04 or 26.04** VPS from any provider. Choose an `amd64` server. Support for `arm64` is still being tested.

**You should have:** the server's IP address, and a way to log in as `root` or as a user with `sudo`.

**If not:** look in your provider's panel. Most providers show the address and login on the server's page.

## Step 2: Connect to the server

On your own computer, open a terminal and connect. Replace the address with your server's:

```bash
ssh root@203.0.113.10
```

**You should see:** a command prompt from the server.

**If not:** check the address and the user name in your provider's panel. Connect directly, not through a VPN that you are about to change.

## Step 3: Run the install command

```bash
curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/latest/download/get.sh | sudo bash
```

**You should see:** `Step 1 of 2: Server address`.

**If not:**
- `curl: command not found`: run `sudo apt update && sudo apt install -y curl`, then run the command again.
- `No stable release is published yet`: use the address of a version from the [Releases](https://github.com/MohZeh/Darban-OVPN/releases) page. In the command, replace `latest/download` with `download/` and the version, for example `download/v1.0.0-beta.1`.

## Step 4: Answer the questions

Each question shows a suggestion. **Press Enter to accept it.**

1. **Server address:** press Enter. A domain name is optional. With a domain name or a public IP address, the tool can get a trusted certificate, so temporary links open without a browser warning.
2. **VPN port:** press Enter.
3. **Install this server?** Press Enter on **Install now**.

Nothing is installed before the third answer; until then the tool only refreshes the list of packages. To see the full plan first, press `2` and then Enter on **Show details**.

**You should see:** five short steps, and then `Your VPN server is ready`.

**If not:** the screen shows the last lines of the log. Run the same command again, and it continues from where it stopped. To undo everything, use the command shown on the screen.

## Step 5: Open the VPN port in your provider's firewall

Many providers have a firewall in their panel, often called **Firewall**, **Security Group** or **Network Rules**. This tool cannot see or change it.

Add a rule that allows **incoming UDP on port 1194**, or on the port you chose.

**If your provider has no such firewall:** go to the next step.

## Step 6: Create your first client

A client is one person or device. The tool asks right after the install:

1. **Create your first client now?** Press Enter.
2. **Client name:** press Enter to use `client1`, or type a name such as `ali-phone`.
3. **How will the client get this profile?** Press Enter for **Temporary link**.
4. **Get a free Let's Encrypt certificate?** This comes only on a public address. Answer **Yes, get a certificate** if you can open TCP port 80 in your provider's firewall for a moment: the link then opens without a browser warning, and the app can import straight from it. Otherwise press Enter. Until you have one, the question comes back with each link. See [The browser warning](sharing.md#the-browser-warning).
5. **Lock the private key with a password?** Press Enter for no password. See [A password on the key](sharing.md#a-password-on-the-key) for when one helps.
6. **How long should the link work?** Press Enter for one hour.

**You should see:** a link that starts with `https://`, and the TCP port it uses.

**If not:** see [Troubleshooting](troubleshooting.md#the-link-does-not-open).

Open that TCP port in your provider's firewall too, as in step 5. The tool shows the port with the link.

## Step 7: Send the link

Send the link in any messenger. A link preview does not use it up. It works once, for the person who presses the button on the page.

If the server has no trusted certificate, the tool also shows a short note. Send it with the link, because the browser shows a security warning for this link. If you chose a password, send it another way, for example by SMS or a call.

## Step 8: Connect the device

The person who receives the link follows [Connect a device](connect-devices.md).

## Step 9: See the connection

The tool waits and shows:

```text
✓ client1 is connected from 198.51.100.7. The server and your provider's firewall let the VPN through.
```

This shows that the device reached the server through your provider's firewall. It does not show the internet on the device: on the device, follow [Check that it works](connect-devices.md#check-that-it-works).

**If not:** after a few minutes, press Enter to stop waiting, and see [Troubleshooting](troubleshooting.md#a-client-cannot-connect).

## Step 10: Reboot if the tool asked for it

If the install added a kernel, the tool asks you to reboot once when convenient. The VPN works without it, but it is faster afterwards.

```bash
sudo reboot
```

## What next

- Open the menu at any time with `sudo darban`.
- Add or remove people: [Everyday tasks](usage.md).
- More ways to send a profile: [Sharing a profile](sharing.md).

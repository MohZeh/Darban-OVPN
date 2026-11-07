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
curl -fsSL https://github.com/MohZeh/darban-ovpn/releases/latest/download/get.sh | sudo bash
```

**You should see:** `Step 1 of 2: Server address`.

**If not:**
- `curl: command not found`: run `sudo apt update && sudo apt install -y curl`, then run the command again.
- `No stable release is published yet`: use the address of a version from the [Releases](https://github.com/MohZeh/darban-ovpn/releases) page. In the command, replace `latest/download` with `download/vX.Y.Z-rc.N`.

## Step 4: Answer the questions

Each question shows a suggestion. **Press Enter to accept it.**

1. **Server address:** press Enter. A domain name is optional, and it lets temporary links open without a browser warning.
2. **VPN port:** press Enter.
3. **Install this server?** Press Enter on **Install now**.

Nothing changes on the server before the third answer. To see the full plan first, press `2` and then Enter on **Show details**.

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
4. **Lock the private key with a password?** Without a domain name the suggestion is yes. Press Enter, and Enter again for the short password it suggests, such as `k7m-3xt-9vw`.
5. **How long should the link work?** Press Enter for one hour.

**You should see:** a link that starts with `https://`, and the TCP port it uses.

**If not:** see [Troubleshooting](troubleshooting.md#the-link-does-not-open).

Open that TCP port in your provider's firewall too, as in step 5. The tool shows the port with the link.

## Step 7: Send the link

Send the link in any messenger. A link preview does not use it up. It works once, for the person who presses the button on the page.

If the server has no trusted certificate, the tool also shows a short note. Send it with the link, because the browser shows a security warning for this link. Send the password another way, for example by SMS or a call.

## Step 8: Connect the device

The person who receives the link follows [Connect a device](connect-devices.md).

## Step 9: See the connection

The tool waits and shows:

```text
✓ client1 is connected from 198.51.100.7. The VPN works.
```

This proves the whole path works, including your provider's firewall.

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

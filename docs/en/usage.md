# Everyday tasks

[Back to README](../../README.md) · [فارسی](../fa/usage.md)

Open the menu with:

```bash
sudo darban
```

The top of the menu shows the state of the server, the [blocklist](glossary.md#blocklist-crl), your clients and any problem that needs attention.

## How to answer

- **In a list of options:** the line `Enter: ...` says what Enter does now. To choose another option, press `↑`/`↓` or its number, then Enter. `Esc` cancels. Moving alone does nothing.
- **In a question with a suggestion:** Enter accepts what is in the brackets.
- **In a question without a suggestion:** Enter alone cancels.

Risky questions start on the safe answer. Persian digits work too.

## Add a person or device

1. Press `1` **Create client**, and type a name such as `ali-phone`.
2. Choose how to send the profile. See [Sharing a profile](sharing.md).

Each device should have its own client, so you can remove one without affecting the others.

## See who is connected

Press `3` **Connected now**. The top of the menu also counts them.

## See all clients

Press `2` **List clients**. It shows who is valid, and when each certificate expires. Revoked clients are hidden, and the tool offers to show them.

## Send a profile again

For example, after a new phone or a changed server address:

1. Press `5` **Share a profile**.
2. Choose the client and the way to send it.

## Remove a person or device

1. Press `4` **Revoke client (permanent)**, and choose the client.
2. Press `2` to move to the revoke option, then Enter.

The old profile can no longer connect, on any device. The tool also ends the open connection of that client alone, while other users stay connected. If ending that one connection is not possible, for example on a server this tool did not set up, the tool says so and asks whether to restart OpenVPN, which drops everyone for a few seconds. If you answer No, the open connection can last up to an hour. This cannot be undone, but you can later create a new client with the same name.

## See a link again, cancel it, or delete a file left on the server

Press `6` **Links and files**. It lists the open links, with the time left and whether the file was downloaded, and then the profile files kept on the server. Choose one, and the tool shows what you can do with it:

- **A link:** show it again and copy it, if you lost it, or cancel it. A link made before `v1.0.0-rc.8` cannot be shown again.
- **A file:** show the download commands again and copy one, or delete the file after you confirm.

A number alone never removes anything. The client keeps working either way. A link's password is not kept, so it cannot be shown again.

## Change the server address or port

Open **7 Settings**:

- `1` **Server address**
- `2` **OpenVPN UDP port**

After changing either one, send the profiles again, because each profile holds the address it was made with. A new port must also be open in your provider's firewall.

The same menu holds the link settings: `3` **Link lifetime**, `4` **Link port** and `5` **Link certificate**. `6` **Advanced** holds the VPN settings; see [Advanced settings](advanced.md#advanced-settings).

## Update the tool

Run the install command again, or use **9 Setup**, then `2` **Check for updates**:

```bash
sudo darban update
```

Only the tool changes. OpenVPN does not restart, and clients stay as they are. If the earlier install lacks a rule the new version needs, such as the TCP MSS limit, the update adds it. To go back, use **9 Setup**, then `4` **Restore previous version**.

## Check the server

Open **8 Maintenance**, then `1` **Diagnostics**, or run:

```bash
sudo darban status
```

The exit status is `1` when a check found a problem, and `0` otherwise, so scripts can use it too. Warnings do not change it. The checks run on the server, so they cannot see your provider's firewall. If something is wrong, see [Troubleshooting](troubleshooting.md).

## Remove the tool

Open **9 Setup**:

- `5` **Uninstall this tool only:** OpenVPN keeps running.
- `6` **Remove everything:** the tool, OpenVPN, and every client. Every profile stops working, unless you restore the backup.

See [what each one removes](advanced.md#what-removal-does).

## All commands

```bash
sudo darban                # menu
sudo darban --no-clear     # menu that never clears the screen
sudo darban list           # active clients
sudo darban list --all     # including revoked clients
sudo darban connected      # clients connected right now
sudo darban status         # diagnostics checklist
sudo darban repair-crl     # publish a fresh blocklist and finish a revocation
sudo darban update         # check for a release and install it
sudo darban about          # version, project address and contact
sudo darban uninstall      # remove only this tool
sudo darban remove-all     # remove this tool, OpenVPN, the CA and profiles
sudo darban version
sudo darban help
```

The menu closes after 15 minutes without input. Each color has one meaning: cyan for the keys to press, magenta for what to type or do, green, yellow and red for success, warnings and errors, and red for menu items that cannot be undone. Every message also has its own symbol and words, so it reads the same without colors. `NO_COLOR=1` turns colors off. Actions are recorded in the system journal: `sudo journalctl -t darban`.

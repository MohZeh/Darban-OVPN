# Usage

[Back to README](../../README.md) · [فارسی](../fa/usage.md)

Start the menu with `sudo darban`. The header shows the service, address, CRL health, client counts, and any alert that needs you.

## Choosing and confirming

Confirmations show two options. Option 1 is the safe default.

- `↑`/`↓` or `1`/`2` (also Persian digits) move the selection
- `Enter` confirms; moving alone does nothing
- `Esc` or `Ctrl+C` cancels

In a script or pipe, the tool reads one line instead: `2` or the exact target confirms.

## Main menu

| Item | What it does |
|---|---|
| 1 List clients | Active clients with status, expiry and days left. Revoked clients are hidden, and offered on request |
| 2 Create client | Issues a certificate and profile, then asks how to share it |
| 3 Revoke client | Permanently revokes the certificate, publishes a verified CRL, deletes the server copy, removes open links, and handles the active session |
| 4 Share a profile | Rebuilds the profile with the current address and port, then shares it. See [Sharing](sharing.md) |
| 5 Active links | Shows open links and lets you cancel them |
| 6 Delete server copy | Deletes a `.ovpn` file on the server. The certificate stays valid |
| 7 Settings | VPN hostname, UDP port, and [Advanced](advanced.md) |
| 8 Maintenance & diagnostics | Checklist, CRL repair, service restart. See [Operations](operations.md) |
| 9 Setup | Update, restore, update notice, about, uninstall, remove everything |

## Client names

New names may use letters, digits, `_` and `-`, up to 64 characters. Existing certificates may also use `.`, `@` and `+`.

A name with a valid certificate cannot be used again. A revoked name can, once its revocation is complete: old profiles stay blocked because OpenVPN rejects them by serial number. You are asked first only if per-client settings exist for that name in `client-config-dir`, because they would apply to the new certificate.

## Commands

```bash
sudo darban                # menu
sudo darban --no-clear     # menu that never clears the screen
sudo darban list           # active clients
sudo darban list --all     # including revoked clients
sudo darban status         # diagnostics checklist
sudo darban repair-crl     # publish a fresh CRL and finish a revocation
sudo darban update         # check for a release and install it
sudo darban about          # version, project address and contact
sudo darban uninstall      # remove only this tool
sudo darban remove-all     # remove this tool, OpenVPN, the CA and profiles
sudo darban version
sudo darban help
```

`NO_COLOR=1` turns colors off. Symbols fall back to ASCII outside UTF-8 locales.

Actions are recorded in the journal:

```bash
sudo journalctl -t darban
```

## Good to know

- The tool closes itself after 15 minutes without input.
- `Ctrl+C` cancels the current action. During critical steps, such as issuing a certificate or publishing a CRL, it is ignored until the step completes.
- Certificates are not renewed automatically. Expiring clients are shown in the list and the header.

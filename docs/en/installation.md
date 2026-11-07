# Installation

[Back to README](../../README.md) · [فارسی](../fa/installation.md)

## Before you start

- Connect through **direct SSH**, not through the VPN you are about to change.
- Use a fresh **Ubuntu 24.04 or 26.04** VPS for a new server (`amd64` or `arm64`) with a TUN device.
- Plan to open the VPN's UDP port in your provider's firewall. The tool cannot see or change that firewall.
- For temporary links, plan to open one TCP port as well (443, 8443 or 9443 by default).

## New server

```bash
curl -fsSL https://github.com/MohZeh/darban-ovpn/releases/latest/download/get.sh -o get.sh
sudo bash get.sh
sudo darban
```

To install a specific version, including a pre-release, download `get.sh` from that release and run:

```bash
sudo bash get.sh --version v1.0.0-rc.1
```

`get.sh` downloads the release, checks it against `SHA256SUMS`, and runs nothing if they do not match.

### What the setup asks

| Question | Default |
|---|---|
| Server hostname or IP | The detected public IPv4 address |
| OpenVPN UDP port | `1194` |
| Add `ufw` rules (only if `ufw` is active) | No |

Use a hostname if you can: moving the server later is easier. A DNS record must not be proxied, for example Cloudflare must be set to DNS only, because this is UDP traffic.

Before changing anything, the setup shows its full plan, including apt's own list of kernel packages, and asks for confirmation.

### What the setup does

- Adds the OpenVPN project's apt repository (stable channel) and installs `openvpn`, `easy-rsa`, `socat` and `nftables`
- If the running kernel has no `ovpn` module, installs `linux-image-virtual-hwe-24.04` or `linux-image-virtual-hwe-26.04`, matching the system, without recommended packages. That kernel ships the module, so no DKMS or headers are needed. If apt plans firmware or graphics packages, the setup stops. A container, or a kernel that already has the module, needs nothing; `--install-kernel` installs the kernel anyway.
- Creates a CA in `/root/pki` and a server certificate valid for 10 years
- Writes `/etc/openvpn/server/server.conf`, enables IPv4 forwarding, and adds NAT for the VPN only, in its own nftables table
- Starts OpenVPN

If a kernel is installed, the current one stays as a fallback and nothing reboots automatically. The VPN works immediately without DCO. **Reboot when convenient** to use the new kernel and DCO.

### Defaults you can change later

| Setting | Default |
|---|---|
| VPN network | First free `/24` from `10.8.0.0` |
| Routing | All client IPv4 traffic |
| Client DNS | `1.1.1.1`, `8.8.8.8` |

Change them under **Settings › Advanced**.

### Without questions

```bash
sudo bash setup/server-setup.sh --host vpn.example.com --port 1194 --subnet 10.8.0.0 --dns "1.1.1.1 8.8.8.8" --yes
sudo bash setup/install.sh
```

If a setup stops half way, run it again: it continues from where it stopped, and it shows the command that undoes everything. Other options are `--split-tunnel`, `--open-ufw` and `--install-kernel`. With `--yes`, `ufw` stays unchanged unless `--open-ufw` is given. Run these from an unpacked release archive.

## Server that already runs OpenVPN

`get.sh` skips the server setup when `/etc/openvpn/server/server.conf` exists, and the installer does not change your OpenVPN configuration or restart it. It expects:

- OpenVPN 2.7 with `udp4` and exactly one `tls-crypt` directive using `/etc/openvpn/server/tls-crypt.key`
- Easy-RSA 3 at `/usr/share/easy-rsa/easyrsa`, with its PKI in `/root/pki` and a CA key without a passphrase
- The server certificate recorded in the PKI's `index.txt`
- `crl-verify /etc/openvpn/server/crl.pem` with a valid CRL
- The unit `openvpn-server@server.service`, running

If a check fails, the installer stops before installing anything and says why. On such a server **Remove everything** is refused, and changing the VPN network is refused because its NAT is not managed by this tool.

For single-client disconnect, add a local management socket. Without it, the tool offers a full restart.

## Check the installation

```bash
sudo darban status
systemctl is-active openvpn-server@server.service darban-crl.timer
sudo darban-crl-maintain --check
```

## Firewall checklist

| Port | Needed for |
|---|---|
| Your chosen UDP port | VPN clients |
| 443, 8443 or 9443 TCP | Temporary links |
| 80 TCP, for a moment | Only when requesting a Let's Encrypt certificate |

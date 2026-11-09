# Glossary

[Back to README](../../README.md) · [فارسی](../fa/glossary.md)

## Client

One person or device allowed to connect. Each client has its own certificate.

## Profile

The `.ovpn` file a device uses to connect. It holds a private key, so treat it like a password.

## Revoke

Permanently block a client. Its old profile stops working everywhere.

## Blocklist (CRL)

The list of revoked clients that OpenVPN checks at each connection. CRL stands for Certificate Revocation List. The tool renews and checks it for you.

## CA

Certificate Authority: the key on your server that issues certificates. Whoever has it can create clients, so keep it safe.

## Server address

What clients connect to: an IP address such as `203.0.113.10`, or a domain name such as `vpn.example.com`.

## Provider's firewall

A firewall in your server provider's panel, outside the server. This tool cannot see or change it, so you open ports there yourself.

## ufw

A firewall that can run inside Ubuntu. It is usually off. If it is on, the tool offers to add the rules the VPN needs.

## UDP and TCP

Two ways of sending data over a network, each with its own ports. This VPN uses UDP, and temporary links use TCP.

## Full tunnel and split tunnel

**Full tunnel** sends all of a client's IPv4 traffic through the server. **Split tunnel** sends only the traffic for the VPN network. Full tunnel is the default.

## NAT

Lets clients reach the internet through the server's address.

## DCO

Data Channel Offload: OpenVPN's traffic handled inside the kernel, which is faster. It needs the `ovpn` kernel module.

## Temporary link

An address to get a profile. It works until the device connects to the VPN for the first time, or until its time is up. Opening it or downloading the file does not use it up.

# Glossary

[Back to README](../../README.md) · [فارسی](../fa/glossary.md)

## Client

A connection profile with its own certificate, usually for one person or one device. Each client can be revoked on its own.

## Profile

The `.ovpn` file a device uses to connect. It holds a private key, so treat it like a password.

## Revoke

Permanently cancel a client's certificate. Its profile stops working on every device. Revoking the certificate is not the same as ending a connection that is open at that moment; the tool ends that connection separately.

## Blocklist (CRL)

The list of revoked certificates that OpenVPN checks at each connection. CRL stands for Certificate Revocation List, and the menu calls it Blocklist. The tool renews and checks it every day.

## CA

Certificate Authority: what issues the server's certificate and the clients' certificates. Its private key stays on the server; whoever can read it can create clients, so access to it must stay limited.

## Server address

What clients connect to: an IP address such as `203.0.113.10`, or a domain name such as `vpn.example.com`.

## Provider's firewall

A firewall in your server provider's panel, outside the server. This tool cannot see or change it, so you open ports there yourself.

## ufw

A firewall that can run inside Ubuntu. It is usually off. If it is on, the tool offers to add the rules the VPN needs.

## UDP and TCP

Two ways of sending data over a network, each with its own ports. This VPN uses UDP, and temporary links use TCP.

## Full tunnel and split tunnel

**Full tunnel** sends all of a client's IPv4 traffic through the server. **Split tunnel** sends only the traffic for the VPN network, and the rest goes directly. Full tunnel is the default. In both, IPv6 traffic does not go through the VPN.

## NAT

Lets clients reach the internet through the server's address.

## TCP MSS

The largest amount of data in one TCP segment. The tool limits it to 1300 in both directions for VPN traffic, so packets also arrive on networks that drop split packets. MSS is not MTU, the largest whole packet on a path.

## DCO

Data Channel Offload: OpenVPN's traffic handled inside the kernel, which is faster where it is supported. It needs the `ovpn` kernel module.

## Temporary link

An address to get a profile. It works until its time is up, or until a connection with the profile is seen, whichever comes first. Opening it or downloading the file does not use it up.

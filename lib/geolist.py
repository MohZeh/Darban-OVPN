#!/usr/bin/env python3
"""Darban OVPN lists of blocked destinations: the IPv4 ranges VPN clients cannot reach through this server.

  geolist.py fetch --source <url> --country <code> --out <file>
      Downloads the ranges of one country from <url> (a folder, ending in /), with those of the Iranian CDNs for
      Iran, checks them and writes them, merged, one range per line. The file is replaced only when the new list
      passes every check; otherwise it stays as it was. Prints ranges=<n> addresses=<n>. Exit 2, with the reason,
      when it is refused.
  geolist.py merge --out <file> [--list <file>]... [--extra "<range> ..."]
      Writes the ranges of the lists and the extra ones, merged, one per line; removes <file> when there are none.
      Prints ranges=<n>.
  geolist.py entry <address or range>
      Prints the range a typed address stands for, such as 203.0.114.0/24. Exit 2, with the reason, when it
      cannot be blocked.
  geolist.py routes --list <file>... --out <file> --android <yes|no> --budget <bytes>
      Writes the ranges of the lists as OpenVPN options that send them outside the tunnel, one
      push "route <network> <mask> net_gateway" per line, after a first line that says whether Android phones get
      them. The largest ranges come first, while they fit the budget, counted as OpenVPN 3 counts pushed options.
      Readable by all: OpenVPN's own user reads it at each connection. Prints, for each list,
      list=<file> ranges=<n> sent=<n> share=<percent of its addresses>, then routes=<n>.

Everything downloaded is data: each line must be an address range, and nothing else in it is used.
"""
import argparse
import ipaddress
import os
import re
import sys
import tempfile
import urllib.request

# The ranges of Iranian CDNs, some of which are outside Iran, go with the list of Iran.
EXTRA_FILES = {'ir': ('text/arvancloud.txt', 'text/derakcloud.txt', 'text/iranserver.txt', 'text/parspack.txt')}
MAX_BYTES = 5 * 1024 * 1024
# A list may shrink from one day to the next, but not to less than half.
MIN_SHARE_OF_LAST = 0.5
# Lines that are not a range, such as a header, are allowed up to this share of the list.
MAX_BAD_SHARE = 0.01
TIMEOUT = 60


class Refused(Exception):
    pass


def blockable(net):
    """A range a VPN client can be kept from: a public one, not shorter than /8."""
    return net.prefixlen >= 8 and net.is_global and not net.is_multicast


def parse(text, name):
    """The blockable IPv4 ranges of a list. IPv6 ranges and comments are skipped; too many other lines refuse it."""
    found, bad, lines = [], 0, 0
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        lines += 1
        if ':' in line:
            continue
        try:
            net = ipaddress.IPv4Network(line, strict=False)
        except ValueError:
            bad += 1
            continue
        if blockable(net):
            found.append(net)
    if lines and bad / lines > MAX_BAD_SHARE:
        raise Refused('%s: %d of its %d lines are not address ranges' % (name, bad, lines))
    return found


def download(url):
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise Refused('%s is larger than %d bytes' % (url, MAX_BYTES))
    try:
        return data.decode('ascii')
    except UnicodeDecodeError:
        raise Refused('%s is not a plain list of addresses' % url)


def read_ranges(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding='ascii') as handle:
        return [ipaddress.IPv4Network(line.strip()) for line in handle if line.strip()]


def write_lines(path, lines, mode=0o600):
    """Replaces the file in one step, so a reader sees the old list or the new one, never half of one."""
    folder = os.path.dirname(os.path.abspath(path))
    handle, temp = tempfile.mkstemp(dir=folder, prefix='.geolist.')
    try:
        with os.fdopen(handle, 'w', encoding='ascii') as out:
            for line in lines:
                out.write('%s\n' % line)
        os.chmod(temp, mode)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def fetch(args):
    if not re.fullmatch(r'[a-z]{2}', args.country):
        raise Refused('%s is not a two-letter country code' % args.country)
    main = 'text/%s.txt' % args.country
    try:
        found = parse(download(args.source + main), main)
    except Refused:
        raise
    except Exception as error:
        raise Refused('could not download %s: %s' % (main, error))
    for name in EXTRA_FILES.get(args.country, ()):
        try:
            found += parse(download(args.source + name), name)
        except Refused:
            raise
        except Exception as error:
            # The CDN lists are small extras; the list of the country stands without them.
            print('note: %s was not downloaded: %s' % (name, error), file=sys.stderr)
    ranges = list(ipaddress.collapse_addresses(found))
    if not ranges:
        raise Refused('the list of %s has no address range' % args.country.upper())
    last = read_ranges(args.out)
    if last and len(ranges) < len(last) * MIN_SHARE_OF_LAST:
        raise Refused('the new list has %d ranges, less than half of the %d of the last one' % (len(ranges), len(last)))
    write_lines(args.out, ranges)
    print('ranges=%d addresses=%d' % (len(ranges), sum(n.num_addresses for n in ranges)))


def merge(args):
    found = []
    for path in args.list or ():
        found += read_ranges(path)
    for word in (args.extra or '').split():
        net = ipaddress.IPv4Network(word, strict=False)
        if blockable(net):
            found.append(net)
    ranges = list(ipaddress.collapse_addresses(found))
    if ranges:
        write_lines(args.out, ranges)
    elif os.path.exists(args.out):
        os.unlink(args.out)
    print('ranges=%d' % len(ranges))


def entry(args):
    try:
        net = ipaddress.IPv4Network(args.value, strict=False)
    except ValueError:
        raise Refused('not an IPv4 address or range')
    if net.prefixlen < 8:
        raise Refused('a range larger than /8 would block too much')
    if not blockable(net):
        raise Refused('a private or special address never goes out to the internet, so it needs no block')
    print(net)


def route_cost(net):
    """What OpenVPN 3 counts for one pushed route: 64 bytes for the option, 16 for each word, and the words."""
    words = ('route', str(net.network_address), str(net.netmask), 'net_gateway')
    return 64 + sum(16 + len(word) for word in words)


def routes(args):
    lists = [(path, read_ranges(path)) for path in args.list]
    if not any(ranges for _, ranges in lists):
        raise Refused('the lists are empty')
    # The largest ranges of all the lists first: they carry the most addresses for the same cost.
    every = sorted(((net, path) for path, ranges in lists for net in ranges),
                   key=lambda item: (-item[0].num_addresses, int(item[0].network_address)))
    chosen, spent, seen = [], 0, set()
    for net, path in every:
        # A range two lists share, such as a CDN in two countries, goes once, counted for the first.
        if net in seen or spent + route_cost(net) > args.budget:
            continue
        seen.add(net)
        chosen.append((net, path))
        spent += route_cost(net)
    lines = ['# darban-direct 1 android=%s' % args.android]
    lines += ['push "route %s %s net_gateway"' % (net.network_address, net.netmask) for net, _ in chosen]
    write_lines(args.out, lines, 0o644)
    for path, ranges in lists:
        sent = [net for net, origin in chosen if origin == path]
        total = sum(n.num_addresses for n in ranges)
        share = 100.0 * sum(n.num_addresses for n in sent) / total if total else 0.0
        print('list=%s ranges=%d sent=%d share=%.1f' % (path, len(ranges), len(sent), share))
    print('routes=%d' % len(chosen))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    one = commands.add_parser('fetch')
    one.add_argument('--source', required=True)
    one.add_argument('--country', required=True)
    one.add_argument('--out', required=True)
    two = commands.add_parser('merge')
    two.add_argument('--out', required=True)
    two.add_argument('--list', action='append')
    two.add_argument('--extra')
    three = commands.add_parser('entry')
    three.add_argument('value')
    four = commands.add_parser('routes')
    four.add_argument('--list', required=True, action='append')
    four.add_argument('--out', required=True)
    four.add_argument('--android', required=True, choices=('yes', 'no'))
    four.add_argument('--budget', required=True, type=int)
    args = parser.parse_args()
    try:
        {'fetch': fetch, 'merge': merge, 'entry': entry, 'routes': routes}[args.command](args)
    except Refused as reason:
        print(reason, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()

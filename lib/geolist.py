#!/usr/bin/env python3
"""Darban OVPN lists of blocked destinations: the IPv4 ranges VPN clients cannot reach through this server.

  geolist.py fetch --source <url> --out <file>
      Downloads the ranges of Iran and of the Iranian CDNs from <url> (a folder, ending in /), checks them and
      writes them, merged, one range per line. The file is replaced only when the new list passes every check;
      otherwise it stays as it was. Prints ranges=<n> addresses=<n>. Exit 2, with the reason, when it is refused.
  geolist.py merge --out <file> [--list <file>] [--extra "<range> ..."]
      Writes the ranges of the list and the extra ones, merged, one per line; removes <file> when there are none.
      Prints ranges=<n>.
  geolist.py entry <address or range>
      Prints the range a typed address stands for, such as 203.0.114.0/24. Exit 2, with the reason, when it
      cannot be blocked.

Everything downloaded is data: each line must be an address range, and nothing else in it is used.
"""
import argparse
import ipaddress
import os
import sys
import tempfile
import urllib.request

# The ranges of Iran, and those of the Iranian CDNs, some of which are outside Iran.
FILES = ('text/ir.txt', 'text/arvancloud.txt', 'text/derakcloud.txt', 'text/iranserver.txt', 'text/parspack.txt')
REQUIRED = 'text/ir.txt'
MAX_BYTES = 5 * 1024 * 1024
# A list of Iran has about 2,100 ranges. Far fewer means a broken or wrong file, not a smaller country.
MIN_RANGES = 500
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


def write_ranges(path, ranges):
    """Replaces the file in one step, so a reader sees the old list or the new one, never half of one."""
    folder = os.path.dirname(os.path.abspath(path))
    handle, temp = tempfile.mkstemp(dir=folder, prefix='.geolist.')
    try:
        with os.fdopen(handle, 'w', encoding='ascii') as out:
            for net in ranges:
                out.write('%s\n' % net)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def fetch(args):
    found = []
    for name in FILES:
        try:
            text = download(args.source + name)
        except Refused:
            raise
        except Exception as error:
            if name == REQUIRED:
                raise Refused('could not download %s: %s' % (name, error))
            # The CDN lists are small extras; the list of Iran stands without them.
            print('note: %s was not downloaded: %s' % (name, error), file=sys.stderr)
            continue
        found += parse(text, name)
    ranges = list(ipaddress.collapse_addresses(found))
    if len(ranges) < MIN_RANGES:
        raise Refused('the list has only %d ranges, too few for the ranges of Iran' % len(ranges))
    last = read_ranges(args.out)
    if last and len(ranges) < len(last) * MIN_SHARE_OF_LAST:
        raise Refused('the new list has %d ranges, less than half of the %d of the last one' % (len(ranges), len(last)))
    write_ranges(args.out, ranges)
    print('ranges=%d addresses=%d' % (len(ranges), sum(n.num_addresses for n in ranges)))


def merge(args):
    found = read_ranges(args.list)
    for word in (args.extra or '').split():
        net = ipaddress.IPv4Network(word, strict=False)
        if blockable(net):
            found.append(net)
    ranges = list(ipaddress.collapse_addresses(found))
    if ranges:
        write_ranges(args.out, ranges)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    one = commands.add_parser('fetch')
    one.add_argument('--source', required=True)
    one.add_argument('--out', required=True)
    two = commands.add_parser('merge')
    two.add_argument('--out', required=True)
    two.add_argument('--list')
    two.add_argument('--extra')
    three = commands.add_parser('entry')
    three.add_argument('value')
    args = parser.parse_args()
    try:
        {'fetch': fetch, 'merge': merge, 'entry': entry}[args.command](args)
    except Refused as reason:
        print(reason, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()

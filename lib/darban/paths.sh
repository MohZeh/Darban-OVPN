#!/usr/bin/env bash
# The paths and constants of the manager, and the values it starts with. bin/darban sources it after lib/common.sh,
# whose DARBAN_LIB and DARBAN_SERVER_DIR it uses. The tests source a copy whose paths all point into a fake server.

DARBAN_REPO=MohZeh/Darban-OVPN
DARBAN_URL=https://github.com/$DARBAN_REPO
DARBAN_EMAIL=zehtabex@gmail.com
BACKUP_ROOT=/var/backups/darban
SBIN_DIR=/usr/local/sbin
UNIT_DIR=/etc/systemd/system
LINK_DIR=/run/darban-links
# Connection events: the script OpenVPN runs, its queue in a tmpfs of its own, and when each client was seen.
EVENT_SCRIPT=/usr/local/libexec/darban-ovpn-event
EVENT_DIR=/run/darban-events
LEDGER_DIR=/var/lib/darban/clients
# Encrypted backups of the CA, apart from the copies of the tool in $BACKUP_ROOT, which an update prunes. A restore
# that could not know later revocations leaves this mark until the owner acknowledges it.
PKI_BACKUP_DIR=/var/backups/darban-pki
PKI_BACKUPS_KEPT=14
# What a finished restore replaced is kept this long, and Diagnostics warn this many days before it goes (C.16.5).
PRE_RESTORE_KEEP_DAYS=30
PRE_RESTORE_WARN_DAYS=7
# A backup hook runs this long at most, then it is killed.
BACKUP_HOOK_SECONDS=120
RESTORE_WARN=/var/lib/darban/restore-unverified
BACKUP_PY=$DARBAN_LIB/backup.py
GEO_PY=$DARBAN_LIB/geolist.py
# The lists of Settings > Blocked destinations: the ranges of each country, and of Iranian CDNs, made each day from
# public GeoIP data. A folder; geolist.py adds the names of the files.
GEO_SOURCE=https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/
# Variables for the tests only (R18-16). Unset, they change nothing. Only root runs this tool, and sudo's env_reset
# drops them, so only a root shell that sets them itself can use them; that shell could change the files anyway.
#   DARBAN_TEST_RESTORE_FAIL=<step>             that restore step fails, as a full disk would
#   DARBAN_TEST_RESTORE_STOP=<rename>|after:<step>  the restore stops there, as a crash would
#   DARBAN_TEST_RESTORE_WAIT=<step>             the restore waits there, holding what it holds, until the file
#   DARBAN_TEST_RESTORE_WAIT_FILE=<file>          DARBAN_TEST_RESTORE_WAIT_FILE names is deleted
#   DARBAN_TEST_COPY_FAIL=write                 writing the copy for the SSH user fails after its file was opened
#   DARBAN_TEST_HOME_COPY_HOOK=<command>        runs while that copy is made, to change its file under it
#   DARBAN_TEST_ACME_SERVER=<url>               acme.sh asks this ACME server, such as Pebble in Acceptance, instead
#   DARBAN_TEST_ACME_CA=<file>                    of Let's Encrypt, and trusts the HTTPS certificate in that file
# tests/run-tests.sh checks that this list names every one the code reads.
# Each run of the worker takes at most this many events, or this many seconds; the path unit starts it again.
EVENT_MAX=500
EVENT_SECONDS=60
# How long darban events waits for a worker already running: longer than one run takes, shorter than its unit allows.
EVENT_WORKER_WAIT=120
DEFAULT_CLIENT_DNS='1.1.1.1 9.9.9.9'
CONF_TEMP=''
OUT_DIR=/root/openvpn-clients
CONFIG_DIR=/etc/darban
DOMAIN_FILE=$CONFIG_DIR/domain
UPDATE_CACHE=$CONFIG_DIR/.latest-version
# After a failed check: "<epoch of the next try> <offline|limited|bad>". Gone once a check works again.
UPDATE_FAILED=$CONFIG_DIR/.update-check-failed
UPDATE_LOCK=$CONFIG_DIR/.update-check.lock
# Seconds between checks after one worked, and after one failed.
UPDATE_EVERY=3600
UPDATE_RETRY=600
LINK_ENV=$CONFIG_DIR/links.env
LINK_CERT=$CONFIG_DIR/link-cert.pem
LINK_KEY=$CONFIG_DIR/link-key.pem
# The ports a first link tries, in order. Uncommon on purpose: panels such as 3x-ui, and tools such as Portainer,
# often take 443, 8443 and 9443, and a link would then block them while it lasts.
LINK_PORT_CHOICES='9347 9563 9741'
# Where a link certificate taken from another tool came from, so a renewal there reaches the links.
LINK_CERT_SOURCE=$CONFIG_DIR/link-cert.source
# The link port the firewall warning was last given for.
LINK_PORT_TOLD=$CONFIG_DIR/.link-port-told
LINK_MORE_LABEL='' LINK_MORE_NOTE=''
SYSTEM_CA_FILE=/etc/ssl/certs/ca-certificates.crt
# Where certbot, panels such as 3x-ui and x-ui, and acme.sh keep certificates.
CERT_SEARCH_DIRS='/etc/letsencrypt/live /root/cert /root/.acme.sh'
# Where certbot keeps the link certificate this tool gets. It can outlive a removal, for the next install.
LE_DIR=/etc/letsencrypt
# Each link certificate Let's Encrypt issued here, so the weekly limit is known before asking. Kept with it.
LINK_CERT_LOG=/var/lib/darban/link-certificates.log
# acme.sh, when this tool installed it for a server without snap: the program, its account and settings, the links'
# certificate it got, and a test certificate from Let's Encrypt's staging server apart from it. Remove everything
# takes the whole folder.
ACME_HOME=/var/lib/darban-acme
CONFIG_FILE=$CONFIG_DIR/config
# lib/common.sh reads the TCP MSS of the NAT rules from it.
DARBAN_CONFIG=$CONFIG_FILE
# Blocked destinations: what NAT loads (lib/common.sh reads it), and the folder of the last good list of each country,
# <code>.v4, with its date and size in <code>.info.
DARBAN_BLOCKED=$CONFIG_DIR/blocked.v4
GEO_DIR=$CONFIG_DIR/geo
# The routes that send those countries outside the tunnel; bin/darban-ovpn-event gives them at each connection, as
# OpenVPN's user, so they live beside server.conf, not in the folder only root can read. The small file is for
# OpenVPN 3 before 3.11.1, which refuses pushed options of more than 256 KiB; how much of each country the large one
# holds is in direct.info.
DIRECT_ROUTES=$DARBAN_SERVER_DIR/darban-direct.routes
DIRECT_ROUTES_SMALL=$DARBAN_SERVER_DIR/darban-direct-small.routes
DIRECT_INFO=$CONFIG_DIR/geo/direct.info
# Nine tenths of what OpenVPN 3 counts at most, 786432 bytes from 3.11.1 and 262144 before, so the other pushed
# options still fit.
DIRECT_BUDGET=707788
DIRECT_BUDGET_SMALL=235929
# The countries the menu offers by number; any other is typed as its two-letter code.
COUNTRY_CHOICES='ir af ru cn tr by tm'
COUNTRIES_MAX=10
# Settings > DNS on this server: Unbound answers clients on this server's VPN address, and asks the upstream DNS.
# The tool writes one file of its own there, and a drop-in that starts Unbound again when it stops; lib/common.sh
# reads the flag that sends clients' DNS to it.
UNBOUND_DIR=/etc/unbound/unbound.conf.d
UNBOUND_CONF=$UNBOUND_DIR/darban.conf
UNBOUND_DROPIN=$UNIT_DIR/unbound.service.d/darban.conf
# The root key of DNSSEC that Unbound reads and keeps up to date, and where the package dns-root-data has it.
UNBOUND_ROOT_KEY=/var/lib/unbound/root.key
DNS_ROOT_DATA=/usr/share/dns/root.key
DARBAN_DNS_REDIRECT=$CONFIG_DIR/dns-redirect
# The names Unbound refuses, as a zone of response policy, outside the folder Unbound reads as configuration.
UNBOUND_RPZ=/etc/unbound/darban.rpz
# The port of the upstream DNS that the daily check of Iranian sites abroad asks.
NAMES_DNS_PORT=53
NAMES_OWN_MAX=200
# The lines this tool added to server.conf for connection events, so their removal takes only those.
EVENT_LINES_FILE=$CONFIG_DIR/.event-lines
# The owner's age public key for backups, and the programs that get each new backup (v1.1 delivers them).
BACKUP_CONF=$CONFIG_DIR/backup.conf
BACKUP_HOOKS=$CONFIG_DIR/backup-hooks
TLS_KEY=$DARBAN_SERVER_DIR/tls-crypt.key
DEFAULT_DATA_CIPHERS=AES-256-GCM:AES-128-GCM
PORT_BACKUPS_KEPT=5
EXPIRY_WARN_DAYS=30
# Download hints; overridden by $CONFIG_FILE (see load_config). Empty host disables them.
DOWNLOAD_SSH_HOST=''
DOWNLOAD_SSH_PORT=22
DOWNLOAD_SSH_USER=root
# Days a new client certificate lasts; empty means the Easy-RSA default.
CLIENT_CERT_DAYS=''
# TCP port of temporary links; empty means the first free one is chosen when it is first needed.
LINK_PORT=''
# Hours a link, or a file kept on the server, lasts at most; empty means 24. The name stays from when it was for
# links only.
LINK_HOURS=''
# Whether a new profile carries the identity of its share, so a connection with another copy of the same client
# does not end it. Off until OpenVPN Connect on every platform is shown to import such a profile.
SHARE_ID_IN_PROFILE=no
# The menu looks for a new release when it starts, at most once an hour; no turns that off.
UPDATE_CHECK=yes
# Blocked destinations: the countries whose ranges are blocked, as two-letter codes, and the owner's own ranges, each
# space separated. Before other countries came, BLOCK_IRAN=yes stood for the first, and is still read.
BLOCK_COUNTRIES=''
BLOCK_EXTRA=''
# Their sites outside the VPN: no, yes, or no-android, which gives the routes to every client but Android phones.
# IRAN_DIRECT is its older name, and is still read.
COUNTRY_DIRECT=no
# The owner's own list stays short enough to read in the menu.
BLOCK_EXTRA_MAX=200
# DNS on this server: on or off; the upstream DNS it asks, empty for the default; DNS over TLS to it; clients made to
# use it; and DNSSEC checked.
DNS_SERVER=no
DNS_UPSTREAM=''
DNS_TLS=no
DNS_FORCE=yes
DNS_DNSSEC=yes
# Blocked names: the lists on (abroad, ads, malware), and the owner's own names to block and to allow, space separated.
NAME_LISTS=''
NAMES_BLOCK=''
NAMES_ALLOW=''
# The largest TCP segment through the VPN, from Settings > Advanced; empty means the default of lib/common.sh. The
# NAT rules read it from the file themselves (darban_mss), so the installer and a restore take it too.
TCP_MSS=''
CONFIG_ISSUES=()
# Normalized serial of the certificate OpenVPN serves; never listed, exported or revoked.
SERVER_SERIAL=''
# Action subshell exit codes besides 0 (done), 1 (refused/failed, reason printed) and 130 (Ctrl+C).
RC_NO_PAUSE=10
RC_QUIT=12
ACTION_RC=0
DARBAN_INT=0
SESSIONS_RESTARTED=0
ACTION_RUNNING=0
# Why this server cannot be managed right now; empty when it is healthy. Diagnostics and removal still work.
SERVER_PROBLEM=''
CA_LOCKED=0
# Set once a client has been given a way to get its profile, so the tool can wait for its first connection.
SHARED=0
# What the scp and sftp commands should fetch; another SSH user than root gets a private copy of the file.
DOWNLOAD_FILE=''
HEALTH_BAD=0 HEALTH_WARN=0 HEALTH_OK=0
HEALTH_PROBLEMS=()
# Revoked clients are history: list_clients hides them unless LIST_ALL is set, and counts them in LIST_HIDDEN.
LIST_ALL=0
LIST_HIDDEN=0
PROFILE_PASSWORD=''
CHOSEN=1

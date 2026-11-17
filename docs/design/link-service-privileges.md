# The link service without root: a feasibility report

**Status:** a report only; nothing in the code changes with it. The decision on what is built, and when, is in [section 6](#6-decision-and-order).
**Base:** `main` at `18ad731`, 2026-11-17. **Systems:** Ubuntu 24.04 (systemd 255) and Ubuntu 26.04 (systemd 259).

Each fact carries where it comes from:

- **S**: read in this repository;
- **U**: upstream documentation (systemd, Linux);
- **P**: expected from the source and the documentation, but not run yet. [Section 8](#8-not-checked-here) lists each, and what covers it.

## 1. The answer in short

1. **A link service with a user of its own is feasible, but it is not small.**
   - Every file it reads or writes changes owner or mode, and so does the key of the link certificate.
   - Updates and rollbacks have to carry that change both ways.
   - One missed file shows up on a real server as every link answering "This link is no longer valid". That page looks like an expired link, not like an error.
   - **Recommendation: v1.1.**
2. **A smaller step removes most of what a broken-into link service could reach today, without a new user.**
   - systemd hides from the service every path it does not need.
   - The service stops reading OpenVPN's management interface. The five-minute check, which runs as root, already does that work.
   - Reload without ending a download stays as it is.
   - **Recommendation: before v1.0.0, as a PR of its own, if the owner agrees.**
3. **`LoadCredential=` cannot give a new key on reload, on either supported Ubuntu.**
   - systemd copies a credential when the service starts.
   - It copies it again on reload only with `RefreshOnReload=credentials`, which systemd 260 added. Ubuntu 24.04 has 255 and 26.04 has 259 (U).
   - So with `LoadCredential=`, a new certificate needs a restart, and a restart ends a download in progress. Neither recommended step uses it.

## 2. What the link service can reach today

The unit is [`systemd/darban-links.service`](../../systemd/darban-links.service) (S). It sets:

- `User=root`;
- `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`;
- `NoNewPrivileges=true`;
- `ProtectSystem=strict`, with `ReadWritePaths=/run/darban-links`;
- `ProtectHome=true`;
- `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`.

**What that means:**

- The process has user id 0. Its only capability is binding a port below 1024. It cannot override file permissions (U).
- Being user 0, it still **owns** every file that belongs to root. So it can read any root file it can see, and send a signal to any process of root (U).
- Writes are limited by `ProtectSystem=strict`: the whole file system is read-only for it, except `/run/darban-links` (U).

**Already hidden.** `ProtectHome=true` hides `/root`. That covers the CA at `/root/pki` and the client profiles at `/root/openvpn-clients` (S: `lib/common.sh`, `bin/darban`).

**Readable today, though the service needs none of it:**

| What | Where |
|---|---|
| The OpenVPN server key, the tls-crypt key, `server.conf` | `/etc/openvpn` |
| Private keys of trusted certificates | `/etc/letsencrypt` |
| Encrypted backups of the CA | `/var/backups/darban-pki` |
| The journal of this tool, with client names and addresses | `/var/lib/darban` |
| Queued connection events, with client names and addresses | `/run/darban-events` |
| Password hashes | `/etc/shadow`, `/etc/gshadow` |
| OpenVPN's management interface, which takes commands such as `kill` and `signal` | `/run/openvpn-server/darban.sock` |

Linux lets a process connect to a socket on a read-only mount, so the last row is reachable despite `ProtectSystem=strict` (P).

`/etc/darban` is readable too, but nothing in it is secret except the pair of the link certificate, which the service needs. The rest is the settings of this tool, its domain, its NAT rules, copies of APT files and the public key of the backups (S).

**What the service does need (S: [`lib/linkd.py`](../../lib/linkd.py)):**

- `/run/darban-links`, to read and write. It rewrites `.meta` on each download, and creates `.lock` and `.reloadable`.
- The pair of the link certificate under `/etc/darban/link-cert`, to read at start and again on each reload.
- `server.conf` and the management interface, **only** on a server without connection events.

**Who writes the link files (S: `share_by_link` in [`bin/darban`](../../bin/darban)):** this tool, as root, with mode 600, and the `.meta` file last. The link service only reads them, except `.meta`.

## 3. The options

### A. Keep it as it is

Nothing changes. Everything in the table of section 2 stays readable to a link service that someone breaks into.

### B. The same user, a smaller view

**What changes in the unit:**

- `InaccessiblePaths=` for every row of the table: `/etc/openvpn`, `/etc/letsencrypt`, `/var/backups/darban-pki`, `/var/lib/darban`, `/run/darban-events`, `/run/openvpn-server`, `/etc/shadow` and `/etc/gshadow`.
  - Each has a leading `-`, which means a path that does not exist is ignored (U). So no server fails to start the service.
- `RestrictAddressFamilies=AF_INET AF_INET6`, without `AF_UNIX`. The service then cannot open a unix socket at all, so the management interface is out of its reach wherever it is.
  - This matters because a hidden path covers only what is there when the service starts. OpenVPN removes and makes `/run/openvpn-server` again when it restarts, and the new folder is visible (P). The socket rule does not depend on the path.
- `/etc/darban` stays visible, with the certificate paths as they are, since nothing else in it is secret (section 2).

**What changes in `linkd.py`:** only its description. A hidden `server.conf` already makes `events_on` and `management_address` find nothing, so the service asks nothing (S).

**What changes for a server without connection events:**

- Today the link service asks the management interface every 10 seconds.
- The five-minute check (`darban sweep`, as root) already ends the links of a client that is connected, when no event did (S: `sweep_connected_links`).
- With B, that check is the only one, so a link ends within five minutes of the connection instead of ten seconds.
- A connection shorter than the gap can be missed, and that link lasts until it expires. The guides already warn about this for the 10-second check. Their sentence changes from "every 10 seconds" to "every five minutes", in `docs/en/sharing.md` and `docs/fa/sharing.md`.
- On a server with events, which is the default, nothing changes.

**What stays as it is:**

- Reload: SIGHUP reads the pair again, from the same paths as now.
- The port and the capability.
- Update and rollback: an older version installs its own unit, and no file on disk changes owner or mode.

**What B does not cover:**

- The process is still user 0. It can send a signal to processes of root, for example to stop OpenVPN, and it can read `/proc` of those processes.
- A system call filter could narrow the signals. That needs its own test, and it is not part of B (P).
- A management interface on localhost TCP stays reachable. This tool's setup never writes one; only a server set up by hand can have it.
- A folder mounted again after the service started, such as the event queue, is visible to it until it restarts (P). The service stops by itself when no link is left, so this lasts at most as long as the links.
- The code that reads the management interface stays in `linkd.py`, unused on a server this tool installed. C removes it.

**Size:**

| What changes | Lines |
|---|---|
| The unit | about 5 |
| `linkd.py` | its description |
| Diagnostics, and the two guides | one sentence each |
| Tests | see [section 7](#7-tests-for-the-pr-that-builds-it) |

One small PR.

### C. A user of its own

**A static system user, `darban-link`,** made by the installer with `useradd --system`.

**Why not `DynamicUser=yes`:**

- `RuntimeDirectory=` is removed when the service stops (U).
- But this service stops by itself once no link is left, and this tool writes a link's files **before** it starts the service (S). The folder would have to be kept with `RuntimeDirectoryPreserve=` anyway.
- A dynamic user id can change between starts, so the files root writes would need a fixed group in any case.
- A static user is simpler on both counts.

**Files:**

- `/run/darban-links` becomes `root:darban-link`, mode 2770.
- Every file root writes there gets mode 640 or 660 and that group: `.ovpn`, `.meta`, `.tmp`, and `.lock`.
- `.lock` matters most: the service opens it to read and write before each change (S: `Store.locked`). A `.lock` of root with mode 600 stops every link at once.
- At update, the files of links made by root before it are given the group and the mode.

**The key of the link certificate.** Two ways:

- **C1:** the pair is readable by the group: `link-cert` 750, `privkey.pem` 640, and `/etc/darban` 711 so the group can pass through it without listing it.
  - SIGHUP keeps working.
  - The service holds this key in memory anyway, so being able to read the file gives it nothing new.
- **C2:** `LoadCredential=`. A new certificate then needs a restart on both supported Ubuntu releases (section 1, point 3).
  - The restart ends a download in progress. The link is not used up, so the person only taps it again.

C1 is the better of the two.

**Port:**

- The port of links is 9347, 9563 or 9741 by default, but any port from 1 to 65535 can be set, 443 among them (S: `valid_link_port`, `LINK_PORT_CHOICES`).
- A user without root needs `AmbientCapabilities=CAP_NET_BIND_SERVICE` for a port below 1024, with the same bounding set as now (U).

**Management interface:** none, as in B. Giving the socket to a less privileged service would hand it commands, not only the list of connections. The code in `linkd.py` that reads it goes, with its tests.

**`.url`:**

- **Today:** the whole address of a link, token included, sits beside `.meta` with mode 600 and owner root (S).
- **The risk:** with a group-writable folder, a later mistake in a mode would give the service every token.
- **The move:** `.url` goes to a folder only root can open, such as `/run/darban-link-urls`.
- **Who removes it:**
  - this tool, wherever it removes a link (it already removes `.url` beside `.meta` in each of those places, S);
  - the five-minute check, for one whose link is gone (`sweep_links` already does this after a minute, S).
- **The service no longer removes it.** One left behind can last up to five minutes. A token opens nothing once its `.meta` is gone (S: `Store._read`).

**Rollback:**

- An older version's unit runs as root, which reads any file, so going back works.
- Going forward again needs the update step of the "Files" paragraph above.
- An older version cannot show again a link made by a newer one, because the address is no longer beside the link. It then says it cannot show the link (P).

**Size:**

- the unit and the installer (the user);
- in `bin/darban`, about 40 to 80 lines: writing a link, the paths of `.url`, the modes of the pairs, the update step, and a Diagnostics check of the modes;
- a few lines in `linkd.py`;
- tests, plus a round on a real server.

That is a medium PR, with the failure described in section 1.

## 4. The questions, one by one

| Question | Answer |
|---|---|
| A separate user, or `DynamicUser=` | A static system user, `darban-link`. `DynamicUser=` does not fit a service that stops by itself while root writes its files before it starts. |
| How the service reads files that root writes | A group and modes 640/660, in a setgid folder (C). With B, nothing changes. |
| A port below 1024 | `AmbientCapabilities=CAP_NET_BIND_SERVICE` (C). With B, as now. |
| `LoadCredential=` and SIGHUP | No new key without a restart, on systemd 255 and 259 (U). Neither recommended step uses it. |
| Reload without ending a download | B keeps it. C keeps it with C1, and loses it with C2. |
| The management interface on a server without events | The service stops reading it in B and in C. The five-minute check, as root, ends those links instead. |
| Where `.url` lives, and who removes it | Beside the link in B, since the user does not change. In its own root-only folder in C, removed by this tool and by the five-minute check. |
| Rollback | B: nothing on disk changes. C: back works, and forward needs the update step. |
| Size | B: small, one PR. C: medium, with a round on a real server. |
| Before or after v1.0.0 | B before, if the owner agrees. C in v1.1. |

## 5. The rule both steps keep

Lowering what the link service can do must not give it anything new: no `.url`, no CA key, no management command.

- **B** hides more than today and adds nothing.
- **C** keeps the rule only if `.url` moves out in the same change as the new user, and only if the service never gets the management interface.

## 6. Decision and order

**Decision (2026-11-17):** B is built before v1.0.0. C is planned for v1.1 and will be done; B does not replace it.

1. This report.
2. B as its own PR, before the release preparation of v1.0.0. It changes one unit, the description in `linkd.py`, one sentence in Diagnostics and in the guides. Its tests run in CI on both supported Ubuntu releases.
3. C in v1.1, after a round on a real server.

## 7. Tests for the PR that builds it

**B, in the acceptance job on both Ubuntu releases:**

1. **Hidden paths.** From inside the running service's mount namespace (`nsenter -t <MainPID> -m`):
   - the link key and the link files are there, which also shows that `nsenter` reached the namespace;
   - each hidden path of section 3 B that has something in it on the machine shows nothing there.
2. **The management interface.** The unit allows `AF_INET` and `AF_INET6`, and not `AF_UNIX`.
3. **Reload.** A renewed certificate is served after the reload, by the same MainPID.
4. **A server without events.** The five-minute check ends the link of a connected client. The suite already tests this, and B does not change that code.
5. **Unchanged jobs.** The reboot job, and the job that goes to rc.10 and back, pass unchanged. Going back to rc.10 brings back its own unit, so its link service asks the management interface again.

**C, in addition:**

1. The process runs as `darban-link`.
2. The link files have the group and modes of section 3 C.
3. A port of 443 binds.
4. Links made before the update still open after it.
5. `runuser -u darban-link -- test -r` fails for `.url` and for the CA.

**`LoadCredential=`, only if C2 is ever chosen:**

1. Make a link.
2. Replace the pair, then run `systemctl reload`.
3. The certificate served is still the old one on systemd 255 and 259. It is the new one only with `RefreshOnReload=credentials` on systemd 260 or later.

## 8. Not checked here

These are the P points:

- Connecting to a socket on a read-only mount, and a folder made again after the service started. B does not depend on either: the service can open no unix socket at all (point 2 of the B tests).
- A system call filter for signals. Not part of B.
- How an older version reports a link it cannot show again. A test for that belongs with C.

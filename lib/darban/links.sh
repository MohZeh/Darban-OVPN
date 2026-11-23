#!/usr/bin/env bash
# The port of the link service, and the running service taking a changed certificate.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

tcp_port_open() { timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$0"' "$1" 2>/dev/null; }
tcp_port_taken() {
    # True when another program listens on TCP $1, on any address: a panel bound only to the public IP counts
    # too. The link service itself does not.
    local listeners pid try cmdline ending
    for (( try = 0; try < 10; try++ )); do
        listeners=$(ss -H -ltnp "sport = :$1" 2>/dev/null) || listeners=''
        if [[ -z $listeners ]]; then tcp_port_open "$1"; return; fi
        ending=''
        for pid in $(grep -o 'pid=[0-9]*' <<<"$listeners" | cut -d= -f2 | sort -u); do
            cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || cmdline=''
            # A process that is ending, or already gone, has no command line left to tell what it was.
            if [[ -z $cmdline ]]; then ending=1; continue; fi
            grep '/linkd\.py ' <<<"$cmdline" >/dev/null || return 0
        done
        [[ -z $ending ]] && grep -q 'pid=' <<<"$listeners" && return 1
        # Held, but by no process this tool can see, or by one that is ending. The link service that ends after its
        # idle time shows its socket so for a moment, so look again for up to a second.
        sleep 0.1
    done
    return 0
}
tcp_port_program() {
    # The name of the program that listens on TCP $1, or "another program".
    local name
    name=$(ss -H -ltnp "sport = :$1" 2>/dev/null | grep -o '(("[^"]*"' | head -n 1 | tr -d '("')
    printf '%s\n' "${name:-another program}"
}
choose_link_port() {
    # The first free one is remembered, so links keep working on a port the firewall already allows. It is
    # checked again for each link: a panel installed later may have taken it.
    local candidate local_port
    # With port-share, links use the OpenVPN TCP port, and the service listens on its local port only.
    if port_share_on; then
        local_port=$(conf_port_share)
        if tcp_port_taken "$local_port"; then
            fail "TCP $local_port on this server, where OpenVPN hands links to the link page, is used by $(safe_text "$(tcp_port_program "$local_port")"). Turn sharing off and on again for a new one: Settings $S_CRUMB 2 $S_CRUMB 5."
            return 1
        fi
        return 0
    fi
    if [[ -n $LINK_PORT ]]; then
        if tcp_port_taken "$LINK_PORT"; then
            fail "TCP $LINK_PORT, the port for links, is now used by $(safe_text "$(tcp_port_program "$LINK_PORT")"). Choose another one: Settings $S_CRUMB Link port."
            return 1
        fi
        return 0
    fi
    if candidate=$(next_link_port); then
        LINK_PORT=$candidate
        save_config || warn 'Could not save the link port.'
        return 0
    fi
    fail "Ports ${LINK_PORT_CHOICES// /, } are all used by other programs. Choose one: Settings $S_CRUMB Link port."
    return 1
}
next_link_port() {
    # The port the first link will take: the first of the choices that no other program uses.
    local candidate
    for candidate in $LINK_PORT_CHOICES; do
        if ! tcp_port_taken "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}
link_port_summary() {
    # For Settings: the saved port, or the one the first link will take.
    local next
    if port_share_on; then printf '%s, shared with OpenVPN\n' "$(listener_port tcp)"; return; fi
    if [[ -n $LINK_PORT ]]; then printf '%s\n' "$LINK_PORT"; return; fi
    if next=$(next_link_port); then printf '%s\n' "$next"; else printf 'all of %s are in use\n' "${LINK_PORT_CHOICES// /, }"; fi
}
host_is_ip() { [[ $1 =~ ^[0-9.]+$ ]]; }

# ---------- the running link service takes a changed certificate ----------
served_link_cert_fingerprint() {
    # The certificate the link service answers with now, asked for the way a browser asks.
    local port
    port=$(awk -F= '$1 == "LINK_PORT" {print $2; exit}' "$LINK_ENV" 2>/dev/null)
    [[ $port =~ ^[0-9]+$ ]] || return 1
    timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername "$(domain)" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}
link_service_serves() {
    # link_service_serves <fingerprint>: the running service answers with it, within a few seconds.
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [[ $(served_link_cert_fingerprint) == "$1" ]] && return 0
        sleep 0.3
    done
    return 1
}
link_service_reloadable() {
    # Only a service from this version reloads on SIGHUP; an older one would end.
    local pid=''
    [[ -s $LINK_DIR/.reloadable ]] && IFS= read -r pid <"$LINK_DIR/.reloadable"
    [[ -n $pid && $pid == "$(systemctl show -p MainPID --value darban-links.service 2>/dev/null)" ]]
}
put_link_cert_in_service() {
    # put_link_cert_in_service <pair before the change>: the running service takes the new pair without stopping a
    # download in progress, and it is called done only once the service answers with it. One it does not take is
    # undone: the pair from before is put back whole, and the service answers with it again.
    local previous=${1:-} want
    if ! systemctl is-active --quiet darban-links.service 2>/dev/null; then
        info 'No link is open, so the link service is not running: the next link uses this certificate.'
        return 0
    fi
    if ! link_service_reloadable; then
        warn "The link service still runs the version from before the last update, so open links keep the previous certificate until the next link. To change it now, which stops a download in progress: $(cmd sudo systemctl restart darban-links.service)"
        return 0
    fi
    want=$(cert_fingerprint "$LINK_CERT")
    if systemctl reload darban-links.service 2>/dev/null && link_service_serves "$want"; then
        ok 'Open links use it now; no download was interrupted.'
        return 0
    fi
    # The service ends a minute after the last link; if it just did, nothing serves the old pair either.
    if ! systemctl is-active --quiet darban-links.service 2>/dev/null; then
        info 'The last link just ended, so the link service stopped: the next link uses this certificate.'
        return 0
    fi
    if [[ -n $previous ]] && with_link_lock link_pair_switch "$previous"; then
        want=$(cert_fingerprint "$LINK_CERT")
        if systemctl is-active --quiet darban-links.service 2>/dev/null; then
            systemctl reload darban-links.service 2>/dev/null || true
        else
            # It stopped, so no download is left to interrupt.
            start_link_service "$(domain)" >/dev/null 2>&1 || true
        fi
        if link_service_serves "$want"; then
            fail "The link service did not take the new certificate, so the previous one was put back, valid until $(cert_end_date "$LINK_CERT"), and open links use it. Details: $(cmd journalctl -u darban-links.service -n 20 --no-pager)"
            return 1
        fi
    fi
    fail "The link service answers with neither certificate, so open links may not open. Restart it: $(cmd sudo systemctl restart darban-links.service), and see $(cmd journalctl -u darban-links.service -n 20 --no-pager)"
    return 1
}
link_service_stays() {
    # Read under the link lock, after a link was written: the running service says in .serving that it has not
    # begun to end, so it serves that link, and that it runs the source installed now. It takes .serving back
    # under the same lock when it decides to end.
    local pid='' sum='' source=''
    systemctl is-active --quiet darban-links.service 2>/dev/null || return 1
    { IFS= read -r pid && IFS= read -r sum && IFS= read -r source; } 2>/dev/null <"$LINK_DIR/.serving" || return 1
    [[ $pid =~ ^[1-9][0-9]*$ && $pid == "$(systemctl show -p MainPID --value darban-links.service 2>/dev/null)" ]] || return 1
    valid_abs_path "$source" && [[ $sum =~ ^[0-9a-f]{64}$ && $(sha256sum -- "$source" 2>/dev/null) == "$sum "* ]]
}
start_link_service() {
    # start_link_service <host>: the link service runs, and serves the links written. One that stays, on the same
    # port, reads each link when it is asked for, so it is not restarted: that would end a download in progress.
    # A reload brings it a certificate that changed, and it counts once the service answers with it. Anything else
    # is restarted.
    local attempt running='' running_extra='' port extra=''
    port=$(link_listen_port)
    # With port-share the service listens on 127.0.0.1 only, reads the real address of each client from OpenVPN's
    # files, and stays up while no link is open, so the shared port always answers with an HTTPS page.
    if port_share_on; then extra="--bind 127.0.0.1 --port-share-dir $PORT_SHARE_DIR --idle-exit 0"; fi
    running=$(awk -F= '$1 == "LINK_PORT" {print $2; exit}' "$LINK_ENV" 2>/dev/null) || running=''
    running_extra=$(awk -F= '$1 == "LINK_EXTRA" {print substr($0, 12); exit}' "$LINK_ENV" 2>/dev/null) || running_extra=''
    printf 'LINK_HOST=%s\nLINK_PORT=%s\nLINK_EXTRA=%s\n' "$1" "$port" "$extra" >"$LINK_ENV" || return 1
    chmod 600 "$LINK_ENV" || return 1
    if [[ $running == "$port" && $running_extra == "$extra" ]] && links_locked link_service_stays && systemctl reload darban-links.service 2>/dev/null \
        && link_service_serves "$(cert_fingerprint "$LINK_CERT")"; then
        return 0
    fi
    systemctl restart darban-links.service || return 1
    for attempt in 1 2 3 4 5 6; do
        if tcp_port_open "$port"; then return 0; fi
        sleep 0.5
    done
    return 1
}

# ---------- port-share: the OpenVPN TCP port also serves the link page ----------
port_share_on() {
    # server.conf has this tool's port-share line, and OpenVPN listens on TCP.
    conf_port_share >/dev/null 2>&1 && listener_port tcp >/dev/null 2>&1
}
link_listen_port() {
    # The port the link service listens on: its local one with port-share, else the link port.
    if port_share_on; then conf_port_share; else printf '%s\n' "$LINK_PORT"; fi
}
link_public_port() {
    # The port in the address of a link: the OpenVPN TCP port with port-share, else the link port.
    if port_share_on; then listener_port tcp; else printf '%s\n' "$LINK_PORT"; fi
}
port_share_dir_ready() {
    # The folder OpenVPN writes a file in for each connection it hands over. OpenVPN's user owns it, and the link
    # service, root without CAP_DAC_OVERRIDE, reads it through the group: setgid gives each file the group root.
    # tmpfiles makes it again at each boot, before OpenVPN starts.
    local user
    user=$(darban_conf_single user 2>/dev/null) || user=root
    [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    # The folder of the links too: the link service starts at boot then, and its unit needs it.
    printf '# Darban OVPN: the files of OpenVPN port-share, for the link service.\nd %s 2750 %s root -\nd %s 0700 root root -\n' \
        "$PORT_SHARE_DIR" "$user" "$LINK_DIR" >"$PORT_SHARE_TMPFILES" || return 1
    chmod 644 "$PORT_SHARE_TMPFILES" || return 1
    systemd-tmpfiles --create "$PORT_SHARE_TMPFILES" >/dev/null 2>&1 || return 1
    [[ -d $PORT_SHARE_DIR && ! -L $PORT_SHARE_DIR ]]
}
port_share_service_on() {
    # port_share_service_on <host>: the link service listens on its local port, stays up, starts at boot, and
    # starts again when it fails.
    install -d -m 700 "$LINK_DIR" || return 1
    install -d -m 755 "${LINK_UNIT_DROPIN%/*}" || return 1
    printf '# Darban OVPN: while port-share is on, the link page stays up.\n[Service]\nRestart=on-failure\nRestartSec=2\n' >"$LINK_UNIT_DROPIN" || return 1
    chmod 644 "$LINK_UNIT_DROPIN" || return 1
    systemctl daemon-reload || return 1
    systemctl enable darban-links.service >/dev/null 2>&1 || return 1
    start_link_service "$1"
}
port_share_service_off() {
    # Back to the service of a link: only while a link is open, on the link port, ending by itself. Under the lock.
    local meta open=0
    rm -f -- "$LINK_UNIT_DROPIN" "$PORT_SHARE_TMPFILES"
    rmdir -- "${LINK_UNIT_DROPIN%/*}" 2>/dev/null || true
    systemctl disable darban-links.service >/dev/null 2>&1 || true
    systemctl daemon-reload || true
    for meta in "$LINK_DIR"/*.meta; do if [[ -e $meta ]]; then open=1; break; fi; done
    if (( open )) && choose_link_port && start_link_service "$(domain)"; then
        info "Open links work on TCP $LINK_PORT again, the port of their own; addresses given before named the OpenVPN port, so share those again."
    else
        systemctl stop darban-links.service >/dev/null 2>&1 || true
        if (( open )); then warn "The link service could not start on the link port, so open links do not open. Share them again (menu 5)."; fi
    fi
    rm -rf -- "$PORT_SHARE_DIR"
}
set_port_share() {
    # set_port_share <udp port or ''> <tcp port>: Settings > 2 > 5, shown only while OpenVPN listens on TCP.
    local udp=$1 tcp=$2 host local_port rc=0
    conf_port_share >/dev/null 2>&1 || rc=$?
    if (( rc == 2 )); then warn 'server.conf has a port-share line this tool did not write. Change it by hand, or remove it first.'; return 1; fi
    if (( rc == 0 )); then
        kv Current "on: TCP $tcp also serves the link page"
        info "Off, links get a port of their own again (Settings $S_CRUMB 4), which must be open in your provider firewall. Addresses of open links named TCP $tcp, so share those again."
        say
        restart_notice
        say
        confirm_choice "Stop sharing TCP $tcp with the link page?" 'No, keep sharing' 'Stop sharing' caution || { cancelled; return 0; }
        ca_lock || return 1
        apply_listeners 'port sharing off' "$udp" "$tcp" '' || return 1
        port_share_service_off
        audit 'port-share turned off'
        ok "TCP $tcp is OpenVPN's alone again."
        return 0
    fi
    kv Current off
    info "On, a connection to TCP $tcp that is not OpenVPN goes to the link page: whoever probes the port sees an ordinary HTTPS site, and links use TCP $tcp instead of a port of their own. The link page then stays up all the time. It does not hide the VPN from a careful look."
    say
    command -v python3 >/dev/null || { fail 'python3 is needed for the link page. Install it: apt install python3'; return 1; }
    host=$(domain)
    [[ -n $host ]] && valid_endpoint "$host" || { warn "Set the server address first: Settings $S_CRUMB 1."; return 1; }
    ensure_link_cert "$host" || return 1
    local_port=$(darban_free_port tcp "$tcp" "$udp" "$LINK_PORT")
    say
    restart_notice
    bullet "the link page listens on 127.0.0.1:$local_port, which only OpenVPN reaches"
    say
    confirm_choice "Share TCP $tcp with the link page?" 'No, keep it off' 'Share the port' caution || { cancelled; return 0; }
    ca_lock || return 1
    port_share_dir_ready || { fail "Could not make $PORT_SHARE_DIR for OpenVPN. Nothing was changed."; rm -f -- "$PORT_SHARE_TMPFILES"; return 1; }
    if ! apply_listeners 'port sharing on' "$udp" "$tcp" "$local_port"; then
        rm -f -- "$PORT_SHARE_TMPFILES"; rm -rf -- "$PORT_SHARE_DIR"
        return 1
    fi
    if ! port_share_service_on "$host"; then
        warn "OpenVPN shares TCP $tcp, but the link page did not start on 127.0.0.1:$local_port, so a probe gets no page. Check: $(cmd journalctl -u darban-links.service -n 30 --no-pager)"
        audit 'port-share turned on; the link service did not start'
        return 1
    fi
    audit "port-share turned on: TCP $tcp, link page on 127.0.0.1:$local_port"
    ok "TCP $tcp now answers HTTPS with the link page, and new links use it."
}
port_share_health() {
    # Diagnostics: the port is shared, its folder is there, and the link page answers on it.
    local local_port rc=0
    local_port=$(conf_port_share 2>/dev/null) || rc=$?
    if (( rc == 2 )); then check warn 'server.conf has a port-share line this tool did not write'; return 0; fi
    (( rc == 0 )) || return 0
    if ! listener_port tcp >/dev/null 2>&1; then check bad "server.conf shares a port, but OpenVPN does not listen on TCP $S_ARROW Settings $S_CRUMB 2"; return 0; fi
    if [[ ! -d $PORT_SHARE_DIR ]]; then
        check warn "The folder of port-share, $PORT_SHARE_DIR, is missing, so links count every visitor as 127.0.0.1 $S_ARROW sudo systemd-tmpfiles --create $PORT_SHARE_TMPFILES"
    fi
    if systemctl is-active --quiet darban-links.service 2>/dev/null && tcp_port_open "$local_port"; then
        check ok "TCP $(listener_port tcp) is shared: other connections reach the link page on 127.0.0.1:$local_port"
    else
        check bad "TCP $(listener_port tcp) is shared, but the link page is not running, so a probe gets no page $S_ARROW sudo systemctl restart darban-links.service"
    fi
}
links_locked() {
    # links_locked <command>...: changes the link files while holding the lock the link service takes too, so a
    # download in progress never writes back a link that is being removed.
    [[ -d $LINK_DIR ]] || { "$@"; return; }
    ( flock -w 10 8 || { warn 'The link service did not let go of its files.'; exit 1; }; "$@" ) 8>"$LINK_DIR/.lock"
}
remove_links_for() {
    # A revoked client must not stay reachable through a link that is still open.
    [[ -d $LINK_DIR ]] || return 0
    links_locked drop_links_of "$1"
}
drop_links_of() {
    # Every link of the name: only revoke calls this, when no other certificate of the name is valid.
    local meta
    for meta in "$LINK_DIR"/*.meta; do
        [[ -e $meta ]] || continue
        if grep -qFx "name=$1" "$meta"; then rm -f -- "$meta" "${meta%.meta}.ovpn" "${meta%.meta}.url" "${meta%.meta}.tmp"; fi
    done
}

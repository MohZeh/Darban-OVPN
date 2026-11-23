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
    local candidate
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
    local attempt running=''
    running=$(awk -F= '$1 == "LINK_PORT" {print $2; exit}' "$LINK_ENV" 2>/dev/null) || running=''
    printf 'LINK_HOST=%s\nLINK_PORT=%s\n' "$1" "$LINK_PORT" >"$LINK_ENV" || return 1
    chmod 600 "$LINK_ENV" || return 1
    if [[ $running == "$LINK_PORT" ]] && links_locked link_service_stays && systemctl reload darban-links.service 2>/dev/null \
        && link_service_serves "$(cert_fingerprint "$LINK_CERT")"; then
        return 0
    fi
    systemctl restart darban-links.service || return 1
    for attempt in 1 2 3 4 5 6; do
        if tcp_port_open "$LINK_PORT"; then return 0; fi
        sleep 0.5
    done
    return 1
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

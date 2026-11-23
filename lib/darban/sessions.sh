#!/usr/bin/env bash
# OpenVPN's management interface: who is connected now, and ending a session.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

mgmt_send() {
    # mgmt_send <command> [seconds]: prints the reply of a password-less management interface on a unix
    # socket or localhost TCP. Returns 2 = no usable interface, 1 = failed. OpenVPN drops the reply to a
    # command that arrives together with "quit", so quit has to wait until the reply has gone out.
    local command=$1 wait=${2:-0.3} spec addr port extra
    spec=$(awk '$1=="management" {n++; s=$2 "\t" $3 "\t" $4} END {if(n==1) print s}' "$DARBAN_SERVER_CONF")
    [[ -n $spec ]] || return 2
    IFS=$'\t' read -r addr port extra <<<"$spec"
    [[ -z $extra ]] || return 2
    if [[ $port == unix ]]; then
        addr=$(darban_conf_path "$addr")
        command -v socat >/dev/null && [[ -S $addr ]] || return 2
        { printf '%s\n' "$command"; sleep "$wait"; printf 'quit\n'; } | timeout "$MGMT_TIMEOUT" socat -t 2 - "UNIX-CONNECT:$addr" 2>/dev/null || return 1
    else
        [[ $addr == 127.0.0.1 || $addr == localhost || $addr == ::1 ]] && [[ $port =~ ^[0-9]+$ ]] || return 2
        timeout "$MGMT_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2" && printf "%s\n" "$3" >&3 && sleep "$4" && printf "quit\n" >&3 && cat <&3' _ "$addr" "$port" "$command" "$wait" 2>/dev/null || return 1
    fi
}
connected_rows() {
    # name<TAB>address<TAB>connected since, one line per connected client. Fails when the interface cannot answer.
    local reply
    reply=$(mgmt_send 'status 3') || return 1
    # name, address, connected since, since as epoch, bytes received, bytes sent.
    awk -F '\t' '$1=="CLIENT_LIST" && $2!="" && $2!="UNDEF" {a=$3; sub(/:[0-9]+$/,"",a); print $2 "\t" a "\t" $8 "\t" $9 "\t" $6 "\t" $7}' <<<"$reply"
}
duration_since() {
    # duration_since <epoch>: "3 h 12 min", "12 min", or "?" when the epoch is not a number.
    local seconds
    [[ ${1:-} =~ ^[0-9]+$ ]] || { printf '?\n'; return; }
    seconds=$(( $(date -u +%s) - $1 ))
    (( seconds >= 0 )) || seconds=0
    if (( seconds >= 86400 )); then printf '%s d %s h\n' $(( seconds / 86400 )) $(( seconds % 86400 / 3600 ))
    elif (( seconds >= 3600 )); then printf '%s h %s min\n' $(( seconds / 3600 )) $(( seconds % 3600 / 60 ))
    else printf '%s min\n' $(( seconds / 60 )); fi
}
human_bytes() {
    # human_bytes <bytes>: "1.2 GB", "340 MB", "12 KB".
    [[ ${1:-} =~ ^[0-9]+$ ]] || { printf '?\n'; return; }
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1000 && i < 5) { b /= 1000; i++ }
        if (i == 1) printf "%d %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i] }'
}
connected_clients() {
    local rows name address since epoch received sent
    if ! mgmt_available; then
        info "Not available: this needs a local management interface in server.conf, and socat."
        return 0
    fi
    rows=$(connected_rows) || { fail 'The OpenVPN management interface did not answer.'; return 1; }
    if [[ -z $rows ]]; then info 'No client is connected right now.'; return 0; fi
    # Built first and written at once, like the client list: a reader that stops early, such as grep -q, then
    # finds everything already in the pipe, and the tool does not end on a closed pipe halfway through.
    local out line
    printf -v out '  %s%-24s %-18s %-14s %s%s\n' "$C_BOLD" CLIENT ADDRESS 'CONNECTED FOR' 'TRAFFIC (down / up)' "$C_RESET"
    while IFS=$'\t' read -r name address since epoch received sent; do
        printf -v line '  %-24s %-18s %-14s %s\n' "$(safe_text "$name")" "$(safe_text "$address")" "$(duration_since "$epoch")" \
            "$(human_bytes "$sent") / $(human_bytes "$received")"
        out+=$line
    done <<<"$rows"
    printf '%s' "$out" || true
    # The note is for a person; a script reads the table alone.
    if (( UI_TTY )); then info 'Traffic is for this session only, as the server counts it: down is what the client received.'; fi
}
wait_for_connection() {
    # The only proof of the whole path, including the provider's firewall, which nothing here can see.
    # Returns 1 when it cannot help, so the caller pauses instead.
    local name=$1 attempt rows row address key port
    (( UI_TTY )) && mgmt_available || return 1
    port=$(server_port 2>/dev/null || printf '?')
    say
    info "Waiting for $name to connect. Press Enter to stop waiting."
    for (( attempt = 0; attempt < 200; attempt++ )); do
        rows=$(connected_rows 2>/dev/null) || rows=''
        row=$(awk -F '\t' -v n="$name" '$1==n {print; exit}' <<<"$rows")
        if [[ -n $row ]]; then
            IFS=$'\t' read -r _ address _ <<<"$row"
            ok "$name is connected from $(safe_text "$address"). The server and your provider's firewall let the VPN through."
            # The server sees the connection, not the device's internet or DNS: only the device can show those.
            info 'To check the internet too, open a website on that device.'
            pause
            return 0
        fi
        if IFS= read -r -t 3 key; then
            info 'Stopped waiting. Later, check: menu 3, Connected now.'
            return 0
        fi
    done
    warn "$name did not connect in 10 minutes. Check that UDP $port is open in your server provider's firewall."
    pause
}
mgmt_kill_client() {
    # Disconnect one CN. Returns 0 = killed, 3 = no such session, 2 = no usable interface, 1 = failed.
    local name=$1 reply rc=0
    reply=$(mgmt_send "kill $name" 1) || rc=$?
    (( rc == 0 )) || return "$rc"
    [[ $reply == *"SUCCESS: common name '$name' found"* ]] && return 0
    [[ $reply == *"ERROR: common name '$name' not found"* ]] && return 3
    printf '%s\n' "$reply" >&2 || true
    return 1
}
link_sees_connections() {
    # Connection events end a link at the first connection. Without them, the five-minute check asks the management
    # interface, as root; the link service cannot reach it. One local management line is enough, with the socat that
    # setup installs.
    local spec addr port extra
    if events_lines_on && events_units_installed; then return 0; fi
    spec=$(awk '$1=="management" {n++; s=$2 "\t" $3 "\t" $4} END {if(n==1) print s}' "$DARBAN_SERVER_CONF" 2>/dev/null)
    [[ -n $spec ]] || return 1
    IFS=$'\t' read -r addr port extra <<<"$spec"
    [[ -z $extra ]] || return 1
    [[ $port == unix || ( ( $addr == 127.0.0.1 || $addr == localhost || $addr == ::1 ) && $port =~ ^[0-9]+$ ) ]]
}
mgmt_available() {
    # True only when mgmt_kill_client could really use it.
    local spec addr port extra
    spec=$(awk '$1=="management" {n++; s=$2 "\t" $3 "\t" $4} END {if(n==1) print s}' "$DARBAN_SERVER_CONF" 2>/dev/null)
    [[ -n $spec ]] || return 1
    IFS=$'\t' read -r addr port extra <<<"$spec"
    [[ -z $extra ]] || return 1
    if [[ $port == unix ]]; then command -v socat >/dev/null; return; fi
    [[ $addr == 127.0.0.1 || $addr == localhost || $addr == ::1 ]] && [[ $port =~ ^[0-9]+$ ]]
}

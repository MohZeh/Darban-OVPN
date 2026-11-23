#!/usr/bin/env bash
# Connection events: the queue, the worker, the client ledger and the sweep.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- connection events ----------
# OpenVPN runs $EVENT_SCRIPT, as its own user, when a client connects and when a session ends. The script leaves one
# line in new/ of $EVENT_DIR, a tmpfs of its own. "darban events", which the queue's path unit starts as root, moves
# each entry to work/ under a name of its own, checks it there, where the script's user cannot reach it, applies it
# and deletes it. A malformed entry goes to bad/ with its reason; one that cannot be applied now stays for a later
# run. "darban sweep", every five minutes, takes what is left, ends expired links, and ends the links of a client
# that is connected although no event said so. A connection may end with the identity of the share its profile
# came from, when the profile carries one.
events_user() {
    # The user OpenVPN runs the script as: the one server.conf names, or root without one.
    local user
    user=$(darban_conf_single user 2>/dev/null) || user=root
    [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    printf '%s\n' "$user"
}
events_group() {
    local group user
    if ! group=$(darban_conf_single group 2>/dev/null); then
        user=$(events_user) || return 1
        group=$(id -gn "$user" 2>/dev/null) || return 1
    fi
    [[ $group =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    printf '%s\n' "$group"
}
events_lines_on() {
    # server.conf runs this tool's script at each connection and at the end of each session, once each.
    awk -v s="$EVENT_SCRIPT" '
        $1=="client-connect" {c++; if ($2!=s || NF!=2) bad=1}
        $1=="client-disconnect" {d++; if ($2!=s || NF!=2) bad=1}
        END {exit !(c==1 && d==1 && !bad)}' "$DARBAN_SERVER_CONF" 2>/dev/null
}
events_units_installed() { [[ -e $UNIT_DIR/darban-events.path ]]; }
events_mounted() {
    # The queue is a tmpfs, and the folders inside it are ready: a path alone, on /run itself, is not enough.
    [[ $(findmnt -n -o FSTYPE "$EVENT_DIR" 2>/dev/null) == tmpfs && -e $EVENT_DIR/.mounted ]]
}
events_blocker() {
    # Prints why the lines for connection events cannot go into server.conf, and returns 0. Returns 1 when nothing
    # stands in the way.
    local value rc=0 user limit
    if [[ $(head -n 1 "$DARBAN_SERVER_CONF" 2>/dev/null) != '# Created by Darban OVPN server-setup.' ]]; then
        printf "server.conf was not made by this tool's setup, so no script is added to it\n"; return 0
    fi
    if awk -v s="$EVENT_SCRIPT" '($1=="client-connect" || $1=="client-disconnect") && $2!=s {f=1} END {exit !f}' "$DARBAN_SERVER_CONF"; then
        printf 'server.conf already runs another client-connect or client-disconnect script\n'; return 0
    fi
    value=$(darban_conf_single script-security 2>/dev/null) || rc=$?
    if (( rc == 2 )); then printf 'server.conf sets script-security more than once\n'; return 0; fi
    if (( rc == 0 )) && [[ $value != 2 && $value != 3 ]]; then
        printf 'server.conf sets script-security %s, which lets OpenVPN run no script\n' "$(safe_text "$value")"; return 0
    fi
    if ! user=$(events_user) || ! events_group >/dev/null; then printf 'server.conf names a user or group this tool cannot use\n'; return 0; fi
    # The real script, as OpenVPN's user: a folder or a file system it cannot run from shows here. Without a client
    # name it writes nothing.
    if [[ ! -f $EVENT_SCRIPT ]] || ! runuser -u "$user" -- env -i script_type=client-connect "$EVENT_SCRIPT" </dev/null >/dev/null 2>&1; then
        printf '%s cannot run %s\n' "$user" "$EVENT_SCRIPT"; return 0
    fi
    # The limit counts every process of that user on the server, so a small one can make the script fail to start,
    # and OpenVPN then refuses the connection. 64 is a choice, not a proven line.
    limit=$(systemctl show -p LimitNPROC --value "$DARBAN_UNIT" 2>/dev/null) || limit=''
    if [[ $limit =~ ^[0-9]+$ ]] && (( limit <= 64 )); then
        printf "OpenVPN's service lets %s run only %s processes (LimitNPROC), so the script could refuse connections\n" "$user" "$limit"; return 0
    fi
    # Without it, OpenVPN's user could link a file of root's into the queue; the worker refuses such a link anyway.
    if [[ $(sysctl -n fs.protected_hardlinks 2>/dev/null) != 1 ]]; then
        printf 'the kernel lets a user link files it does not own (fs.protected_hardlinks is not 1)\n'; return 0
    fi
    if ! events_mounted; then printf 'the event queue %s is not mounted\n' "$EVENT_DIR"; return 0; fi
    return 1
}
enable_events() {
    # darban enable-events, which install.sh runs once the script and the units are in place: the lines go into
    # server.conf with one restart, and the previous file comes back if OpenVPN does not. Only when every check
    # passes; otherwise it says why and changes nothing, and links end when they expire, or when the link service
    # sees the connection.
    local reason value rc=0
    local -a add=()
    value=$(darban_conf_single script-security 2>/dev/null) || value=''
    if events_lines_on && [[ $value == 2 || $value == 3 ]]; then ok 'Connection events are on.'; return 0; fi
    if reason=$(events_blocker); then info "Connection events stay off: $reason."; return 0; fi
    conf_ready || { info 'Connection events stay off for now. Running the installer again tries once more.'; return 0; }
    info 'Turning on connection events: OpenVPN restarts once, so connected users drop for a few seconds and reconnect by themselves.'
    new_conf_file || return 1
    if [[ -z $value ]]; then add+=('script-security 2'); fi
    if ! events_lines_on; then add+=("client-connect $EVENT_SCRIPT" "client-disconnect $EVENT_SCRIPT"); fi
    { awk 1 "$DARBAN_SERVER_CONF" && printf '%s\n' "${add[@]}"; } >"$CONF_TEMP" || return 1
    conf_apply 'connection events' "$CONF_TEMP" || rc=$?
    if (( rc != 0 )); then info 'Connection events stay off. Running the installer again tries once more.'; return 0; fi
    printf '%s\n' "${add[@]}" >>"$EVENT_LINES_FILE" || true
    chmod 600 "$EVENT_LINES_FILE" 2>/dev/null || true
    ok 'Connection events are on: a link now ends at the first connection the server sees.'
}
event_lines_removal() {
    # The command that takes this tool's lines out of server.conf, and then the script: in that order, since
    # OpenVPN refuses connections while it names a script that is gone.
    local expr="\\#$EVENT_SCRIPT#d"
    if grep -qx 'script-security 2' "$EVENT_LINES_FILE" 2>/dev/null; then expr+="; /^script-security 2\$/d"; fi
    printf "sudo sed -i '%s' %s && sudo systemctl restart %s && sudo rm %s" "$expr" "$DARBAN_SERVER_CONF" "$DARBAN_UNIT" "$EVENT_SCRIPT"
}
events_setup() {
    # darban events-setup (darban-events-setup.service): the folders of the queue inside its tmpfs, then the mark
    # the script waits for. Nothing is made on /run itself.
    local user group
    if [[ $(findmnt -n -o FSTYPE "$EVENT_DIR" 2>/dev/null) != tmpfs ]]; then darban_error "$EVENT_DIR is not a tmpfs mount; nothing was made."; return 1; fi
    if ! user=$(events_user) || ! group=$(events_group); then darban_error 'server.conf names a user or group this tool cannot use.'; return 1; fi
    rm -f -- "$EVENT_DIR/.mounted"
    install -d -o "$user" -g "$group" -m 700 "$EVENT_DIR/tmp" "$EVENT_DIR/new" || return 1
    install -d -o root -g root -m 700 "$EVENT_DIR/work" "$EVENT_DIR/bad" || return 1
    chmod 755 "$EVENT_DIR" || return 1
    : >"$EVENT_DIR/.mounted"
}
uptime_cs() {
    # Hundredths of a second since boot, as the event script reads them.
    local up
    read -r up _ </proc/uptime || return 1
    up=${up/./}
    up=${up#"${up%%[!0]*}"}
    printf '%s\n' "${up:-0}"
}
# The name of this run: its claimed entries are named after it, so no two runs ever pick the same name.
event_run_id() { local cs; cs=$(uptime_cs) || cs=0; printf '%s-%s\n' "$$" "$cs"; }
events_claim() {
    # Moves what is in new/ to work/, each under a new name of this run, so nothing there is ever overwritten. The
    # result is read from the files: what mv returns for a target that exists differs between coreutils versions.
    local entry dest attempt restore
    restore=$(shopt -p nullglob dotglob || true)
    shopt -s nullglob dotglob
    for entry in "$EVENT_DIR"/new/*; do
        # The mark of an earlier run of this worker, owned by its own user, which OpenVPN's user cannot be.
        if [[ ${entry##*/} == "$EVENT_RERUN" && ! -L $entry && -O $entry ]]; then rm -f -- "$entry"; continue; fi
        (( EVENT_TAKEN < EVENT_MAX )) || break
        for attempt in 1 2 3; do
            EVENT_SEQ=$(( EVENT_SEQ + 1 ))
            dest=$EVENT_DIR/work/$EVENT_RUN-$EVENT_SEQ
            if [[ -e $dest || -L $dest ]]; then continue; fi
            mv -n -T -- "$entry" "$dest" 2>/dev/null || true
            if [[ -e $entry || -L $entry ]]; then continue; fi
            # Gone without reaching this name: another run took it.
            if [[ -e $dest || -L $dest ]]; then EVENT_TAKEN=$(( EVENT_TAKEN + 1 )); fi
            break
        done
    done
    eval "$restore"
}
event_read() {
    # event_read <file> <uid>: the one line of an event, read once, in EVENT_FIELDS; else EVENT_WHY and 1.
    local facts type owner links size line share
    EVENT_FIELDS=()
    if [[ -L $1 ]]; then EVENT_WHY='a symbolic link'; return 1; fi
    if ! facts=$(stat -c '%F|%u|%h|%s' -- "$1" 2>/dev/null); then EVENT_WHY='cannot be read'; return 1; fi
    IFS='|' read -r type owner links size <<<"$facts"
    if [[ $type != 'regular file' ]]; then EVENT_WHY="not a regular file but a $type"; return 1; fi
    if [[ $owner != "$2" ]]; then EVENT_WHY="written by uid $owner, not by OpenVPN's user"; return 1; fi
    if [[ $links != 1 ]]; then EVENT_WHY='a file with more than one hard link'; return 1; fi
    if [[ ! $size =~ ^[0-9]+$ ]]; then EVENT_WHY='cannot be read'; return 1; fi
    if (( size > 512 )); then EVENT_WHY='longer than 512 bytes'; return 1; fi
    # Read once: what follows uses this copy, whatever happens to the file.
    if ! line=$(head -c 513 -- "$1" 2>/dev/null); then EVENT_WHY='cannot be read'; return 1; fi
    if [[ ! $line =~ $EVENT_RE ]]; then EVENT_WHY='not an event line'; return 1; fi
    # The twelve fields after "darban-event 1"; the share is - when the line has none.
    share=${BASH_REMATCH[12]:-}
    share=${share# }
    EVENT_FIELDS=("${BASH_REMATCH[@]:1:11}" "${share:--}")
}
event_reject() {
    # event_reject <file> <reason>: a malformed entry is set aside and never applied. Its content is never logged.
    local name=${1##*/}
    mv -f -T -- "$1" "$EVENT_DIR/bad/$name" 2>/dev/null || rm -rf -- "$1" 2>/dev/null || true
    rm -f -- "$1.next" 2>/dev/null || true
    printf '%s\n' "$2" >"$EVENT_DIR/bad/$name.why" 2>/dev/null || true
    EVENT_REJECTED=$(( EVENT_REJECTED + 1 )) EVENT_REJECT_WHY="$name: $2"
}
event_later() {
    # event_later <file> <reason>: a well-formed event that could not be applied now waits at least 30 seconds,
    # then a minute, then five minutes, then until each next check. Nothing wakes the worker at those times: the
    # next event or the five-minute check does, so it is tried again by that check at the latest. It is never
    # called malformed.
    local tries=0 next=0 wait
    if [[ -f $1.next ]]; then read -r tries next _ <"$1.next" || true; fi
    [[ $tries =~ ^[0-9]+$ ]] || tries=0
    tries=$(( tries + 1 ))
    case $tries in 1) wait=30 ;; 2) wait=60 ;; 3) wait=300 ;; *) wait=240 ;; esac
    printf '%s %s %s\n' "$tries" "$(( $(date -u +%s) + wait ))" "$2" >"$1.next" 2>/dev/null || true
}
ledger_value() {
    # ledger_value <name> <field>: one value from the record of when a client was seen.
    [[ -f $LEDGER_DIR/$1 ]] || return 1
    awk -F= -v k="$2" '$1==k && $2 ~ /^[0-9A-Fa-f.:]+$/ {v=$2} END {if (v == "") exit 1; print v}' "$LEDGER_DIR/$1" 2>/dev/null
}
ledger_update() {
    # ledger_update <kind> <cn> <boot> <cs> <us> <ip> <serial> <rx> <tx> <seconds> <start>: when the client was
    # seen. Each value moves one way only, so an event applied twice, or two in another order, end the same.
    local kind=$1 name=$2 us=$5 address=$6 file=$LEDGER_DIR/$2 key value temp
    local first='' last='' connect='' ip='' end='' rx='' tx='' seconds='' start=''
    if [[ -f $file ]]; then
        while IFS='=' read -r key value; do
            [[ $value =~ ^[0-9A-Fa-f.:]{1,45}$ ]] || continue
            case $key in
                first_seen) first=$value ;; last_seen) last=$value ;; last_connect) connect=$value ;; last_address) ip=$value ;;
                session_end) end=$value ;; session_received) rx=$value ;; session_sent) tx=$value ;;
                session_seconds) seconds=$value ;; session_start) start=$value ;;
            esac
        done <"$file"
    fi
    [[ $first =~ ^[0-9]{16}$ ]] || first=''
    [[ $last =~ ^[0-9]{16}$ ]] || last=''
    [[ $connect =~ ^[0-9]{16}$ ]] || connect=''
    [[ $end =~ ^[0-9]{16}$ ]] || end=''
    if [[ -z $first ]] || (( 10#$us < 10#$first )); then first=$us; fi
    if [[ -z $last ]] || (( 10#$us > 10#$last )); then last=$us; fi
    if [[ $kind == connect ]]; then
        if [[ -z $connect ]] || (( 10#$us > 10#$connect )); then
            connect=$us
            if [[ $address != - ]]; then ip=$address; fi
        fi
    elif [[ -z $end ]] || (( 10#$us > 10#$end )); then
        end=$us rx=${8#-} tx=${9#-} seconds=${10#-} start=${11#-}
    fi
    install -d -m 700 "$LEDGER_DIR" || return 1
    temp=$(mktemp "$LEDGER_DIR/.$name.XXXXXXXX") || return 1
    if ! {
        printf 'first_seen=%s\nlast_seen=%s\n' "$first" "$last"
        for key in last_connect:"$connect" last_address:"$ip" session_end:"$end" session_received:"$rx" session_sent:"$tx" \
            session_seconds:"$seconds" session_start:"$start"; do
            if [[ -n ${key#*:} ]]; then printf '%s=%s\n' "${key%%:*}" "${key#*:}"; fi
        done
    } >"$temp" || ! mv -f -- "$temp" "$file"; then
        rm -f -- "$temp"
        return 1
    fi
}
link_meta() {
    # link_meta <meta>: the fields of a link record this tool uses, read in one pass.
    local key value
    LM_NAME='' LM_EXPIRES='' LM_CREATED='' LM_BOOT='' LM_CS='' LM_US='' LM_SHARE=''
    [[ -f $1 && ! -L $1 ]] || return 1
    while IFS='=' read -r key value; do
        case $key in
            name) LM_NAME=$value ;; expires) LM_EXPIRES=$value ;; created) LM_CREATED=$value ;;
            created_boot) LM_BOOT=$value ;; created_cs) LM_CS=$value ;; created_us) LM_US=$value ;;
            share_id) LM_SHARE=$value ;;
        esac
    done <"$1" || return 1
    [[ -n $LM_NAME ]]
}
link_made_before() {
    # link_made_before <meta> <cn> <boot> <cs> <serial> [share]: true when a connection of <cn> at that moment ends
    # the link. A link records the boot and the hundredth of a second it was made at, a clock NTP cannot move. Made
    # in an earlier boot, it is older than any event in the queue, which is a tmpfs. Made at the very same hundredth,
    # it stays. Without that record, made before an update, only its time ends it. A link whose certificate this tool
    # cannot identify is never ended by an event: it stays until its time is up or it is deleted in menu 6, and the
    # diagnostics name it. The serial OpenVPN gives, and the share the profile names, when there are any, only
    # narrow this: a link holding another certificate of the same name, or another share, stays.
    local share
    link_meta "$1" || return 1
    [[ $LM_NAME == "$2" ]] || return 1
    [[ $LM_BOOT =~ ^[0-9a-f-]{36}$ && $LM_CS =~ ^[0-9]{1,12}$ ]] || return 1
    if [[ $LM_BOOT == "$3" ]] && (( 10#$4 <= 10#$LM_CS )); then return 1; fi
    share=$(share_serial "${1%.meta}.ovpn" "$2") || return 1
    if [[ $5 != - && $(darban_norm_serial "$5" 2>/dev/null) != "$share" ]]; then return 1; fi
    if [[ ${6:--} != - && $6 != "$LM_SHARE" ]]; then return 1; fi
    return 0
}
events_end_links() {
    # events_end_links <cn> <boot> <cs> <serial> <share>: ends each open link of the client made before this
    # connection. Without one, the lock of the link files is not needed at all.
    local meta
    local -a found=()
    [[ -d $LINK_DIR ]] || return 0
    for meta in "$LINK_DIR"/*.meta; do
        [[ -e $meta ]] || continue
        if link_made_before "$meta" "$@"; then found+=("$meta"); fi
    done
    (( ${#found[@]} > 0 )) || return 0
    links_locked events_drop_links "$@" "${found[@]}"
}
events_drop_links() {
    local cn=$1 boot=$2 cs=$3 serial=$4 share=$5 meta
    shift 5
    for meta; do
        # Read again under the lock: the link may have ended, or changed, since.
        link_made_before "$meta" "$cn" "$boot" "$cs" "$serial" "$share" || continue
        rm -f -- "$meta" "${meta%.meta}.ovpn" "${meta%.meta}.url" "${meta%.meta}.tmp" || return 1
        audit "temporary link ended: $cn connected"
    done
}
kept_made_before() {
    # kept_made_before <cn> <boot> <cs> <serial> <share>: true when a connection of <cn> at that moment deletes its
    # kept file, by the same rules as a link. A file whose record is missing or no longer describes it, or names no
    # certificate, stays until the five-minute check gives it a record, or its time is up.
    share_record_read "$OUT_DIR/$1.ovpn" || return 1
    [[ $SR_BOOT =~ ^[0-9a-f-]{36}$ && $SR_CS =~ ^[0-9]{1,12}$ && -n $SR_SERIAL ]] || return 1
    if [[ $SR_BOOT == "$2" ]] && (( 10#$3 <= 10#$SR_CS )); then return 1; fi
    if [[ $4 != - && $(darban_norm_serial "$4" 2>/dev/null) != "$SR_SERIAL" ]]; then return 1; fi
    if [[ $5 != - && $5 != "$SR_ID" ]]; then return 1; fi
    return 0
}
events_end_kept() {
    # events_end_kept <cn> <boot> <cs> <serial> <share>: deletes the kept file of the client made before this
    # connection, under the CA lock the worker holds.
    valid_existing_name "$1" || return 0
    kept_made_before "$@" || return 0
    kept_file_drop "$1" "$1 connected" || return 1
    EXPIRE_DIRTY=1
}
event_apply() {
    # event_apply <kind> <cn> <boot> <cs> <us> <ip> <serial> <rx> <tx> <seconds> <start> [share]. Applied first and
    # deleted after, so a crash in between applies it again, which changes nothing more.
    local share=${12:--}
    if ! ledger_update "$@"; then EVENT_WHY='the client record could not be written'; return 1; fi
    if [[ $1 == connect ]] && ! events_end_links "$2" "$3" "$4" "$7" "$share" 2>/dev/null; then EVENT_WHY='the link files were busy'; return 1; fi
    if [[ $1 == connect ]] && ! events_end_kept "$2" "$3" "$4" "$7" "$share" 2>/dev/null; then EVENT_WHY='the kept file could not be deleted'; return 1; fi
    return 0
}
events_lock() {
    # The CA lock, as every writer of the client records and the links takes it first. Never held while waiting
    # for anything else, so the menu waits for it a few seconds at most.
    if (( CA_LOCKED )); then return 0; fi
    darban_lock 30 2>/dev/null || return 1
    CA_LOCKED=1
}
events_apply_claimed() {
    # Applies what work/ holds, oldest first by the clock inside each event, in turns of at most 50 under the CA
    # lock. An event that is not due yet waits. Each entry is read once: its checks, its order and what is applied
    # all come from that one copy, so a change to the file afterwards, through a descriptor its writer kept open,
    # changes nothing. This run stops at EVENT_MAX entries or its deadline; what is left waits for the next run.
    local file uid boot now rows count=0 cs busy=0 restore tries next fields
    local -a event=()
    uid=$(stat -c %u -- "$EVENT_DIR/new" 2>/dev/null) || return 0
    read -r boot </proc/sys/kernel/random/boot_id || return 0
    now=$(date -u +%s)
    rows=''
    restore=$(shopt -p nullglob dotglob || true)
    shopt -s nullglob dotglob
    for file in "$EVENT_DIR"/work/*; do
        [[ $file != *.next ]] || continue
        if [[ -f $file.next ]]; then
            tries=0 next=0
            read -r tries next _ <"$file.next" || true
            if [[ $next =~ ^[0-9]+$ ]] && (( next > now )); then continue; fi
        fi
        if ! event_read "$file" "$uid"; then event_reject "$file" "$EVENT_WHY"; continue; fi
        # The queue is a tmpfs, so an event of another boot cannot be real.
        if [[ ${EVENT_FIELDS[2]} != "$boot" ]]; then event_reject "$file" 'from another boot'; continue; fi
        # The fields hold no space or tab, so the copy travels in the row itself.
        rows+="${EVENT_FIELDS[3]}"$'\t'"$file"$'\t'"${EVENT_FIELDS[*]}"$'\n'
    done
    eval "$restore"
    if [[ -n $rows ]]; then
        while IFS=$'\t' read -r cs file fields; do
            [[ -n $file ]] || continue
            if (( EVENT_DONE >= EVENT_MAX || SECONDS >= EVENT_DEADLINE )); then EVENT_LEFT=1; break; fi
            if (( busy )); then event_later "$file" 'the CA lock was busy'; continue; fi
            if (( count % 50 == 0 )); then
                ca_unlock
                if ! events_lock; then busy=1; event_later "$file" 'the CA lock was busy'; continue; fi
            fi
            count=$(( count + 1 )) EVENT_DONE=$(( EVENT_DONE + 1 ))
            read -r -a event <<<"$fields"
            if event_apply "${event[@]}"; then
                rm -f -- "$file" "$file.next"
            else
                event_later "$file" "$EVENT_WHY"
            fi
        done < <(sort -t $'\t' -k1,1n -k2,2 <<<"$rows")
        ca_unlock
    fi
    if (( EVENT_REJECTED > 0 )); then
        audit "connection events set aside as malformed: $EVENT_REJECTED; the last: $EVENT_REJECT_WHY"
        EVENT_REJECTED=0
    fi
}
events_worker_lock() {
    # events_worker_lock <seconds>: waits that long for another worker to finish, 0 for not at all; 1 if it did not.
    exec 7>>"$EVENT_DIR/$EVENT_WORKER_LOCK" 2>/dev/null || return 1
    if (( $1 > 0 )); then flock -w "$1" 7 2>/dev/null && return 0; else flock -n 7 2>/dev/null && return 0; fi
    exec 7>&-
    return 1
}
events_worker_unlock() { flock -u 7 2>/dev/null || true; exec 7>&-; }
# darban events: the worker, waiting for one already running.
events_worker() { events_run "$EVENT_WORKER_WAIT"; }
events_run() {
    # darban events (darban-events.service, started by the path unit while new/ holds something): takes what
    # OpenVPN left and applies it, until new/ is empty, or it has taken or applied EVENT_MAX entries, or
    # EVENT_SECONDS have passed. What is left then is not lost: entries still in new/ start it again by themselves,
    # and for those it took but did not apply, it leaves its mark in new/, which does the same.
    # events_run [seconds]: how long to wait for a worker already running, none by default. darban events waits:
    # returning at once, the path unit would start it again and again while new/ holds something. The sweep does
    # not: the worker that holds the lock takes what is waiting, and the sweep goes on with its own work.
    local before
    events_mounted || return 0
    events_worker_lock "${1:-0}" || return 0
    EVENT_RUN=$(event_run_id) EVENT_SEQ=0 EVENT_TAKEN=0 EVENT_DONE=0 EVENT_LEFT=0 EXPIRE_DIRTY=0
    EVENT_DEADLINE=$(( SECONDS + EVENT_SECONDS ))
    while :; do
        before=$EVENT_TAKEN
        events_claim
        events_apply_claimed
        (( ! EVENT_LEFT && EVENT_TAKEN > before && EVENT_TAKEN < EVENT_MAX && SECONDS < EVENT_DEADLINE )) || break
    done
    if (( EVENT_LEFT )); then : >"$EVENT_DIR/new/$EVENT_RERUN" 2>/dev/null || true; fi
    # A kept file went: the timer now waits for the next one.
    if (( EXPIRE_DIRTY )) && events_lock; then expire_schedule || true; ca_unlock; fi
    EXPIRE_DIRTY=0
    events_worker_unlock
}
sweep_links() {
    # Expired links, and the files of a link whose record is gone for a minute, as the link service removes them
    # while it runs. Without it running, nothing else would.
    local meta file now
    now=$(date -u +%s)
    for meta in "$LINK_DIR"/*.meta; do
        [[ -e $meta ]] || continue
        if link_meta "$meta" && [[ $LM_EXPIRES =~ ^[0-9]+$ ]] && (( LM_EXPIRES > now )); then continue; fi
        rm -f -- "$meta" "${meta%.meta}.ovpn" "${meta%.meta}.url" "${meta%.meta}.tmp" || return 1
        audit "temporary link ended: its time was up${LM_NAME:+: $LM_NAME}"
    done
    for file in "$LINK_DIR"/*.ovpn "$LINK_DIR"/*.url "$LINK_DIR"/*.tmp; do
        [[ -e $file && ! -e ${file%.*}.meta ]] || continue
        if [[ -n $(find "$file" -maxdepth 0 -mmin +1 2>/dev/null) ]]; then rm -f -- "$file"; fi
    done
}
sweep_files() {
    # The files kept on the server, under the CA lock. One made before this version, or rewritten by something that
    # does not know records, gets a record now, and with it the whole time of Settings, once, in the journal. One
    # whose time is up goes, with the copy made for the SSH user. A record without its file goes. Only <name>.ovpn,
    # a regular file, of a name the CA knows: anything else there is someone else's.
    local file record name now serial remote listed=0
    local -A known=()
    now=$(date -u +%s)
    for file in "$OUT_DIR"/*.ovpn; do
        [[ -f $file && ! -L $file ]] || continue
        if (( ! listed )); then
            while IFS=$'\t' read -r name _; do if [[ -n $name ]]; then known[$name]=1; fi; done < <(client_index_rows 2>/dev/null)
            listed=1
        fi
        name=${file##*/}; name=${name%.ovpn}
        valid_existing_name "$name" && [[ -n ${known[$name]:-} ]] || continue
        if ! share_record_read "$file"; then
            serial=$(share_serial "$file" "$name") || serial=''
            remote=$(grep -m1 '^remote ' "$file" 2>/dev/null) || remote=''
            share_record_write "$name" "$(openssl rand -hex 8)" "$serial" "$remote" || continue
            audit "profile kept on the server from before: $file, deleted in $(hours_label "$(link_hours)") or when $name connects"
            continue
        fi
        (( SR_EXPIRES <= now )) || continue
        kept_file_drop "$name" 'its time was up' || return 1
    done
    for record in "$OUT_DIR"/*.share; do
        [[ -f $record && ! -e ${record%.share}.ovpn ]] || continue
        rm -f -- "$record"
    done
    find "$OUT_DIR" -maxdepth 1 -name '.share.*' -mmin +10 -delete 2>/dev/null || true
    home_copy_sweep
    HC_DONE='' HC_KEPT=
}
connected_after() {
    # connected_after <rows of connected_rows> <name> <boot> <cs> <us>: true when <name> is connected now in a
    # session that began after a share made at that moment. The wall clock is trusted only when it has not jumped
    # since the share was made: its gap to the time since boot is the same within 2 seconds.
    local boot up now offset made since
    read -r boot </proc/sys/kernel/random/boot_id || return 1
    [[ $3 == "$boot" && $4 =~ ^[0-9]{1,12}$ && $5 =~ ^[0-9]{16}$ ]] || return 1
    up=$(uptime_cs) || return 1
    now=${EPOCHREALTIME//[!0-9]/}
    offset=$(( 10#$now / 10000 - 10#$up ))
    made=$(( 10#$5 / 10000 - 10#$4 - offset ))
    (( made >= -200 && made <= 200 )) || return 1
    since=$(awk -F '\t' -v n="$2" '$1==n && $4 ~ /^[0-9]+$/ && $4 > s {s=$4} END {print s + 0}' <<<"$1")
    (( since * 1000000 > 10#$5 ))
}
sweep_connected_links() {
    # sweep_connected_links <rows of connected_rows>: a client connected now ends the links made before its session
    # began, when no event did, because it was lost or events are off.
    local rows=$1 meta
    [[ -n $rows ]] || return 0
    for meta in "$LINK_DIR"/*.meta; do
        [[ -e $meta ]] || continue
        link_meta "$meta" || continue
        connected_after "$rows" "$LM_NAME" "$LM_BOOT" "$LM_CS" "$LM_US" || continue
        # A link with a certificate this tool cannot identify stays, as with an event.
        share_serial "${meta%.meta}.ovpn" "$LM_NAME" >/dev/null || continue
        rm -f -- "$meta" "${meta%.meta}.ovpn" "${meta%.meta}.url" "${meta%.meta}.tmp" || return 1
        audit "temporary link ended: $LM_NAME connected (seen by the five-minute check, with no event)"
    done
}
sweep_connected_files() {
    # sweep_connected_files <rows of connected_rows>: the same for the files kept on the server, under the CA lock.
    local rows=$1 file name
    [[ -n $rows ]] || return 0
    for file in "$OUT_DIR"/*.ovpn; do
        name=${file##*/}; name=${name%.ovpn}
        valid_existing_name "$name" && share_record_read "$file" && [[ -n $SR_SERIAL ]] || continue
        connected_after "$rows" "$name" "$SR_BOOT" "$SR_CS" "$SR_US" || continue
        kept_file_drop "$name" "$name connected (seen by the five-minute check, with no event)" || return 1
    done
}
sweep_queue() {
    # What the script left half way, malformed entries older than a week, and more than the newest 100 of them.
    local file
    local -a kept=()
    [[ -d $EVENT_DIR/tmp && -d $EVENT_DIR/bad ]] || return 0
    find "$EVENT_DIR/tmp" -mindepth 1 -maxdepth 1 -mmin +10 -exec rm -rf -- {} + 2>/dev/null || true
    find "$EVENT_DIR/bad" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf -- {} + 2>/dev/null || true
    mapfile -t kept < <(find "$EVENT_DIR/bad" -mindepth 1 -maxdepth 1 ! -name '*.why' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    for file in "${kept[@]:100}"; do rm -rf -- "$file" "$file.why" 2>/dev/null || true; done
}
sweep() {
    # darban sweep (darban-sweep.timer: a minute after boot, then every five minutes; darban-expire.timer: when the
    # next kept file is due). Quick when there is nothing to do.
    local rows='' files=0
    # The watcher of the queue, failed for example under a burst of starts, is started again.
    if events_units_installed && systemctl is-failed --quiet darban-events.path 2>/dev/null; then
        systemctl reset-failed darban-events.path 2>/dev/null || true
        if systemctl start darban-events.path 2>/dev/null; then audit 'connection events: the queue watcher had failed, and was started again'; fi
    fi
    events_run
    if compgen -G "$OUT_DIR/*.ovpn" >/dev/null || compgen -G "$OUT_DIR/*.share" >/dev/null || compgen -G "$OUT_DIR/.homecopy.*" >/dev/null; then files=1; fi
    if [[ -d $LINK_DIR ]] || (( files )); then
        # Asked before any lock is taken: the management interface may be slow, and nothing waits on it.
        if mgmt_available; then rows=$(MGMT_TIMEOUT=3 connected_rows 2>/dev/null) || rows=''; fi
        if events_lock; then
            if [[ -d $LINK_DIR ]]; then
                links_locked sweep_links 2>/dev/null || true
                links_locked sweep_connected_links "$rows" 2>/dev/null || true
            fi
            if (( files )); then
                sweep_files 2>/dev/null || true
                sweep_connected_files "$rows" 2>/dev/null || true
                expire_schedule || true
            fi
            ca_unlock
        fi
    fi
    # What finished restores replaced, once its time is over.
    if compgen -G "$PKI_BACKUP_DIR/pre-restore-*" >/dev/null && ca_lock 2>/dev/null; then pre_restore_prune || true; ca_unlock; fi
    sweep_queue
}
events_health() {
    # The Diagnostics group "Connection events": what can be seen of the way from OpenVPN to this tool. A lost event
    # of a short connection cannot be seen; that link then lasts until it expires.
    local user value limit tasks count reason rows name since connect now late='' before=$((HEALTH_BAD + HEALTH_WARN)) reinstall
    reinstall="sudo bash -c 'curl -fsSL https://github.com/$DARBAN_REPO/releases/download/v$DARBAN_VERSION/get.sh | bash -s -- --version v$DARBAN_VERSION'"
    if ! events_lines_on; then
        if events_units_installed; then
            if reason=$(events_blocker); then
                check info "Connection events are off: $reason. A link ends when it expires, or when the five-minute check sees the connection"
            else
                check info "Connection events are off. A link ends when it expires, or when the five-minute check sees the connection. To turn them on $S_ARROW $reinstall"
            fi
        fi
        return 0
    fi
    value=$(darban_conf_single script-security 2>/dev/null) || value=''
    if [[ $value != 2 && $value != 3 ]]; then
        check bad "server.conf runs $EVENT_SCRIPT at each connection, but script-security is ${value:-not set}, so OpenVPN refuses every connection $S_ARROW $reinstall"
    fi
    user=$(events_user) || user=nobody
    if [[ ! -f $EVENT_SCRIPT ]] || ! runuser -u "$user" -- test -x "$EVENT_SCRIPT" 2>/dev/null; then
        check bad "server.conf runs $EVENT_SCRIPT as $user at each connection, but $user cannot run it, so connections may be refused $S_ARROW $reinstall"
    fi
    if ! events_units_installed; then
        check info 'Connection events are not processed: their systemd units are not installed. A link ends when it expires'
        return 0
    fi
    if ! events_mounted; then
        check bad "The event queue $EVENT_DIR is not mounted, so connections are not seen $S_ARROW sudo systemctl restart darban-events-setup.service"
    else
        if ! systemctl is-active --quiet darban-events.path 2>/dev/null; then
            check bad "The queue watcher darban-events.path is not running, so connections are not seen $S_ARROW sudo systemctl restart darban-events.path"
        fi
        count=$(find "$EVENT_DIR/new" "$EVENT_DIR/work" -mindepth 1 -maxdepth 1 ! -name '*.next' -mmin +10 2>/dev/null | wc -l) || count=0
        if (( count > 0 )); then
            reason=$(cat "$EVENT_DIR"/work/*.next 2>/dev/null | awk '{$1=""; $2=""; sub(/^ +/, ""); r=$0} END {print r}') || reason=''
            check bad "$count connection event(s) waited more than 10 minutes${reason:+ (the last failure: $reason)} $S_ARROW sudo journalctl -u darban-events.service -n 30"
        fi
        if read -r value count < <(df --output=avail,iavail "$EVENT_DIR" 2>/dev/null | tail -n 1) && [[ $value =~ ^[0-9]+$ && $count =~ ^[0-9]+$ ]] && (( value < 64 || count < 16 )); then
            check bad "The event queue $EVENT_DIR is full, so new connections are not seen $S_ARROW sudo journalctl -u darban-events.service -n 30"
        fi
        count=$(find "$EVENT_DIR/bad" -mindepth 1 -maxdepth 1 ! -name '*.why' 2>/dev/null | wc -l) || count=0
        if (( count > 0 )); then check warn "$count malformed connection event(s) were set aside in $EVENT_DIR/bad $S_ARROW sudo journalctl -t darban"; fi
    fi
    if [[ $(sysctl -n fs.protected_hardlinks 2>/dev/null) != 1 ]]; then
        check warn "The kernel lets a user link files it does not own, so a malformed connection event could point at one; such entries are set aside $S_ARROW sudo sysctl -w fs.protected_hardlinks=1"
    fi
    if ! systemctl is-active --quiet darban-sweep.timer 2>/dev/null; then
        check bad "The five-minute check darban-sweep.timer is not active, so an expired link can stay $S_ARROW sudo systemctl enable --now darban-sweep.timer"
    fi
    limit=$(systemctl show -p LimitNPROC --value "$DARBAN_UNIT" 2>/dev/null) || limit=''
    tasks=$(systemctl show -p TasksMax --value "$DARBAN_UNIT" 2>/dev/null) || tasks=''
    count=$(pgrep -c -u "$user" 2>/dev/null) || count=${count:-0}
    if [[ $limit =~ ^[0-9]+$ ]] && (( limit <= 64 )); then
        check bad "OpenVPN's service lets $user run only $limit processes (LimitNPROC), and $user runs $count now, so the script may fail and refuse connections $S_ARROW remove that limit from $DARBAN_UNIT"
    else
        check info "Process limits of OpenVPN: LimitNPROC ${limit:-unknown}, TasksMax ${tasks:-unknown}; $user runs $count process(es)"
    fi
    # A session the server lists for over a minute, with no connect event since it began.
    if mgmt_available && rows=$(connected_rows 2>/dev/null) && [[ -n $rows ]]; then
        now=$(date -u +%s)
        while IFS=$'\t' read -r name _ _ since _; do
            [[ $since =~ ^[0-9]+$ ]] && (( now - since > 60 )) || continue
            connect=$(ledger_value "$name" last_connect) || connect=0
            if (( 10#$connect / 1000000 + 5 < since )); then late+="$name"$'\n'; fi
        done <<<"$rows"
        late=$(printf '%s' "$late" | join_lines)
        if [[ -n $late ]]; then
            check warn "Connected, but no connection event was seen: $(safe_text "$late"). Their open links end at the next five-minute check"
        fi
    fi
    if (( HEALTH_BAD + HEALTH_WARN == before )); then check ok 'Connection events are seen: a link ends at the first connection'; fi
}
last_seen_label() {
    # last_seen_label <name> <online list> <events on>: now, "12 min ago", "3 h ago", "5 d ago", never, or - when
    # this server does not record it.
    local us seconds
    if [[ $2 == *$'\n'"$1"$'\n'* ]]; then printf 'now'; return 0; fi
    if ! us=$(ledger_value "$1" last_seen) || [[ ! $us =~ ^[0-9]{16}$ ]]; then
        if (( $3 )); then printf 'never'; else printf -- '-'; fi
        return 0
    fi
    seconds=$(( $(date -u +%s) - 10#$us / 1000000 ))
    (( seconds >= 0 )) || seconds=0
    if (( seconds < 3600 )); then printf '%d min ago' $(( seconds < 60 ? 1 : seconds / 60 ))
    elif (( seconds < 86400 )); then printf '%d h ago' $(( seconds / 3600 ))
    else printf '%d d ago' $(( seconds / 86400 )); fi
}

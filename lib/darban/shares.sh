#!/usr/bin/env bash
# Sharing a profile: the copies for the SSH user, and the copies this tool keeps with their records.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

# ---------- sharing ----------
share_profile() {
    profile_preconditions || return 1
    pick_client 'Share which client?' can_reexport export_block_reason || return 0
    ca_lock || return 1
    write_profile "$PICKED" yes || return 1
    ca_unlock
    audit "profile rebuilt: $PICKED"
    clear_screen
    share_client "$PICKED"
    if (( SHARED )) && wait_for_connection "$PICKED"; then no_pause; fi
}
share_client() {
    # share_client <name>: asks how the profile travels and shows only that method. The QR code of a link is
    # offered with the link itself, and the download commands come with keeping the file on the server.
    local name=$1 method
    choose_one "How will $name get this profile?" \
        'Temporary link: send it to the user' \
        'Keep it on the server: download it with scp or sftp' || {
        info "Kept on the server: $OUT_DIR/$name.ovpn. $(kept_until "$name") Share it from menu 5, or delete it from menu 6."
        return 0
    }
    method=$CHOSEN
    SHARED=1
    PROFILE_PASSWORD=''
    say
    if (( method == 2 )); then
        # The admin fetches this file over SSH, which already proves the server: a password would add nothing.
        share_by_download "$name"
        return 0
    fi
    # The link's certificate is settled first, because a link without a trusted one gets a word about the password.
    prepare_link || return 1
    if link_cert_is_trusted "$(domain)"; then choose_profile_password; else choose_profile_password untrusted; fi
    if [[ -n $PROFILE_PASSWORD ]]; then
        ca_lock || return 1
        write_profile "$name" yes || return 1
        ca_unlock
    fi
    say
    share_by_link "$name" || return 1
}
share_text() {
    # share_text <link> <password> <note>: what goes to the person, each label and value on its own line.
    local text=''
    if [[ -n $1 ]]; then text+=$'Link:\n'$1$'\n'; fi
    if [[ -n $2 ]]; then text+=$'Password:\n'$2$'\n'; fi
    if [[ -n $3 ]]; then text+=$'Note:\n'$3$'\n'; fi
    printf '%s' "${text%$'\n'}"
}
show_share_block() {
    # show_share_block <link> <password> <note>: the same lines as share_text, unindented and with no frame, so
    # one mouse selection from the first label down copies exactly what the copy key copies.
    say "${C_BOLD}Send this to the person:${C_RESET}"
    say
    if [[ -n $1 ]]; then say "${C_BOLD}Link:${C_RESET}"; say "$C_LINK$1$C_RESET"; fi
    if [[ -n $2 ]]; then say "${C_BOLD}Password:${C_RESET}"; say "$C_SECRET$2$C_RESET"; fi
    if [[ -n $3 ]]; then say "${C_BOLD}Note:${C_RESET}"; say "$3"; fi
    say
}
offer_copy() {
    # offer_copy <what to select instead> <extra option or ''> <option> <text> [<option> <text>]...: Enter copies
    # the first text. Returns 3 when the extra option, placed after the copy options, was chosen. Only a terminal
    # has a clipboard to reach; a script gets no question, so its answers stay in step.
    local select=$1 extra=$2 i
    shift 2
    (( UI_TTY )) || return 0
    local -a labels=() texts=()
    while (( $# >= 2 )); do labels+=("$1"); texts+=("$2"); shift 2; done
    if [[ -n $extra ]]; then labels+=("$extra"); fi
    choose_one 'Copy it to your clipboard?' "${labels[@]}" 'Do not copy' || return 0
    i=$(( CHOSEN - 1 ))
    if [[ -n $extra ]] && (( i == ${#texts[@]} )); then return 3; fi
    (( i < ${#texts[@]} )) || return 0
    copy_to_clipboard "${texts[i]}" || { warn 'Could not copy.'; return 0; }
    ok 'Copied to your clipboard, if your terminal allows it.'
    info "If pasting does not give this text, your terminal does not allow it (PuTTY, for example). Select $select with the mouse instead."
}
make_password() {
    # Nine characters in one piece: nothing that might or might not belong to it, easy to type on a phone, and
    # no characters that look alike. Bytes from 248 up are skipped, so all 31 characters are equally likely.
    local alphabet=abcdefghjkmnpqrstuvwxyz23456789 raw='' out='' i=0 count=0 byte
    while (( count < 9 )); do
        if (( i * 2 >= ${#raw} )); then raw=$(openssl rand -hex 32) || return 1; i=0; fi
        byte=$(( 16#${raw:i*2:2} )); i=$(( i + 1 ))
        (( byte < 248 )) || continue
        out+=${alphabet:$(( byte % ${#alphabet} )):1}
        count=$(( count + 1 ))
    done
    printf '%s\n' "$out"
}
choose_profile_password() {
    # choose_profile_password [untrusted]: Enter means no password. A link without a trusted certificate gets
    # a word about it, and the choice stays with the person.
    local suggested
    PROFILE_PASSWORD=''
    if [[ ${1:-} == untrusted ]]; then info 'This link has no trusted certificate. A password on the key protects the profile if someone else gets the file.'; fi
    confirm_choice 'Lock the private key with a password?' 'No password' 'Yes, make a password' normal '' 1 || return 0
    suggested=$(make_password) || { fail 'Could not create a password.'; return 1; }
    PROFILE_PASSWORD=$suggested
    (( UI_TTY )) || return 0
    # The suggestion stands on its own line in the color it has in the final block, so it reads as the
    # password and not as part of a sentence.
    say
    say "${C_BOLD}Suggested password:${C_RESET}"
    say "$C_SECRET$suggested$C_RESET"
    say
    info 'Press Enter to use it. Or type your own: a word or a short phrase of at least 9 characters, in English letters, digits, spaces or symbols.'
    while :; do
        ask 'Password (Enter = the suggested one): ' || { PROFILE_PASSWORD=$suggested; return 0; }
        if [[ -z $REPLY ]]; then
            PROFILE_PASSWORD=$suggested
            ok 'The suggested password is used.'
            return 0
        fi
        if (( ${#REPLY} < 9 )); then warn 'Use at least 9 characters.'; continue; fi
        # Another keyboard can encode other letters differently, and the key would then not open on the device.
        if printf '%s' "$REPLY" | LC_ALL=C grep -q '[^ -~]'; then
            warn 'Use only English letters, digits, spaces and symbols, so the password types the same on every device.'
            continue
        fi
        PROFILE_PASSWORD=$REPLY
        ok 'Your password is used.'
        return 0
    done
}
# ---------- copies for the SSH user ----------
# Profiles live under /root, which only root can read. Another SSH user gets a private copy in their home. Each copy
# this tool makes is recorded until it is deleted, in $OUT_DIR/.homecopy.<id>: apart from the record of the share
# and from the user set now, so a copy is never lost when the share is made again, becomes a link, or the user
# changes. A copy ends with its share: when the client connects, when its time is up, when it becomes a link, or
# when it is shared again. A revocation also deletes every recorded copy that holds the revoked certificate, and the
# file of that name in the home of the user set now when it holds it too. Nothing is deleted or written over unless,
# at that moment, it is still the file this tool made: the same inode, size, change and modification time, and one
# name. A copy changed after it was made is kept, and so is its record, marked kept: Diagnostics name it, a
# revocation still deletes it when it holds the revoked certificate, and the record goes once the file is gone.
# The SSH user receives private keys, so is trusted like the owner with these files: nothing here holds
# against a race by the owner of that home.
copy_id() { stat -c '%i:%Y:%s:%Z' -- "$1" 2>/dev/null; }
copy_is() {
    # copy_is <path> <id>: that path is now that very file: a regular file, not a link, with one name.
    local facts
    [[ -n $2 && -f $1 && ! -L $1 ]] || return 1
    facts=$(stat -c '%i:%Y:%s:%Z %h' -- "$1" 2>/dev/null) || return 1
    [[ $facts == "$2 1" ]]
}
copy_holds() {
    # copy_holds <path> <name> <serial>: a regular file with one name that holds this CA's certificate <serial>
    # for <name>. Only a revocation deletes by this.
    [[ -f $1 && ! -L $1 && $(stat -c %h -- "$1" 2>/dev/null) == 1 ]] || return 1
    [[ $(share_serial "$1" "$2" 2>/dev/null) == "$3" ]]
}
home_copy_read() {
    # home_copy_read <entry>: one record of a copy into HC_*.
    local key value
    HC_ENTRY=$1 HC_NAME='' HC_SERIAL='' HC_PATH='' HC_FILE='' HC_SHARE='' HC_USER='' HC_KEPT_AT=''
    [[ -f $1 && ! -L $1 ]] || return 1
    while IFS='=' read -r key value; do
        case $key in
            name) HC_NAME=$value ;; serial) HC_SERIAL=$value ;; path) HC_PATH=$value ;;
            file) HC_FILE=$value ;; share) HC_SHARE=$value ;; user) HC_USER=$value ;; kept) HC_KEPT_AT=$value ;;
        esac
    done <"$1" || return 1
    valid_existing_name "$HC_NAME" && [[ $HC_PATH == /* && $HC_FILE =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ && $HC_SHARE =~ ^[0-9a-f]{16}$ ]]
}
home_copy_entries() {
    local entry
    for entry in "$OUT_DIR"/.homecopy.*; do [[ -f $entry ]] && printf '%s\n' "$entry"; done
    return 0
}
home_copy_record() {
    # home_copy_record <name> <serial> <path> <share>: under the CA lock, once the copy is in place.
    local id temp
    id=$(copy_id "$3") || return 1
    temp=$(mktemp "$OUT_DIR/.homecopy-new.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    if ! printf 'name=%s\nserial=%s\npath=%s\nfile=%s\nshare=%s\nuser=%s\ncreated=%s\n' "$1" "$2" "$3" "$id" "$4" "$DOWNLOAD_SSH_USER" "$(date -u +%s)" >"$temp" \
        || ! chmod 600 "$temp" || ! mv -f -- "$temp" "$OUT_DIR/.homecopy.$(openssl rand -hex 8)"; then
        rm -f -- "$temp"; return 1
    fi
}
home_copy_drop() {
    # home_copy_drop <entry> <why> [revoked serial]: under the CA lock. The copy goes only when it is, now, the file
    # this tool made, or, with a revoked serial, one that holds that certificate; then its record goes too. Anything
    # else at that path stays, and so does the record, marked kept, so the copy is still known and named in
    # Diagnostics. A record whose path is empty goes.
    if ! home_copy_read "$1"; then rm -f -- "$1"; return 0; fi
    # For the tests only: what another program could do between the question and the deletion.
    if [[ -n ${DARBAN_TEST_HOME_COPY_HOOK:-} ]]; then bash -c "$DARBAN_TEST_HOME_COPY_HOOK" _ "$HC_PATH" >/dev/null 2>&1 || true; fi
    if copy_is "$HC_PATH" "$HC_FILE" || { [[ -n ${3:-} ]] && copy_holds "$HC_PATH" "$HC_NAME" "$3"; }; then
        rm -f -- "$HC_PATH" || return 1
        HC_DONE+="${HC_DONE:+$'\n'}$HC_PATH"
        audit "profile deleted from server: $HC_PATH, $2"
    elif [[ -e $HC_PATH || -L $HC_PATH ]]; then
        if [[ -z $HC_KEPT_AT ]]; then
            printf 'kept=%s\n' "$(date -u +%s)" >>"$1" || return 1
            HC_KEPT+="${HC_KEPT:+$'\n'}$HC_PATH"
            audit "copy kept, it changed since this tool made it: $HC_PATH, $2"
        fi
        return 0
    fi
    rm -f -- "$1"
}
home_copy_end_share() {
    # home_copy_end_share <share id> <why>: the recorded copies of that share, under the CA lock.
    local entry rc=0
    [[ -n $1 ]] || return 0
    while IFS= read -r entry; do
        home_copy_read "$entry" && [[ $HC_SHARE == "$1" && -z $HC_KEPT_AT ]] || continue
        home_copy_drop "$entry" "$2" || rc=1
    done < <(home_copy_entries)
    return "$rc"
}
home_copy_revoked() {
    # home_copy_revoked <name> <serial>: after a revocation, under the CA lock: every recorded copy of that
    # certificate, and <name>.ovpn in the home of the SSH user set now when it holds it. A kept copy is no longer
    # the file this tool made, so the certificate it holds now decides, as the repair would.
    local entry home rc=0
    while IFS= read -r entry; do
        home_copy_read "$entry" || continue
        if [[ -n $HC_KEPT_AT ]]; then
            [[ $HC_NAME == "$1" && $(share_serial "$HC_PATH" "$HC_NAME" 2>/dev/null) == "$2" ]] || continue
        else
            [[ $HC_SERIAL == "$2" ]] || continue
        fi
        home_copy_drop "$entry" "$1 revoked" "$2" || rc=1
    done < <(home_copy_entries)
    if home=$(ssh_user_home) && copy_holds "$home/$1.ovpn" "$1" "$2"; then
        if rm -f -- "$home/$1.ovpn"; then HC_DONE+="${HC_DONE:+$'\n'}$home/$1.ovpn"; audit "profile deleted from server: $home/$1.ovpn, $1 revoked"; else rc=1; fi
    fi
    return "$rc"
}
home_copy_of_share() {
    # home_copy_of_share <share id> [folder]: the recorded copy of that share, when it is still the file this tool
    # made; with [folder], only one there.
    local entry
    [[ -n $1 ]] || return 1
    while IFS= read -r entry; do
        home_copy_read "$entry" && [[ $HC_SHARE == "$1" ]] || continue
        [[ -z ${2:-} || ${HC_PATH%/*} == "$2" ]] || continue
        if copy_is "$HC_PATH" "$HC_FILE"; then printf '%s\n' "$HC_PATH"; return 0; fi
    done < <(home_copy_entries)
    return 1
}
home_copy_sweep() {
    # Under the CA lock: a record whose share has ended, because its file went, became a link or was made again,
    # ends its copy; one whose copy is gone goes. A copy recorded by a version before this one, in the record of
    # its share, is recorded here.
    local entry file name
    for file in "$OUT_DIR"/*.ovpn; do
        share_record_read "$file" && [[ -n $SR_HOME && -n $SR_HOME_FILE ]] || continue
        name=${file##*/}; name=${name%.ovpn}
        [[ -f $SR_HOME && ! -L $SR_HOME && $SR_HOME_FILE == "$(stat -c '%i:%Y:%s' -- "$SR_HOME" 2>/dev/null)" ]] || continue
        home_copy_of_share "$SR_ID" >/dev/null || home_copy_record "$name" "$SR_SERIAL" "$SR_HOME" "$SR_ID" || true
    done
    while IFS= read -r entry; do
        if ! home_copy_read "$entry"; then rm -f -- "$entry"; continue; fi
        if [[ ! -e $HC_PATH && ! -L $HC_PATH ]]; then rm -f -- "$entry"; continue; fi
        # A kept copy stays known until it is gone.
        [[ -z $HC_KEPT_AT ]] || continue
        if share_record_read "$OUT_DIR/$HC_NAME.ovpn" && [[ $SR_ID == "$HC_SHARE" ]]; then continue; fi
        home_copy_drop "$entry" 'its share ended' || true
    done < <(home_copy_entries)
    find "$OUT_DIR" -maxdepth 1 -name '.homecopy-new.*' -mmin +10 -delete 2>/dev/null || true
}
home_copy_health() {
    # The Diagnostics lines for copies this tool made and kept, since they changed after they were made.
    local entry
    while IFS= read -r entry; do
        home_copy_read "$entry" && [[ -n $HC_KEPT_AT ]] && [[ -e $HC_PATH || -L $HC_PATH ]] || continue
        check warn "$(safe_text "$HC_PATH"), a copy of $(safe_text "$HC_NAME") this tool made for $(safe_text "${HC_USER:-the SSH user}"), changed after it was made, so it was kept. Delete it if it is no longer needed; this tool then forgets it"
    done < <(home_copy_entries)
}
home_copy_report() {
    # What the last drops did, said to the person at the terminal.
    local path
    while IFS= read -r path; do [[ -z $path ]] || ok "Copy for $DOWNLOAD_SSH_USER deleted: $path"; done <<<"$HC_DONE"
    while IFS= read -r path; do [[ -z $path ]] || warn "$path changed since this tool made it, so it was kept. Diagnostics name it until it is deleted."; done <<<"$HC_KEPT"
    HC_DONE='' HC_KEPT=''
}
prepare_download_copy() {
    # prepare_download_copy <kept file>: under the CA lock. For another SSH user, its copy in that user's home, made
    # once for each share and user, never over a file already there. Sets DOWNLOAD_FILE to it.
    local file=$1 name entry home uid gid rc target
    DOWNLOAD_FILE=''
    [[ $DOWNLOAD_SSH_USER != root ]] || return 0
    name=${file##*/}; name=${name%.ovpn}
    entry=$(getent passwd "$DOWNLOAD_SSH_USER" 2>/dev/null) || entry=''
    IFS=: read -r _ _ uid gid _ home _ <<<"$entry"
    if [[ -z $home || ! -d $home || -L $home || ! $uid =~ ^[0-9]+$ || ! $gid =~ ^[0-9]+$ ]]; then
        warn "$DOWNLOAD_SSH_USER has no home directory of its own here, so it cannot read $file."
        return 0
    fi
    if ! share_record_read "$file"; then
        warn "$file has no record yet, so no copy was made for $DOWNLOAD_SSH_USER. Share it again (menu 5)."
        return 0
    fi
    home_copy_sweep
    HC_DONE='' HC_KEPT=''
    share_record_read "$file" || return 0
    # This share has its copy in this home already: the same file serves again.
    if target=$(home_copy_of_share "$SR_ID" "$home"); then DOWNLOAD_FILE=$target; return 0; fi
    target=$home/$name.ovpn
    rc=0; python3 -I -c "$HOME_COPY_PY" "$file" "$home" "${target##*/}" "$uid" "$gid" 2>/dev/null || rc=$?
    if (( rc == 4 )); then
        # A file of that name that is not this share's copy stays as it is.
        target=$home/$name-${SR_ID:0:8}.ovpn
        rc=0; python3 -I -c "$HOME_COPY_PY" "$file" "$home" "${target##*/}" "$uid" "$gid" 2>/dev/null || rc=$?
        if (( rc == 0 )); then warn "$home/$name.ovpn is not a copy this tool made for this share, so it was left as it is. The copy is $target."; fi
    fi
    if (( rc == 3 )); then warn "The home of $DOWNLOAD_SSH_USER, $home, is a link or not its own, so no copy was made."; return 0; fi
    if (( rc != 0 )); then warn "Could not make a copy for $DOWNLOAD_SSH_USER, which cannot read $file."; return 0; fi
    if ! home_copy_record "$name" "$SR_SERIAL" "$target" "$SR_ID"; then
        rm -f -- "$target"
        warn "Could not record the copy for $DOWNLOAD_SSH_USER, so it was not kept; $DOWNLOAD_SSH_USER cannot read $file."
        return 0
    fi
    DOWNLOAD_FILE=$target
}
share_by_download() {
    # The file stays on the server. A person at a terminal is asked which computer downloads it and sees only that
    # command; a script gets all of them.
    local name=$1 file only=all
    local -a kinds=(windows unix sftp)
    file=$OUT_DIR/$name.ovpn
    ca_lock || return 1
    prepare_download_copy "$file"
    ca_unlock
    if (( UI_TTY )) && [[ -n $DOWNLOAD_SSH_HOST ]]; then
        info "Kept on the server: $file."
        choose_one 'Which computer will download it?' 'Windows' 'macOS or Linux' 'An SFTP app (WinSCP, FileZilla, Termius)' || {
            info "Share it from menu 5 later, or delete it from menu 6."
            return 0
        }
        only=${kinds[CHOSEN - 1]}
    fi
    download_panel "$file" "Profile for \"$name\" rebuilt" "$only"
    info "Kept on the server: $file. $(kept_until "$name")"
    [[ -n $DOWNLOAD_SSH_HOST && $only != all ]] || return 0
    offer_copy 'the command' '' 'Copy the command' "$(download_command "$only" "$file")"
}

# ---------- shares: the copies of a profile this tool keeps ----------
# A file kept on the server, $OUT_DIR/<name>.ovpn, has a record beside it, <name>.share, written with the file: the
# share's own identity, when it was made by both clocks, when it expires, the certificate it holds, and where it
# points. The copy made for the SSH user has a record of its own. With it the tool never reads the file again, since a read is what "file read"
# shows. A record that no longer describes its file, because something else wrote the file, does not count.
file_id() { stat -c '%i:%Y:%s' -- "$1" 2>/dev/null; }
share_record_read() {
    # share_record_read <profile>: the record of a kept file into SR_*, when it describes that very file.
    local record=${1%.ovpn}.share key value
    SR_ID='' SR_SERIAL='' SR_CREATED='' SR_BOOT='' SR_CS='' SR_US='' SR_EXPIRES='' SR_REMOTE='' SR_FILE='' SR_HOME='' SR_HOME_FILE=''
    [[ -f $record && ! -L $record && -f $1 && ! -L $1 ]] || return 1
    while IFS='=' read -r key value; do
        case $key in
            share_id) SR_ID=$value ;; serial) SR_SERIAL=$value ;; created) SR_CREATED=$value ;; created_boot) SR_BOOT=$value ;;
            created_cs) SR_CS=$value ;; created_us) SR_US=$value ;; expires) SR_EXPIRES=$value ;; remote) SR_REMOTE=$value ;;
            file) SR_FILE=$value ;; home) SR_HOME=$value ;; home_file) SR_HOME_FILE=$value ;;
        esac
    done <"$record" || return 1
    [[ $SR_ID =~ ^[0-9a-f]{16}$ && $SR_CREATED =~ ^[0-9]{1,12}$ && $SR_EXPIRES =~ ^[0-9]{1,12}$ ]] || return 1
    [[ $SR_SERIAL =~ ^[0-9A-F]+$ ]] || SR_SERIAL=''
    [[ -n $SR_FILE && $SR_FILE == "$(file_id "$1")" ]]
}
share_record_write() {
    # share_record_write <name> <share id> <serial or ''> <remote line> [expires]: under the CA lock, once the file
    # is in place. Without [expires], the share lasts the hours of Settings from now.
    local name=$1 file=$OUT_DIR/$1.ovpn temp now expires boot cs us id
    now=$(date -u +%s)
    expires=${5:-$(( now + $(link_hours) * 3600 ))}
    id=$(file_id "$file") || return 1
    read -r boot </proc/sys/kernel/random/boot_id || boot=''
    cs=$(uptime_cs) || cs=''
    us=${EPOCHREALTIME//[!0-9]/}
    temp=$(mktemp "$OUT_DIR/.share.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    if ! {
        printf 'share_id=%s\nname=%s\nserial=%s\ncreated=%s\nexpires=%s\nremote=%s\nfile=%s\n' "$2" "$name" "$3" "$now" "$expires" "$4" "$id"
        if [[ $boot =~ ^[0-9a-f-]{36}$ && $cs =~ ^[0-9]+$ && $us =~ ^[0-9]{16}$ ]]; then
            printf 'created_boot=%s\ncreated_cs=%s\ncreated_us=%s\n' "$boot" "$cs" "$us"
        fi
    } >"$temp" || ! chmod 600 "$temp" || ! mv -f -- "$temp" "$OUT_DIR/$name.share"; then
        rm -f -- "$temp"
        return 1
    fi
}
share_record_set() {
    # share_record_set <profile> <key> <value> [<key> <value>]...: changes fields of a record that still describes
    # its file, under the CA lock.
    local file=$1 record=${1%.ovpn}.share temp keys=' ' i
    shift
    share_record_read "$file" || return 1
    for (( i = 1; i <= $#; i += 2 )); do keys+="${!i} "; done
    temp=$(mktemp "$OUT_DIR/.share.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    if ! awk -F= -v keys="$keys" 'index(keys, " " $1 " ") == 0' "$record" >"$temp"; then rm -f -- "$temp"; return 1; fi
    while (( $# >= 2 )); do printf '%s=%s\n' "$1" "$2" >>"$temp" || { rm -f -- "$temp"; return 1; }; shift 2; done
    chmod 600 "$temp" && mv -f -- "$temp" "$record" || { rm -f -- "$temp"; return 1; }
}
time_left() {
    # time_left <expires> <now>: "23 h 5 min", "40 min".
    local minutes=$(( ($1 - $2 + 59) / 60 )) left
    (( minutes > 0 )) || minutes=0
    left="$minutes min"
    if (( minutes >= 60 )); then left="$(( minutes / 60 )) h"; fi
    if (( minutes >= 60 && minutes % 60 )); then left+=" $(( minutes % 60 )) min"; fi
    printf '%s' "$left"
}
kept_until() {
    # kept_until <name>: one sentence on when the kept file of <name> goes.
    if share_record_read "$OUT_DIR/$1.ovpn"; then
        printf 'It is deleted in %s, or when %s connects.' "$(time_left "$SR_EXPIRES" "$(date -u +%s)")" "$1"
    else
        printf 'It is deleted in %s, or when %s connects.' "$(hours_label "$(link_hours)")" "$1"
    fi
}
kept_read_label() {
    # kept_read_label <name>: "file read" when the file the download command fetches was read after it was made,
    # "not read yet" when it was not, and nothing when that cannot be told: no record, no copy made for the SSH
    # user yet, or a file system mounted without access times. A read in the second the file was made is not
    # seen. Never a reason to delete.
    local target=$OUT_DIR/$1.ovpn times atime mtime options
    share_record_read "$target" || return 0
    if [[ $DOWNLOAD_SSH_USER != root ]]; then
        target=$(home_copy_of_share "$SR_ID" "$(ssh_user_home)") || return 0
    fi
    options=$(findmnt -n -o OPTIONS -T "$target" 2>/dev/null) || return 0
    [[ ,$options, != *,noatime,* ]] || return 0
    times=$(stat -c '%X %Y' -- "$target" 2>/dev/null) || return 0
    read -r atime mtime <<<"$times"
    [[ $atime =~ ^[0-9]+$ && $mtime =~ ^[0-9]+$ ]] || return 0
    if (( atime > mtime && atime > SR_CREATED )); then printf 'file read'; else printf 'not read yet'; fi
}
kept_file_drop() {
    # kept_file_drop <name> <why>: the kept file, its record and the copy made for the SSH user, under the CA lock.
    local name=$1 file=$OUT_DIR/$1.ovpn share=''
    if share_record_read "$file"; then share=$SR_ID; fi
    rm -f -- "$file" "$OUT_DIR/$name.share" || return 1
    audit "profile deleted from server: $file, $2"
    # Only the copy of this share: one of a share made before, or by another user, has ended already.
    home_copy_end_share "$share" "$2" || true
    HC_DONE='' HC_KEPT=''
}
expire_schedule() {
    # One timer, darban-expire.timer, for the earliest time a kept file is due, under the CA lock. It only starts
    # the same check as the five-minute timer, which reads every time from the records themselves, so a timer left
    # from a file that went early never deletes a newer one. Returns 1 when the timer could not be set.
    local earliest='' now
    [[ -e $UNIT_DIR/darban-expire.service ]] || return 0
    # One pass over every record. One left without its file only starts a check early, which removes it.
    if compgen -G "$OUT_DIR/*.share" >/dev/null; then
        earliest=$(awk -F= '$1=="expires" && $2 ~ /^[0-9]+$/ && length($2) <= 12 && (e == "" || $2 + 0 < e + 0) {e=$2} END {print e}' "$OUT_DIR"/*.share 2>/dev/null) || earliest=''
    fi
    systemctl stop darban-expire.timer >/dev/null 2>&1 || true
    systemctl reset-failed darban-expire.timer >/dev/null 2>&1 || true
    [[ -n $earliest ]] || return 0
    now=$(date -u +%s)
    if (( earliest <= now )); then earliest=$(( now + 1 )); fi
    systemd-run --quiet --unit=darban-expire --on-calendar="@$earliest" --timer-property=AccuracySec=1s >/dev/null 2>&1
}
# A share is a profile that can still reach someone: an open link, the copy kept on the server, or the copy made
# for the SSH user. The certificate inside it says which certificate it belongs to; a kept file's record says it
# too, so that file is not read again.
ssh_user_home() {
    local home
    [[ $DOWNLOAD_SSH_USER != root ]] || return 1
    home=$(getent passwd "$DOWNLOAD_SSH_USER" 2>/dev/null | cut -d: -f6) || return 1
    [[ -n $home && -d $home ]] || return 1
    printf '%s\n' "$home"
}
share_serial() {
    # share_serial <profile> <name>: the serial of the certificate in the profile, normalized, when it parses, this
    # CA issued it and it is for <name>. Its dates are not checked, so an expired certificate is still known.
    # Anything else prints nothing and returns 1: the share is "unknown".
    local cert facts serial cn
    [[ -f $1 && ! -L $1 ]] || return 1
    cert=$(awk '/^<\/cert>\r?$/ {f=0} f {print} /^<cert>\r?$/ {f=1}' "$1" 2>/dev/null) || return 1
    [[ -n $cert ]] || return 1
    facts=$(openssl x509 -noout -serial -subject -nameopt multiline <<<"$cert" 2>/dev/null) || return 1
    serial=$(awk -F= '$1=="serial" {print $2; exit}' <<<"$facts")
    serial=$(darban_norm_serial "$serial") || return 1
    # Exactly one common name, and it must be the name the share is filed under.
    cn=$(awk '$1=="commonName" {n++; sub(/^[^=]*= /, ""); v=$0} END {if (n == 1) print v}' <<<"$facts")
    [[ -n $cn && $cn == "$2" ]] || return 1
    openssl verify -no_check_time -CAfile "$DARBAN_PKI/ca.crt" <<<"$cert" >/dev/null 2>&1 || return 1
    printf '%s\n' "$serial"
}
share_rows() {
    # share_rows: one line per share, "<state>\t<kind>\t<name>\t<file>". kind: link (file is its .meta), server
    # or home. state: revoked or current from the CA index; unknown when the certificate cannot be identified;
    # orphan for a link record without its profile, which holds no secret. A copy this tool made for the SSH user
    # is a "copy", known from its record, in any home and for any user. Another file in the home of the SSH user
    # set now is a "home" share only when it holds this CA's profile for that name. The certificate of each share is
    # found first, and the CA index then answers for all of them in one call to darban-core: one read of the index,
    # however many shares there are. An index that cannot be read leaves every share unknown, so none is deleted.
    local meta name file home entry serial data kind place state i
    local -a sr_states=() sr_kinds=() sr_names=() sr_files=() sr_serials=() sr_known=() sr_found=()
    local -A recorded=()
    if [[ -d $LINK_DIR ]]; then
        for meta in "$LINK_DIR"/*.meta; do
            [[ -e $meta ]] || continue
            name=$(awk -F= '$1=="name" {print substr($0, 6); exit}' "$meta")
            if [[ ! -e ${meta%.meta}.ovpn ]]; then share_row_add orphan link "$name" "$meta" '' 0; continue; fi
            serial=$(share_serial "${meta%.meta}.ovpn" "$name") || serial=''
            share_row_add '' link "$name" "$meta" "$serial" 0
        done
    fi
    for file in "$OUT_DIR"/*.ovpn; do
        [[ -f $file ]] || continue
        name=${file##*/}; name=${name%.ovpn}
        # A kept file's record, when it describes this very file, names its certificate, so the file is not read. A
        # record that names none it could identify means unknown, as the file itself would.
        if share_record_read "$file"; then serial=$SR_SERIAL; else serial=$(share_serial "$file" "$name") || serial=''; fi
        share_row_add '' server "$name" "$file" "$serial" 0
    done
    while IFS= read -r entry; do
        home_copy_read "$entry" && [[ -e $HC_PATH ]] || continue
        recorded[$HC_PATH]=1
        if [[ -n $HC_KEPT_AT ]]; then
            # Changed since it was made: only a certificate of this CA for that name makes it a share.
            serial=$(share_serial "$HC_PATH" "$HC_NAME") || serial=''
            share_row_add '' copy "$HC_NAME" "$entry" "$serial" 1
        else
            share_row_add '' copy "$HC_NAME" "$entry" "$HC_SERIAL" 0
        fi
    done < <(home_copy_entries)
    if home=$(ssh_user_home); then
        for file in "$home"/*.ovpn; do
            [[ -f $file && -z ${recorded[$file]:-} ]] || continue
            name=${file##*/}; name=${name%.ovpn}
            serial=$(share_serial "$file" "$name") || serial=''
            share_row_add '' home "$name" "$file" "$serial" 1
        done
    fi
    (( ${#sr_kinds[@]} > 0 )) || return 0
    # "serial <place> <state>" for each serial the index has, by its place among those given, from 1.
    if data=$(core_index serials -- "${sr_serials[@]}"); then
        while IFS=$'\t' read -r kind place state; do
            if [[ $kind == serial && $place =~ ^[0-9]+$ ]]; then sr_found[place - 1]=$state; fi
        done <<<"$data"
    fi
    for i in "${!sr_kinds[@]}"; do
        state=${sr_states[i]}
        if [[ -z $state ]]; then
            case ${sr_found[i]:-} in
                '') state=unknown ;;
                R) state=revoked ;;
                *) state=current ;;
            esac
            if (( sr_known[i] )) && [[ $state == unknown ]]; then continue; fi
        fi
        printf '%s\t%s\t%s\t%s\n' "$state" "${sr_kinds[i]}" "${sr_names[i]}" "${sr_files[i]}"
    done
}
share_row_add() {
    # share_row_add <state, or empty to ask the index> <kind> <name> <file> <serial, or empty> <1: only when known>:
    # one share for share_rows, into its arrays.
    sr_states+=("$1"); sr_kinds+=("$2"); sr_names+=("$3"); sr_files+=("$4"); sr_serials+=("$5"); sr_known+=("$6")
}
share_names() {
    # share_names <state> [rows]: the names with a share in that state, one per line.
    local rows=${2-}
    if [[ -z ${2+set} ]]; then rows=$(share_rows 2>/dev/null) || rows=''; fi
    awk -F '\t' -v want="$1" '$1==want && $3!="" {print $3}' <<<"$rows" | sort -u
}
revoked_share_names() {
    # A finished revocation leaves no share behind, so one left behind marks an unfinished one.
    share_names revoked
}
drop_share() {
    # drop_share <kind> <file>: a link goes with all its files, under the lock the link service takes too.
    local serial
    if [[ $1 == link ]]; then
        links_locked rm -f -- "$2" "${2%.meta}.ovpn" "${2%.meta}.url" "${2%.meta}.tmp"
    elif [[ $1 == server ]]; then
        rm -f -- "$2" "${2%.ovpn}.share"
    elif [[ $1 == copy ]]; then
        home_copy_read "$2" || { rm -f -- "$2"; return 0; }
        serial=$HC_SERIAL
        if [[ -n $HC_KEPT_AT ]]; then serial=$(share_serial "$HC_PATH" "$HC_NAME") || serial=''; fi
        home_copy_drop "$2" 'its certificate is revoked' "$serial"
    else
        rm -f -- "$2"
    fi
}
finish_revoked_shares() {
    # Deletes every share whose certificate the CA lists as revoked, and every link record left without its
    # profile. A share whose certificate cannot be identified stays, and is named. Returns 1 when something could
    # not be deleted; everything else is still done.
    local rows state kind name file rc=0
    rows=$(share_rows) || return 1
    while IFS=$'\t' read -r state kind name file; do
        case $state in
            orphan) drop_share link "$file" || rc=1 ;;
            revoked)
                if ! drop_share "$kind" "$file"; then rc=1; continue; fi
                case $kind in
                    link) ok "Open link of $(safe_text "$name") ended."; audit "temporary link ended, its certificate is revoked: $name" ;;
                    server) ok "Server copy deleted: $file"; audit "profile deleted from server: $file" ;;
                    home) ok "Copy for $DOWNLOAD_SSH_USER deleted: $file"; audit "profile deleted from server: $file" ;;
                    copy) home_copy_report ;;
                esac ;;
        esac
    done <<<"$rows"
    name=$(share_names unknown "$rows" | join_lines)
    if [[ -n $name ]]; then
        warn "A link or file of $(safe_text "$name") holds a certificate this tool cannot identify, so it was kept. Check it, then delete it in Links and files (menu 6)."
    fi
    return "$rc"
}
prepare_link() {
    # Everything a link needs before the questions about it: python, the address, a port and a certificate.
    local host
    command -v python3 >/dev/null || { fail 'python3 is needed for temporary links. Install it: apt install python3'; return 1; }
    host=$(domain)
    [[ -n $host ]] && valid_endpoint "$host" || { warn "Set the server address first: Settings $S_CRUMB 1."; return 1; }
    choose_link_port || return 1
    ensure_link_cert "$host"
}
share_by_link() {
    local name=$1 host hours minutes label token key now expires url temp note='' boot cs us share='' public
    host=$(domain)
    if ! link_sees_connections; then
        warn "This server has no local management interface, so the link cannot see a connection: it works for $(hours_label "$(link_hours)")."
    fi
    # A link must not outlive its certificate. That can only happen with a trusted one that could not be renewed:
    # the link then gets the whole hours the certificate has left.
    hours=$(link_hours)
    while (( hours > 0 )) && ! link_cert_usable "$host" $(( hours * 3600 )); do hours=$(( hours - 1 )); done
    if (( hours == 0 )); then
        fail 'The link certificate ends in less than an hour, so no link was made. Open TCP 80 in your provider firewall, and share again for a new certificate.'
        return 1
    fi
    label=$(hours_label "$hours")
    minutes=$(( hours * 60 ))
    if (( hours < $(link_hours) )); then warn "The link certificate ends sooner than $(hours_label "$(link_hours)"), so this link works for at most $label."; fi
    ca_lock || return 1
    # The answers above took time: this client may have been revoked since.
    client_valid "$name" || { warn "\"$name\" no longer has a valid certificate, so no link was made."; return 1; }
    install -d -m 700 "$LINK_DIR" || return 1
    token=$(openssl rand -hex 32) || return 1
    key=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
    now=$(date -u +%s)
    expires=$(( now + minutes * 60 ))
    install -m 600 "$OUT_DIR/$name.ovpn" "$LINK_DIR/$key.ovpn" || return 1
    url=https://$host
    public=$(link_public_port)
    if [[ $public != 443 ]]; then url+=:$public; fi
    url+=/l/$token
    # The address itself, so menu 6 can show a link again. Only root reads it, and root can read the profile
    # anyway; the link service never reads it.
    printf '%s\npassword=%s\n' "$url" "$([[ -n $PROFILE_PASSWORD ]] && echo yes || echo no)" >"$LINK_DIR/$key.url" || return 1
    chmod 600 "$LINK_DIR/$key.url"
    # The .meta file appears last: until then, the link does not exist for the server. Besides the time in seconds,
    # which an older link service reads, it records the boot and the hundredth of a second since it, a clock NTP
    # cannot move: a connection event ends only a link made before it.
    temp=$LINK_DIR/$key.tmp
    read -r boot </proc/sys/kernel/random/boot_id || boot=''
    cs=$(uptime_cs) || cs=''
    us=${EPOCHREALTIME//[!0-9]/}
    printf 'name=%s\nexpires=%s\ncreated=%s\ndownloads=0\n' "$name" "$expires" "$now" >"$temp" || return 1
    if [[ $boot =~ ^[0-9a-f-]{36}$ && $cs =~ ^[0-9]+$ ]]; then
        printf 'created_boot=%s\ncreated_cs=%s\ncreated_us=%s\n' "$boot" "$cs" "$us" >>"$temp" || return 1
    fi
    # The identity the profile carries, when it carries one: a connection that names another share leaves this one.
    if share_record_read "$OUT_DIR/$name.ovpn"; then share=$SR_ID; fi
    if [[ -n $share ]]; then printf 'share_id=%s\n' "$share" >>"$temp" || return 1; fi
    mv -f -- "$temp" "$LINK_DIR/$key.meta" || return 1
    if ! start_link_service "$host"; then
        rm -f -- "$LINK_DIR/$key.meta" "$LINK_DIR/$key.ovpn" "$LINK_DIR/$key.url"
        fail "The link service did not start on TCP $(link_listen_port). Check: $(cmd journalctl -u darban-links.service -n 30 --no-pager)"
        return 1
    fi
    # The link holds its own copy, so nothing stays behind in the download folder, nor in the home of the SSH user.
    rm -f -- "$OUT_DIR/$name.ovpn" "$OUT_DIR/$name.share"
    home_copy_end_share "$share" 'it became a link' || true
    home_copy_report
    expire_schedule || true
    ca_unlock
    audit "temporary link created: $name, valid for $label"
    note=$(link_note)
    LINK_MORE_LABEL=$label LINK_MORE_NOTE=$note
    if link_sees_connections; then ok "Link for \"$name\": works $label, or until $name connects"; else ok "Link for \"$name\": works $label"; fi
    # The firewall is said once for each port: after that it is either open, or the first link already failed.
    if ! port_share_on && [[ $(cat "$LINK_PORT_TOLD" 2>/dev/null) != "$LINK_PORT" ]]; then
        warn "TCP $LINK_PORT must be open in your provider firewall."
        printf '%s\n' "$LINK_PORT" >"$LINK_PORT_TOLD" 2>/dev/null || true
    fi
    say
    present_link "$url" "$PROFILE_PASSWORD" "$note" more
}
link_more_info() {
    # What used to stand before the link: true for every link, so it waits until asked for. A script gets it at
    # once, since it has nobody to ask.
    say
    if link_sees_connections; then kv Valid "$LINK_MORE_LABEL, or until a connection with this profile is seen"; else kv Valid "$LINK_MORE_LABEL"; fi
    kv Later 'menu 6 shows it again or cancels it'
    kv Firewall "TCP $(link_public_port) must be open in your provider firewall"
    if [[ -n $LINK_MORE_NOTE ]]; then
        warn 'This server has no trusted certificate, so the browser shows a warning for this link. The note tells the person what to do.'
        info "Certificate fingerprint: $(openssl x509 -in "$LINK_CERT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    fi
    if [[ -n $PROFILE_PASSWORD ]]; then
        info 'In OpenVPN Connect, the person can turn on "Save private key password" when importing, so it is asked only once.'
    fi
    info "Until the link ends, anyone who has it can get this profile. If a connection you did not expect shows up, revoke the client and issue a new one."
    say
}
link_note() {
    # The note for the person, only when the browser will warn. English only: a terminal shows right-to-left
    # text backwards. The guides have the note in Persian.
    link_cert_is_trusted "$(domain)" && return 0
    printf '%s' 'Your browser will warn that this connection is not private, because this server has no trusted certificate. Only for this link, which came to you straight from me: choose Advanced, then Continue. Never do this for other sites.'
}
present_link() {
    # present_link <url> <password> <note> [more]: what to send first, then one question: copy it, show the QR
    # code, or, with "more", read what holds for every link.
    local url=$1 password=$2 note=$3 more=${4:-} qr='Show a QR code' pick
    local -a labels=() texts=()
    show_share_block "$url" "$password" "$note"
    if [[ -n $password ]]; then info 'The password is shown only now. To send it another way, for example by SMS or a call, copy without it.'; fi
    if (( ! UI_TTY )); then
        if [[ -n $more ]]; then link_more_info; fi
        return 0
    fi
    labels+=("$(copy_label "$note" "$password")"); texts+=("$(share_text "$url" "$password" "$note")")
    if [[ -n $password ]]; then
        labels+=('Copy without the password')
        texts+=("$(share_text "$url" '' "${note:+$note }The file is locked. Its password comes to you separately.")")
    fi
    while :; do
        local -a options=("${labels[@]}")
        if [[ -n $qr ]]; then options+=("$qr"); fi
        if [[ -n $more ]]; then options+=('More about this link'); fi
        options+=('Do not copy')
        choose_one 'Copy it to your clipboard?' "${options[@]}" || return 0
        pick=${options[CHOSEN - 1]}
        if (( CHOSEN <= ${#texts[@]} )); then copy_shown_text "${texts[CHOSEN - 1]}" 'the lines from "Link:" down'; return 0; fi
        case $pick in
            "$qr") say; show_qr "$url"; qr='' ;;
            'More about this link') link_more_info; more='' ;;
            *) return 0 ;;
        esac
    done
}
copy_shown_text() {
    # copy_shown_text <text> <what to select instead>
    copy_to_clipboard "$1" || { warn 'Could not copy.'; return 0; }
    ok 'Copied to your clipboard, if your terminal allows it.'
    info "If pasting does not give this text, your terminal does not allow it (PuTTY, for example). Select $2 with the mouse instead."
}
copy_label() {
    # copy_label <note> [password]: names what the first copy option holds.
    if [[ -n ${2:-} && -n $1 ]]; then printf 'Copy link, password and note'
    elif [[ -n ${2:-} ]]; then printf 'Copy link and password'
    elif [[ -n $1 ]]; then printf 'Copy link and note'
    else printf 'Copy the link'; fi
}
show_qr() {
    local marker=$CONFIG_DIR/.server-setup-started
    if ! command -v qrencode >/dev/null; then
        if confirm_choice 'The small qrencode package is needed to draw the QR code. Install it?' 'No, just show the link' 'Install qrencode' normal; then
            apt-get -o DPkg::Lock::Timeout=120 -qq update >/dev/null || true
            apt-get -o DPkg::Lock::Timeout=120 -y -q --no-install-recommends install qrencode >/dev/null || warn 'Could not install qrencode.'
            if command -v qrencode >/dev/null && [[ -e $marker ]]; then printf 'package qrencode\n' >>"$marker" || true; fi
        fi
    fi
    if command -v qrencode >/dev/null; then
        qrencode -t ANSIUTF8 "$1" || warn 'Could not draw the QR code; use the link above.'
        say
    fi
}
delete_server_copy() {
    # delete_server_copy <name>: the .ovpn file kept on the server, and the copy made for the SSH user.
    local name=$1 path home_copy='' share=''
    path=$OUT_DIR/$name.ovpn
    if share_record_read "$path"; then home_copy=$(home_copy_of_share "$SR_ID") || home_copy=''; fi
    info 'The certificate stays valid, and the profile can be shared again later.'
    info 'Copies already downloaded to devices are not affected.'
    if [[ -n $home_copy ]]; then info "The copy made for ${HC_USER:-$DOWNLOAD_SSH_USER} is deleted too: $home_copy"; fi
    confirm_choice "Delete $path?" 'No, keep it' 'Delete the file' danger || { cancelled; return 0; }
    ca_lock || return 1
    # Read again under the lock: the share may have changed while the question was open.
    if share_record_read "$path"; then share=$SR_ID; fi
    rm -f -- "$path" "$OUT_DIR/$name.share"
    audit "profile deleted from server: $path"
    ok "Deleted: $path"
    home_copy_end_share "$share" 'deleted in Links and files' || true
    home_copy_report
    expire_schedule || true
}

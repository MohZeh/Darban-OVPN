#!/usr/bin/env bash
# Backups of the CA, for bin/darban, which sources it after lib/darban/paths.sh.

# ---------- backup and restore of the CA ----------
# A backup is one tar of a closed list of files (lib/backup.py), encrypted with age for the owner's public key: this
# server can make one at any time and can never read one back. Beside it, a manifest says what it holds, readable
# without the key. Only the owner's computer opens it; "darban restore" then takes the opened tar.
valid_age_key() { [[ $1 =~ ^age1[0-9a-z]{58}$ ]]; }
backup_recipient() {
    local value
    value=$(awk -F= '$1=="BACKUP_RECIPIENT" {v=$2} END {print v}' "$BACKUP_CONF" 2>/dev/null) || value=''
    valid_age_key "$value" || return 1
    printf '%s\n' "$value"
}
backup_set_recipient() {
    local temp
    install -d -m 700 "$CONFIG_DIR" || return 1
    temp=$(mktemp "$CONFIG_DIR/.backup.XXXXXXXX") || return 1
    darban_tmp_register "$temp"
    printf 'BACKUP_RECIPIENT=%s\n' "$1" >"$temp" && chmod 600 "$temp" && mv -f -- "$temp" "$BACKUP_CONF"
}
ca_fingerprint_label() {
    # The SHA-256 fingerprint of a CA certificate, as openssl prints it. A restore asks for it.
    openssl x509 -in "${1:-$DARBAN_PKI/ca.crt}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//'
}
fingerprint_hex() {
    # fingerprint_hex <fingerprint in any case, with or without colons>: 64 lowercase hex digits, or 1.
    local value=${1//:/}
    value=${value,,}
    [[ $value =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$value"
}
backup_host() { local host; host=$(hostname -s 2>/dev/null) || host=''; host=${host//[!A-Za-z0-9.-]/}; printf '%s' "${host:-server}"; }
backup_latest_value() {
    # backup_latest_value <field>: one value from the manifest of the newest backup. That is the manifest beside the
    # archive "latest" names: a stop between the two renames below leaves latest.manifest.json one backup behind.
    local archive manifest
    archive=$(readlink "$PKI_BACKUP_DIR/latest.tar.age" 2>/dev/null) || return 1
    [[ $archive == darban-pki-*.tar.age ]] || return 1
    manifest=$PKI_BACKUP_DIR/${archive%.tar.age}.manifest.json
    # Only a backup that is there and whole: a manifest left beside an archive deleted by hand describes nothing, and
    # neither does one whose archive no longer has the bytes it recorded, after a fault of the disk or a change by
    # hand. That is not proof the archive opens, which needs the private key, only that it is the one made.
    [[ -f $PKI_BACKUP_DIR/$archive && -f $manifest ]] || return 1
    python3 -I -c 'import hashlib, json, sys
manifest = json.load(open(sys.argv[1]))
with open(sys.argv[2], "rb") as handle:
    if manifest.get("archive_sha256") != hashlib.sha256(handle.read()).hexdigest():
        sys.exit(1)
value = manifest.get(sys.argv[3], "")
print(value if isinstance(value, (str, int)) else "")' "$manifest" "$PKI_BACKUP_DIR/$archive" "$1" 2>/dev/null
}
backup_make() {
    # backup_make <auto|now> <reason> [passphrase]: one backup, under the CA lock the caller holds, so the index, the
    # serial, the CRL and the certificates are of one moment. An automatic one is skipped when nothing changed since
    # the newest. Sets BACKUP_MADE to the archive, empty when skipped; BACKUP_WHY when it fails.
    local mode=$1 reason=$2 secret=${3:-} recipient='' tmp facts content name stamp encryption=recipient link
    BACKUP_MADE='' BACKUP_WHY=''
    if [[ $secret != passphrase ]]; then recipient=$(backup_recipient) || { BACKUP_WHY='no backup key is set'; return 1; }; fi
    command -v age >/dev/null || { BACKUP_WHY='age is not installed'; return 1; }
    { install -d -o root -g root -m 700 "$PKI_BACKUP_DIR" 2>/dev/null || install -d -m 700 "$PKI_BACKUP_DIR"; } && chmod 700 "$PKI_BACKUP_DIR" || { BACKUP_WHY="$PKI_BACKUP_DIR cannot be made"; return 1; }
    tmp=$(mktemp -d "$PKI_BACKUP_DIR/.new.XXXXXXXX") || { BACKUP_WHY='no room for a new backup'; return 1; }
    if ! facts=$(python3 -I "$BACKUP_PY" pack --out "$tmp/archive.tar" --inner "$tmp/inner.json" --pki "$DARBAN_PKI" \
        --server "$DARBAN_SERVER_DIR" --config "$CONFIG_DIR" --ledger "$LEDGER_DIR" --host "$(backup_host)" --version "$DARBAN_VERSION" 2>&1); then
        rm -rf -- "$tmp"; BACKUP_WHY=${facts##*REFUSED: }; return 1
    fi
    content=$(sed -n 's/^content=//p' <<<"$facts")
    if [[ $mode == auto && -n $content && $content == "$(backup_latest_value content)" ]]; then rm -rf -- "$tmp"; return 0; fi
    if [[ $secret == passphrase ]]; then
        encryption=passphrase
        if ! age -p -o "$tmp/archive.tar.age" "$tmp/archive.tar" </dev/tty; then rm -rf -- "$tmp"; BACKUP_WHY='age did not encrypt it'; return 1; fi
    elif ! age -r "$recipient" -o "$tmp/archive.tar.age" "$tmp/archive.tar" </dev/null; then
        rm -rf -- "$tmp"; BACKUP_WHY='age did not encrypt it'; return 1
    fi
    rm -f -- "$tmp/archive.tar"
    sync -- "$tmp/archive.tar.age" 2>/dev/null || sync
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    name=darban-pki-$(backup_host)-$stamp
    while [[ -e $PKI_BACKUP_DIR/$name.tar.age ]]; do name=darban-pki-$(backup_host)-$stamp-$RANDOM; done
    if ! mv -- "$tmp/archive.tar.age" "$PKI_BACKUP_DIR/$name.tar.age"; then rm -rf -- "$tmp"; BACKUP_WHY='the archive could not be put in place'; return 1; fi
    sync -- "$PKI_BACKUP_DIR" 2>/dev/null || true
    if ! python3 -I "$BACKUP_PY" outer --inner "$tmp/inner.json" --archive "$PKI_BACKUP_DIR/$name.tar.age" --encryption "$encryption" >"$tmp/manifest.json" \
        || ! chmod 600 "$tmp/manifest.json" || ! mv -- "$tmp/manifest.json" "$PKI_BACKUP_DIR/$name.manifest.json"; then
        rm -rf -- "$tmp"; BACKUP_WHY='its manifest could not be written'; return 1
    fi
    rm -rf -- "$tmp"
    # The names "latest" change in one step each.
    for link in tar.age manifest.json; do
        ln -sfn -- "$name.$link" "$PKI_BACKUP_DIR/.latest.$link" && mv -T -f -- "$PKI_BACKUP_DIR/.latest.$link" "$PKI_BACKUP_DIR/latest.$link"
    done
    backup_prune
    BACKUP_MADE=$PKI_BACKUP_DIR/$name.tar.age
    audit "CA backup made: $name.tar.age ($reason)"
}
backup_prune() {
    # Only after a new backup worked: the newest PKI_BACKUPS_KEPT stay, and always the one "latest" names.
    local latest file
    local -a all=()
    latest=$(readlink "$PKI_BACKUP_DIR/latest.tar.age" 2>/dev/null) || latest=''
    mapfile -t all < <(find "$PKI_BACKUP_DIR" -maxdepth 1 -type f -name 'darban-pki-*.tar.age' -printf '%T@ %f\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    for file in "${all[@]:PKI_BACKUPS_KEPT}"; do
        [[ $file != "$latest" ]] || continue
        rm -f -- "$PKI_BACKUP_DIR/$file" "$PKI_BACKUP_DIR/${file%.tar.age}.manifest.json"
    done
}
backup_hooks_run() {
    # backup_hooks_run <archive> <manifest>: each program in backup-hooks/ gets the two paths and nothing else: no
    # secret, no environment, BACKUP_HOOK_SECONDS at most. Only root's own files with mode 700, in root's folder with mode
    # 700. A hook that fails never fails the backup; Diagnostics name it.
    local hook failed=''
    # While a restore is unfinished it owns the CA; nothing is sent anywhere meanwhile.
    [[ ! -e $DARBAN_RESTORE_JOURNAL ]] || return 0
    [[ -d $BACKUP_HOOKS && ! -L $BACKUP_HOOKS && -O $BACKUP_HOOKS && $(stat -c %a "$BACKUP_HOOKS" 2>/dev/null) == 700 ]] || return 0
    for hook in "$BACKUP_HOOKS"/*; do
        # Checked before each one: a hook already running finishes, but none starts once a restore has begun.
        [[ ! -e $DARBAN_RESTORE_JOURNAL ]] || break
        [[ -f $hook && ! -L $hook && -O $hook && $(stat -c %a "$hook" 2>/dev/null) == 700 ]] || continue
        # A hook that ignores the end of its time is killed ten seconds later.
        if timeout -k 10 "$BACKUP_HOOK_SECONDS" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$hook" "$1" "$2" </dev/null >/dev/null 2>&1; then
            audit "backup hook ran: ${hook##*/}"
        else
            failed+="${failed:+, }${hook##*/}"
        fi
    done
    if [[ -n $failed ]]; then
        printf '%s %s\n' "$(date -u +%s)" "$failed" >"$PKI_BACKUP_DIR/.hooks-failed" 2>/dev/null || true
        audit "backup hook failed: $failed"
    else
        rm -f -- "$PKI_BACKUP_DIR/.hooks-failed"
    fi
}
backup_hooks_start() {
    # The hooks of the backup just made, apart from this process and without the CA lock it may hold.
    [[ -n $BACKUP_MADE && -d $BACKUP_HOOKS ]] || return 0
    ( exec 9>&-; backup_hooks_run "$BACKUP_MADE" "${BACKUP_MADE%.tar.age}.manifest.json" ) </dev/null >/dev/null 2>&1 &
}
backup_auto() {
    # backup_auto <reason>: after a change to the CA, under its lock, and daily. Only with a key set, and only when
    # something changed. Never fails what came before it.
    backup_recipient >/dev/null && command -v age >/dev/null || return 0
    if backup_make auto "$1"; then
        rm -f -- "$PKI_BACKUP_DIR/.failed"
        return 0
    fi
    warn "The automatic backup of the CA failed: $BACKUP_WHY. See: sudo darban status"
    printf '%s %s\n' "$(date -u +%s)" "$BACKUP_WHY" >"$PKI_BACKUP_DIR/.failed" 2>/dev/null || true
    audit "CA backup failed: $BACKUP_WHY"
    return 0
}
backup_command() {
    # darban backup-auto <reason> (darban-backup.service, after the daily CRL check): the hooks run here, in the
    # foreground, since systemd ends what a finished job leaves running.
    darban_lock 60 || return 1
    CA_LOCKED=1
    backup_auto "$1"
    ca_unlock
    if [[ -n $BACKUP_MADE ]]; then backup_hooks_run "$BACKUP_MADE" "${BACKUP_MADE%.tar.age}.manifest.json"; fi
}
backup_ask_key() {
    info 'On your own computer, make a key once: age-keygen -o darban-backup.key. It prints a public key starting with age1. Keep that file safe: only it opens the backups.'
    prompt_valid 'Your age public key, starting with age1 (Enter = cancel): ' valid_age_key \
        'Paste the public key age-keygen printed: age1 and 58 more letters and digits.' || return 1
    backup_set_recipient "$REPLY" || { fail 'Could not save the key.'; return 1; }
    audit "backup key set: ${REPLY:0:12}"
    ok 'Saved. Backups are also made after each change to the CA, and daily when something changed.'
}
backup_now() {
    # Maintenance 4.
    local recipient secret='' file manifest home name
    info 'A backup holds the CA and its private key, every client certificate, the blocklist and the server settings, encrypted with age.'
    if ! command -v age >/dev/null; then
        confirm_choice 'The small age package encrypts the backup. Install it?' 'No, not now' 'Install age' normal || { cancelled; return 0; }
        apt-get -o DPkg::Lock::Timeout=120 -qq update >/dev/null || true
        apt-get -o DPkg::Lock::Timeout=120 -y -q --no-install-recommends install age >/dev/null || true
        command -v age >/dev/null || { fail 'Could not install age. Install it yourself: sudo apt install age'; return 1; }
        if [[ -e $CONFIG_DIR/.server-setup-started ]]; then printf 'package age\n' >>"$CONFIG_DIR/.server-setup-started" || true; fi
    fi
    if recipient=$(backup_recipient); then
        kv Key "${recipient:0:12}${S_ELL}${recipient: -6}"
        choose_one 'Back up now?' 'Back up with this key' 'Use another key' || { cancelled; return 0; }
        if (( CHOSEN == 2 )); then backup_ask_key || { cancelled; return 0; }; fi
    else
        CHOSEN=1
        if (( UI_TTY )); then
            choose_one 'How is the backup locked?' 'With your age public key; automatic backups too' 'With a passphrase, for this backup only' || { cancelled; return 0; }
        fi
        if (( CHOSEN == 1 )); then backup_ask_key || { cancelled; return 0; }; else secret=passphrase; fi
    fi
    ca_lock || return 1
    if ! backup_make now 'Backup now' "$secret"; then ca_unlock; fail "No backup was made: $BACKUP_WHY."; return 1; fi
    ca_unlock
    backup_hooks_start
    file=$BACKUP_MADE
    manifest=${file%.tar.age}.manifest.json
    ok "Backup made: $file"
    kv Manifest "$manifest"
    kv 'CA fingerprint' "$(ca_fingerprint_label)"
    info 'Write the fingerprint down: a restore asks for it, or for a profile from one of your devices.'
    info 'This copy is on this server. To recover from a lost server you need a copy elsewhere and your private key.'
    # Encrypted, so another SSH user may get a copy it can read.
    if [[ $DOWNLOAD_SSH_USER != root ]] && home=$(ssh_user_home); then
        if install -o "$DOWNLOAD_SSH_USER" -m 600 "$file" "$home/${file##*/}"; then file=$home/${file##*/}; fi
    fi
    if [[ -n $DOWNLOAD_SSH_HOST ]]; then
        say
        say '  Copy it to your computer:'
        printf '%s%s%s\n' "$C_CMD" "scp -P $DOWNLOAD_SSH_PORT $DOWNLOAD_SSH_USER@$DOWNLOAD_SSH_HOST:$file ./" "$C_RESET" || true
    fi
    name=${file##*/}
    say
    info "To restore: on your computer, age -d -i darban-backup.key $name > darban-pki.tar; then on the server, sudo darban restore darban-pki.tar --ca-fingerprint <the fingerprint above>."
}
backup_health() {
    # The Diagnostics group "Backup of the CA".
    local value created when extras
    if [[ -f $DARBAN_RESTORE_JOURNAL ]] && restore_committed; then
        check warn "A restore is done, and OpenVPN runs with the restored CA, but its cleanup is unfinished $S_ARROW sudo darban restore --resume"
    elif [[ -f $DARBAN_RESTORE_JOURNAL && $(journal_value state) == undoing ]]; then
        check bad "A rollback of a restore is unfinished $S_ARROW sudo darban restore --rollback"
    elif [[ -f $DARBAN_RESTORE_JOURNAL && $(journal_value state) == starting ]]; then
        check bad "A restore is unfinished: OpenVPN may be running with the restored files, and is not enabled at boot $S_ARROW sudo darban restore --resume (or --rollback)"
    elif [[ -f $DARBAN_RESTORE_JOURNAL ]]; then
        check bad "A restore is unfinished, so OpenVPN stays off $S_ARROW sudo darban restore --resume (or --rollback)"
    fi
    if [[ -f $RESTORE_WARN ]]; then
        read -r when <"$RESTORE_WARN" || when='?'
        check warn "The CA was restored from a backup of $(safe_text "$when"): revocations and certificates issued after it cannot be known. Revoke, and issue again, any client you are not sure of $S_ARROW sudo darban restore --acknowledge"
    fi
    pre_restore_health
    if extras=$(restore_extras_present | head -n 20 | tr '
' ' ') && [[ -n $extras ]]; then
        check warn "Records in $LEDGER_DIR are not in the backup that was restored, and were left: $(safe_text "$extras") $S_ARROW delete them if they are not needed"
    fi
    if [[ -s $DARBAN_PKI/ca.crt ]]; then check info "CA fingerprint $(ca_fingerprint_label); a restore asks for it"; fi
    if ! backup_recipient >/dev/null; then
        check info "No backup key is set, so the CA is not backed up by itself $S_ARROW Maintenance $S_CRUMB 4"
    elif ! command -v age >/dev/null; then
        check warn "A backup key is set, but age is not installed, so no backup is made $S_ARROW sudo apt install age"
    fi
    if created=$(backup_latest_value created) && [[ -n $created ]]; then
        check ok "Newest backup of the CA: $created, in $PKI_BACKUP_DIR"
        check info 'This copy is on this server. To recover from a lost server you need a copy elsewhere and your private key.'
    elif [[ -L $PKI_BACKUP_DIR/latest.tar.age ]]; then
        # "latest" names a backup that is not there, or not whole: the next automatic one makes a new one.
        check warn "The newest backup of the CA is missing or damaged in $PKI_BACKUP_DIR $S_ARROW Maintenance $S_CRUMB 4"
    elif backup_recipient >/dev/null; then
        check warn "No backup of the CA has been made yet $S_ARROW Maintenance $S_CRUMB 4"
    fi
    # C.16.3: the daily backup is started by the daily CRL check, and only when that check succeeds.
    if backup_recipient >/dev/null; then check info 'The daily backup runs after the daily blocklist (CRL) check, and only when that check succeeds'; fi
    if [[ -f $PKI_BACKUP_DIR/.failed ]]; then
        read -r _ value <"$PKI_BACKUP_DIR/.failed" || value=''
        check warn "The last automatic backup failed: $(safe_text "${value:-unknown}") $S_ARROW Maintenance $S_CRUMB 4"
    fi
    if [[ -f $PKI_BACKUP_DIR/.hooks-failed ]]; then
        read -r _ value <"$PKI_BACKUP_DIR/.hooks-failed" || value=''
        check warn "A backup hook failed: $(safe_text "${value:-unknown}") $S_ARROW sudo journalctl -t darban"
    fi
}

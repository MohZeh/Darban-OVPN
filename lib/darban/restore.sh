#!/usr/bin/env bash
# Restores of the CA, for bin/darban, which sources it after lib/darban/backup.sh.

# A restore takes the opened tar of a backup. Nothing changes until every check has passed, and the checks that
# decide are made again under the CA lock. Then the CA folder and the server folder are each swapped by two renames,
# with a journal, while OpenVPN is proven off now and at boot. Its states only move forward: staged, swapping,
# swapped, starting, committed, cleanup (C.16.9). Before committed it can be undone; from committed on it is done,
# and what is left is a cleanup, each step of it once. Any later run of this tool, or of the installer, finishes
# a restore that stopped half way.
journal_value() { awk -F= -v k="$1" '$1==k {v=substr($0, length(k) + 2)} END {print v}' "$DARBAN_RESTORE_JOURNAL" 2>/dev/null; }
journal_write() {
    # journal_write <key=value>...: the journal with these values set, written and synced with its folder.
    local temp line pair
    install -d -m 700 "${DARBAN_RESTORE_JOURNAL%/*}" || return 1
    temp=$(mktemp "${DARBAN_RESTORE_JOURNAL%/*}/.journal.XXXXXXXX") || return 1
    {
        if [[ -f $DARBAN_RESTORE_JOURNAL ]]; then
            while IFS= read -r line; do
                for pair; do if [[ ${pair%%=*} == "${line%%=*}" ]]; then continue 2; fi; done
                printf '%s\n' "$line"
            done <"$DARBAN_RESTORE_JOURNAL"
        fi
        printf '%s\n' "$@"
    } >"$temp" || { rm -f -- "$temp"; return 1; }
    sync -- "$temp" 2>/dev/null || sync
    mv -f -- "$temp" "$DARBAN_RESTORE_JOURNAL" || { rm -f -- "$temp"; return 1; }
    sync -- "${DARBAN_RESTORE_JOURNAL%/*}" 2>/dev/null || sync
}
journal_stage_ok() {
    # The stage of a restore is the folder mktemp made beside the journal, and a rollback or cleanup deletes it. A
    # journal naming any other path is not one this tool wrote, so nothing in it is acted on.
    local stage dir=${DARBAN_RESTORE_JOURNAL%/*}/.restore-stage.
    stage=$(journal_value stage)
    [[ -z $stage ]] || { [[ $stage == "$dir"* ]] && [[ ${stage#"$dir"} =~ ^[A-Za-z0-9]{8}$ ]]; }
}
journal_state_rank() { case $1 in staged) echo 1 ;; swapping) echo 2 ;; swapped) echo 3 ;; starting) echo 4 ;; committed) echo 5 ;; cleanup) echo 6 ;; *) echo 0 ;; esac; }
restore_committed() { (( $(journal_state_rank "$(journal_value state)") >= 5 )); }
restore_failpoint() {
    # For the tests only: DARBAN_TEST_RESTORE_FAIL=<step> makes that step fail, as a full disk would.
    if [[ ${DARBAN_TEST_RESTORE_FAIL:-} == "$1" ]]; then RESTORE_WHY="step $1 failed, as the test asked"; return 1; fi
}
restore_point() {
    # For the tests only: DARBAN_TEST_RESTORE_STOP=after:<step> stops right after that step, as a crash or a power
    # cut would; DARBAN_TEST_RESTORE_WAIT=<step> waits there, holding what it holds, until the test deletes the file
    # DARBAN_TEST_RESTORE_WAIT_FILE.
    local i
    if [[ ${DARBAN_TEST_RESTORE_STOP:-} == "after:$1" ]]; then printf 'Stopped after %s, as the test asked.\n' "$1" >&2; exit 99; fi
    if [[ ${DARBAN_TEST_RESTORE_WAIT:-} == "$1" && -n ${DARBAN_TEST_RESTORE_WAIT_FILE:-} ]]; then
        : >"$DARBAN_TEST_RESTORE_WAIT_FILE"
        for (( i = 0; i < 600; i++ )); do [[ -e $DARBAN_TEST_RESTORE_WAIT_FILE ]] || return 0; sleep 0.1; done
    fi
}
restore_tree_live() { case $1 in pki) printf '%s' "$DARBAN_PKI" ;; server) printf '%s' "$DARBAN_SERVER_DIR" ;; esac; }
restore_rename() {
    # restore_rename <from> <to>: one rename of a restore, made durable before the next.
    mv -T -- "$1" "$2" || return 1
    sync -- "${2%/*}" 2>/dev/null || sync
    RESTORE_RENAMES=$(( RESTORE_RENAMES + 1 ))
    # For the tests only: stop here as a crash or a power cut would.
    if [[ ${DARBAN_TEST_RESTORE_STOP:-} == "$RESTORE_RENAMES" ]]; then printf 'Stopped after rename %s, as the test asked.\n' "$RESTORE_RENAMES" >&2; exit 99; fi
}
restore_swap_tree() {
    # restore_swap_tree <pki|server> <id>: what the folder, its staged copy and its previous copy show decides the
    # step, so this works the same the first time and after a stop at any point.
    local live stage pre state
    live=$(restore_tree_live "$1"); stage=$live.restore-$2; pre=$live.pre-restore
    if [[ -e $live/.restore-$2 ]]; then state=new; elif [[ -e $live ]]; then state=old; else state=none; fi
    state+=:$([[ -e $stage ]] && echo yes || echo no):$([[ -e $pre ]] && echo yes || echo no)
    case $state in
        old:yes:no) restore_rename "$live" "$pre" && restore_rename "$stage" "$live" ;;
        none:yes:no|none:yes:yes) restore_rename "$stage" "$live" ;;
        new:no:yes|new:no:no) return 0 ;;
        *) RESTORE_WHY="$live is in a state a restore cannot go on from (folder $state, staged and previous copy). Look at $live, $stage and $pre, then: sudo darban restore --rollback"; return 1 ;;
    esac
}
restore_openvpn_off() {
    # OpenVPN off now and at the next boot, proven and not only asked for: no rename is made without it.
    systemctl disable --now "$DARBAN_UNIT" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$DARBAN_UNIT" 2>/dev/null; then RESTORE_WHY='OpenVPN did not stop'; return 1; fi
    if [[ $(systemctl is-enabled "$DARBAN_UNIT" 2>/dev/null) == enabled ]]; then RESTORE_WHY='OpenVPN would start again at boot: it is still enabled'; return 1; fi
}
restore_nat() {
    # The NAT file, written again from server.conf as the installer does, and loaded. Returns 1, and says so, when
    # the rules are not in place.
    local net iface file=$CONFIG_DIR/nat.nft
    [[ -f $file || -e $UNIT_DIR/darban-nat.service ]] || return 0
    net=$(darban_conf_net)
    iface=$(darban_nat_iface "$file" 2>/dev/null) || iface=''
    if [[ -z $iface ]] || ! ip link show dev "$iface" >/dev/null 2>&1; then iface=$(darban_default_iface); fi
    if ! valid_ipv4 "${net:-}" || [[ ! $iface =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        warn 'NAT was not written again: server.conf has no single /24 network, or no outgoing interface was found.'; return 1
    fi
    if ! { darban_nat_rules "$net" "$iface" >"$file.new" && chmod 600 "$file.new" && nft -c -f "$file.new" 2>/dev/null && mv -f -- "$file.new" "$file"; }; then
        rm -f -- "$file.new"; warn 'NAT could not be written again; see: sudo darban status'; return 1
    fi
    nft -f "$file" 2>/dev/null || { warn 'The NAT rules did not load; see: sudo darban status'; return 1; }
}
restore_index_state() {
    # restore_index_state <normalized serial> <rows of darban_index_rows>: its state there, or nothing.
    awk -F '\t' -v s="$1" '{v=toupper($3); gsub(/:/, "", v); sub(/^0+/, "", v); if (v == "") v = "0"; if (v == s) {print $1; exit}}' <<<"$2"
}
restore_index_unique() {
    # True when no serial appears twice in these rows: an index that says two things of one certificate is not read.
    awk -F '\t' '{v=toupper($3); gsub(/:/, "", v); sub(/^0+/, "", v); if (seen[v]++) bad=1} END {exit bad}' <<<"$1"
}
restore_serial_name() {
    # restore_serial_name <normalized serial> <index>: the client name of that serial in a CA index.
    awk -F '\t' -v s="$1" '{v=toupper($4); gsub(/:/, "", v); sub(/^0+/, "", v); if (v == "") v = "0"; if (v == s) {cn=$6; sub(/^.*\/CN=/, "", cn); sub(/\/.*/, "", cn); print cn; exit}}' "$2" 2>/dev/null
}
restore_note_undone() {
    # restore_note_undone <normalized serial> <backup files>: one difference the backup does not know, named once.
    local name
    [[ " $RESTORE_UNDONE_SERIALS " != *" $1 "* ]] || return 0
    RESTORE_UNDONE_SERIALS+=" $1"
    name=$(restore_serial_name "$1" "$2/pki/index.txt")
    [[ -n $name ]] || name=$(restore_serial_name "$1" "$DARBAN_PKI/index.txt")
    RESTORE_UNDONE+="${RESTORE_UNDONE:+, }${name:-unknown name} (serial $1)"
}
restore_history() {
    # restore_history <checked files>: what this CA issued and revoked, against what the backup knows (C.16.1).
    # Sets RESTORE_SAME_CA (yes|no), RESTORE_HISTORY (known|unknown) and RESTORE_UNDONE, the differences the backup
    # does not know. Returns 1 when the backup's own index cannot be read.
    local files=$1 want ca live_rows backup_rows state bstate serial crl_ok=0
    RESTORE_SAME_CA=no RESTORE_HISTORY=unknown RESTORE_UNDONE='' RESTORE_UNDONE_SERIALS='' RESTORE_REVOKED=''
    want=$(ca_fingerprint_label "$files/pki/ca.crt")
    [[ -n $want ]] || return 1
    # The same CA, from what this server has: its CA, the CA its server uses, or a CRL that CA signed.
    for ca in "$DARBAN_PKI/ca.crt" "$DARBAN_SERVER_DIR/ca.crt"; do
        if [[ -s $ca && $(ca_fingerprint_label "$ca") == "$want" ]]; then RESTORE_SAME_CA=yes; fi
    done
    if ( DARBAN_PKI=$files/pki; darban_crl_signature_ok "$DARBAN_CRL" ); then RESTORE_SAME_CA=yes crl_ok=1; fi
    [[ $RESTORE_SAME_CA == yes ]] || return 0
    backup_rows=$( DARBAN_PKI=$files/pki; darban_index_rows 2>/dev/null ) || return 1
    # The live index of this CA, read whole: every certificate it issued, and each revocation.
    if [[ -s $DARBAN_PKI/ca.crt && $(ca_fingerprint_label "$DARBAN_PKI/ca.crt") == "$want" ]] \
        && live_rows=$(darban_index_rows 2>/dev/null) && [[ -n $live_rows ]] && restore_index_unique "$live_rows"; then
        RESTORE_HISTORY=known
        while IFS=$'\t' read -r state _ serial; do
            serial=$(darban_norm_serial "$serial") || continue
            bstate=$(restore_index_state "$serial" "$backup_rows")
            # Issued after the backup, in any state; or revoked after it. V to E is only time passing.
            if [[ -z $bstate ]] || { [[ $state == R && $bstate != R ]]; }; then
                restore_note_undone "$serial" "$files"
            elif [[ $bstate == R && $state != R ]]; then
                RESTORE_REVOKED+="${RESTORE_REVOKED:+, }$(restore_serial_name "$serial" "$files/pki/index.txt") (serial $serial)"
            fi
        done <<<"$live_rows"
    fi
    # The live CRL of this CA holds revocations even when the index is gone.
    if (( crl_ok )); then
        while IFS= read -r serial; do
            serial=$(darban_norm_serial "$serial") || continue
            [[ $(restore_index_state "$serial" "$backup_rows") == R ]] || restore_note_undone "$serial" "$files"
        done < <(darban_crl_serials "$DARBAN_CRL" 2>/dev/null)
    fi
}
restore_stage_trees() {
    # restore_stage_trees <checked files> <id> <rebuilt server.conf>: the new CA folder and server folder, beside the
    # ones they replace, so each swap is a rename on one file system. Built, never copied, where the contract says so:
    # the server folder gets the CA and the CRL of the CA folder, and server.conf from the template. Under the CA lock.
    local files=$1 id=$2 spki=$DARBAN_PKI.restore-$2 ssrv=$DARBAN_SERVER_DIR.restore-$2 dir cnf log dropped
    rm -rf -- "$spki" "$ssrv"
    install -d -m 700 "$spki" || return 1
    cp -a -- "$files/pki/." "$spki/" || return 1
    for dir in issued private reqs certs_by_serial revoked revoked/certs_by_serial revoked/private_by_serial revoked/reqs_by_serial renewed renewed/certs_by_serial renewed/private_by_serial renewed/reqs_by_serial; do
        install -d -m 700 "$spki/$dir" || return 1
    done
    find "$spki" -type f -exec chmod 600 {} + || return 1
    # Easy-RSA's own settings come from this server's Easy-RSA, not from the archive.
    cnf=${DARBAN_EASYRSA%/*}/openssl-easyrsa.cnf
    if [[ ! -e $spki/openssl-easyrsa.cnf && -f $cnf ]]; then install -m 600 "$cnf" "$spki/openssl-easyrsa.cnf" || return 1; fi
    if (( RESTORE_NEW_CRL )); then
        log=$(env EASYRSA_PKI="$spki" EASYRSA_BATCH=1 "$DARBAN_EASYRSA" gen-crl </dev/null 2>&1) || { RESTORE_WHY="a new CRL could not be made with the restored CA: ${log##*$'\n'}"; return 1; }
    fi
    install -d -m 755 "$ssrv" || return 1
    install -m 644 "$spki/ca.crt" "$ssrv/ca.crt" && install -m 644 "$files/server/server.crt" "$ssrv/server.crt" \
        && install -m 600 "$files/server/server.key" "$ssrv/server.key" && install -m 600 "$files/server/tls-crypt.key" "$ssrv/tls-crypt.key" \
        && install -m 644 "$spki/crl.pem" "$ssrv/crl.pem" && install -m 644 "$3" "$ssrv/server.conf" || return 1
    # C.16.6, in place of a publication: the CRL checked as the restored server will use it, and never smaller than
    # the CRL this CA has published here.
    ( DARBAN_PKI=$spki DARBAN_SERVER_DIR=$ssrv DARBAN_SERVER_CONF=$ssrv/server.conf; darban_verify_crl "$ssrv/crl.pem" ) >/dev/null 2>&1 \
        || { RESTORE_WHY='the CRL does not cover the revocations of the backup, and no new one could be made'; return 1; }
    dropped=$( DARBAN_PKI=$spki; darban_crl_dropped_serials "$ssrv/crl.pem" 2>/dev/null ) || { RESTORE_WHY='the CRL of the backup could not be compared with the one published here'; return 1; }
    [[ -z $dropped ]] || { RESTORE_WHY="the CRL of the backup leaves out serial(s) this server's CRL revokes: ${dropped//$'\n'/ }"; return 1; }
    : >"$spki/.restore-$id" && : >"$ssrv/.restore-$id" || return 1
    sync 2>/dev/null || true
}
restore_commit() {
    # From both swaps to OpenVPN running with them, under the CA lock. Each step can run again; none of them runs once
    # the restore is committed. What it changes besides the two folders is in the journal, so a rollback undoes it.
    local stage file name added
    stage=$(journal_value stage)
    # Forward only: a resume from "starting" does not write an earlier state.
    if (( $(journal_state_rank "$(journal_value state)") < 3 )); then journal_write state=swapped || return 1; fi
    restore_point swapped
    for file in config domain; do
        [[ -f $stage/files/darban/$file ]] || continue
        if [[ -z $(journal_value "saved_$file") ]]; then
            if [[ -e $CONFIG_DIR/$file ]]; then
                cp -a -- "$CONFIG_DIR/$file" "$CONFIG_DIR/$file.pre-restore" && journal_write "saved_$file=copy" || return 1
            else
                journal_write "saved_$file=absent" || return 1
            fi
        fi
        install -m 600 "$stage/files/darban/$file" "$CONFIG_DIR/.$file.restore" && mv -f -- "$CONFIG_DIR/.$file.restore" "$CONFIG_DIR/$file" || return 1
    done
    # When each client was seen: a record this server has stays; one only the backup has comes back (C.16.8).
    for file in "$stage"/files/clients/*; do
        [[ -f $file ]] || continue
        name=${file##*/}
        valid_existing_name "$name" || continue
        added=$(journal_value added_ledger)
        # One this restore added is its own: written again on every try, since a stop may have left it half written.
        if [[ " $added " != *" $name "* ]]; then
            [[ ! -e $LEDGER_DIR/$name ]] || continue
            journal_write "added_ledger=${added:+$added }$name" || return 1
            restore_point ledger-noted
        fi
        install -D -m 600 "$file" "$LEDGER_DIR/$name" 2>/dev/null && sync -- "$LEDGER_DIR/$name" 2>/dev/null \
            || { RESTORE_WHY="the record of when $name was seen could not be put back in $LEDGER_DIR"; return 1; }
    done
    dns_restore_check || true
    if ! restore_nat; then journal_write nat=failed || return 1; fi
    # Connection events, when this server can have them: the lines go into the new server.conf while OpenVPN is off.
    if ! events_lines_on && ! events_blocker >/dev/null; then
        printf 'script-security 2\nclient-connect %s\nclient-disconnect %s\n' "$EVENT_SCRIPT" "$EVENT_SCRIPT" >>"$DARBAN_SERVER_CONF" || return 1
    fi
    chmod 644 "$DARBAN_CRL" 2>/dev/null || true
    if [[ -n $(server_files_problem) ]]; then RESTORE_WHY="the restored server cannot run: $(server_files_problem)"; return 1; fi
    darban_verify_crl "$DARBAN_CRL" >/dev/null 2>&1 || { RESTORE_WHY='the restored CRL does not pass its checks'; return 1; }
    restore_failpoint commit || return 1
    journal_write state=starting || return 1
    # C.16.7: the check here is the service, its port, the CRL and Diagnostics; a real client is proven in CI.
    # Started, not enabled: a crash before the commit leaves OpenVPN off after a reboot. The cleanup enables it.
    systemctl start "$DARBAN_UNIT" >/dev/null 2>&1 || true
    restore_point started
    if ! wait_for_port "$(server_port 2>/dev/null || echo 0)"; then RESTORE_WHY='OpenVPN did not come back with the restored files'; return 1; fi
    journal_write state=committed || return 1
    restore_point committed
}
restore_cleanup() {
    # After the commit: what the restore replaced goes to where it is kept, each step once, so a stop at any point
    # resumes without losing or overwriting anything. It never undoes the restore.
    local id stage dest tree live file
    id=$(journal_value id); stage=$(journal_value stage)
    dest=$PKI_BACKUP_DIR/pre-restore-$id
    journal_write state=cleanup || return 1
    # Enabled at boot only now, when the restore is done, and only when it was before.
    if [[ $(journal_value unit_enabled) == yes && $(journal_value enabled) != yes ]]; then
        restore_failpoint enable || return 1
        systemctl enable "$DARBAN_UNIT" >/dev/null 2>&1 || true
        [[ $(systemctl is-enabled "$DARBAN_UNIT" 2>/dev/null) == enabled ]] || { RESTORE_WHY='OpenVPN runs, but could not be enabled at boot'; return 1; }
        journal_write enabled=yes || return 1
        restore_point enabled
    fi
    install -d -m 700 "$PKI_BACKUP_DIR" "$dest" || { RESTORE_WHY="$dest could not be made"; return 1; }
    for tree in pki server; do
        live=$(restore_tree_live "$tree")
        if [[ $(journal_value "kept_$tree") != yes ]]; then
            restore_failpoint "keep-$tree" || return 1
            # Copied whole under a temporary name, then renamed, and only then is the original removed: a stop at
            # any point leaves one complete copy at least.
            if [[ -e $live.pre-restore && ! -e $dest/$tree ]]; then
                rm -rf -- "${dest:?}/.$tree.copy"
                { cp -a -- "$live.pre-restore" "$dest/.$tree.copy" && sync && mv -T -- "$dest/.$tree.copy" "$dest/$tree"; } \
                    || { RESTORE_WHY="$live.pre-restore could not be kept in $dest"; return 1; }
                sync -- "$dest" 2>/dev/null || sync
            fi
            journal_write "kept_$tree=yes" || return 1
            restore_point "kept-$tree"
        fi
        if [[ -e $dest/$tree ]]; then rm -rf -- "$live.pre-restore"; fi
        rm -f -- "$live/.restore-$id"
    done
    for file in config domain; do
        [[ $(journal_value "kept_$file") != yes ]] || continue
        if [[ $(journal_value "saved_$file") == copy && -e $CONFIG_DIR/$file.pre-restore ]]; then
            install -d -m 700 "$dest/darban" && mv -f -- "$CONFIG_DIR/$file.pre-restore" "$dest/darban/$file" || { RESTORE_WHY="the previous $file could not be kept"; return 1; }
        fi
        journal_write "kept_$file=yes" || return 1
        restore_point "kept-$file"
    done
    # The time it is kept from (C.16.5).
    if [[ ! -e $dest/.restored ]]; then date -u +%s >"$dest/.restored" || return 1; restore_point restored; fi
    if [[ $(journal_value unverified) == yes ]]; then printf '%s\n' "$(journal_value created)" >"$RESTORE_WARN" || return 1; fi
    RESTORE_NAT_FAILED=$([[ $(journal_value nat) == failed ]] && echo 1 || echo 0)
    audit "CA restored from the backup of $(journal_value created)"
    rm -rf -- "$stage"
    restore_point cleaned
    rm -f -- "$DARBAN_RESTORE_JOURNAL"
    sync 2>/dev/null || true
    RESTORE_KEPT=$dest
}
restore_done_message() {
    # The end of a restore, the same from restore_from and from resume.
    local until
    until=$(date -u -d "@$(( $(cat "$RESTORE_KEPT/.restored" 2>/dev/null || date -u +%s) + PRE_RESTORE_KEEP_DAYS * 86400 ))" +%Y-%m-%d 2>/dev/null) || until=''
    info "What this replaced is kept in $RESTORE_KEPT until ${until:-$PRE_RESTORE_KEEP_DAYS days from now}, then deleted."
    if (( RESTORE_NAT_FAILED )); then
        urgent 'The NAT rules are not loaded, so clients may connect without reaching the internet. Run the installer again, or see: sudo darban status'
        return 1
    fi
}
restore_unit_as_before() {
    # OpenVPN as it was before the restore, and checked: active and enabled at boot as the journal recorded.
    local active enabled
    active=$(journal_value unit_active); enabled=$(journal_value unit_enabled)
    if [[ $enabled == yes ]]; then
        systemctl enable --now "$DARBAN_UNIT" >/dev/null 2>&1 || true
    elif [[ $active == yes ]]; then
        systemctl start "$DARBAN_UNIT" >/dev/null 2>&1 || true
    fi
    if [[ $enabled == yes ]] && [[ $(systemctl is-enabled "$DARBAN_UNIT" 2>/dev/null) != enabled ]]; then return 1; fi
    if [[ $enabled == yes || $active == yes ]] && ! systemctl is-active --quiet "$DARBAN_UNIT" 2>/dev/null; then return 1; fi
}
restore_rollback() {
    # darban restore --rollback: before the commit, the folders as they were, every other change undone, and OpenVPN
    # as it was; "undone" only once each of them is checked. What could not be undone keeps the journal, in the state
    # "undoing", so nothing finishes the restore forward any more and the next rollback goes on. After the commit,
    # nothing to undo. Everything is decided from the journal read under the lock.
    local id tree live stage pre file name from failed='' began
    [[ -f $DARBAN_RESTORE_JOURNAL ]] || { info 'No restore is unfinished.'; return 0; }
    began=$(journal_value id)
    DARBAN_RESTORE_OWNER=1
    ca_lock || return 1
    # Read again under the lock: another run may have finished, or undone, the restore while this one waited, and
    # another restore may have begun since. Only the restore this was asked for is undone.
    if [[ ! -f $DARBAN_RESTORE_JOURNAL ]]; then
        ca_unlock; fail 'Not undone: the restore was finished, or undone, while this waited. Nothing was changed.'; return 1
    fi
    if [[ $(journal_value id) != "$began" ]]; then
        ca_unlock; fail "Not undone: another restore, of the backup of $(journal_value created), began while this waited. Nothing was changed; run this again to undo that one."; return 1
    fi
    if restore_committed; then
        ca_unlock
        fail "The restore of the backup of $(journal_value created) was completed: OpenVPN runs with the restored CA, so it is not undone. Only its cleanup is left: sudo darban restore --resume"
        return 1
    fi
    id=$(journal_value id)
    [[ $id =~ ^[0-9a-zA-Z]+$ ]] && journal_stage_ok || { ca_unlock; urgent "The restore journal $DARBAN_RESTORE_JOURNAL cannot be read. Look at it by hand."; return 1; }
    critical_begin
    from=$(journal_value undo_from)
    if [[ -z $from ]]; then
        from=$(journal_value state)
        journal_write "undo_from=${from:-unknown}" state=undoing || { critical_end; return 1; }
    fi
    # Before the swaps began nothing was moved, so OpenVPN need not be off to undo what was prepared.
    if [[ $from != staged ]] && ! restore_openvpn_off; then
        critical_end; urgent "Not undone, and this rollback moved nothing: $RESTORE_WHY. To try again: sudo darban restore --rollback"; return 1
    fi
    for tree in server pki; do
        live=$(restore_tree_live "$tree"); stage=$live.restore-$id; pre=$live.pre-restore
        if [[ -e $live/.restore-$id ]]; then
            if [[ -e $stage ]]; then urgent "Both $live and $stage are copies of the backup. Look at them, and at $pre, by hand."; critical_end; return 1; fi
            mv -T -- "$live" "$stage" || { critical_end; urgent "Not undone: $live could not be moved back. To try again: sudo darban restore --rollback"; return 1; }
        fi
        restore_point "undo-moved-$tree"
        if [[ ! -e $live && -e $pre ]]; then mv -T -- "$pre" "$live" || { critical_end; urgent "Not undone: $pre could not be moved back. To try again: sudo darban restore --rollback"; return 1; }; fi
        rm -rf -- "$stage"
        sync -- "${live%/*}" 2>/dev/null || sync
        restore_point "undo-$tree"
    done
    # Checked, not assumed: no folder of the backup is left in place, and nothing is left aside.
    for tree in server pki; do
        live=$(restore_tree_live "$tree")
        if [[ -e $live/.restore-$id || -e $live.pre-restore || -e $live.restore-$id ]]; then
            critical_end; urgent "The restore could not be undone: look at $live, $live.pre-restore and $live.restore-$id. The journal stays."; return 1
        fi
    done
    for file in config domain; do
        case $(journal_value "saved_$file") in
            copy)
                if [[ -e $CONFIG_DIR/$file.pre-restore ]]; then mv -f -- "$CONFIG_DIR/$file.pre-restore" "$CONFIG_DIR/$file" 2>/dev/null || true; fi
                if [[ -e $CONFIG_DIR/$file.pre-restore || ! -e $CONFIG_DIR/$file ]]; then failed+="${failed:+, }$CONFIG_DIR/$file"; fi ;;
            absent)
                rm -f -- "$CONFIG_DIR/$file" 2>/dev/null || true
                if [[ -e $CONFIG_DIR/$file ]]; then failed+="${failed:+, }$CONFIG_DIR/$file"; fi ;;
        esac
    done
    for name in $(journal_value added_ledger); do
        valid_existing_name "$name" || continue
        rm -f -- "$LEDGER_DIR/$name" 2>/dev/null || true
        if [[ -e $LEDGER_DIR/$name ]]; then failed+="${failed:+, }$LEDGER_DIR/$name"; fi
    done
    if ! restore_nat; then failed+="${failed:+, }the NAT rules"; fi
    if ! restore_unit_as_before; then failed+="${failed:+, }OpenVPN as it was (active $(journal_value unit_active), enabled at boot $(journal_value unit_enabled))"; fi
    if [[ -n $failed ]]; then
        critical_end
        ca_unlock
        audit "CA restore rollback unfinished: $failed"
        urgent "The CA, the clients and the server files are as they were before the restore, but this could not be put back: $failed. The journal stays; fix that, then: sudo darban restore --rollback"
        return 1
    fi
    rm -rf -- "$(journal_value stage)"
    rm -f -- "$DARBAN_RESTORE_JOURNAL"
    critical_end
    ca_unlock
    audit 'CA restore rolled back'
    ok 'The restore was undone: the CA, the clients, the server files, the settings and OpenVPN are as they were before it.'
}
restore_resume() {
    # darban restore --resume, and every run of this tool or of the installer while a restore is unfinished: it is
    # finished forward. Before the commit the swaps go on; after it, only the cleanup is left. Everything is decided
    # from the journal read under the lock.
    local id tree began
    [[ -f $DARBAN_RESTORE_JOURNAL ]] || { info 'No restore is unfinished.'; return 0; }
    began=$(journal_value id)
    DARBAN_RESTORE_OWNER=1
    ca_lock || return 1
    # Read again under the lock: another run may have finished, or undone, the restore while this one waited, and
    # another restore may have begun since. Only the restore this was asked for is finished.
    if [[ ! -f $DARBAN_RESTORE_JOURNAL ]]; then ca_unlock; info 'The restore was finished, or undone, while this waited. Nothing was changed.'; return 0; fi
    if [[ $(journal_value id) != "$began" ]]; then
        ca_unlock; fail "Not finished: another restore, of the backup of $(journal_value created), began while this waited. Nothing was changed; run this again to finish that one."; return 1
    fi
    id=$(journal_value id)
    [[ $id =~ ^[0-9a-zA-Z]+$ ]] && journal_stage_ok || { ca_unlock; urgent "The restore journal $DARBAN_RESTORE_JOURNAL cannot be read. Look at it by hand."; return 1; }
    if [[ $(journal_value state) == undoing ]]; then
        ca_unlock
        urgent 'A rollback of this restore is unfinished, so it is not finished forward. Finish the rollback: sudo darban restore --rollback'
        return 1
    fi
    info "A restore of the backup of $(journal_value created) is unfinished; it is finished now."
    critical_begin
    if ! restore_committed; then
        restore_openvpn_off || { critical_end; urgent "The restore cannot go on: $RESTORE_WHY. Nothing was moved."; return 1; }
        for tree in pki server; do
            restore_swap_tree "$tree" "$id" || { critical_end; urgent "The restore cannot go on: $RESTORE_WHY"; return 1; }
        done
        if ! restore_commit; then
            critical_end
            urgent "The restore is not finished: $RESTORE_WHY. OpenVPN stays off. To go back: sudo darban restore --rollback"
            return 1
        fi
    fi
    if ! restore_cleanup; then
        critical_end
        warn "The restore is done and OpenVPN runs with the restored CA, but its cleanup is unfinished: $RESTORE_WHY. To finish it: sudo darban restore --resume"
        return 1
    fi
    critical_end
    ca_unlock
    ok 'The restore is finished.'
    restore_done_message
}
restore_acknowledge() {
    [[ -f $RESTORE_WARN ]] || { info 'There is nothing to acknowledge.'; return 0; }
    rm -f -- "$RESTORE_WARN"
    audit 'restore acknowledged: revocations and certificates issued after the backup were checked by the owner'
    ok 'Acknowledged. Diagnostics no longer warn about what was revoked or issued after the backup.'
}
pre_restore_prune() {
    # C.16.5: what a finished restore replaced is deleted PRE_RESTORE_KEEP_DAYS after it. Never while a restore is
    # unfinished, never one without its time, or with a time in the future, and never anything but such a folder.
    local dir when now found
    [[ ! -e $DARBAN_RESTORE_JOURNAL ]] || return 0
    now=$(date -u +%s)
    for dir in "$PKI_BACKUP_DIR"/pre-restore-*; do
        [[ -d $dir && ! -L $dir && -f $dir/.restored && ! -L $dir/.restored ]] || continue
        [[ -d $dir/pki || -d $dir/server ]] || continue
        # Only what a restore keeps there, and no link anywhere in it.
        # A find that fails cannot say so, so the folder stays.
        found=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name pki ! -name server ! -name darban ! -name .restored -print -quit 2>/dev/null) || continue
        [[ -z $found ]] || continue
        found=$(find "$dir" -type l -print -quit 2>/dev/null) || continue
        [[ -z $found ]] || continue
        read -r when <"$dir/.restored" || continue
        [[ $when =~ ^[0-9]{1,12}$ ]] || continue
        if (( when > now || now - when < PRE_RESTORE_KEEP_DAYS * 86400 )); then continue; fi
        if rm -rf -- "$dir"; then audit "the CA a restore replaced was deleted, $PRE_RESTORE_KEEP_DAYS days after the restore: ${dir##*/}"; fi
    done
}
pre_restore_health() {
    # The Diagnostics lines for what restores replaced: when each goes, and anything kept for another reason.
    local dir when now left
    now=$(date -u +%s)
    for dir in "$PKI_BACKUP_DIR"/pre-restore-*; do
        [[ -d $dir && ! -L $dir ]] || continue
        if [[ ! -f $dir/.restored ]] || ! read -r when <"$dir/.restored" || [[ ! $when =~ ^[0-9]{1,12}$ ]]; then
            check warn "$dir holds the CA a restore replaced, and is kept: its restore did not finish its cleanup $S_ARROW sudo darban restore --resume"
            continue
        fi
        if (( when > now )); then check warn "$dir has a restore time in the future, so it is kept; check the clock"; continue; fi
        left=$(( (when + PRE_RESTORE_KEEP_DAYS * 86400 - now + 86399) / 86400 ))
        if (( left <= PRE_RESTORE_WARN_DAYS )); then
            check warn "$dir, the CA a restore replaced, is deleted in $left day(s). To keep it, copy it elsewhere now"
        else
            check info "$dir holds the CA a restore replaced, unencrypted and readable by root only; it is deleted in $left days"
        fi
    done
}
restore_from() {
    # darban restore <tar> --ca-fingerprint <sha256> | --ca-from <profile.ovpn>
    local file='' want='' from='' stage id facts got created host version valid revoked crl_state='' unverified=no
    local now next line tree history restored_host mine
    local -a stale=()
    while (( $# )); do
        case $1 in
            --ca-fingerprint) want=${2:-}; shift 2 || shift ;;
            --ca-from) from=${2:-}; shift 2 || shift ;;
            -*) fail "Unknown option: $1"; return 2 ;;
            *) file=$1; shift ;;
        esac
    done
    if [[ -z $file ]]; then
        fail 'Name the opened backup: sudo darban restore darban-pki.tar --ca-fingerprint <SHA-256>'
        info "Open it on your computer first: age -d -i darban-backup.key <backup>.tar.age > darban-pki.tar"
        return 2
    fi
    [[ -f $file && ! -L $file ]] || { fail "$file is not a file."; return 1; }
    [[ ! -e $DARBAN_RESTORE_JOURNAL ]] || { fail 'A restore is unfinished. Finish it: sudo darban restore --resume, or undo it: sudo darban restore --rollback'; return 1; }
    # The CA the backup must hold comes from outside the backup: a profile on a device, or the fingerprint noted.
    if [[ -n $from ]]; then
        [[ -f $from ]] || { fail "$from is not a file."; return 1; }
        want=$(awk '/^<ca>\r?$/ {f=1; next} /^<\/ca>\r?$/ {f=0} f' "$from" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')
        [[ -n $want ]] || { fail "$from has no <ca> block this tool can read."; return 1; }
    fi
    if ! want=$(fingerprint_hex "$want"); then
        fail 'Say which CA the backup must hold, from outside the backup: --ca-fingerprint <the SHA-256 fingerprint the backup message and Diagnostics showed>, or --ca-from <a profile from one of your devices>.'
        return 2
    fi
    if [[ $(head -n 1 "$DARBAN_SERVER_CONF" 2>/dev/null) != '# Created by Darban OVPN server-setup.' ]]; then
        fail "This server was not set up by this tool's setup. Set it up first; a restore then replaces its new CA, clients and server files."
        return 1
    fi
    install -d -m 700 "${DARBAN_RESTORE_JOURNAL%/*}" || return 1
    stage=$(mktemp -d "${DARBAN_RESTORE_JOURNAL%/*}/.restore-stage.XXXXXXXX") || return 1
    mkdir -m 700 "$stage/files" || return 1
    restore_refuse() { rm -rf -- "$stage"; fail "Not restored: $1"; info 'Nothing on this server was changed.'; return 1; }
    facts=$(python3 -I "$BACKUP_PY" check --archive "$file" --stage "$stage/files" 2>&1) || { restore_refuse "${facts##*REFUSED: }"; return 1; }
    got=$(sed -n 's/^ca_fingerprint=//p' <<<"$facts")
    created=$(sed -n 's/^created=//p' <<<"$facts"); host=$(sed -n 's/^host=//p' <<<"$facts"); version=$(sed -n 's/^version=//p' <<<"$facts")
    valid=$(sed -n 's/^valid=//p' <<<"$facts"); revoked=$(sed -n 's/^revoked=//p' <<<"$facts")
    [[ $got == "$want" ]] || { restore_refuse 'the CA in the backup is not the CA you named. A backup of another CA, or one changed by someone, is never restored.'; return 1; }
    local files=$stage/files
    if ! cmp -s <(openssl x509 -in "$files/pki/ca.crt" -noout -pubkey 2>/dev/null) <(openssl pkey -in "$files/pki/private/ca.key" -pubout 2>/dev/null); then
        restore_refuse 'the CA private key in the backup does not belong to its CA certificate.'; return 1
    fi
    if ! openssl verify -CAfile "$files/pki/ca.crt" "$files/server/server.crt" >/dev/null 2>&1 \
        || ! cmp -s <(openssl x509 -in "$files/server/server.crt" -noout -pubkey 2>/dev/null) <(openssl pkey -in "$files/server/server.key" -pubout 2>/dev/null); then
        restore_refuse 'the server certificate in the backup is not valid from its CA, or does not match its key.'; return 1
    fi
    ( DARBAN_PKI=$files/pki; darban_index_rows ) >/dev/null 2>&1 || { restore_refuse 'the CA index in the backup cannot be read.'; return 1; }
    # An index that names one certificate twice says two things of it; such a backup is not restored.
    restore_index_unique "$( DARBAN_PKI=$files/pki; darban_index_rows 2>/dev/null )" || { restore_refuse 'the CA index in the backup names a certificate twice.'; return 1; }
    # The CRL of the backup: missing, unreadable, signed by another CA, or expired; each is said apart.
    RESTORE_NEW_CRL=0
    now=$(date -u +%s)
    if [[ ! -s $files/pki/crl.pem ]]; then
        crl_state='The backup has no CRL; a new one is made with the restored CA.'; RESTORE_NEW_CRL=1
    elif ! openssl crl -in "$files/pki/crl.pem" -noout 2>/dev/null; then
        crl_state='The CRL in the backup cannot be read; a new one is made with the restored CA.'; RESTORE_NEW_CRL=1
    elif ! ( DARBAN_PKI=$files/pki; darban_crl_signature_ok "$files/pki/crl.pem" ); then
        restore_refuse 'the CRL in the backup is not signed by its CA.'; return 1
    else
        next=$(darban_crl_expiry_epoch "$files/pki/crl.pem" 2>/dev/null) || next=0
        if (( next <= now )); then crl_state='The CRL in the backup has expired; a new one is made with the restored CA.'; RESTORE_NEW_CRL=1; fi
        if ! ( DARBAN_PKI=$files/pki DARBAN_SERVER_DIR=$files/server DARBAN_SERVER_CONF=$files/server/server.conf; darban_verify_crl "$files/pki/crl.pem" ) >/dev/null 2>&1; then
            crl_state=${crl_state:-'The CRL in the backup does not list every revocation of its index; a new one is made.'}; RESTORE_NEW_CRL=1
        fi
    fi
    # The archive as a whole first: a server.conf with a line this tool does not restore refuses it.
    if ! python3 -I "$BACKUP_PY" conf --conf "$files/server/server.conf" --server-dir "$DARBAN_SERVER_DIR" >"$stage/server.conf" 2>"$stage/conf.notes"; then
        restore_refuse "$(sed -n 's/^REFUSED: //p' "$stage/conf.notes")"; return 1
    fi
    # C.16.1: on this CA, a backup that does not know a certificate issued, or a revocation made, after it is never
    # restored. Checked now, to say so before asking, and again under the lock, which decides.
    restore_history "$files" || { restore_refuse 'the CA index in the backup cannot be read.'; return 1; }
    if [[ -n $RESTORE_UNDONE ]]; then
        restore_refuse "this backup is older than the CA in use here: it does not know $(safe_text "$RESTORE_UNDONE"), issued or revoked after it. Restoring it would leave them out of this tool's control. Use a newer backup, or keep the CA in use."
        return 1
    fi
    if [[ $RESTORE_HISTORY == unknown ]]; then unverified=yes; fi
    history=$RESTORE_SAME_CA:$RESTORE_HISTORY
    # What would happen, before anything does.
    say
    kv Backup "${created:-unknown time}"
    kv Server "${host:-unknown}"
    kv Version "${version:-unknown}"
    kv 'CA fingerprint' "$(ca_fingerprint_label "$files/pki/ca.crt")"
    kv Clients "$valid valid $S_SEP $revoked revoked"
    restored_host=$(head -n 1 "$files/darban/domain" 2>/dev/null || true)
    if valid_domain "$restored_host"; then kv Address "$restored_host"; fi
    if [[ -n $crl_state ]]; then info "$crl_state"; fi
    if [[ -n $RESTORE_REVOKED ]]; then info "The backup has these revoked, and they stay revoked: $(safe_text "$RESTORE_REVOKED")."; fi
    while IFS= read -r line; do [[ -z $line ]] || info "${line#NOTE: }"; done <"$stage/conf.notes"
    info 'server.conf is written again from the template of this tool, with its port, network, routing, DNS, ciphers, keepalive and log detail.'
    if [[ -e $DARBAN_PKI ]]; then info "The CA, clients and server files of this server are replaced. What they are now is kept in $PKI_BACKUP_DIR for $PRE_RESTORE_KEEP_DAYS days, then deleted."; fi
    info 'OpenVPN stays off from the first change until the end, even across a reboot.'
    if valid_domain "$restored_host" && mine=$(address_elsewhere "$restored_host"); then
        warn "The backup's server address, $restored_host, is not this server, which is $mine. Profiles made with it connect to the server it came from. After the restore, set this server's address in Settings $S_CRUMB 1, then share each client again."
    fi
    mapfile -t stale < <(share_rows 2>/dev/null | awk -F '\t' '$1!="orphan" {print $3}' | sort -u)
    if (( ${#stale[@]} )); then info "Links and files kept on this server hold profiles of the CA in use now; after the restore, share those clients again: $(safe_text "${stale[*]}")."; fi
    say
    if [[ $unverified == yes ]]; then
        warn "Revocations and certificates issued after ${created:-the backup} cannot be known."
        if [[ $RESTORE_SAME_CA == yes ]]; then
            info "This server's CA is the one in the backup, but its index cannot be read, so certificates issued after the backup cannot be known; the revocations its CRL lists were checked."
        else
            info 'This server has no CA index or blocklist of the same CA, so a client revoked, or a certificate issued, after the backup cannot be known.'
        fi
        info 'Such a certificate would connect after the restore, and this tool could not list or revoke it. After the restore, revoke, and issue again, any client you are not sure of. Diagnostics warn until you acknowledge it.'
        if ! ask "To restore anyway, type the server name of the backup, ${host:-server} (Enter = cancel): " || [[ $REPLY != "${host:-server}" ]]; then
            rm -rf -- "$stage"; cancelled; return 0
        fi
    elif ! confirm_choice "Restore the backup of ${created:-unknown time}?" 'No, keep this server as it is' 'Restore it' caution restore; then
        rm -rf -- "$stage"; cancelled; return 0
    fi
    # The lock refuses while a journal is there: another restore may have started while the question was open.
    ca_lock || { rm -rf -- "$stage"; info 'Nothing on this server was changed.'; return 1; }
    DARBAN_RESTORE_OWNER=1
    restore_point locked
    # Under the lock, again: another session may have revoked or issued while the question was open.
    if ! restore_history "$files" || [[ -n $RESTORE_UNDONE ]]; then
        ca_unlock
        restore_refuse "this server changed while the question was open: the backup does not know ${RESTORE_UNDONE:-the CA index of this server}."
        return 1
    fi
    if [[ $RESTORE_SAME_CA:$RESTORE_HISTORY != "$history" ]]; then ca_unlock; restore_refuse 'what this server knows of its CA changed while the question was open. Run the restore again.'; return 1; fi
    if [[ -e $DARBAN_PKI.pre-restore || -e $DARBAN_SERVER_DIR.pre-restore ]]; then
        ca_unlock; rm -rf -- "$stage"; fail "An earlier restore left $DARBAN_PKI.pre-restore or $DARBAN_SERVER_DIR.pre-restore. Move it away first."; return 1
    fi
    id=$(date -u +%Y%m%d%H%M%S)$RANDOM
    if ! restore_stage_trees "$files" "$id" "$stage/server.conf"; then
        rm -rf -- "$stage" "$DARBAN_PKI.restore-$id" "$DARBAN_SERVER_DIR.restore-$id"
        ca_unlock
        fail "Not restored: ${RESTORE_WHY:-the new folders could not be made}."; info 'Nothing on this server was changed.'; return 1
    fi
    critical_begin
    journal_write "id=$id" "created=${created:-unknown}" "stage=$stage" "unverified=$unverified" \
        "unit_enabled=$([[ $(systemctl is-enabled "$DARBAN_UNIT" 2>/dev/null) == enabled ]] && echo yes || echo no)" \
        "unit_active=$(systemctl is-active --quiet "$DARBAN_UNIT" 2>/dev/null && echo yes || echo no)" state=staged || { critical_end; return 1; }
    # From here on, no boot starts OpenVPN until the restore is done or undone; no rename is made before that is so.
    if ! restore_openvpn_off; then
        critical_end
        urgent "Not restored: $RESTORE_WHY. No folder was moved."
        restore_rollback || true
        return 1
    fi
    journal_write state=swapping || { critical_end; return 1; }
    for tree in pki server; do
        restore_swap_tree "$tree" "$id" || { critical_end; urgent "The restore stopped: $RESTORE_WHY"; return 1; }
    done
    if ! restore_commit; then
        urgent "The restore did not finish: $RESTORE_WHY. Undoing it:"
        critical_end
        restore_rollback || true
        return 1
    fi
    if ! restore_cleanup; then
        critical_end
        ca_unlock
        warn "Restored the backup of ${created:-unknown time}, and OpenVPN runs with the restored CA, but the cleanup is unfinished: $RESTORE_WHY. To finish it: sudo darban restore --resume"
        return 1
    fi
    critical_end
    ca_unlock
    ok "Restored the backup of ${created:-unknown time}. OpenVPN runs with the restored CA."
    local rc=0
    restore_done_message || rc=1
    if [[ $unverified == yes ]]; then warn 'Revoke, and issue again, any client you are not sure of, then: sudo darban restore --acknowledge'; fi
    return "$rc"
}
restore_command() {
    # darban restore ...: the one command of a restore; it has no menu item, since it needs the opened backup.
    case ${1:-} in
        --resume) restore_resume ;;
        --rollback) restore_rollback ;;
        --acknowledge) restore_acknowledge ;;
        *) restore_from "$@" ;;
    esac
}

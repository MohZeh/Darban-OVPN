#!/usr/bin/env bash
# Easy-RSA, the CRL and revoking a client.
# A part of bin/darban, which sources it after lib/darban/paths.sh and lib/darban/config.sh.

verify_published_crl() {
    # verify_published_crl <CRL file>: darban_verify_crl of lib/common.sh, the same checks in the same order with
    # the same words, for the screens that only read: the file, its signature and its dates by openssl as there,
    # then darban-core compares it with the CA index in one reading of each, where the Bash loops took minutes with
    # thousands of revoked clients. What changes the CRL still checks it with darban_verify_crl.
    local file=$1 exp start now server_serial
    [[ -s $file ]] || { darban_error "CRL missing: $file"; return 1; }
    darban_crl_signature_ok "$file" || { darban_error 'CRL signature verification failed.'; return 1; }
    exp=$(darban_crl_expiry_epoch "$file") || { darban_error 'Unreadable CRL nextUpdate.'; return 1; }
    start=$(darban_crl_this_epoch "$file") || { darban_error 'Unreadable CRL lastUpdate.'; return 1; }
    now=$(date -u +%s)
    (( exp > now && start <= now + 300 && start < exp )) || {
        darban_error 'CRL is expired, not yet valid, or has an inconsistent validity window.'; return 1;
    }
    # An unreadable index is named before the server certificate, as there; darban-core says both.
    server_serial=$(darban_server_serial 2>/dev/null) || server_serial=''
    core_index crl --crl "$file" --now "$now" --server-serial "$server_serial" >/dev/null
}
run_easyrsa() {
    # Easy-RSA's own notices (e.g. "now run gen-crl") contradict the automated flow and bury the
    # result, so its output is kept out of sight and shown only when it fails.
    local log rc=0
    log=$(mktemp "${TMPDIR:-/tmp}/darban-easyrsa.XXXXXXXX") || return 1
    darban_tmp_register "$log"
    env EASYRSA_PKI="$DARBAN_PKI" EASYRSA_BATCH=1 "$DARBAN_EASYRSA" "$@" </dev/null >"$log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        fail "Easy-RSA '$1' failed (status $rc). Its output:"
        sed 's/^/    /' "$log" >&2 || true
    fi
    rm -f -- "$log"
    return "$rc"
}
disconnect_revoked() {
    local name=$1 rc=0
    # One restart already ended every session, including those of the other names being repaired.
    if (( SESSIONS_RESTARTED )); then return 0; fi
    if ! valid_existing_name "$name"; then info "Cannot address $(safe_text "$name") through the management interface."; return 0; fi
    if ! systemctl is-active --quiet "$DARBAN_UNIT"; then warn "OpenVPN service is not active; review its status (Maintenance $S_CRUMB 1)."; return 0; fi
    info "Disconnecting any active session of $name${S_ELL}"
    mgmt_kill_client "$name" || rc=$?
    case $rc in
        0) ok "Active session of $name disconnected (other users were not affected)."; audit "session disconnected: $name"; return 0 ;;
        3) ok "$name has no active VPN session."; return 0 ;;
        1) warn 'The management interface did not confirm the disconnect.' ;;
        *) info "Single-client disconnect is unavailable. To enable it, add this to server.conf and install socat: management /run/openvpn-server/darban.sock unix" ;;
    esac
    say
    info "$name cannot start new connections. A session already open may last until it renegotiates (up to 1 hour)."
    if confirm_choice 'Restart OpenVPN now to end it? This drops ALL connected VPN users for a few seconds.' 'No, do not restart' 'Restart OpenVPN' caution; then
        info "Restarting OpenVPN${S_ELL}"
        if systemctl restart "$DARBAN_UNIT" && systemctl is-active --quiet "$DARBAN_UNIT"; then
            ok 'OpenVPN restarted.'
            SESSIONS_RESTARTED=1
            audit "OpenVPN restarted to drop revoked client: $name"
        else
            urgent 'OpenVPN restart FAILED. The CRL is published; check: journalctl -u openvpn-server@server'
        fi
    else
        info 'Not restarted.'
    fi
}
generate_and_publish_crl() {
    # generate_and_publish_crl [serial that must be listed]. On failure the previous CRL stays active.
    local must_list=${1:-}
    info "Generating and verifying a new CRL${S_ELL}"
    run_easyrsa gen-crl || { urgent 'CRL generation failed; the previous CRL stays active.'; return 1; }
    darban_verify_crl "$DARBAN_PKI/crl.pem" || { urgent 'The new CRL is invalid or incomplete; it was not published.'; return 1; }
    if [[ -n $must_list ]] && ! darban_crl_has_serial "$DARBAN_PKI/crl.pem" "$must_list"; then
        urgent 'The new CRL omits this client; it was not published.'; return 1
    fi
    darban_publish_crl "$DARBAN_PKI/crl.pem" || { urgent 'The CRL was not published; the previous CRL stays active.'; return 1; }
    ok 'New CRL published to OpenVPN and verified.'
    backup_auto 'CRL published'
}
revoke_and_publish() {
    local name=$1 client_serial=$2
    info "Revoking the certificate${S_ELL}"
    run_easyrsa revoke "$name" || { fail 'Easy-RSA revoke failed. Review the CA index before any retry.'; return 1; }
    [[ $(index_state_of_serial "$client_serial") == R ]] || {
        urgent 'The CA index did not mark the certificate revoked. Manual investigation required.'; return 1;
    }
    ok 'Marked revoked in the CA index.'
    audit "client revoked in the CA: $name (serial $client_serial)"
    generate_and_publish_crl "$client_serial" || {
        urgent "$name is revoked in the CA, but OpenVPN can still accept it. Do NOT assume it is blocked."
        info "After fixing the cause, finish this revocation: Maintenance $S_CRUMB 2, or: sudo darban repair-crl"
        audit "CRL not published after revoking: $name"
        return 1
    }
}
repair_crl() {
    # Finishes whatever an interrupted revocation left: the index and published files show what is
    # missing, so there is no separate state to get out of step with them.
    local pending leftovers rows name publish=0 rc=0 cleanup=0
    local -a targets=()
    darban_crl_configured || { warn "server.conf lacks a single 'crl-verify $DARBAN_CRL'; OpenVPN would ignore a CRL. Fix the server first."; return 1; }
    ca_lock || return 1
    pending=$(revocation_pending_names) || { fail 'Could not read the CA index.'; return 1; }
    rows=$(share_rows) || { fail 'Could not read the links and files on the server.'; return 1; }
    leftovers=$(share_names revoked "$rows")
    if ! darban_verify_crl "$DARBAN_CRL"; then publish=1; fi
    if [[ -n $pending ]]; then publish=1; fi
    if (( ! publish )) && [[ -z $leftovers ]]; then
        # A link record without its profile holds no secret; it goes without a word.
        finish_revoked_shares || true
        ok 'The CRL is healthy and no revocation is unfinished. Nothing to repair.'
        return 0
    fi
    if (( publish )); then
        critical_begin
        generate_and_publish_crl || rc=$?
        critical_end
        if (( rc != 0 )); then
            fail 'Repair failed; see the reason above. Nothing else was changed.'
            audit 'CRL repair failed'
            return 1
        fi
        audit 'CRL repaired and republished'
    fi
    # By certificate, not by name: a link or file of a name issued again belongs to the new certificate and stays.
    finish_revoked_shares || cleanup=1
    ca_unlock
    # Read into an array first: the prompts in disconnect_revoked must read the terminal, not this list.
    # A name with a valid certificate again is left alone: its session belongs to the new certificate.
    mapfile -t targets < <(printf '%s\n' "$pending" "$leftovers" | awk 'NF' | sort -u)
    for name in "${targets[@]}"; do
        if [[ $(client_index_status "$name") == V ]] && ! grep -qFx -- "$name" <<<"$pending"; then continue; fi
        disconnect_revoked "$name"
    done
    say
    if (( cleanup )); then
        fail 'Some links or files could not be deleted; see above. Run the repair again: Maintenance '"$S_CRUMB"' 2, or: sudo darban repair-crl'
        audit 'revocation cleanup unfinished after repair'
        return 1
    fi
    if (( publish )); then ok 'The CRL is repaired.'; else ok 'The unfinished revocation is complete.'; fi
}
revoke_client() {
    local name state client_serial db_serial path pending unknown rc=0 links_left=0
    pending=$(revocation_pending_names | join_lines) || pending=''
    if [[ -n $pending ]]; then
        urgent "Revoked but NOT blocked yet: $(safe_text "$pending"). Finish this first: Maintenance $S_CRUMB 2, or: sudo darban repair-crl"
        say
    fi
    pick_client 'Revoke which client?' can_revoke revoke_block_reason || return 0
    name=$PICKED
    state=$(client_index_status "$name")
    [[ $state == V ]] || { warn "Client is not uniquely valid: ${state:-not found}"; return 1; }
    client_cert_safe "$name" || {
        warn 'Refused: this is the OpenVPN server certificate or a certificate usable for server authentication.'; return 1;
    }
    darban_crl_configured || { warn "server.conf lacks a single 'crl-verify $DARBAN_CRL'; revocation would not be enforced. Fix the server first."; return 1; }
    # Publishing would be refused after the permanent step, so a rolled-back database stops it here.
    if darban_crl_signature_ok "$DARBAN_CRL"; then
        unknown=$(darban_crl_unknown_serials "$DARBAN_CRL") || { fail 'Could not compare the CA database with the published CRL. No changes made.'; return 1; }
        if [[ -n $unknown ]]; then fail "No changes made. $(darban_rollback_hint)"; return 1; fi
    fi
    # A broken CRL must not block an emergency revocation: a complete new CRL is generated and verified below.
    if ! darban_verify_crl "$DARBAN_CRL"; then
        warn 'The published CRL is currently unhealthy; this revocation will replace it with a freshly generated, fully verified CRL.'
    fi
    client_serial=$(openssl x509 -in "$DARBAN_PKI/issued/$name.crt" -noout -serial | sed 's/^serial=//') || return 1
    db_serial=$(client_index_serial "$name")
    [[ $(darban_norm_serial "$client_serial") == "$(darban_norm_serial "$db_serial")" ]] || {
        warn 'Client certificate serial does not match the CA index. No changes made.'; return 1;
    }
    say
    printf '%sRevoking %s is PERMANENT:%s\n' "$C_BOLD" "$name" "$C_RESET"
    bullet 'every copy of its .ovpn profile stops working for new connections'
    bullet 'this certificate can never be restored; only a new one can be issued later'
    bullet 'the server-side copy is deleted; copies on devices cannot be deleted remotely'
    say
    confirm_choice "Revoke $name permanently?" 'No, keep this client' "Revoke $name" danger "$name" || { cancelled; return 0; }
    ca_lock || return 1
    # Checked again under the lock: another session may have changed this client during the question.
    if [[ $(client_index_status "$name") != V || $(client_index_serial "$name") != "$db_serial" ]]; then
        warn "$name changed while this question was open. Nothing was revoked."
        return 1
    fi
    say
    critical_begin
    revoke_and_publish "$name" "$client_serial" || rc=$?
    critical_end
    # The CA has revoked it either way, so its links go now. If the link service holds their files, everything
    # else still happens, and the repair removes the links later.
    remove_links_for "$name" || links_left=1
    if (( rc != 0 )); then
        if (( links_left )); then warn 'Its open links could not be removed either; the same repair removes them.'; fi
        return 1
    fi
    if path=$(profile_path "$name"); then
        if rm -f -- "$path" "${path%.ovpn}.share"; then ok "Server copy deleted: $path"; else warn 'Could not delete the server copy; the revocation still succeeded.'; fi
    fi
    # Found now, under the lock, by the record of each copy and by the certificate, and checked again just before
    # each deletion.
    home_copy_revoked "$name" "$(darban_norm_serial "$client_serial")" || warn "A copy for the SSH user could not be deleted; the revocation still succeeded."
    home_copy_report
    ca_unlock
    disconnect_revoked "$name"
    say
    if (( links_left )); then
        warn "$name is revoked; link cleanup unfinished. Finish it: Maintenance $S_CRUMB 2, or: sudo darban repair-crl"
        audit "revocation cleanup unfinished, links still open: $name"
        return 1
    fi
    ok "$name is revoked."
}

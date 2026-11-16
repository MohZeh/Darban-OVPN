#!/usr/bin/env bash
# shellcheck disable=SC2319  # "[[ ... ]]; rc_is ... "$?"" is how these tests read a condition's result.
# Regression tests for Darban OVPN. Run: bash tests/run-tests.sh [name-filter]
#
# Each test gets a fresh fake server (see fake-server.sh) and drives the real entry points: the
# manager's menu and commands, and the CRL maintainer. Only synthetic data under a temp directory.
#
# Limits: Easy-RSA, systemd, ss and flock are stand-ins, there is no real terminal and no real
# OpenVPN client. Passing here does not replace the acceptance test on a disposable Linux VM.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FILTER=${1:-}
export MSYS2_ARG_CONV_EXCL='*' LC_ALL=C.UTF-8 NO_COLOR=1
# The one more try of a failed snap install comes at once.
export DARBAN_SNAP_RETRY_DELAY=0
native() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
posix() { if command -v cygpath >/dev/null; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
WORK=$(native "$(mktemp -d "${TMPDIR:-/tmp}/darban-tests.XXXXXXXX")")
trap 'rm -rf "$WORK"' EXIT
export BASE_PATH=$PATH
PASS=0; FAIL=0; FAILED=()
CURRENT=''

fresh() {
    E=$WORK/env
    bash "$HERE/fake-server.sh" "$(native "$REPO")" "$E" >/dev/null || { echo 'fake server build FAILED'; exit 2; }
    PATH="$(posix "$E/bin"):$BASE_PATH"
    SERVER_CONF=$E/server/server.conf; STUB_LOG=$E/stub.log; CRL=$E/server/crl.pem; PKI=$E/pki
    EASYRSA_PKI=$PKI EASYRSA_BATCH=1
    export PATH SERVER_CONF STUB_LOG E EASYRSA_PKI EASYRSA_BATCH
    unset FAIL_GENCRL
}
result() { if (( $1 )); then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED+=("$CURRENT: $2"); printf '  FAIL %s\n' "$2"; fi; }
ok_if() { local what=$1; shift; if "$@"; then result 1 "$what"; else result 0 "$what"; fi; }
has() { local what=$1 needle=$2 text=$3; if [[ $text == *"$needle"* ]]; then result 1 "$what"; else result 0 "$what (wanted: $needle)"; printf '%s\n' "$text" | sed 's/^/    | /' | tail -25; fi; }
lacks() { local what=$1 needle=$2 text=$3; if [[ $text != *"$needle"* ]]; then result 1 "$what"; else result 0 "$what (unwanted: $needle)"; printf '%s\n' "$text" | sed 's/^/    | /' | tail -25; fi; }
rc_is() { local what=$1 want=$2 got=$3; if [[ $got == "$want" ]]; then result 1 "$what"; else result 0 "$what (rc $got, wanted $want)"; fi; }
rc_not0() { local what=$1 got=$2; if [[ $got != 0 ]]; then result 1 "$what"; else result 0 "$what (rc 0)"; fi; }

# Commands get an empty stdin: an open one that never answers would hold a prompt until the idle timeout.
mgr() { bash "$E/manager.sh" "$@" 2>&1 </dev/null; }
menu() { printf "$1" | bash "$E/manager.sh" 2>&1; }
maintain() { bash "$E/crl-maintain" "$@" 2>&1; }
easyrsa() { bash "$E/bin/easyrsa" "$@"; }
publish_now() { easyrsa gen-crl && cp "$PKI/crl.pem" "$CRL"; }
crl_count() { openssl crl -in "$1" -noout -text | grep -c 'Serial Number'; }
serial_of() { openssl x509 -in "$1" -noout -serial | sed 's/^serial=//'; }
crl_lists() { openssl crl -in "$1" -noout -text | grep -q "Serial Number: $2"; }
state_row() { awk -F '\t' -v cn="/CN=$1" '$6==cn {print $1}' "$PKI/index.txt" | tr -d '\n'; }
revoke_menu() { menu "4\n$1\n$1\n0\n"; }
# Restores the index as a backup would, including the files the revocation moved away.
snapshot_index() { cp "$PKI/index.txt" "$E/index.before"; cp "$PKI/issued/alice.crt" "$E/alice.crt"; cp "$PKI/private/alice.key" "$E/alice.key"; }
restore_index() { cp "$E/index.before" "$PKI/index.txt"; cp "$E/alice.crt" "$PKI/issued/alice.crt"; cp "$E/alice.key" "$PKI/private/alice.key"; }
# Runs the library's CRL check by itself, for states the entry points refuse earlier.
lib_verify() { bash -c 'set -uo pipefail; source "$E/lib/common.sh"; darban_verify_crl "$E/server/crl.pem"' 2>&1; }

test_create_and_revoke_baseline() {
    local out rc serial
    out=$(menu '1\nbob\n0\n')
    has 'create prints the download panel' 'created and verified' "$out"
    has 'create prints a scp command' 'scp -P 2222' "$out"
    ok_if 'profile written' test -s "$E/clients/bob.ovpn"
    has 'list shows the new client' 'bob' "$(mgr list)"
    lacks 'list hides the server certificate' 'server_abc123' "$(mgr list)"
    serial=$(serial_of "$PKI/issued/bob.crt")
    out=$(revoke_menu bob)
    has 'revoke reports success' 'bob is revoked.' "$out"
    ok_if 'CRL lists the revoked serial' crl_lists "$CRL" "$serial"
    ok_if 'server copy deleted' test ! -e "$E/clients/bob.ovpn"
    out=$(mgr status); rc=$?
    has 'status reports a healthy CRL' 'Published CRL valid and complete' "$out"
    lacks 'status has no unfinished revocation' 'NOT blocked' "$out"
    out=$(maintain --check); rc=$?
    rc_is 'maintainer check passes' 0 "$rc"
}

test_index_missing_empty_or_malformed_is_rejected() {
    local out rc
    out=$(maintain --check); rc=$?
    rc_is 'healthy baseline passes' 0 "$rc"

    mv "$PKI/index.txt" "$PKI/index.saved"
    out=$(lib_verify); rc=$?
    rc_not0 'missing index rejected (R-01)' "$rc"
    has 'missing index is named' 'CA database is missing' "$out"
    mkdir "$PKI/index.txt"
    out=$(lib_verify); rc=$?
    rc_not0 'unreadable index rejected: the read error is not swallowed (R-01)' "$rc"
    rmdir "$PKI/index.txt"

    : > "$PKI/index.txt"
    out=$(maintain --check); rc=$?
    rc_not0 'empty index rejected' "$rc"
    has 'empty index is explained' 'does not contain the server certificate' "$out"
    cp "$CRL" "$E/crl.keep"
    out=$(maintain --auto); rc=$?
    rc_not0 'timer run on an empty index fails' "$rc"
    ok_if 'timer run on an empty index leaves the CRL alone' cmp -s "$CRL" "$E/crl.keep"

    { cat "$PKI/index.saved"; printf 'garbage line\n'; } > "$PKI/index.txt"
    out=$(maintain --check); rc=$?
    rc_not0 'malformed record rejected' "$rc"
    has 'malformed record is named' 'malformed record' "$out"

    grep -v server_abc123 "$PKI/index.saved" > "$PKI/index.txt"
    out=$(maintain --check); rc=$?
    rc_not0 'index without the server certificate rejected' "$rc"
}

test_index_rollback_cannot_unrevoke() {
    local out rc serial
    snapshot_index
    serial=$(serial_of "$PKI/issued/alice.crt")
    out=$(revoke_menu alice)
    ok_if 'alice is on the CRL' crl_lists "$CRL" "$serial"
    cp "$CRL" "$E/crl.keep"
    restore_index

    out=$(maintain --check); rc=$?
    rc_not0 'check detects the rollback (C-01)' "$rc"
    has 'check explains the rollback' 'looks older than the published CRL' "$out"
    out=$(maintain --auto); rc=$?
    rc_not0 'timer run refuses (C-01)' "$rc"
    has 'timer run refuses to un-revoke' 'would un-revoke' "$out"
    ok_if 'CRL unchanged after the timer run' cmp -s "$CRL" "$E/crl.keep"
    out=$(maintain --renew); rc=$?
    rc_not0 'manual renew refuses without the flag' "$rc"
    ok_if 'CRL unchanged after renew' cmp -s "$CRL" "$E/crl.keep"
    has 'header shows the problem' 'problem' "$(menu '0\n')"
    out=$(mgr repair-crl); rc=$?
    rc_not0 'repair refuses too' "$rc"
    ok_if 'CRL unchanged after repair' cmp -s "$CRL" "$E/crl.keep"

    out=$(menu '1\nbob\n0\n')
    cp "$PKI/index.txt" "$E/index.mid"
    out=$(revoke_menu bob)
    has 'revoke stops before the permanent step' 'No changes made' "$out"
    ok_if 'revoke changed nothing in the index' cmp -s "$PKI/index.txt" "$E/index.mid"

    out=$(maintain --auto --allow-crl-shrink); rc_is 'override is not accepted on --auto' 2 "$?"
    out=$(DARBAN_ALLOW_CRL_SHRINK=1 maintain --renew); rc=$?
    rc_not0 'override cannot come from the environment' "$rc"
    ok_if 'CRL still unchanged' cmp -s "$CRL" "$E/crl.keep"
    out=$(maintain --renew --allow-crl-shrink); rc=$?
    rc_is 'explicit override publishes' 0 "$rc"
    has 'override names what it un-revokes' 'explicitly un-revoking' "$out"
    rc_is 'override leaves no revoked entries' 0 "$(crl_count "$CRL")"
    out=$(maintain --check); rc_is 'state is consistent after the override' 0 "$?"
}

test_expired_revoked_entry_may_leave_the_crl() {
    local out rc serial
    serial=$(serial_of "$PKI/issued/alice.crt")
    out=$(revoke_menu alice)
    ok_if 'alice is on the CRL' crl_lists "$CRL" "$serial"
    # The database now says this certificate has long expired and drops it from future CRLs.
    awk -F '\t' 'BEGIN {OFS="\t"} $6=="/CN=alice" {$1="E"; $2="200101000000Z"; $3=""} {print}' "$PKI/index.txt" > "$PKI/index.new"
    mv "$PKI/index.new" "$PKI/index.txt"
    out=$(maintain --check); rc=$?
    rc_is 'an expired certificate on the CRL is not a rollback' 0 "$rc"
    out=$(maintain --renew); rc=$?
    rc_is 'renew may omit an expired certificate' 0 "$rc"
    rc_is 'expired entry left the CRL' 0 "$(crl_count "$CRL")"
}

test_crl_bad_signature_is_rejected() {
    # OpenSSL 3.0 may print "verify failure" and exit 0: neither Diagnostics nor the maintainer may accept it.
    local out
    openssl crl -in "$CRL" -badsig -out "$E/bad-signature.pem"
    cp "$E/bad-signature.pem" "$CRL"
    out=$(lib_verify); rc_is 'a parseable CRL with a bad signature is rejected' 1 "$?"
    has 'the signature failure is named' 'CRL signature verification failed' "$out"
    out=$(maintain --check); rc_is 'the maintainer refuses it too' 1 "$?"
    out=$(mgr status); rc_is 'Diagnostics refuse it too' 1 "$?"
    has 'Diagnostics name the signature failure' 'CRL signature verification failed' "$out"
}

test_garbage_published_crl_never_blocks_repair() {
    local out rc
    echo garbage > "$CRL"
    out=$(maintain --check); rc=$?
    rc_not0 'garbage CRL detected' "$rc"
    out=$(revoke_menu alice)
    has 'emergency revoke still works' 'alice is revoked.' "$out"
    out=$(maintain --check); rc_is 'CRL healthy again' 0 "$?"
}

test_dotted_name_is_fully_managed() {
    local out serial
    easyrsa build-client-full john.doe nopass
    publish_now
    serial=$(serial_of "$PKI/issued/john.doe.crt")
    out=$(mgr list)
    has 'list shows the dotted name (C-02)' 'john.doe' "$out"
    has 'list counts it' '2 valid' "$out"
    has 'header agrees with the list' '2 valid' "$(menu '0\n')"
    out=$(menu '5\njohn.doe\n2\n0\n')
    has 're-export works' 'Profile for "john.doe" rebuilt' "$out"
    ok_if 'profile written' test -s "$E/clients/john.doe.ovpn"
    has 'download offers it' 'john.doe' "$(menu '5\n\n0\n')"
    out=$(revoke_menu john.doe)
    has 'revoke works' 'john.doe is revoked.' "$out"
    ok_if 'CRL lists it' crl_lists "$CRL" "$serial"
    out=$(menu '1\nnew.dotted\n\n0\n')
    has 'new names stay strict' 'Use 1-64 letters' "$out"
}

test_reissued_name_revokes_the_valid_certificate() {
    local out old_serial new_serial
    old_serial=$(serial_of "$PKI/issued/alice.crt")
    easyrsa revoke alice; publish_now
    easyrsa build-client-full alice nopass
    new_serial=$(serial_of "$PKI/issued/alice.crt")
    out=$(mgr list)
    has 'list shows the valid certificate (C-02)' 'VALID' "$out"
    lacks 'the default list leaves the history out' 'REVOKED' "$out"
    has 'list --all shows the revoked history' 'REVOKED' "$(mgr list --all)"
    out=$(menu '5\nalice\n2\n0\n')
    has 're-export works' 'Profile for "alice" rebuilt' "$out"
    grep -q "$(openssl x509 -in "$PKI/issued/alice.crt" -outform PEM | sed -n 2p)" "$E/clients/alice.ovpn"
    rc_is 'the profile holds the new certificate' 0 "$?"
    out=$(revoke_menu alice)
    has 'revoke works' 'alice is revoked.' "$out"
    ok_if 'CRL lists the new serial' crl_lists "$CRL" "$new_serial"
    ok_if 'CRL keeps the old serial' crl_lists "$CRL" "$old_serial"
    rc_is 'both records are revoked' RR "$(state_row alice)"
    out=$(menu '4\n0\n')
    has 'nothing left to revoke' 'No clients are available' "$out"
}

test_stale_certificate_file_is_refused_with_a_reason() {
    local out
    cp "$PKI/issued/alice.crt" "$E/old.crt"
    easyrsa revoke alice; publish_now
    easyrsa build-client-full alice nopass
    # The file on disk is the OLD, revoked certificate, while the index lists a new valid one.
    cp "$E/old.crt" "$PKI/issued/alice.crt"
    out=$(menu '4\n0\n')
    has 'revoke explains (C-02)' 'is not the certificate the CA lists as valid' "$out"
    out=$(menu '5\n0\n')
    has 're-export explains' 'is not the certificate the CA lists as valid' "$out"
    ok_if 'no profile built from the revoked certificate' test ! -e "$E/clients/alice.ovpn"
    has 'list explains' 'cannot be revoked here' "$(mgr list)"
}

test_blocked_valid_certificates_are_visible() {
    local out
    # This builds states the real Easy-RSA refuses to create: a repeated name and a name with a space.
    if [[ -n ${DARBAN_REAL_EASYRSA:-} ]]; then return 0; fi
    easyrsa build-client-full bob nopass
    rm "$PKI/issued/bob.crt"
    easyrsa build-client-full carol nopass
    easyrsa build-client-full carol nopass
    bash -c 'cd "$EASYRSA_PKI"
        openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout private/x.key -out x.csr -subj "/CN=has space" 2>/dev/null
        openssl ca -batch -config openssl.cnf -extensions client -in x.csr -out x.crt -notext -days 825 2>/dev/null
        rm -f x.csr x.crt issued/[0-9A-F]*.pem'
    # A second server-capable certificate that is not the one OpenVPN runs with.
    easyrsa build-server-full spare nopass
    out=$(mgr list)
    has 'missing file: listed (C-02)' 'bob' "$out"
    has 'missing file: explained' 'bob cannot be revoked here: pki/issued/bob.crt is missing' "$out"
    has 'duplicate valid: explained' 'carol cannot be revoked here: several valid' "$out"
    has 'unsupported name: listed' 'has space' "$out"
    has 'unsupported name: explained' 'has space cannot be revoked here' "$out"
    has 'server-capable: explained' 'spare cannot be revoked here: this certificate can act as a server' "$out"
    has 'list count matches every valid record' '6 valid' "$out"
    has 'header count matches the list' '6 valid' "$(menu '0\n')"
    out=$(menu '4\n\n0\n')
    has 'picker still offers alice' 'alice' "$out"
    has 'picker gives the reasons apart' 'Valid, but not available for this action:' "$out"
    has 'picker explains bob' 'bob: pki/issued/bob.crt is missing' "$out"
    out=$(menu '4\nbob\n\n0\n')
    has 'a blocked name cannot be picked' 'is not in the list above' "$out"
}

test_failed_crl_after_revoke_can_be_finished() {
    local out rc serial
    menu '5\nalice\n2\n0\n' >/dev/null
    ok_if 'export exists' test -s "$E/clients/alice.ovpn"
    serial=$(serial_of "$PKI/issued/alice.crt")
    out=$(printf '4\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" 2>&1)
    has 'the failure is urgent (R-03)' 'OpenVPN can still accept it' "$out"
    has 'the next step is named' 'sudo darban repair-crl' "$out"
    lacks 'no false success' 'alice is revoked.' "$out"
    rc_is 'the CA already marked it' R "$(state_row alice)"

    out=$(menu '0\n')
    has 'header names the client after a restart' 'NOT blocked yet: alice' "$out"
    has 'list names the client' 'NOT blocked yet: alice' "$(mgr list)"
    has 'status names the client' 'NOT blocked yet: alice' "$(mgr status)"
    has 'revoke menu points to the repair' 'Finish this first' "$(menu '4\n0\n')"

    out=$(FAIL_GENCRL=1 mgr repair-crl); rc=$?
    rc_not0 'a failed repair reports failure' "$rc"
    has 'still pending after the failed repair' 'NOT blocked yet: alice' "$(menu '0\n')"
    ok_if 'export kept until the repair succeeds' test -s "$E/clients/alice.ovpn"

    : > "$STUB_LOG"
    out=$(mgr repair-crl); rc=$?
    rc_is 'repair succeeds' 0 "$rc"
    has 'repair reports success' 'The CRL is repaired.' "$out"
    ok_if 'CRL now lists the client' crl_lists "$CRL" "$serial"
    ok_if 'server copy deleted' test ! -e "$E/clients/alice.ovpn"
    has 'the session step runs' 'cannot start new connections' "$out"
    grep -q 'CRL repaired' "$STUB_LOG"; rc_is 'repair is audited' 0 "$?"
    out=$(menu '0\n')
    lacks 'alert gone' 'NOT blocked' "$out"
    has 'header healthy' 'valid' "$out"
    has 'a second repair has nothing to do' 'Nothing to repair' "$(mgr repair-crl)"
}

test_repair_runs_from_the_settings_menu() {
    local out
    printf '4\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" >/dev/null 2>&1
    out=$(menu '8\n2\n\n0\n')
    has 'menu item exists' 'Fix the blocklist (CRL), or finish a revocation' "$out"
    has 'menu item repairs' 'The CRL is repaired.' "$out"
}

test_timer_repair_leaves_a_visible_unfinished_revocation() {
    local out rc
    menu '5\nalice\n2\n0\n' >/dev/null
    printf '4\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" >/dev/null 2>&1
    out=$(maintain --auto); rc=$?
    rc_is 'timer repairs the CRL' 0 "$rc"
    ok_if 'export is still there' test -s "$E/clients/alice.ovpn"
    out=$(menu '0\n')
    lacks 'nothing is pending any more' 'NOT blocked' "$out"
    has 'the leftover is flagged' 'profile still on server: alice' "$out"
    out=$(mgr repair-crl); rc=$?
    rc_is 'repair finishes it' 0 "$rc"
    ok_if 'server copy deleted' test ! -e "$E/clients/alice.ovpn"
    has 'the session step runs' 'cannot start new connections' "$out"
    has 'completion is reported' 'unfinished revocation is complete' "$out"
}

test_restart_from_settings() {
    local out
    : > "$STUB_LOG"
    out=$(menu '8\n3\n1\n0\n0\n')
    has 'menu item exists' '3  Restart OpenVPN' "$out"
    has 'it warns about all users' 'drops ALL connected VPN users' "$out"
    has 'option 1 cancels' 'Cancelled; nothing changed' "$out"
    if grep -q 'systemctl restart' "$STUB_LOG"; then result 0 'option 1 does not restart'; else result 1 'option 1 does not restart'; fi

    out=$(menu '8\n3\n2\n0\n0\n')
    has 'option 2 restarts and checks the port' 'listening on UDP 1194' "$out"
    grep -q 'systemctl restart' "$STUB_LOG"; rc_is 'the service was restarted' 0 "$?"
    grep -q 'OpenVPN restarted from the menu' "$STUB_LOG"; rc_is 'the restart is audited' 0 "$?"

    out=$(printf '8\n3\n2\n0\n0\n' | FAIL_RESTART=1 bash "$E/manager.sh" 2>&1)
    has 'a failed restart is urgent and names the log' 'journalctl -u openvpn-server@server.service' "$out"
    lacks 'a failed restart reports no success' 'listening on UDP' "$out"
    grep -q 'restart from the menu FAILED' "$STUB_LOG"; rc_is 'the failure is audited' 0 "$?"
}

test_revoked_name_can_be_issued_again() {
    local out old new
    old=$(serial_of "$PKI/issued/alice.crt")
    revoke_menu alice >/dev/null

    out=$(menu '1\nalice\n0\n')
    has 'no question is asked: one line explains it' 'old .ovpn files stay blocked' "$out"
    lacks 'nothing to confirm without per-client settings' 'Choose [1-2' "$out"
    has 'the new certificate is issued' 'Client "alice" created and verified' "$out"
    ok_if 'a new profile is written' test -s "$E/clients/alice.ovpn"
    new=$(serial_of "$PKI/issued/alice.crt")
    [[ $new != "$old" ]]; rc_is 'the new certificate has its own serial' 0 "$?"
    rc_is 'old record stays revoked, new one valid' RV "$(state_row alice)"
    ok_if 'the CRL still lists the old serial' crl_lists "$CRL" "$old"
    if crl_lists "$CRL" "$new"; then result 0 'the CRL does not list the new serial'; else result 1 'the CRL does not list the new serial'; fi
    out=$(maintain --check); rc_is 'the CRL stays healthy' 0 "$?"
    grep -q 'client created again with a used name: alice' "$STUB_LOG"; rc_is 'reuse is audited' 0 "$?"

    out=$(menu '1\nalice\n\n0\n')
    has 'a name with a valid certificate is refused' 'it still has a valid certificate' "$out"

    out=$(revoke_menu alice)
    has 'the new certificate can be revoked too' 'alice is revoked.' "$out"
    rc_is 'both records are revoked' RR "$(state_row alice)"
    ok_if 'the CRL lists both serials' crl_lists "$CRL" "$new"
}

test_name_reuse_requires_a_finished_revocation() {
    local out
    menu '5\nalice\n2\n0\n' >/dev/null
    printf '4\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" >/dev/null 2>&1
    out=$(menu '1\nalice\n\n0\n')
    has 'refused while the old certificate is not blocked' 'the published CRL has a problem' "$out"
    ok_if 'nothing issued' test ! -e "$PKI/issued/alice.crt"

    maintain --auto >/dev/null
    out=$(menu '1\nalice\n\n0\n')
    has 'refused while the revocation is unfinished' 'its revocation is unfinished' "$out"
    mgr repair-crl >/dev/null

    mkdir -p "$PKI/reqs"; : > "$PKI/reqs/alice.req"
    out=$(menu '1\nalice\n\n0\n')
    has 'refused while an old request file exists' 'pki/reqs/alice.req is still there' "$out"
    rm "$PKI/reqs/alice.req"

    out=$(menu '1\nalice\n0\n')
    has 'allowed once everything is finished' 'Client "alice" created and verified' "$out"
}

test_name_reuse_asks_only_when_server_settings_exist() {
    local out
    revoke_menu alice >/dev/null
    mkdir -p "$E/server/ccd"; echo 'ifconfig-push 10.8.0.50 255.255.255.0' > "$E/server/ccd/alice"
    echo 'client-config-dir ccd' >> "$SERVER_CONF"
    out=$(menu '1\nalice\n1\n\n0\n')
    has 'the settings file is named' 'ccd/alice and will apply to the new certificate' "$out"
    ok_if 'answering No issues nothing' test ! -e "$PKI/issued/alice.crt"
    rc_is 'answering No leaves the index alone' R "$(state_row alice)"
    out=$(menu '1\nalice\n2\n0\n')
    has 'answering Yes issues it' 'Client "alice" created and verified' "$out"
}

test_case_warning_only_for_valid_clients() {
    local out
    if [[ ! -e "$PKI/issued/ALICE.crt" ]]; then
        out=$(menu '1\nALICE\n1\n\n0\n')
        has 'warns about a valid client with the same letters' 'differing only in letter case: alice' "$out"
    fi
    revoke_menu alice >/dev/null
    out=$(menu '1\nAlice\n0\n')
    lacks 'a revoked client does not cause the warning' 'letter case' "$out"
    has 'the client is created' 'Client "Alice" created and verified' "$out"
}

test_list_hides_revoked_unless_asked() {
    local out rc
    menu '1\nbob\n0\n' >/dev/null
    revoke_menu bob >/dev/null
    out=$(mgr list)
    lacks 'default list hides the revoked client' 'REVOKED' "$out"
    has 'default list still shows active clients' 'alice' "$out"
    has 'the summary still counts it' '1 valid · 1 revoked' "$out"
    has 'it says how to see them' 'sudo darban list --all' "$out"
    out=$(mgr list --all)
    has 'list --all shows it' 'REVOKED' "$out"
    has 'list --all names it' 'bob' "$out"
    has 'the header still counts it' '1 revoked' "$(menu '0\n')"
    out=$(mgr status --all); rc=$?
    rc_is '--all is refused elsewhere' 2 "$rc"
    revoke_menu alice >/dev/null
    out=$(mgr list)
    has 'only revoked clients: says so' 'No active clients' "$out"
    has 'only revoked clients: still counts them' '2 revoked' "$out"
}

test_menu_groups_profile_files_together() {
    local out
    out=$(menu '0\n')
    has 'creating a client comes first' '1  Create client' "$out"
    has 'who is connected sits with clients' '3  Connected now' "$out"
    has 'revoke ends the clients group' '4  Revoke client' "$out"
    has 'sharing has its own group' 'SHARING' "$out"
    has 'sharing is in that group' '5  Share a profile' "$out"
    has 'links and files are one item, with what it does' '6  Links and files (show, cancel, delete)' "$out"
    out=$(menu '7\n0\n0\n')
    has 'settings holds the address' 'Server address' "$out"
    has 'settings groups what sharing needs' $'SHARING\n    3  Shares expire after' "$out"
    has 'the link port is there' '4  Link port' "$out"
    has 'advanced comes last' '6  Advanced' "$out"
    lacks 'settings no longer holds maintenance' 'Restart OpenVPN' "$out"
    lacks 'advanced no longer holds the link port' 'Share link port' "$(menu '7\n6\n0\n0\n0\n')"
    out=$(menu '8\n1\n0\n0\n')
    has 'maintenance runs diagnostics' 'Revocation (CRL)' "$out"
    has 'maintenance says what it is for' 'fix what a revocation left unfinished' "$out"
    out=$(menu '0\n')
    has 'a healthy blocklist is one word on the server line' 'blocklist ✓' "$(grep -E '^  Server' <<<"$out")"
    lacks 'and has no line of its own' 'Blocklist' "$out"
    has 'the hints are one line' 'An empty answer or Ctrl+C cancels' "$out"
    has 'the notice reads on or off' 'Update notice            off' "$(menu '9\n0\n0\n')"
    lacks 'maintenance no longer lists who is connected' '4  Connected now' "$(menu '8\n0\n0\n')"
}

test_links_and_files() {
    # Menu 6: open links, then files on the server. A row opens what can be done with it; its number alone
    # removes nothing.
    local out url
    start_links_stub
    menu '1\nbob\n0\n' >/dev/null
    url=$(menu '5\nalice\n1\n1\n0\n' | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
    out=$(menu '6\n\n0\n')
    has 'it says how long each one stays' 'A link works until its time is up, or until the client connects.' "$out"
    has 'links have their own group' $'OPEN LINKS\n    1  alice' "$out"
    has 'with the time left' '24 h left' "$out"
    has 'and whether it was downloaded' 'not downloaded yet' "$out"
    has 'files have theirs' $'FILES ON THE SERVER\n    2  bob' "$out"
    out=$(menu '6\n1\n\n0\n')
    has 'a row shows what can be done' 'Show the link again and copy it' "$out"
    ok_if 'and choosing Back removes nothing' test -n "$(find "$E/links" -name '*.meta')"
    out=$(menu '6\n1\n1\n0\n')
    has 'the link is shown again' $'Link:\n'"$url" "$out"
    out=$(menu '6\n2\n1\n0\n')
    has 'a file shows its download commands again' 'USERPROFILE' "$out"
    ok_if 'and stays' test -s "$E/clients/bob.ovpn"
    out=$(menu '6\n2\n2\n2\n0\n')
    has 'a file is deleted after asking' "Deleted: $E/clients/bob.ovpn" "$out"
    ok_if 'it is gone' test ! -e "$E/clients/bob.ovpn"
    has 'a link is cancelled' 'Link for "alice" cancelled.' "$(menu '6\n1\n2\n0\n')"
    ok_if 'with its saved address' test -z "$(find "$E/links" -name '*.url')"
    has 'then the list is empty' 'No open links and no files on the server' "$(menu '6\n0\n')"
    stop_links_stub
}

test_setup_menu_and_commands() {
    local out rc
    out=$(menu '0\n')
    has 'the main menu offers setup' '9  Setup (update, uninstall, remove all)' "$out"
    out=$(menu '9\n0\n0\n')
    has 'setup shows the installed version' "installed: v$(cat "$REPO/VERSION")" "$out"
    has 'help names the commands' 'uninstall  remove this tool' "$(bash "$E/manager.sh" help </dev/null 2>&1)"
    [[ $(bash "$E/manager.sh" version </dev/null 2>&1) == "$(cat "$REPO/VERSION")" ]]; rc_is 'VERSION matches the manager' 0 "$?"
}

fake_release() {
    # A release directory served by a stand-in curl; its installer only leaves a marker.
    local fixture=$E/fixture
    RELEASE=$E/release; MARKER=$E/installed
    mkdir -p "$fixture/setup" "$RELEASE"
    printf '#!/usr/bin/env bash\necho "installer ran" > "$MARKER"\n' > "$fixture/setup/install.sh"
    echo 9.9.9 > "$fixture/VERSION"
    tar -C "$fixture" -czf "$RELEASE/darban-ovpn.tar.gz" setup VERSION
    (cd "$RELEASE" && sha256sum darban-ovpn.tar.gz > SHA256SUMS)
    echo 9.9.9 > "$RELEASE/VERSION"
    cat > "$E/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=''; url=''; hdr=''
while (( $# )); do case $1 in -o) out=$2; shift 2 ;; --proto|--proto-redir|--tlsv1.2|--retry|--max-time) if [[ $1 == --tlsv1.2 ]]; then shift; else shift 2; fi ;; -D) hdr=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "curl $url" >> "$STUB_LOG"
if [[ -n ${hdr:-} && -n ${FAKE_HEADERS:-} ]]; then printf '%b' "$FAKE_HEADERS" > "$hdr"; fi
if [[ -n ${CURL_FAIL:-} ]]; then exit "${CURL_RC:-22}"; fi
if [[ -n $out ]]; then cp "$RELEASE/${url##*/}" "$out"; else cat "$RELEASE/${url##*/}"; fi
STUB
    chmod +x "$E/bin/curl"
    # The test user is not root; everything else in get.sh runs unchanged.
    sed -e 's/^\( *\)\[\[ \$EUID == 0 \]\] .*/\1:/' -e "s#^SERVER_CONF=.*#SERVER_CONF=$SERVER_CONF#" \
        -e "s#^TOOL=.*#TOOL=$E/fake-tool#" -e "s#^SETUP_RECORD=.*#SETUP_RECORD=$E/cfg/.server-setup-started#" \
        -e "s#^INSTALL_RECORD=.*#INSTALL_RECORD=$E/install-record#" "$REPO/setup/get.sh" > "$E/get.sh"
    export RELEASE MARKER
}

test_get_sh_verifies_before_installing() {
    local out rc
    fake_release
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_is 'a good release installs' 0 "$rc"
    ok_if 'the installer ran' test -s "$MARKER"
    grep -q 'releases/latest/download/darban-ovpn.tar.gz' "$STUB_LOG"; rc_is 'default is the latest release' 0 "$?"

    rm -f "$MARKER"; : > "$STUB_LOG"
    out=$(bash "$E/get.sh" --version v1.2.3 2>&1 </dev/null)
    grep -q 'releases/download/v1.2.3/' "$STUB_LOG"; rc_is 'a version can be pinned' 0 "$?"
    : > "$STUB_LOG"
    out=$(bash "$E/get.sh" --version v1.2.3-rc.1 2>&1 </dev/null)
    grep -q 'releases/download/v1.2.3-rc.1/' "$STUB_LOG"; rc_is 'a pre-release can be pinned' 0 "$?"
    out=$(bash "$E/get.sh" --version 'v1;reboot' 2>&1 </dev/null); rc=$?
    rc_not0 'a malformed version is refused' "$rc"

    rm -f "$MARKER"
    echo tampered >> "$RELEASE/darban-ovpn.tar.gz"
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_not0 'a changed archive is refused' "$rc"
    has 'it says why' 'Checksum mismatch' "$out"
    ok_if 'the installer did not run' test ! -e "$MARKER"

    : > "$RELEASE/SHA256SUMS"
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_not0 'a release without a checksum is refused' "$rc"
    ok_if 'the installer did not run' test ! -e "$MARKER"

    fake_release
    CURL_FAIL=1 out=$(CURL_FAIL=1 bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_not0 'a failed download is reported' "$rc"
    ok_if 'the installer did not run' test ! -e "$MARKER"
}

test_get_sh_sets_up_a_server_only_when_there_is_none() {
    local out rc
    fake_release
    printf '#!/usr/bin/env bash\necho "server setup ran" >> "$MARKER.setup"\n' > "$E/fixture/setup/server-setup.sh"
    tar -C "$E/fixture" -czf "$RELEASE/darban-ovpn.tar.gz" setup VERSION
    (cd "$RELEASE" && sha256sum darban-ovpn.tar.gz > SHA256SUMS)
    # The test has no terminal, so the fallback to the real terminal is replaced by the test's stdin.
    sed -i 's#</dev/tty#</dev/null#' "$E/get.sh"

    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_is 'an existing server installs' 0 "$rc"
    ok_if 'an existing server skips the server setup' test ! -e "$MARKER.setup"
    ok_if 'the installer ran' test -s "$MARKER"

    rm -f "$MARKER"; mv "$SERVER_CONF" "$E/conf.keep"
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_is 'a cancelled server setup ends cleanly' 0 "$rc"
    ok_if 'a blank server runs the server setup' test -s "$MARKER.setup"
    ok_if 'no server: the installer does not run' test ! -e "$MARKER"
    mv "$E/conf.keep" "$SERVER_CONF"
}

test_update_from_the_menu() {
    local out
    fake_release
    # The installed copy of get.sh, as setup/install.sh places it.
    cp "$E/get.sh" "$E/lib/get.sh"
    # A final version, which is offered only final versions.
    set_installed_version 1.0.0
    out=$(menu '9\n2\n1\n0\n0\n')
    has 'the new version is offered' 'Install v9.9.9' "$out"
    has 'option 1 keeps this version' 'Cancelled; nothing changed' "$out"
    ok_if 'nothing was installed' test ! -e "$MARKER"

    echo "$(cat "$REPO/VERSION")" > "$RELEASE/VERSION"
    out=$(menu '9\n2\n0\n0\n')
    has 'same version: nothing to do' 'This is the latest version' "$out"
    echo 0.0.1 > "$RELEASE/VERSION"
    out=$(menu '9\n2\n0\n0\n')
    has 'an older release is never offered' 'This is the latest version' "$out"
    echo 'not a version' > "$RELEASE/VERSION"
    out=$(menu '9\n2\n0\n0\n')
    has 'a bad version file is refused' 'does not state a valid version' "$out"
    out=$(CURL_FAIL=1 CURL_RC=6 bash "$E/manager.sh" update </dev/null 2>&1)
    has 'no network is reported' 'Could not reach GitHub' "$out"
    out=$(CURL_FAIL=1 bash "$E/manager.sh" update </dev/null 2>&1)
    has 'no stable release is reported as that' 'No stable release is published yet' "$out"

    echo 9.9.9 > "$RELEASE/VERSION"
    out=$(bash "$E/manager.sh" update 2>&1 <<<'9.9.9')
    has 'confirming installs the release' 'Updated to v9.9.9' "$out"
    ok_if 'the installer ran' test -s "$MARKER"
}

test_uninstall_removes_only_the_tool() {
    local out rc lib=$E/fake-lib sbin=$E/fake-sbin units=$E/fake-units before
    mkdir -p "$lib" "$sbin" "$units"
    : > "$lib/common.sh"; : > "$sbin/darban"; : > "$sbin/darban-crl-maintain"
    : > "$units/darban-crl.timer"; : > "$units/darban-crl.service"
    : > "$units/openvpn-server@.service"
    sed -e "s#^LIB=.*#LIB=$lib#" -e "s#^SBIN=.*#SBIN=$sbin#" -e "s#^UNITS=.*#UNITS=$units#" \
        -e 's/^\[\[ \$EUID == 0 \]\] .*/:/' "$REPO/setup/uninstall.sh" > "$E/lib/uninstall.sh"
    before=$(cat "$PKI/index.txt" "$CRL" "$SERVER_CONF" | sha256sum)

    out=$(bash "$E/lib/uninstall.sh" 2>&1 </dev/null); rc=$?
    rc_is 'the script alone needs --yes' 2 "$rc"
    ok_if 'nothing removed without --yes' test -e "$sbin/darban"

    out=$(menu '9\n5\n1\n0\n0\n')
    has 'the CRL consequence is stated' 'Nothing will renew the CRL' "$out"
    has 'option 1 keeps the tool' 'Cancelled; nothing changed' "$out"
    ok_if 'nothing removed on No' test -e "$sbin/darban"

    out=$(bash "$E/manager.sh" uninstall 2>&1 <<<'uninstall')
    has 'confirming removes the tool' 'was removed' "$out"
    ok_if 'the tool is gone' test ! -e "$sbin/darban"
    ok_if 'the library is gone' test ! -e "$lib"
    ok_if 'the timer is gone' test ! -e "$units/darban-crl.timer"
    ok_if 'other units stay' test -e "$units/openvpn-server@.service"
    [[ $before == "$(cat "$PKI/index.txt" "$CRL" "$SERVER_CONF" | sha256sum)" ]]; rc_is 'PKI, CRL and server.conf are untouched' 0 "$?"
}

prepare_blank_server() {
    # A fresh Ubuntu stand-in, 24.04 unless a test changes it: no server.conf, no PKI, and stubs for what the setup calls.
    # Easy-RSA is the same stand-in as elsewhere, restored from a template PKI at init-pki.
    local conf_dir=$E/setup-root
    mv "$PKI" "$E/pki-template"
    rm -f "$SERVER_CONF" "$CRL" "$E/server/server.crt" "$E/server/tls-crypt.key" "$E/cfg/domain" "$E/cfg/config"
    mkdir -p "$conf_dir/keyrings" "$conf_dir/sources" "$conf_dir/sysctl" "$conf_dir/modules" "$conf_dir/units" "$E/setup"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$conf_dir/os-release"
    cat > "$E/bin/easyrsa-setup" <<STUB
#!/usr/bin/env bash
case \$1 in
  init-pki) cp -r "$E/pki-template" "$PKI"; rm -f "$PKI/issued/alice.crt" ;;
  build-ca) ;;
  *) exec bash "$E/bin/easyrsa" "\$@" ;;
esac
STUB
    cat > "$E/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
# FAIL_APT_REMOVE: a real "remove" fails, as when dpkg is broken.
if [[ -n ${FAIL_APT_REMOVE:-} && " $* " != *" -s "* && " $* " == *" remove "* ]]; then exit 100; fi
if [[ " $* " == *" -s "* ]]; then
    case " $* " in
      *" purge "*) on=0; for a; do if (( on )); then echo "Remv $a"; fi; [[ $a == purge ]] && on=1; done; if [[ -n ${REMV_EXTRA:-} ]]; then echo "Remv $REMV_EXTRA"; fi ;;
      *" remove "*) on=0; for a; do if (( on )); then echo "Remv $a"; fi; [[ $a == remove ]] && on=1; done; if [[ -n ${REMV_EXTRA_REMOVE:-} ]]; then echo "Remv $REMV_EXTRA_REMOVE"; fi ;;
      *" autoremove "*) for a in ${AUTOREMOVE:-}; do echo "Remv $a"; done ;;
      *" install openvpn "*) for a in openvpn easy-rsa socat nftables liblzo2-2; do echo "Inst $a"; done; if [[ -n ${APT_UPGRADE:-} ]]; then echo "Inst dep-$APT_UPGRADE [1.0] (2.0 Ubuntu [amd64])"; fi ;;
      *" install certbot "*) echo 'Inst certbot'; echo 'Inst python3-certbot' ;;
      *) printf '%s\n' ${APT_PLAN:-Inst linux-image-virtual-hwe-24.04 Inst linux-modules-7.0.0-42-generic} | awk 'NR%2==1 {a=$0; next} {print a, $0}'; if [[ -n ${APT_UPGRADE:-} ]]; then echo "Inst $APT_UPGRADE [1.0] (2.0 Ubuntu [amd64])"; fi ;;
    esac
fi
exit 0
STUB
    cat > "$E/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
name=${!#}
if [[ -n ${KERNEL_PRESENT:-} && $name == linux-image-virtual-hwe-24.04 ]]; then printf 'install ok installed'; exit 0; fi
for p in ${INSTALLED_PKGS:-}; do if [[ $p == "$name" ]]; then printf 'install ok installed'; exit 0; fi; done
exit 1
STUB
    printf '#!/usr/bin/env bash\necho amd64\n' > "$E/bin/dpkg"
    # certbot for links: Ubuntu's is older than 5.3, so an IP address takes the snap.
    printf '#!/usr/bin/env bash\necho "apt-cache $*" >> "$STUB_LOG"\nif [[ $1 == policy ]]; then echo "  Candidate: ${FAKE_CERTBOT_CANDIDATE:-2.9.0-1}"; fi\n' > "$E/bin/apt-cache"
    fake_snap
    cat > "$E/bin/openvpn" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then echo "OpenVPN ${FAKE_OPENVPN_VERSION:-2.7.8} x86_64-pc-linux-gnu"; exit 0; fi
if [[ $1 == --genkey ]]; then echo 'tls-crypt key' > "$3"; exit 0; fi
STUB
    cat > "$E/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *ipify* || " $* " == *ifconfig.me* ]]; then if [[ -n ${FAKE_PUBLIC_IP:-} ]]; then echo "$FAKE_PUBLIC_IP"; exit 0; fi; exit 6; fi
while (( $# )); do if [[ $1 == -o ]]; then echo '-----BEGIN PGP PUBLIC KEY BLOCK-----' > "$2"; fi; shift; done
STUB
    cat > "$E/bin/ip" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" route get "*) echo "1.1.1.1 via 192.0.2.1 dev eth0 src ${FAKE_LOCAL_IP:-203.0.113.50} uid 0" ;;
  *" route show default "*) echo 'default via 192.0.2.1 dev eth0 proto dhcp' ;;
  *" route show "*) printf 'default via 192.0.2.1 dev eth0\n192.0.2.0/24 dev eth0\n172.20.0.0/16 dev docker0\n'; if [[ -n ${FAKE_ROUTE:-} ]]; then echo "$FAKE_ROUTE dev tun7"; fi ;;
esac
STUB
    for stub in nft modprobe; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$stub" > "$E/bin/$stub"; done
    printf '#!/usr/bin/env bash\necho "sysctl $*" >> "$STUB_LOG"\nif [[ ${1:-} == -n ]]; then echo "${FORWARD_BEFORE:-0}"; fi\n' > "$E/bin/sysctl"
    printf '#!/usr/bin/env bash\nif [[ -n ${FAKE_OVPN:-} ]]; then exit 0; fi\nexit 1\n' > "$E/bin/modinfo"
    printf '#!/usr/bin/env bash\nif [[ -n ${FAKE_CONTAINER:-} ]]; then exit 0; fi\nexit 1\n' > "$E/bin/systemd-detect-virt"
    printf '#!/usr/bin/env bash\nif [[ ${1:-} == -r ]]; then echo "${KERNEL_RUN:-6.8.0-50-generic}"; else exec /usr/bin/uname "$@"; fi\n' > "$E/bin/uname"
    chmod +x "$E/bin/"*
    sed -e 's/^\[\[ \$EUID == 0 \]\] .*/:/' -e 's/^    \[\[ \$EUID == 0 \]\] .*/    :/' \
        -e "s#^OS_RELEASE=.*#OS_RELEASE=$conf_dir/os-release#" -e "s#^PKI=.*#PKI=$PKI#" \
        -e "s#^EASYRSA_BIN=.*#EASYRSA_BIN=$E/bin/easyrsa-setup#" -e "s#^SERVER_DIR=.*#SERVER_DIR=$E/server#" \
        -e "s#^CONFIG_DIR=.*#CONFIG_DIR=$E/cfg#" -e "s#^APT_KEY=.*#APT_KEY=$conf_dir/keyrings/key.asc#" \
        -e "s#^APT_LIST=.*#APT_LIST=$conf_dir/sources/openvpn.list#" -e "s#^SYSCTL_FILE=.*#SYSCTL_FILE=$conf_dir/sysctl/darban.conf#" \
        -e "s#^MODULES_FILE=.*#MODULES_FILE=$conf_dir/modules/darban.conf#" -e "s#^NAT_UNIT=.*#NAT_UNIT=$conf_dir/units/nat.service#" \
        -e "s#^TOOL=.*#TOOL=$E/fake-sbin/darban#" -e "s#^TOOL_LIB=.*#TOOL_LIB=$conf_dir/lib#" -e "s#^SETUP_LOG=.*#SETUP_LOG=$E/setup.log#" \
        -e "s#^TUN_DEV=.*#TUN_DEV=\${FAKE_TUN:-/dev/null}#" "$REPO/setup/server-setup.sh" > "$E/setup/server-setup.sh"
    cp "$REPO/setup/remove-server.sh" "$REPO/setup/uninstall.sh" "$E/setup/"
    SETUP_ROOT=$conf_dir
}
setup_run() { bash "$E/setup/server-setup.sh" "$@" 2>&1 </dev/null; }

test_server_setup_builds_a_server_the_manager_accepts() {
    local out rc
    prepare_blank_server
    out=$(setup_run --host VPN.Example.COM --port 21194 --subnet 10.9.0.0 --dns '9.9.9.9 149.112.112.112' --yes); rc=$?
    rc_is 'setup finishes' 0 "$rc"
    has 'it names the kernel it will install' 'linux-image-virtual-hwe-24.04' "$out"
    has 'the plan warns nothing is hidden' 'adds the OpenVPN project apt repository' "$out"
    grep -q 'build.openvpn.net/debian/openvpn/stable noble main' "$SETUP_ROOT/sources/openvpn.list"; rc_is 'the stable OpenVPN channel is used' 0 "$?"
    grep -q -- '-y -q --no-install-recommends install openvpn easy-rsa socat nftables linux-image-virtual-hwe-24.04' "$STUB_LOG"; rc_is 'recommended packages are not installed' 0 "$?"
    if grep -q 'linux-headers\|linux-firmware\|linux-modules-extra' "$STUB_LOG"; then result 0 'no headers, firmware or extra modules are requested'; else result 1 'no headers, firmware or extra modules are requested'; fi
    grep -q 'masquerade' "$E/cfg/nat.nft"; rc_is 'NAT rule written' 0 "$?"
    grep -q 'oifname "eth0"' "$E/cfg/nat.nft"; rc_is 'NAT uses the default interface' 0 "$?"
    grep -q 'ip_forward=1' "$SETUP_ROOT/sysctl/darban.conf"; rc_is 'forwarding enabled' 0 "$?"
    if grep -Eq '^(compress|comp-lzo|fragment|tls-auth)' "$SERVER_CONF"; then result 0 'nothing in server.conf disables DCO'; else result 1 'nothing in server.conf disables DCO'; fi

    out=$(bash -c 'set -uo pipefail; source "$E/lib/common.sh"; darban_preflight && darban_crl_configured && darban_verify_crl "$DARBAN_CRL" && darban_server_serial >/dev/null' 2>&1); rc=$?
    rc_is 'the checks the installer runs accept this server' 0 "$rc"
    out=$(maintain --check); rc_is 'the CRL maintainer accepts it' 0 "$?"
    out=$(menu '1\nfirst\n0\n')
    has 'the manager creates a client on it' 'Client "first" created and verified' "$out"
    lacks 'the server certificate is not listed' 'darban-server' "$(mgr list)"
    has 'the profile uses the chosen address and port' 'remote vpn.example.com 21194' "$(cat "$E/clients/first.ovpn")"
    grep -q '^server 10.9.0.0 255.255.255.0' "$SERVER_CONF"; rc_is 'the chosen network is used' 0 "$?"
    grep -q 'dhcp-option DNS 9.9.9.9' "$SERVER_CONF"; rc_is 'the first DNS server is pushed' 0 "$?"
    grep -q 'dhcp-option DNS 149.112.112.112' "$SERVER_CONF"; rc_is 'the second DNS server is pushed' 0 "$?"
    grep -q 'redirect-gateway' "$SERVER_CONF"; rc_is 'full tunnel is the default' 0 "$?"
    grep -q '10.9.0.0/24' "$E/cfg/nat.nft"; rc_is 'NAT uses the chosen network' 0 "$?"
    grep -q 'DOWNLOAD_SSH_HOST=203.0.113.50' "$E/cfg/config"; rc_is 'downloads use the public IP' 0 "$?"
    has 'status sees the unix-socket management' 'Management interface' "$(mgr status)"

    out=$(setup_run --port 21194 --yes); rc=$?
    rc_not0 'a second run is refused' "$rc"
    has 'it says nothing changed' 'Nothing was changed' "$out"
}

test_server_setup_does_not_claim_upgraded_packages() {
    # A package apt only upgrades was already installed: a later removal must not purge it.
    local out rc
    prepare_blank_server
    out=$(APT_UPGRADE=bpftool setup_run --port 21194 --yes); rc=$?
    rc_is 'setup finishes' 0 "$rc"
    lacks 'an upgraded package is not shown as new' 'bpftool' "$out"
    if grep -q 'bpftool' "$E/cfg/.server-setup-started"; then result 0 'upgraded packages are not recorded for removal'; else result 1 'upgraded packages are not recorded for removal'; fi
    grep -q '^kernel linux-image-virtual-hwe-24.04$' "$E/cfg/.server-setup-started"; rc_is 'new kernel packages are still recorded' 0 "$?"
    grep -q '^dep liblzo2-2$' "$E/cfg/.server-setup-started"; rc_is 'new dependencies are still recorded' 0 "$?"
}

test_server_setup_follows_the_ubuntu_version() {
    local out rc
    prepare_blank_server
    printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$SETUP_ROOT/os-release"
    out=$(APT_PLAN='Inst linux-image-virtual-hwe-26.04 Inst linux-modules-7.0.0-42-generic' setup_run --port 21194 --yes); rc=$?
    rc_is 'setup finishes on Ubuntu 26.04' 0 "$rc"
    has 'it names the 26.04 kernel' 'linux-image-virtual-hwe-26.04' "$out"
    grep -q 'build.openvpn.net/debian/openvpn/stable resolute main' "$SETUP_ROOT/sources/openvpn.list"; rc_is 'the 26.04 OpenVPN repository is used' 0 "$?"
    grep -q -- 'nftables linux-image-virtual-hwe-26.04' "$STUB_LOG"; rc_is 'the 26.04 kernel is installed' 0 "$?"
    if grep -q 'hwe-24.04' "$STUB_LOG"; then result 0 'the 24.04 kernel is not requested'; else result 1 'the 24.04 kernel is not requested'; fi
    if grep -q 'noble' "$SETUP_ROOT/sources/openvpn.list"; then result 0 'the 24.04 repository is not used'; else result 1 'the 24.04 repository is not used'; fi
}

test_server_setup_refuses_or_changes_nothing() {
    local out rc
    prepare_blank_server
    printf 'ID=ubuntu\nVERSION_ID="22.04"\n' > "$SETUP_ROOT/os-release"
    out=$(setup_run --port 21194 --yes); rc=$?
    rc_not0 'another Ubuntu version is refused' "$rc"
    has 'it names the supported versions' 'Ubuntu 24.04 and 26.04 only' "$out"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$SETUP_ROOT/os-release"

    out=$(setup_run --port 80 --yes); rc=$?
    rc_not0 'a bad port is refused' "$rc"

    : > "$STUB_LOG"
    out=$(printf '\n21194\n3\n' | bash "$E/setup/server-setup.sh" 2>&1); rc=$?
    has 'Enter accepts the detected public IP' 'Address   203.0.113.50' "$out"
    rc_is 'answering No ends cleanly' 0 "$rc"
    has 'it says nothing changed' 'Cancelled; nothing was changed' "$out"
    ok_if 'no server.conf after No' test ! -e "$SERVER_CONF"
    ok_if 'no PKI after No' test ! -e "$PKI"
    if grep -q ' install openvpn' "$STUB_LOG"; then result 0 'nothing installed after No'; else result 1 'nothing installed after No'; fi

    out=$(APT_PLAN='Inst linux-image-virtual-hwe-24.04 Inst linux-firmware' setup_run --port 21194 --yes); rc=$?
    rc_not0 'a plan with firmware stops the setup' "$rc"
    has 'it says why' 'firmware or graphics' "$out"
    ok_if 'nothing was configured' test ! -e "$SERVER_CONF"

    out=$(FAKE_OPENVPN_VERSION=2.6.19 setup_run --port 21194 --yes); rc=$?
    rc_not0 'an old OpenVPN stops the setup' "$rc"
    has 'it names the version' 'but got 2.6.19' "$out"
    ok_if 'no server.conf with an old OpenVPN' test ! -e "$SERVER_CONF"
}

test_server_setup_questions() {
    local out rc
    prepare_blank_server
    out=$(setup_run --host 'bad_name!' --port 21194 --yes); rc=$?
    rc_not0 'a bad address is refused' "$rc"
    out=$(setup_run --host 999.1.1.1 --port 21194 --yes); rc=$?
    rc_not0 'an impossible IP is refused' "$rc"
    out=$(setup_run --subnet 8.8.8.0 --port 21194 --yes); rc=$?
    rc_not0 'a public network is refused' "$rc"
    out=$(setup_run --subnet 10.8.0.5 --port 21194 --yes); rc=$?
    rc_not0 'a network not ending in .0 is refused' "$rc"
    out=$(setup_run --subnet 172.20.5.0 --port 21194 --yes); rc=$?
    rc_not0 'an overlapping network is refused' "$rc"
    has 'it names the route' 'overlaps the existing route 172.20.0.0/16' "$out"
    out=$(setup_run --dns '1.1.1.1 8.8.8.8 9.9.9.9' --port 21194 --yes); rc=$?
    rc_not0 'three DNS servers are refused' "$rc"
    out=$(setup_run --dns 'not-an-ip' --port 21194 --yes); rc=$?
    rc_not0 'a bad DNS server is refused' "$rc"
    out=$(FAKE_TUN=/nonexistent setup_run --port 21194 --yes); rc=$?
    rc_not0 'a missing TUN device is refused' "$rc"
    has 'it says what to do' 'does not offer a TUN device' "$out"
    ok_if 'nothing was configured by the refusals' test ! -e "$SERVER_CONF"

    out=$(printf 'bad_name!\n10.0.0.5\n80\n21194\n2\n3\n' | bash "$E/setup/server-setup.sh" 2>&1); rc=$?
    rc_is 'wrong answers are asked again' 0 "$rc"
    has 'a private address gets a warning' 'private address' "$out"
    has 'the plan shows the address' '10.0.0.5' "$out"
    has 'the network is not asked: the default is shown' '10.8.0.0/24' "$out"
    has 'it says where to change the defaults' 'Settings' "$out"
    has 'the plan shows the default DNS' '1.1.1.1 8.8.8.8' "$out"

    out=$(setup_run --host 203.0.113.9 --port 21194 --split-tunnel --yes); rc=$?
    rc_is 'split tunnel finishes' 0 "$rc"
    if grep -q 'redirect-gateway\|dhcp-option' "$SERVER_CONF"; then result 0 'split tunnel pushes no route or DNS'; else result 1 'split tunnel pushes no route or DNS'; fi
    grep -qx '203.0.113.9' "$E/cfg/domain"; rc_is 'an IP address is saved as the client address' 0 "$?"
    lacks 'split tunnel has no DNS line' 'DNS  ' "$out"
}

test_server_setup_in_a_container_installs_no_kernel() {
    local out rc
    prepare_blank_server
    : > "$STUB_LOG"
    out=$(FAKE_CONTAINER=1 setup_run --port 21194 --yes); rc=$?
    rc_is 'setup finishes in a container' 0 "$rc"
    has 'it explains the host kernel' 'uses the host kernel' "$out"
    if grep -q 'linux-image' "$STUB_LOG"; then result 0 'no kernel is planned or installed'; else result 1 'no kernel is planned or installed'; fi
    has 'it does not ask for a reboot' 'this is a container' "$out"
}

test_server_setup_ufw_rules_are_asked_and_removed() {
    local out rc
    prepare_blank_server
    cat > "$E/bin/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >> "$STUB_LOG"
if [[ ${1:-} == status ]]; then echo 'Status: active'; fi
STUB
    chmod +x "$E/bin/ufw"
    : > "$STUB_LOG"
    out=$(setup_run --port 21194 --yes); rc=$?
    rc_is 'setup finishes with ufw active' 0 "$rc"
    if grep -q 'ufw allow' "$STUB_LOG"; then result 0 '--yes alone leaves ufw alone'; else result 1 '--yes alone leaves ufw alone'; fi
    has 'it prints the commands' 'ufw allow 21194/udp' "$out"

    fresh
    prepare_blank_server
    cat > "$E/bin/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >> "$STUB_LOG"
if [[ ${1:-} == status ]]; then echo 'Status: active'; fi
STUB
    chmod +x "$E/bin/ufw"
    : > "$STUB_LOG"
    out=$(setup_run --port 21194 --open-ufw --yes); rc=$?
    rc_is 'setup with --open-ufw finishes' 0 "$rc"
    grep -q 'ufw allow 21194/udp' "$STUB_LOG"; rc_is 'the port rule is added' 0 "$?"
    grep -q 'ufw route allow in on tun0 out on eth0' "$STUB_LOG"; rc_is 'the forwarding rule is added' 0 "$?"
    install_removal_scripts
    : > "$STUB_LOG"
    out=$(bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null); rc=$?
    rc_is 'removal finishes' 0 "$rc"
    grep -q 'ufw delete allow 21194/udp' "$STUB_LOG"; rc_is 'the port rule is removed' 0 "$?"
    grep -q 'ufw route delete allow in on tun0 out on eth0' "$STUB_LOG"; rc_is 'the forwarding rule is removed' 0 "$?"
}

test_server_certificate_expiry_is_in_the_header() {
    local out
    out=$(menu '0\n')
    lacks 'a long-lived server certificate gives no alert' 'Server certificate expires' "$out"
    sed -i 's/^EXPIRY_WARN_DAYS=.*/EXPIRY_WARN_DAYS=5000/' "$E/manager.sh"
    out=$(menu '0\n')
    has 'a certificate near expiry gives an alert' 'Server certificate expires' "$out"
}

test_port_change_reports_a_failed_rollback_truthfully() {
    local out
    cat > "$E/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
q=0; for a; do [[ $a == --quiet ]] && q=1; done
case " $* " in
  *" restart "*) exit 1 ;;
  *" is-failed "*) ((q)) || echo active; exit 1 ;;
  *" is-active "*) ((q)) || echo active; exit 0 ;;
esac
exit 0
STUB
    out=$(menu '7\n2\n21194\n21194\n0\n0\n')
    lacks 'it never claims the port did not change' 'The port was NOT changed' "$out"
    has 'it says the rollback did not finish' 'The rollback did not finish' "$out"
}

test_server_setup_keeps_an_existing_setup_safe() {
    local out rc
    prepare_blank_server
    mkdir -p "$PKI"
    out=$(setup_run --port 21194 --yes); rc=$?
    rc_not0 'a PKI it did not create is refused' "$rc"
    has 'it names the PKI' 'this setup did not create it' "$out"
    rm -rf "$PKI"

    : > "$STUB_LOG"
    out=$(KERNEL_PRESENT=1 setup_run --port 21194 --yes); rc=$?
    rc_is 'an installed kernel is fine' 0 "$rc"
    has 'it says so' 'is already installed' "$out"
    grep -q 'install openvpn easy-rsa socat nftables$' "$STUB_LOG"; rc_is 'the kernel is not installed again' 0 "$?"
}

install_removal_scripts() {
    # The scripts as install.sh places them, with every path pointing into this fake server.
    local root=$SETUP_ROOT
    mkdir -p "$E/fake-sbin" "$E/fake-units" "$E/backups" "$E/tool-backups" "$E/fake-lib"
    : > "$E/fake-sbin/darban"; : > "$E/fake-units/darban-crl.timer"; : > "$E/tool-backups/old"
    sed -e 's/^\[\[ \$EUID == 0 \]\] .*/:/' \
        -e "s#^PKI=.*#PKI=$PKI#" -e "s#^SERVER_DIR=.*#SERVER_DIR=$E/server#" -e "s#^OUT_DIR=.*#OUT_DIR=$E/clients#" \
        -e "s#^CONFIG_DIR=.*#CONFIG_DIR=$E/cfg#" -e "s#^APT_KEY=.*#APT_KEY=$root/keyrings/key.asc#" \
        -e "s#^APT_LIST=.*#APT_LIST=$root/sources/openvpn.list#" -e "s#^SYSCTL_FILE=.*#SYSCTL_FILE=$root/sysctl/darban.conf#" \
        -e "s#^MODULES_FILE=.*#MODULES_FILE=$root/modules/darban.conf#" -e "s#^NAT_UNIT=.*#NAT_UNIT=$root/units/nat.service#" \
        -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$E/backups#" -e "s#^TOOL_BACKUPS=.*#TOOL_BACKUPS=$E/tool-backups#" \
        -e "s#^SETUP_LOG=.*#SETUP_LOG=$E/setup.log#" -e "s#^LOCK_FILE=.*#LOCK_FILE=$E/run/lock#" \
        -e "s#^CERT_LOG=.*#CERT_LOG=$E/varlib/link-certificates.log#" -e "s#^EVENT_SCRIPT=.*#EVENT_SCRIPT=$E/libexec/darban-ovpn-event#" \
        -e "s#^LEDGER_DIR=.*#LEDGER_DIR=$E/varlib/clients#" "$REPO/setup/remove-server.sh" > "$E/lib/remove-server.sh"
    sed -e "s#^LIB=.*#LIB=$E/fake-lib#" -e "s#^SBIN=.*#SBIN=$E/fake-sbin#" -e "s#^UNITS=.*#UNITS=$E/fake-units#" \
        -e "s#^CONFIG_DIR=.*#CONFIG_DIR=$E/cfg#" -e "s#^LE_DIR=.*#LE_DIR=$E/le#" -e "s#^RENEW_HOOK=.*#RENEW_HOOK='$E/sbin/darban reload-links'#" \
        -e "s#^EVENT_SCRIPT=.*#EVENT_SCRIPT=$E/libexec/darban-ovpn-event#" \
        -e 's/^\[\[ \$EUID == 0 \]\] .*/:/' "$REPO/setup/uninstall.sh" > "$E/lib/uninstall.sh"
}
built_server() {
    prepare_blank_server
    # nftables was already on this server, so the setup must not count it as its own.
    INSTALLED_PKGS=nftables setup_run --port 21194 --yes >/dev/null
    install_removal_scripts
    menu '1\nfirst\n0\n' >/dev/null
}

test_remove_everything_removes_only_what_setup_added() {
    local out rc log
    built_server
    # Connection events: their script, their units and the record of when each client was seen go too.
    mkdir -p "$E/varlib/clients"; echo 'first_seen=1' > "$E/varlib/clients/first"; : > "$E/fake-units/darban-events.path"
    : > "$STUB_LOG"
    echo 'other tool data' > "$E/unrelated"

    out=$(printf '1\n1\n1\n' | bash "$E/manager.sh" remove-all 2>&1); rc=$?
    has 'it states the consequence' 'stops working for good' "$out"
    has 'answering No keeps everything' 'Cancelled; nothing changed' "$out"
    ok_if 'the CA stays after No' test -s "$PKI/ca.crt"
    ok_if 'no backup is made before the last answer' test -z "$(ls "$E/backups")"

    out=$(printf '1\n1\nremove-everything\n' | bash "$E/manager.sh" remove-all 2>&1); rc=$?
    rc_is 'full removal finishes' 0 "$rc"
    log=$(cat "$STUB_LOG")
    has 'the setup packages are purged' '-y -q purge easy-rsa openvpn socat' "$log"
    lacks 'a package that was already there stays' 'purge easy-rsa nftables' "$log"
    lacks 'a package that was already there stays (any order)' 'socat nftables' "$log"
    if grep -q 'autoremove$' <<<"$(grep -v -- ' -s ' <<<"$log")"; then result 0 'real autoremove is never run'; else result 1 'real autoremove is never run'; fi
    lacks 'the kernel stays unless asked' 'purge linux-' "$log"
    for path in "$PKI" "$E/server" "$E/clients" "$E/cfg" "$SETUP_ROOT/sources/openvpn.list" "$SETUP_ROOT/keyrings/key.asc" "$SETUP_ROOT/sysctl/darban.conf" "$SETUP_ROOT/modules/darban.conf" "$SETUP_ROOT/units/nat.service" "$E/fake-sbin/darban" "$E/fake-units/darban-crl.timer" "$E/tool-backups" "$E/libexec/darban-ovpn-event" "$E/varlib/clients" "$E/fake-units/darban-events.path"; do
        ok_if "gone: ${path##*/}" test ! -e "$path"
    done
    ok_if 'unrelated files stay' test -s "$E/unrelated"
    has 'forwarding goes back to what it was' 'net.ipv4.ip_forward=0' "$log"
    local backup listing
    backup=$(ls "$E"/backups/darban-backup-*.tar.gz)
    ok_if 'a backup exists' test -s "$backup"
    # Read the whole list first: grep -q stops early, and with pipefail that can fail tar with SIGPIPE.
    listing=$(tar -tzPf "$backup")
    has 'the backup holds the CA key' 'pki/private/ca.key' "$listing"
    has 'the backup holds the profiles' 'clients/first.ovpn' "$listing"
}

test_remove_everything_keeps_the_link_certificate() {
    # Let's Encrypt gives 5 a week for one address: the link certificate stays for the next install, unless
    # the admin deletes it.
    local out
    built_server
    mkdir -p "$E/le/live/darban-ovpn-links" "$E/varlib"
    echo cert > "$E/le/live/darban-ovpn-links/fullchain.pem"
    echo '1 vpn.example.com' > "$E/varlib/link-certificates.log"
    echo 'certbot_cert darban-ovpn-links' >> "$E/cfg/.server-setup-started"
    printf '#!/usr/bin/env bash\necho "certbot $*" >> "$STUB_LOG"\n' > "$E/bin/certbot"; chmod +x "$E/bin/certbot"
    : > "$STUB_LOG"
    out=$(printf '2\n1\n1\nremove-everything\n' | bash "$E/manager.sh" remove-all 2>&1)
    has 'it asks, and keeping is the default' "Keep the Let's Encrypt certificate of the links?" "$out"
    has 'it says the certificate stays' "Kept the Let's Encrypt certificate darban-ovpn-links" "$out"
    has 'and how to delete it' 'To delete it: sudo rm -rf /etc/letsencrypt/live/darban-ovpn-links' "$out"
    if grep -q 'certbot delete' "$STUB_LOG"; then result 0 'certbot does not delete it'; else result 1 'certbot does not delete it'; fi
    ok_if 'the record of issues stays' test -s "$E/varlib/link-certificates.log"
}

test_a_kept_certificate_survives_certbot_from_apt() {
    # A purge of Ubuntu's certbot deletes /etc/letsencrypt (seen on a test server): with the certificate kept,
    # certbot's packages are removed instead, and the rest is purged as usual.
    local out
    built_server
    mkdir -p "$E/le/live/darban-ovpn-links" "$E/varlib"
    echo cert > "$E/le/live/darban-ovpn-links/fullchain.pem"
    printf 'certbot_cert darban-ovpn-links\npackage certbot\ndep python3-certbot\ndep python3-acme\n' >> "$E/cfg/.server-setup-started"
    printf '#!/usr/bin/env bash\necho "certbot $*" >> "$STUB_LOG"\n' > "$E/bin/certbot"; chmod +x "$E/bin/certbot"
    : > "$STUB_LOG"
    out=$(printf '2\n1\n1\nremove-everything\n' | AUTOREMOVE='python3-certbot python3-acme' bash "$E/manager.sh" remove-all 2>&1)
    has 'the certificate is kept' "Kept the Let's Encrypt certificate darban-ovpn-links" "$out"
    grep -q -- '-y -q remove certbot$' "$STUB_LOG"; rc_is 'certbot is removed, not purged' 0 "$?"
    grep -q -- '-y -q remove python3-certbot$' "$STUB_LOG"; rc_is 'and so is its library' 0 "$?"
    if grep -Eq -- '-y -q purge .*\b(certbot|python3-certbot)\b' "$STUB_LOG"; then result 0 'neither is purged'; else result 1 'neither is purged'; fi
    grep -q -- '-y -q purge python3-acme$' "$STUB_LOG"; rc_is 'other dependencies are purged as usual' 0 "$?"

}

test_remove_everything_can_delete_the_link_certificate() {
    local out
    built_server
    mkdir -p "$E/le/live/darban-ovpn-links" "$E/varlib"
    echo cert > "$E/le/live/darban-ovpn-links/fullchain.pem"
    echo '1 vpn.example.com' > "$E/varlib/link-certificates.log"
    printf 'certbot_cert darban-ovpn-links\npackage certbot\n' >> "$E/cfg/.server-setup-started"
    printf '#!/usr/bin/env bash\necho "certbot $*" >> "$STUB_LOG"\n' > "$E/bin/certbot"; chmod +x "$E/bin/certbot"
    : > "$STUB_LOG"
    out=$(printf '2\n2\n1\nremove-everything\n' | bash "$E/manager.sh" remove-all 2>&1)
    grep -Eq -- '-y -q purge .*\bcertbot\b' "$STUB_LOG"; rc_is 'with the certificate deleted, certbot is purged as before' 0 "$?"
    has 'deleting is a choice' 'The certificate will be deleted.' "$out"
    grep -q 'certbot delete --non-interactive --cert-name darban-ovpn-links' "$STUB_LOG"; rc_is 'certbot deletes it' 0 "$?"
    ok_if 'with the record of issues' test ! -e "$E/varlib/link-certificates.log"
}

test_remove_everything_backup_choice() {
    local out rc
    built_server
    out=$(printf '2\n1\nremove-everything\n' | bash "$E/manager.sh" remove-all 2>&1); rc=$?
    rc_is 'removal without a backup finishes' 0 "$rc"
    has 'option 2 skips the backup' 'No backup will be made' "$out"
    ok_if 'no backup file exists' test -z "$(ls "$E/backups")"
}

test_remove_everything_refuses_a_server_it_did_not_set_up() {
    local out rc
    prepare_blank_server
    INSTALLED_PKGS=nftables setup_run --port 21194 --yes >/dev/null
    install_removal_scripts
    rm -f "$E/cfg/.server-setup-started"
    : > "$STUB_LOG"
    out=$(bash "$E/manager.sh" remove-all 2>&1 </dev/null); rc=$?
    rc_not0 'the menu action refuses' "$rc"
    has 'it explains' 'was not set up by this tool' "$out"
    out=$(bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null); rc=$?
    rc_not0 'the script refuses by itself' "$rc"
    ok_if 'the CA stays' test -s "$PKI/ca.crt"
    ok_if 'server.conf stays' test -s "$SERVER_CONF"
    if grep -q 'purge' "$STUB_LOG"; then result 0 'nothing is purged'; else result 1 'nothing is purged'; fi

    out=$(bash "$E/lib/remove-server.sh" 2>&1 </dev/null); rc=$?
    rc_is 'without --yes it only explains' 2 "$rc"
}

test_remove_everything_never_takes_other_packages() {
    local out rc log
    built_server
    : > "$STUB_LOG"
    out=$(REMV_EXTRA=some-other-tool AUTOREMOVE='liblzo2-2 foreign-orphan' bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null); rc=$?
    rc_is 'removal finishes' 0 "$rc"
    log=$(grep -v -- ' -s ' "$STUB_LOG")
    lacks 'nothing is purged if another package would go too' 'purge' "$log"
    has 'it reports what was kept' 'would also remove: some-other-tool' "$out"
    ok_if 'the server files are still removed' test ! -e "$E/server"

    built_server
    : > "$STUB_LOG"
    out=$(AUTOREMOVE='liblzo2-2 foreign-orphan' bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null)
    log=$(grep -v -- ' -s ' "$STUB_LOG")
    has 'a dependency of the setup is cleaned up' 'purge liblzo2-2' "$log"
    lacks 'another program orphan stays' 'foreign-orphan' "$log"
}

test_remove_everything_kernel_rules() {
    local out rc log
    prepare_blank_server
    export APT_PLAN='Inst linux-image-virtual-hwe-24.04 Inst linux-image-7.0.0-42-generic'
    INSTALLED_PKGS=nftables setup_run --port 21194 --yes >/dev/null
    install_removal_scripts
    [[ $(KERNEL_RUN=7.0.0-42-generic bash "$E/lib/remove-server.sh" --kernel-status) == running ]]; rc_is 'the running kernel is reported' 0 "$?"
    [[ $(KERNEL_RUN=6.8.0-50-generic bash "$E/lib/remove-server.sh" --kernel-status) == removable ]]; rc_is 'another kernel is removable' 0 "$?"

    : > "$STUB_LOG"
    out=$(KERNEL_RUN=7.0.0-42-generic bash "$E/lib/remove-server.sh" --yes --kernel 2>&1 </dev/null); rc=$?
    rc_not0 'removing the running kernel is refused' "$rc"
    ok_if 'nothing else was removed either' test -s "$PKI/ca.crt"

    out=$(printf '1\n1\nremove-everything\n' | KERNEL_RUN=7.0.0-42-generic bash "$E/manager.sh" remove-all 2>&1)
    has 'the menu says the kernel stays' 'the system is running it now' "$out"
    log=$(grep -v -- ' -s ' "$STUB_LOG")
    lacks 'the running kernel is not purged' 'linux-image' "$log"

    fresh
    prepare_blank_server
    INSTALLED_PKGS=nftables setup_run --port 21194 --yes >/dev/null
    install_removal_scripts
    : > "$STUB_LOG"
    out=$(printf '1\n2\nremove-everything\n' | KERNEL_RUN=6.8.0-50-generic bash "$E/manager.sh" remove-all 2>&1); rc=$?
    rc_is 'removal with the kernel finishes' 0 "$rc"
    log=$(grep -v -- ' -s ' "$STUB_LOG")
    has 'the chosen kernel is purged' 'purge linux-image-7.0.0-42-generic linux-image-virtual-hwe-24.04' "$log"
    unset APT_PLAN
}

test_install_picks_a_free_network_by_itself() {
    local out rc
    prepare_blank_server
    out=$(FAKE_ROUTE=10.8.0.0/24 setup_run --port 21194 --yes); rc=$?
    rc_is 'setup finishes' 0 "$rc"
    grep -q '^server 10.9.0.0 255.255.255.0' "$SERVER_CONF"; rc_is 'a taken default moves to the next free network' 0 "$?"
}

conf_has() { grep -q -- "$1" "$SERVER_CONF"; }
fail_restart_when() {
    # systemctl stand-in: restart fails only while server.conf holds this text, so a rollback can succeed.
    cat > "$E/bin/systemctl" <<STUB
#!/usr/bin/env bash
echo "systemctl \$*" >> "\$STUB_LOG"
q=0; for a; do [[ \$a == --quiet ]] && q=1; done
case " \$* " in
  *" restart "*) if grep -q -- '$1' "\$SERVER_CONF"; then exit 1; fi ;;
  *" is-failed "*) ((q)) || echo active; exit 1 ;;
  *" is-active "*) ((q)) || echo active; exit 0 ;;
  *" is-enabled "*) echo enabled; exit 0 ;;
esac
exit 0
STUB
}

test_advanced_settings_are_applied_and_rolled_back() {
    local out before
    built_server
    out=$(menu '7\n6\n0\n0\n0\n')
    has 'settings offers Advanced' '6  Advanced' "$out"
    has 'it shows the routing' 'full tunnel' "$out"
    has 'it shows the DNS' '1.1.1.1 8.8.8.8' "$out"
    has 'it shows the network' '10.8.0.0/24' "$out"
    has 'it shows the ciphers' 'AES-256-GCM' "$out"

    : > "$STUB_LOG"
    out=$(menu '7\n6\n2\n9.9.9.9 8.8.4.4\n1\n0\n0\n0\n')
    has 'option 1 changes nothing' 'Cancelled; nothing changed' "$out"
    if conf_has 'DNS 9.9.9.9'; then result 0 'the DNS stays after No'; else result 1 'the DNS stays after No'; fi
    if grep -q 'systemctl restart' "$STUB_LOG"; then result 0 'no restart after No'; else result 1 'no restart after No'; fi
    out=$(menu '7\n6\n2\nnot-an-ip\n\n0\n0\n0\n')
    has 'a bad DNS is asked again' 'or one or two IPv4 addresses' "$out"

    out=$(menu '7\n6\n2\n9.9.9.9 8.8.4.4\n2\n0\n0\n0\n')
    has 'the DNS change is confirmed' 'Applied: DNS 9.9.9.9 8.8.4.4' "$out"
    conf_has 'dhcp-option DNS 9.9.9.9'; rc_is 'the new DNS is in server.conf' 0 "$?"
    if conf_has 'dhcp-option DNS 1.1.1.1'; then result 0 'the old DNS is gone'; else result 1 'the old DNS is gone'; fi
    grep -q 'systemctl restart' "$STUB_LOG"; rc_is 'OpenVPN was restarted' 0 "$?"
    grep -q 'server.conf changed: DNS' "$STUB_LOG"; rc_is 'the change is audited' 0 "$?"

    out=$(menu '7\n6\n1\n2\n0\n0\n0\n')
    has 'split tunnel is applied' 'Applied: split tunnel' "$out"
    if conf_has 'redirect-gateway'; then result 0 'split: no redirect'; else result 1 'split: no redirect'; fi
    if conf_has 'dhcp-option DNS'; then result 0 'split: no DNS push'; else result 1 'split: no DNS push'; fi
    out=$(menu '7\n6\n2\n0\n0\n0\n')
    has 'split: DNS is explained, not asked' 'keep their own DNS' "$out"
    out=$(menu '7\n6\n1\n2\n0\n0\n0\n')
    has 'full tunnel is applied' 'Applied: full tunnel' "$out"
    conf_has 'redirect-gateway'; rc_is 'full: redirect is back' 0 "$?"
    conf_has 'dhcp-option DNS 1.1.1.1'; rc_is 'full: default DNS is back' 0 "$?"

    out=$(menu '7\n6\n3\n8.8.8.0\n\n0\n0\n0\n')
    has 'a public network is asked again' 'Enter a private network' "$out"
    out=$(menu '7\n6\n3\n172.20.5.0\n0\n0\n0\n')
    has 'an overlapping network is refused' 'overlaps the existing route 172.20.0.0/16' "$out"
    out=$(menu '7\n6\n3\n10.50.0.0\n2\n0\n0\n0\n')
    has 'the network change is confirmed' 'Applied: VPN network 10.50.0.0/24' "$out"
    conf_has '^server 10.50.0.0 255.255.255.0'; rc_is 'server.conf has the new network' 0 "$?"
    grep -q 'ip saddr 10.50.0.0/24' "$E/cfg/nat.nft"; rc_is 'NAT follows the new network' 0 "$?"

    out=$(menu '7\n6\n4\nBF-CBC\n\n0\n0\n0\n')
    has 'a non-AEAD cipher is refused' 'or only AES-256-GCM, AES-128-GCM and CHACHA20-POLY1305' "$out"
    out=$(menu '7\n6\n4\nAES-256-GCM\n2\n0\n0\n0\n')
    has 'the ciphers change' 'Applied: data ciphers AES-256-GCM' "$out"
    conf_has '^data-ciphers AES-256-GCM$'; rc_is 'one data-ciphers line remains' 0 "$?"
    out=$(menu '7\n6\n5\n10 5\n\n0\n0\n0\n')
    has 'a too short timeout is refused' 'at least twice the first' "$out"
    out=$(menu '7\n6\n5\n15 90\n2\n0\n0\n0\n')
    conf_has '^keepalive 15 90$'; rc_is 'keepalive changes' 0 "$?"
    out=$(menu '7\n6\n6\n4\n2\n0\n0\n0\n')
    conf_has '^verb 4$'; rc_is 'log detail changes' 0 "$?"

    # Common values come as a numbered list; a number picks one, and a value can still be typed.
    out=$(menu '7\n6\n2\n3\n2\n0\n0\n0\n')
    has 'the DNS list names what each does' 'Quad9, blocks known malicious sites (9.9.9.9 149.112.112.112)' "$out"
    has 'a number picks a DNS' 'Applied: DNS 9.9.9.9 149.112.112.112' "$out"
    out=$(menu '7\n6\n5\n3\n2\n0\n0\n0\n')
    conf_has '^keepalive 5 30$'; rc_is 'a number picks a keepalive' 0 "$?"
    out=$(menu '7\n6\n4\n2\n2\n0\n0\n0\n')
    conf_has '^data-ciphers CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM$'; rc_is 'a number picks ciphers' 0 "$?"
    out=$(menu '7\n6\n3\n\n0\n0\n0\n')
    has 'the network question suggests a free one' 'A free one on this server: 10.8.0.0' "$out"
    out=$(menu '7\n6\n0\n0\n')
    has 'Advanced says what it holds' 'The defaults suit most servers' "$out"
    has 'items that restart OpenVPN are marked' 'DNS for clients *' "$out"
    has 'and the mark is explained' '* restarts OpenVPN' "$out"
    out=$(menu '7\n0\n0\n')
    has 'Settings says what it holds' 'What clients connect to, and how profiles are shared' "$out"
    has 'the port is marked as a restart' 'OpenVPN UDP port *' "$out"

    before=$(cat "$SERVER_CONF")
    cp "$E/cfg/nat.nft" "$E/nat.before"
    fail_restart_when 'keepalive 20 120'
    out=$(menu '7\n6\n5\n20 120\n2\n0\n0\n0\n')
    has 'a service that does not come back is rolled back' 'Rolled back' "$out"
    has 'it says nothing changed' 'Nothing was changed' "$out"
    [[ $before == "$(cat "$SERVER_CONF")" ]]; rc_is 'server.conf is exactly as before' 0 "$?"
    fail_restart_when '^server 10.60.0.0'
    out=$(menu '7\n6\n3\n10.60.0.0\n2\n0\n0\n0\n')
    [[ $before == "$(cat "$SERVER_CONF")" ]]; rc_is 'a failed network change restores server.conf' 0 "$?"
    cmp -s "$E/cfg/nat.nft" "$E/nat.before"; rc_is 'a failed network change restores NAT' 0 "$?"
}

test_advanced_network_needs_nat_from_this_tool() {
    local out
    echo 'server 10.8.0.0 255.255.255.0' >> "$SERVER_CONF"
    out=$(menu '7\n6\n3\n0\n0\n0\n')
    has 'an existing server keeps its own NAT' 'was not set up by this tool' "$out"
    sed -i '/^server /d' "$SERVER_CONF"
    out=$(menu '7\n6\n3\n0\n0\n0\n')
    has 'another layout is refused' 'another layout' "$out"
}

test_advanced_download_access_and_client_lifetime() {
    local out end days
    echo '# my note' >> "$E/cfg/config"
    out=$(menu '7\n6\n8\nsrv.example.com\n2200\n\n0\n0\n0\n')
    has 'download access is saved' 'Saved: root@srv.example.com:2200' "$out"
    grep -q '^DOWNLOAD_SSH_HOST=srv.example.com$' "$E/cfg/config"; rc_is 'the host is in the file' 0 "$?"
    grep -q '^DOWNLOAD_SSH_PORT=2200$' "$E/cfg/config"; rc_is 'the port is in the file' 0 "$?"
    grep -q '^# my note$' "$E/cfg/config"; rc_is 'other lines stay' 0 "$?"
    out=$(menu '7\n6\n8\nbad_host!\n\n99999\n\nBAD USER\n\n0\n0\n0\n')
    has 'a bad host is asked again' 'Enter a hostname or an IPv4 address' "$out"
    has 'a bad port is asked again' 'from 1 to 65535' "$out"
    has 'a bad user is asked again' 'valid Linux user name' "$out"
    out=$(menu '7\n6\n7\n5000\n0\n0\n0\n')
    has 'a bad lifetime is refused' 'Nothing changed' "$out"
    out=$(menu '7\n6\n7\n100\n0\n0\n0\n')
    has 'the lifetime is saved' 'Saved: new clients last 100 days. It applies to clients created from now on.' "$out"
    out=$(menu '1\nshortlived\n0\n')
    has 'a client is created' 'Client "shortlived" created' "$out"
    end=$(openssl x509 -in "$PKI/issued/shortlived.crt" -noout -enddate | sed 's/notAfter=//')
    days=$(( ($(date -u -d "$end" +%s) - $(date -u +%s)) / 86400 ))
    (( days >= 98 && days <= 100 )); rc_is "the new client lasts 100 days (got $days)" 0 "$?"
    out=$(menu '7\n6\n7\n0\n0\n0\n0\n')
    has 'the default can be restored' 'Easy-RSA default' "$out"
    if grep -q CLIENT_CERT_DAYS "$E/cfg/config"; then result 0 'the setting is removed'; else result 1 'the setting is removed'; fi
    has 'status still works' 'Revocation (CRL)' "$(mgr status)"
}

start_links_stub() {
    # systemctl stand-in that really runs the link server, so the tests fetch real HTTPS.
    LINKS_PIDFILE=$E/links.pid
    mv "$E/bin/systemctl" "$E/bin/systemctl.real"
    cat > "$E/bin/systemctl" <<STUB
#!/usr/bin/env bash
if [[ " \$* " == *" restart darban-links.service "* ]]; then
    echo "systemctl \$*" >> "\$STUB_LOG"
    if [[ -s "$LINKS_PIDFILE" ]]; then kill "\$(cat "$LINKS_PIDFILE")" 2>/dev/null; sleep 0.3; fi
    source "$E/cfg/links.env"
    python3 -I "$REPO/lib/linkd.py" --dir "$E/links" --cert "$E/cfg/link-cert.pem" --key "$E/cfg/link-key.pem" --host "\$LINK_HOST" --port "\$LINK_PORT" --server-conf "$SERVER_CONF" --event-script "$E/libexec/darban-ovpn-event" --interval 0.2 --idle-exit 1 >>"$E/links.log" 2>&1 </dev/null &
    echo \$! > "$LINKS_PIDFILE"
    exit 0
fi
# The service's state and its reload, as systemd would give them. FAKE_RELOAD_FAIL: the signal never arrives.
if [[ " \$* " == *" reload darban-links.service "* ]]; then
    echo "systemctl \$*" >> "\$STUB_LOG"
    [[ -n \${FAKE_RELOAD_FAIL:-} ]] && exit 0
    kill -HUP "\$(cat "$LINKS_PIDFILE")"; exit
fi
if [[ " \$* " == *" is-active "*darban-links.service* ]]; then [[ -s "$LINKS_PIDFILE" ]] && kill -0 "\$(cat "$LINKS_PIDFILE")" 2>/dev/null; exit; fi
if [[ " \$* " == *" show "*darban-links.service* ]]; then cat "$LINKS_PIDFILE" 2>/dev/null; exit 0; fi
exec bash "$E/bin/systemctl.real" "\$@"
STUB
    chmod +x "$E/bin/systemctl"
    # A local address needs no certificate question, and a high port needs no privileges.
    LINK_TEST_PORT=$(( 20000 + RANDOM % 20000 ))
    echo 127.0.0.1 > "$E/cfg/domain"
    printf 'LINK_PORT=%s\n' "$LINK_TEST_PORT" >> "$E/cfg/config"
}
stop_links_stub() { if [[ -s ${LINKS_PIDFILE:-/nonexistent} ]]; then kill "$(cat "$LINKS_PIDFILE")" 2>/dev/null; fi; }
web() { /usr/bin/curl -ks --max-time 10 "$@"; }
new_link() { menu "5\n${1:-alice}\n1\n1\n0\n" | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}'; }

test_temporary_link_end_to_end() {
    local url base out head code
    start_links_stub
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'the link is shown' "https://127.0.0.1:$LINK_TEST_PORT/l/" "$out"
    has 'it says how long it works' 'Valid     24 hours' "$out"
    has 'without a management interface it says a connection cannot end it' 'the link cannot see a connection' "$out"
    has 'it warns about the firewall' "TCP $LINK_TEST_PORT must be open" "$out"
    has 'it warns about the browser warning' 'no trusted certificate' "$out"
    has 'the note limits going past the warning to this link' 'Never do this for other sites' "$out"
    lacks 'and does not call the warning normal' 'That is expected' "$out"
    lacks 'no Persian reaches the terminal, which would show it backwards' 'مرورگر' "$out"
    url=$(grep -oE 'https://[^ ]+/l/[0-9a-f]{64}' <<<"$out")
    base=${url%/l/*}
    ok_if 'no copy stays in the download folder' test ! -e "$E/clients/alice.ovpn"
    if find "$E/links" -type f | grep -q "${url##*/}"; then result 0 'the token itself is not stored'; else result 1 'the token itself is not stored'; fi

    for code in 1 2 3; do out=$(web "$url"); done
    has 'opening shows the download' "/l/${url##*/}/file" "$out"
    lacks 'opening does not reveal the profile' 'BEGIN' "$out"
    lacks 'there is no button that opens the app directly' 'openvpn://' "$out"
    head=$(web -D - -o /dev/null "$url")
    has 'responses are not cached' 'no-store' "$head"
    has 'responses keep the address private' 'no-referrer' "$head"

    has 'active links shows it not downloaded' 'not downloaded' "$(menu '6\n\n0\n')"
    has 'and the time left in hours and minutes' '24 h left' "$(menu '6\n\n0\n')"
    head=$(web -D - -o "$E/got.ovpn" "$url/file")
    has 'the file type is what OpenVPN clients expect' 'application/x-openvpn-profile' "$head"
    has 'it downloads under the client name' 'alice.ovpn' "$head"
    grep -q '<key>' "$E/got.ovpn"; rc_is 'the real profile arrives' 0 "$?"
    grep -qx 'setenv FRIENDLY_NAME "alice"' "$E/got.ovpn"; rc_is 'the profile carries the client name for the app' 0 "$?"
    out=$(menu '6\n\n0\n')
    lacks 'active links shows it downloaded' 'not downloaded' "$out"
    has 'and still lists it' 'alice' "$out"
    web -o /dev/null "$url/file"; web -o /dev/null "$url/file"
    [[ $(web -o /dev/null -w '%{http_code}' "$url/file") == 200 ]]; rc_is 'the file can be downloaded again until the first connection' 0 "$?"
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 200 ]]; rc_is 'and the page opened again' 0 "$?"
    [[ $(web -o /dev/null -w '%{http_code}' -X POST "$url") == 410 ]]; rc_is 'nothing is posted to a link' 0 "$?"

    [[ $(web -o /dev/null -w '%{http_code}' "$base/l/$(printf 'a%.0s' {1..64})") == 410 ]]; rc_is 'an unknown link looks the same as a used one' 0 "$?"
    [[ $(web -o /dev/null -w '%{http_code}' "$base/c/${url##*/}") == 410 ]]; rc_is 'the old second address gives nothing' 0 "$?"
    [[ $(web -o /dev/null -w '%{http_code}' "$base/etc/passwd") == 410 ]]; rc_is 'other paths give nothing' 0 "$?"
    if grep -Eq '[0-9a-f]{64}' "$E/links.log"; then result 0 'no token reaches the log'; else result 1 'no token reaches the log'; fi
    grep -q 'profile downloaded: alice' "$E/links.log"; rc_is 'each download is logged' 0 "$?"
    grep -q 'temporary link created: alice' "$STUB_LOG"; rc_is 'creating the link is audited' 0 "$?"
    stop_links_stub
}

link_mgmt_server() {
    # A management interface that really listens, for the link service: each connection gets $E/mgmt-status.
    cat > "$E/mgmt-server.py" <<'PY'
import os, socket, sys
path, reply = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(4)
while True:
    conn, _ = server.accept()
    with conn:
        conn.settimeout(2)
        try:
            conn.recv(1024)
            with open(reply, 'rb') as handle:
                conn.sendall(b'>INFO:OpenVPN Management Interface\r\n' + handle.read())
            conn.recv(1024)
        except OSError:
            pass
PY
    printf 'TITLE\tOpenVPN\nEND\n' > "$E/mgmt-status"
    python3 -I "$E/mgmt-server.py" "$E/linkmgmt.sock" "$E/mgmt-status" >/dev/null 2>&1 </dev/null &
    MGMT_PID=$!
    sed -i '/^management /d' "$SERVER_CONF"
    printf 'management %s unix\n' "$E/linkmgmt.sock" >> "$SERVER_CONF"
}

test_link_ends_at_the_first_connection() {
    local url meta created attempt out
    link_mgmt_server
    start_links_stub
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'with a management interface it says a connection ends it' 'works 24 hours, or until alice connects' "$out"
    has 'and so does the validity line' 'or until a connection with this profile is seen' "$out"
    url=$(grep -oE 'https://[^ ]+/l/[0-9a-f]{64}' <<<"$out")
    meta=$(ls "$E"/links/*.meta)
    created=$(awk -F= '$1=="created" {print $2}' "$meta")
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\talice\t198.51.100.7:1\t10.8.0.2\t\t1\t1\tthen\t%s\tUNDEF\t0\t0\tAES-256-GCM\nCLIENT_LIST\tbob\t198.51.100.8:1\t10.8.0.3\t\t1\t1\tnow\t%s\tUNDEF\t1\t1\tAES-256-GCM\nEND\n' \
        "$(( created - 100 ))" "$(( created + 5 ))" > "$E/mgmt-status"
    sleep 1
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 200 ]]; rc_is 'a session from before the link, or another client, does not end it' 0 "$?"
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\talice\t198.51.100.7:1\t10.8.0.2\t\t1\t1\tnow\t%s\tUNDEF\t0\t0\tAES-256-GCM\nEND\n' "$(( created + 1 ))" > "$E/mgmt-status"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [[ $(web -o /dev/null -w '%{http_code}' "$url") == 410 ]] && break
        sleep 0.3
    done
    [[ $(web -o /dev/null -w '%{http_code}' "$url/file") == 410 ]]; rc_is 'the first connection ends the link' 0 "$?"
    ok_if 'and leaves no copy of the profile' test -z "$(find "$E/links" -name '*.ovpn')"
    grep -q 'link ended: alice connected' "$E/links.log"; rc_is 'the end is logged' 0 "$?"
    stop_links_stub
    kill "$MGMT_PID" 2>/dev/null
}

test_temporary_link_expiry_cancel_and_revoke() {
    local url meta out
    start_links_stub
    url=$(new_link alice)
    meta=$(ls "$E"/links/*.meta)
    sed -i 's/^expires=.*/expires=1000/' "$meta"
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 410 ]]; rc_is 'an expired link is refused' 0 "$?"
    [[ $(web -o /dev/null -w '%{http_code}' "$url/file") == 410 ]]; rc_is 'and gives no file' 0 "$?"
    has 'active links drops an expired link' 'No open links and no files on the server' "$(menu '6\n0\n')"

    url=$(new_link alice)
    out=$(menu '6\n1\n2\n0\n')
    has 'a link can be cancelled' 'cancelled' "$out"
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 410 ]]; rc_is 'a cancelled link is refused' 0 "$?"
    ok_if 'a cancelled link leaves no copy' test -z "$(find "$E/links" -name '*.ovpn')"

    url=$(new_link alice)
    revoke_menu alice >/dev/null
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 410 ]]; rc_is 'revoking a client ends its links' 0 "$?"
    ok_if 'revoking leaves no copy' test -z "$(find "$E/links" -name '*.ovpn')"
    stop_links_stub
}

test_link_removal_waits_for_the_link_service() {
    # A download and a removal take turns on the link files, so the record of a removed link never comes back.
    local dir=$E/race key started took
    mkdir -p "$dir"
    key=$(printf '%s' "$(printf 'a%.0s' {1..64})" | sha256sum | awk '{print $1}')
    printf 'name=alice\nexpires=%s\ncreated=1\ndownloads=0\n' "$(( $(date -u +%s) + 3600 ))" > "$dir/$key.meta"
    echo profile > "$dir/$key.ovpn"
    # darban holds the lock and removes the link while a download is waiting for it. The real flock: the
    # stand-in in $E/bin does not lock.
    ( /usr/bin/flock 8; touch "$dir/held"; sleep 2; rm -f -- "$dir/$key.meta" "$dir/$key.ovpn" ) 8>"$dir/.lock" &
    for started in 1 2 3 4 5 6 7 8 9 10; do [[ -e $dir/held ]] && break; sleep 0.1; done
    took=$(python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); import linkd
start = time.time(); name, data = linkd.Store(sys.argv[2]).take("a" * 64)
print(f"{time.time() - start:.1f} {name}")' "$REPO/lib" "$dir")
    wait
    [[ ${took%% *} != 0.* ]]; rc_is 'the download waits for the removal' 0 "$?"
    [[ ${took#* } == None ]]; rc_is 'and then finds no link' 0 "$?"
    ok_if 'and does not write its record back' test ! -e "$dir/$key.meta"
}

test_link_certificate_heals_and_survives_failures() {
    # A key and a certificate that do not match are replaced at the next link; a failed replacement keeps the pair.
    local before
    start_links_stub
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/other.key" -out "$E/other.pem" \
        -days 30 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 >/dev/null 2>&1
    menu '5\nalice\n1\n1\n0\n' >/dev/null
    menu '6\n1\n2\n0\n' >/dev/null
    cp "$E/other.key" "$E/cfg/link-key.pem"
    has 'a pair that does not match is replaced, and the link is made' '/l/' "$(menu '5\nalice\n1\n1\n0\n')"
    openssl x509 -in "$E/cfg/link-cert.pem" -noout -pubkey > "$E/pub.cert"
    openssl pkey -in "$E/cfg/link-key.pem" -pubout > "$E/pub.key"
    cmp -s "$E/pub.cert" "$E/pub.key"; rc_is 'the new pair matches' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null

    # The pair is unusable again, and making a new one fails: the files stay as they were.
    cp "$E/other.key" "$E/cfg/link-key.pem"
    before=$(cat "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem" | sha256sum)
    printf '#!/usr/bin/env bash\nif [[ " $* " == *" req "* ]]; then exit 1; fi\nexec /usr/bin/openssl "$@"\n' > "$E/bin/openssl"
    chmod +x "$E/bin/openssl"
    has 'a failed new certificate says so' 'Could not create a certificate for the link.' "$(menu '5\nalice\n1\n1\n0\n')"
    [[ $(cat "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem" | sha256sum) == "$before" ]]; rc_is 'and leaves the files as they were' 0 "$?"
    ok_if 'with nothing left over' test -z "$(find "$E/cfg" -name '.link-*.new')"
    [[ $(find "$E/cfg/link-cert/pairs" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]; rc_is 'and no half-made pair' 0 "$?"
    rm -f "$E/bin/openssl"
    stop_links_stub
}

test_link_lifetime_setting() {
    # The time a link works is a setting, in whole hours from 1 to 72, and sharing no longer asks for it.
    local out expires now
    start_links_stub
    has 'Settings shows the default' 'Shares expire after      24 hours' "$(menu '7\n0\n0\n')"
    out=$(menu '7\n3\n73\nabc\n\n0\n0\n')
    has 'more than three days is refused' 'from 1 to 72' "$out"
    if grep -q '^LINK_HOURS=' "$E/cfg/config"; then result 0 'nothing is saved then'; else result 1 'nothing is saved then'; fi
    out=$(menu '7\n3\n6\n0\n0\n')
    has 'a lifetime is saved' 'Saved: shares expire after 6 hours.' "$out"
    grep -q '^LINK_HOURS=6$' "$E/cfg/config"; rc_is 'it is in the file' 0 "$?"
    out=$(menu '5\nalice\n1\n1\n0\n')
    lacks 'sharing does not ask how long' 'At most, how long' "$out"
    has 'the link takes the setting' 'Valid     6 hours' "$out"
    now=$(date -u +%s)
    expires=$(sed -n 's/^expires=//p' "$E"/links/*.meta | head -n 1)
    (( expires > now + 6 * 3600 - 120 && expires <= now + 6 * 3600 )); rc_is 'and expires after 6 hours' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    printf 'LINK_HOURS=100\n' >> "$E/cfg/config"
    has 'a bad value in the file falls back to 24 hours' 'Invalid LINK_HOURS' "$(menu '7\n0\n0\n')"
    stop_links_stub
}

test_link_page_language_follows_the_preference_order() {
    local h
    for h in 'fa' 'fa-IR' 'fa-IR,fa;q=0.9,en;q=0.8'; do
        [[ $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import linkd; print(linkd.language(sys.argv[2]))' "$REPO/lib" "$h") == fa ]]; rc_is "Persian for: $h" 0 "$?"
    done
    for h in 'en-US,fa;q=0.9' 'fa;q=0' 'fa;q=0,de' 'de-DE' '' 'fa;q=abc' ';;;'; do
        [[ $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import linkd; print(linkd.language(sys.argv[2]))' "$REPO/lib" "$h") == en ]]; rc_is "English for: ${h:-no header}" 0 "$?"
    done
}

test_link_server_ends_when_idle() {
    local url pid second attempt
    start_links_stub
    url=$(new_link alice)
    pid=$(cat "$LINKS_PIDFILE")
    kill -0 "$pid"; rc_is 'the server runs while a link exists' 0 "$?"
    sleep 2
    kill -0 "$pid"; rc_is 'it stays up while the link is waiting' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    for attempt in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then result 0 'it ends when no link is left'; else result 1 'it ends when no link is left'; fi
    stop_links_stub
}

test_share_questions() {
    local out
    out=$(menu '5\nalice\n2\n0\n')
    has 'the question has two options' '  2  Keep it on the server: download it with scp or sftp' "$out"
    lacks 'the QR code is not one of them' 'QR code: scan it' "$out"
    has 'keeping it says where the file is' 'Kept on the server' "$out"
    ok_if 'the file is on the server' test -s "$E/clients/alice.ovpn"
    has 'with the Windows command' 'USERPROFILE' "$out"
    # shellcheck disable=SC2088  # The literal text the tool prints.
    has 'the macOS and Linux command' '~/Downloads/' "$out"
    has 'and the sftp address' 'sftp://root@' "$out"
    lacks 'and no question about deleting it now' 'Finished downloading?' "$out"
    out=$(menu '1\nbob\n0\n')
    has 'a script still gets every command' 'USERPROFILE' "$out"
    has 'a script gets every command, sftp too' 'sftp://' "$out"
}

test_share_password() {
    local out password profile
    lacks 'keeping the file on the server asks no password' 'Lock the private key' "$(menu '5\nalice\n2\n0\n')"
    start_links_stub
    out=$(menu '5\nalice\n1\n2\n0\n')
    stop_links_stub
    has 'the password is shown once' 'shown only now' "$out"
    password=$(grep -A1 '^Password:$' <<<"$out" | tail -n 1)
    [[ $password =~ ^[a-km-np-z2-9]{9}$ ]]; rc_is 'the password is nine characters in one piece, without look-alike characters' 0 "$?"
    # The link holds its own copy of the profile.
    profile=$(find "$E/links" -name '*.ovpn' | head -n 1)
    grep -q 'ENCRYPTED PRIVATE KEY' "$profile"; rc_is 'the key in the profile is locked' 0 "$?"
    if grep -q 'BEGIN PRIVATE KEY' "$profile"; then result 0 'no open key in the profile'; else result 1 'no open key in the profile'; fi
    sed -n '/<key>/,/<\/key>/p' "$profile" | sed '1d;$d' > "$E/locked.key"
    openssl pkey -in "$E/locked.key" -passin "pass:$password" -noout 2>/dev/null; rc_is 'the password opens it' 0 "$?"
    openssl asn1parse -in "$E/locked.key" 2>/dev/null | grep -q 'INTEGER *:0927C0'; rc_is 'guessing it is slowed by 600000 rounds' 0 "$?"
    openssl pkey -in "$E/locked.key" -passin pass:wrong -noout 2>/dev/null; rc_not0 'a wrong password does not' "$?"
    grep -q 'BEGIN PRIVATE KEY' "$PKI/private/alice.key"; rc_is 'the key in the PKI stays usable' 0 "$?"
    if grep -rq "$password" "$E/stub.log"; then result 0 'the password is not logged'; else result 1 'the password is not logged'; fi
}

test_first_link_takes_an_uncommon_port() {
    # Without a saved port, the first free one of 9347, 9563 and 9741, never one a panel usually takes.
    local out pid
    start_links_stub
    sed -i '/^LINK_PORT=/d' "$E/cfg/config"
    python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 9347)); s.listen(); time.sleep(60)' &
    pid=$!
    sleep 0.5
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'a busy first choice is passed over for the next one' 'https://127.0.0.1:9563/l/' "$out"
    grep -qx 'LINK_PORT=9563' "$E/cfg/config"; rc_is 'and it is remembered' 0 "$?"
    kill "$pid" 2>/dev/null
    stop_links_stub
}

test_link_port_taken_by_another_program() {
    local port out pid
    port=$(( 40000 + RANDOM % 20000 ))
    python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(60)' "$port" &
    pid=$!
    sleep 0.5
    echo 127.0.0.1 > "$E/cfg/domain"
    printf 'LINK_PORT=%s\n' "$port" >> "$E/cfg/config"
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'a link port another program took is named' "TCP $port, the port for links, is now used by python3" "$out"
    lacks 'and no link is made' '/l/' "$out"
    out=$(menu "7\n4\n$port\n0\n0\n0\n")
    has 'the setting refuses a port in use, and names the program' "TCP $port is already used by python3" "$out"
    kill "$pid" 2>/dev/null
}

test_share_qr_code_in_a_real_terminal() {
    # The QR code is one option of the copy question; once drawn, the question comes back without it.
    local script=$E/script out rc
    start_links_stub
    printf '#!/usr/bin/env bash\necho "qrencode $*" >> "$STUB_LOG"; echo QRCODE-DRAWN\n' > "$E/bin/qrencode"
    chmod +x "$E/bin/qrencode"
    cat > "$script" <<'EOF'
Choose [0-9] => 5\r
Number or name => alice\r
Enter: Temporary link => \r
Enter: No password => \r
Enter: Copy link and note => 2\r
QRCODE-DRAWN
Enter: Copy link and note => 3\r
Press Enter to return => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" 2>&1); rc=$?
    rc_is 'the QR code comes from the copy question' 0 "$rc"
    has 'it is offered there' '2  Show a QR code' "$out"
    has 'the QR code is drawn' 'QRCODE-DRAWN' "$out"
    grep -q 'qrencode -t ANSIUTF8 https://127.0.0.1' "$STUB_LOG"; rc_is 'the QR holds the link' 0 "$?"
    lacks 'and is not offered again' 'Show a QR code' "${out#*QRCODE-DRAWN}"
    lacks 'Do not copy copies nothing' 'Copied to your clipboard' "$out"
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
    stop_links_stub
}

test_link_port_setting() {
    local out
    out=$(menu '7\n4\nabc\n\n0\n0\n0\n')
    has 'a bad link port is asked again' 'from 1 to 65535' "$out"
    out=$(menu '7\n4\n30123\n0\n0\n0\n')
    has 'the link port is saved' 'Saved: TCP 30123' "$out"
    grep -q '^LINK_PORT=30123$' "$E/cfg/config"; rc_is 'it is in the file' 0 "$?"
}

test_link_certificate_for_a_hostname() {
    local out before
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    out=$(menu '5\nalice\n1\n2\n1\n0\n')
    has 'a hostname offers a trusted certificate' "Let's Encrypt" "$out"
    has 'declining falls back to a self-signed certificate' 'no trusted certificate' "$out"
    has 'the link uses the hostname' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    openssl x509 -in "$E/cfg/link-cert.pem" -noout -checkhost vpn.example.com | grep -q 'does match'; rc_is 'the certificate fits the hostname' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    before=$(sha256sum < "$E/cfg/link-cert.pem")
    out=$(menu '5\nalice\n1\n2\n1\n0\n')
    has 'a self-signed certificate is offered a trusted one again' "Let's Encrypt" "$out"
    [[ $(sha256sum < "$E/cfg/link-cert.pem") == "$before" ]]; rc_is 'declining keeps the current self-signed certificate' 0 "$?"
    has 'and the link is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    menu '6\n1\n2\n0\n' >/dev/null

    # A link to a self-signed certificate is no trusted certificate: the menu, the note and the password say so.
    mkdir -p "$E/le"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/le/privkey.pem" -out "$E/le/fullchain.pem" \
        -days 30 -subj /CN=vpn.example.com -addext subjectAltName=DNS:vpn.example.com >/dev/null 2>&1
    mv "$E/cfg/link-cert.pem" "$E/cfg/link-cert.self"; mv "$E/cfg/link-key.pem" "$E/cfg/link-key.self"
    ln -s "$E/le/fullchain.pem" "$E/cfg/link-cert.pem"; ln -s "$E/le/privkey.pem" "$E/cfg/link-key.pem"
    has 'Settings does not call it trusted' 'browser warning: browsers do not trust who issued it' "$(menu '7\n0\n0\n')"
    out=$(menu '5\nalice\n1\n2\n1\n0\n')
    has 'a trusted one is offered again' "Let's Encrypt" "$out"
    has 'and the person is told about the warning' 'Your browser will warn' "$out"
    menu '6\n1\n2\n0\n' >/dev/null

    # A trusted certificate valid for weeks is not asked about again.
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    make_test_ca vpn.example.com "$E/le" fullchain.pem privkey.pem
    ln -s "$E/le/fullchain.pem" "$E/cfg/link-cert.pem"; ln -s "$E/le/privkey.pem" "$E/cfg/link-key.pem"
    # 29 or 30: within the second the certificate was made, a whole 30 days are left.
    grep -Eq "Link certificate +trusted, Let's Encrypt, (29|30) days left$" <<<"$(menu '7\n0\n0\n')"; rc_is 'Settings calls it trusted, with the days left' 0 "$?"
    out=$(menu '5\nalice\n1\n1\n0\n')
    lacks 'a usable trusted certificate is not asked about again' "Let's Encrypt" "$out"
    has 'and the link is made with it' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    # This failed once on CI with no cause in the last lines: keep all of it, and the state of the certificates.
    if [[ $out != *"https://vpn.example.com:$LINK_TEST_PORT/l/"* ]]; then
        printf '%s\n' "$out" | sed 's/^/    > /'
        ls -l "$E/cfg/" "$E/le/" 2>&1 | sed 's/^/    > /'
        openssl x509 -in "$E/cfg/link-cert.pem" -noout -subject -issuer -dates 2>&1 | sed 's/^/    > /'
    fi
    menu '6\n1\n2\n0\n' >/dev/null
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    mv "$E/cfg/link-cert.self" "$E/cfg/link-cert.pem"; mv "$E/cfg/link-key.self" "$E/cfg/link-key.pem"

    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 2.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 1\n' > "$E/bin/certbot"
    chmod +x "$E/bin/certbot"
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'a failed request explains itself' 'certbot could not get a certificate' "$out"
    has 'and still gives a working link' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    grep -q 'certbot certonly --standalone' "$STUB_LOG"; rc_is 'certbot was asked' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null

    # A trusted certificate with less than a day left, and a renewal that fails: the one that still works stays.
    make_test_ca vpn.example.com "$E/le" fullchain.pem privkey.pem 1
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    ln -s "$E/le/fullchain.pem" "$E/cfg/link-cert.pem"; ln -s "$E/le/privkey.pem" "$E/cfg/link-key.pem"
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'a trusted certificate that still works stays' 'The current trusted certificate stays' "$out"
    menu '6\n1\n2\n0\n' >/dev/null
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'a link does not outlive the certificate' 'The link certificate ends sooner than 24 hours, so this link works for at most 23 hours.' "$out"
    has 'and a shorter one is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    has 'for the whole hours left' 'Valid     23 hours' "$out"
    ok_if 'it is not replaced by a self-signed one' test -L "$E/cfg/link-cert.pem"
    has 'and the link is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    stop_links_stub
}

test_about_and_contact_are_shown() {
    local out
    has 'the main menu shows the project' 'github.com/MohZeh/Darban-OVPN' "$(menu '0\n')"
    has 'the main menu shows the email' 'zehtabex@gmail.com' "$(menu '0\n')"
    out=$(bash "$E/manager.sh" about 2>&1 </dev/null)
    has 'about shows the address' 'https://github.com/MohZeh/Darban-OVPN' "$out"
    has 'about shows the email' 'zehtabex@gmail.com' "$out"
    has 'about shows the license' 'MIT' "$out"
    has 'about states independence' 'Not affiliated with OpenVPN Inc.' "$out"
    has 'help shows the contact' 'zehtabex@gmail.com' "$(bash "$E/manager.sh" help 2>&1 </dev/null)"
    has 'the Setup menu has About' 'Not affiliated' "$(menu '9\n1\n0\n0\n')"
    [[ $(bash "$E/manager.sh" version 2>&1 </dev/null) =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; rc_is 'version stays machine-readable' 0 "$?"
}

set_installed_version() { sed -i "s/^DARBAN_VERSION=.*/DARBAN_VERSION=$1/" "$E/manager.sh"; }
# A test version reads the list of all releases; release_list <tag> stands for it with one release.
release_list() { printf '[{"tag_name": "v%s", "prerelease": true}]\n' "$1" > "$RELEASE/releases?per_page=20"; }
test_update_knows_pre_releases() {
    local out
    fake_release
    cp "$E/get.sh" "$E/lib/get.sh"
    printf 'Fixed things.\n\033[31mno escape\n' > "$RELEASE/RELEASE-NOTES.txt"
    set_installed_version 1.0.0-beta.1
    release_list 1.0.0
    out=$(menu '9\n2\n1\n0\n0\n')
    has 'the final release is newer than its beta' 'Install v1.0.0' "$out"
    has 'its notes are shown' 'Fixed things.' "$out"
    if [[ $out == *$'\033'* ]]; then result 0 'escape codes in notes are removed'; else result 1 'escape codes in notes are removed'; fi
    release_list 1.0.0-rc.1
    has 'an rc is newer than a beta' 'Install v1.0.0-rc.1' "$(menu '9\n2\n1\n0\n0\n')"
    release_list 1.0.0-alpha.1
    has 'an alpha is older than a beta' 'This is the latest version' "$(menu '9\n2\n0\n0\n')"
    set_installed_version 1.0.0
    echo 1.0.0-rc.9 > "$RELEASE/VERSION"
    has 'an rc is older than the final release' 'This is the latest version' "$(menu '9\n2\n0\n0\n')"
    echo 1.0.1 > "$RELEASE/VERSION"
    has 'a higher version is newer' 'Install v1.0.1' "$(menu '9\n2\n1\n0\n0\n')"
    echo 1.10.0 > "$RELEASE/VERSION"
    set_installed_version 1.9.0
    has 'numbers compare as numbers' 'Install v1.10.0' "$(menu '9\n2\n1\n0\n0\n')"
}

test_a_test_version_is_offered_the_next_test_version() {
    # A release candidate follows the newest release, test versions included; a final version does not.
    local out list
    fake_release
    cp "$E/get.sh" "$E/lib/get.sh"
    list="$RELEASE/releases?per_page=20"
    printf '[\n  {\n    "tag_name": "v1.0.0-rc.4",\n    "prerelease": true\n  },\n  {\n    "tag_name": "v1.0.0-rc.10",\n    "prerelease": true\n  },\n  {\n    "tag_name": "v1.0.0-rc.9",\n    "prerelease": true\n  }\n]\n' > "$list"
    set_installed_version 1.0.0-rc.4
    out=$(menu '9\n2\n1\n0\n0\n')
    has 'the highest test version is offered' 'Install v1.0.0-rc.10' "$out"
    grep -q 'api.github.com/repos/MohZeh/Darban-OVPN/releases?per_page=20' "$STUB_LOG"; rc_is 'from the list of all releases' 0 "$?"
    printf '[{"tag_name": "v1.0.0", "prerelease": false}, {"tag_name": "v1.0.0-rc.10", "prerelease": true}]\n' > "$list"
    has 'then the final version' 'Install v1.0.0' "$(menu '9\n2\n1\n0\n0\n')"
    printf '[{"tag_name": "v1.0.0-rc.4", "prerelease": true}]\n' > "$list"
    has 'the same test version: nothing to do' 'This is the latest version' "$(menu '9\n2\n0\n0\n')"
    printf '[{"tag_name": "v9; rm -rf", "prerelease": true}]\n' > "$list"
    has 'a tag that is not a version is ignored' 'No stable release is published yet' "$(menu '9\n2\n0\n0\n')"
    set_installed_version 1.0.0
    echo 1.0.0 > "$RELEASE/VERSION"
    printf '[{"tag_name": "v1.0.1-rc.1", "prerelease": true}]\n' > "$list"
    has 'a final version is not offered a test version' 'This is the latest version' "$(menu '9\n2\n0\n0\n')"
}

test_settings_apply_in_the_same_session() {
    # Each action runs apart from the menu: a setting it saves must reach the menu and the next action at once.
    local out
    start_links_stub
    out=$(menu '7\n3\n5\n0\n5\nalice\n1\n1\n0\n')
    has 'Settings shows the new lifetime at once' 'Shares expire after      5 hours' "$out"
    has 'and the next link takes it' 'Valid     5 hours' "$out"
    menu '6\n1\n2\n0\n' >/dev/null
    out=$(menu '7\n6\n7\n30\n0\n0\n0\n')
    has 'Advanced shows a new client lifetime at once' 'New client lifetime      30' "$out"
    out=$(menu '7\n6\n7\n0\n0\n0\n0\n')
    has 'a setting returned to its default shows the default' 'New client lifetime      Easy-RSA default' "${out##*Days a new client}"
    grep -Eq 'Link port +[0-9]+$' <<<"$(menu '7\n0\n0\n')"; rc_is 'Settings shows the link port by number, before any link' 0 "$?"
    lacks 'and no longer says when it is chosen' 'chosen when needed' "$(menu '7\n4\n\n0\n0\n')"
    stop_links_stub
}

test_update_notice_in_the_header() {
    local out calls next reason cache=$E/cfg/.latest-version failed=$E/cfg/.update-check-failed
    fake_release
    set_installed_version 1.0.0
    lacks 'nothing is checked when it is off' 'Update available' "$(menu '0\n')"
    ok_if 'no check was made' test ! -e "$cache"

    out=$(menu '9\n0\n0\n')
    has 'Setup shows the notice setting' 'Update notice' "$out"
    has 'and says beside Check for updates that it is off' 'notice off' "$out"
    menu '9\n3\n0\n0\n' >/dev/null
    if grep -q '^UPDATE_CHECK=no' "$E/cfg/config"; then result 0 'the setting can be turned on'; else result 1 'the setting can be turned on'; fi
    grep -Eq 'Update available: v9\.9\.9 .{1,3} Setup .{1,3} 2$' <<<"$(menu '0\n')"; rc_is 'the first screen after a start already announces it' 0 "$?"
    ok_if 'the version was stored' test -s "$cache"
    ok_if 'nothing was installed by the notice' test ! -e "$MARKER"
    has 'Setup names the new version' 'v9.9.9 is available' "$(menu '9\n0\n0\n')"
    calls=$(grep -c 'releases/latest/download/VERSION' "$STUB_LOG")
    menu '0\n' >/dev/null
    [[ $(grep -c 'releases/latest/download/VERSION' "$STUB_LOG") == "$calls" ]]; rc_is 'it checks at most once an hour' 0 "$?"
    touch -d '2 hours ago' "$cache"
    menu '0\n' >/dev/null
    (( $(grep -c 'releases/latest/download/VERSION' "$STUB_LOG") > calls )); rc_is 'and again once the hour is over' 0 "$?"

    echo 'bad; version' > "$cache"
    lacks 'a damaged stored version is ignored' 'Update available' "$(menu '0\n')"
    echo 0.0.1 > "$cache"
    lacks 'an older version is not announced' 'Update available' "$(menu '0\n')"
    echo 1.0.0 > "$RELEASE/VERSION"
    rm -f "$cache"
    has 'the same version is shown as up to date' 'up to date, checked' "$(menu '9\n0\n0\n')"
    echo 9.9.9 > "$RELEASE/VERSION"

    # A failed check keeps what was known before, and is tried again minutes later, not the next day.
    echo 9.9.9 > "$cache"; touch -d '2 hours ago' "$cache"
    out=$(CURL_FAIL=1 CURL_RC=6 bash "$E/manager.sh" </dev/null 2>&1)
    has 'a failed check keeps the version known before' 'Update available: v9.9.9' "$out"
    ok_if 'the failure is recorded apart' test -s "$failed"
    calls=$(grep -c 'releases/latest/download/VERSION' "$STUB_LOG")
    CURL_FAIL=1 CURL_RC=6 bash "$E/manager.sh" </dev/null >/dev/null 2>&1
    [[ $(grep -c 'releases/latest/download/VERSION' "$STUB_LOG") == "$calls" ]]; rc_is 'a failed check is not repeated at once' 0 "$?"
    has 'Setup still names the version known before' 'v9.9.9 is available' "$(menu '9\n0\n0\n')"
    rm -f "$cache"
    has 'and without one, says the last check failed' 'not checked: GitHub could not be reached' "$(menu '9\n0\n0\n')"
    # First no internet, then internet: the next start after the wait shows the new version.
    printf '%s offline\n' "$(( $(date -u +%s) - 1 ))" > "$failed"
    has 'once a failed check is due again, the next start shows the release' 'Update available: v9.9.9' "$(menu '0\n')"
    ok_if 'and the failure record is gone' test ! -e "$failed"

    # GitHub's own limit: its time is kept, and the manual check says why.
    rm -f "$cache" "$failed"
    out=$(CURL_FAIL=1 FAKE_HEADERS="HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: $(( $(date -u +%s) + 3000 ))\r\n" bash "$E/manager.sh" update </dev/null 2>&1)
    has 'a refusal for the limit is named' 'GitHub asks this server to wait 50 minutes' "$out"
    read -r next reason < "$failed"
    [[ $reason == limited ]] && (( next >= $(date -u +%s) + 2900 )); rc_is 'and its time is kept for the next try' 0 "$?"
    has 'Setup says why the state is not known' 'GitHub asked this server to wait' "$(menu '9\n0\n0\n')"
    out=$(CURL_FAIL=1 FAKE_HEADERS="HTTP/2 429\r\nretry-after: 120\r\n" bash "$E/manager.sh" update </dev/null 2>&1)
    has 'a 429 with Retry-After is a refusal too' 'wait 2 minutes' "$out"
    out=$(CURL_FAIL=1 FAKE_HEADERS="HTTP/2 404\r\n" bash "$E/manager.sh" update </dev/null 2>&1)
    has 'a 404 is not taken for the limit' 'No stable release is published yet' "$out"

    # The manual check stores its answer, so the header says the same.
    rm -f "$cache" "$failed"
    bash "$E/manager.sh" update <<<'' >/dev/null 2>&1
    [[ $(cat "$cache" 2>/dev/null) == 9.9.9 ]]; rc_is 'Check for updates stores what it found' 0 "$?"

    menu '9\n3\n0\n0\n' >/dev/null
    grep -q '^UPDATE_CHECK=no' "$E/cfg/config"; rc_is 'the setting can be turned off' 0 "$?"
    ok_if 'and what was stored is removed' test ! -e "$cache" -a ! -e "$failed"
}

test_restore_previous_version() {
    local out backup=$E/backups-tool/20260101T000000
    mkdir -p "$E/sbin" "$E/units"
    has 'nothing stored is said plainly' 'No previous version is stored' "$(menu '9\n4\n0\n0\n')"
    mkdir -p "$backup/sbin" "$backup/lib" "$backup/units"
    printf '#!/usr/bin/env bash\nDARBAN_VERSION=0.9.0\n' > "$backup/sbin/darban"
    echo 'old lib' > "$backup/lib/old-marker"
    echo 'old unit' > "$backup/units/darban-crl.timer"
    out=$(menu '9\n4\n1\n0\n0\n')
    has 'it names the version' 'Go back to v0.9.0?' "$out"
    has 'option 1 keeps this version' 'Cancelled; nothing changed' "$out"
    ok_if 'nothing is restored on No' test ! -e "$E/sbin/darban"
    out=$(menu '9\n4\n2\n')
    has 'it restores' 'Restored v0.9.0' "$out"
    ok_if 'the program is back' test -s "$E/sbin/darban"
    ok_if 'the library is back' test -s "$E/lib/old-marker"
    ok_if 'the units are back' test -s "$E/units/darban-crl.timer"
    ok_if 'that backup is used up' test ! -e "$backup"
    ok_if 'the CA was not touched' test -s "$PKI/ca.crt"
    grep -q 'restored previous version' "$STUB_LOG"; rc_is 'the restore is audited' 0 "$?"
}

tool_version() { printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$E/fake-tool"; chmod +x "$E/fake-tool"; }

test_get_sh_knows_install_from_update() {
    local out rc
    fake_release
    out=$(bash "$E/get.sh" 2>&1 </dev/null)
    has 'nothing installed: it installs' 'Installing Darban OVPN v9.9.9' "$out"
    ok_if 'the installer ran' test -s "$MARKER"

    tool_version 1.0.0; rm -f "$MARKER"
    out=$(bash "$E/get.sh" 2>&1 </dev/null)
    has 'an older version: it updates' 'Updating Darban OVPN from v1.0.0 to v9.9.9' "$out"
    ok_if 'the update ran' test -s "$MARKER"

    tool_version 9.9.9-rc.1; rm -f "$MARKER"
    out=$(bash "$E/get.sh" 2>&1 </dev/null)
    has 'a pre-release of it: it updates' 'from v9.9.9-rc.1 to v9.9.9' "$out"

    tool_version 9.9.9; rm -f "$MARKER"
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    has 'an install that never finished is repaired' 'Repairing the installation of Darban OVPN v9.9.9' "$out"
    ok_if 'the repair ran the installer' test -s "$MARKER"
    rm -f "$MARKER"; echo 9.9.9 > "$E/install-record"
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_is 'the same version is not an error' 0 "$rc"
    has 'the same version: nothing to do' 'already up to date' "$out"
    ok_if 'nothing was installed' test ! -e "$MARKER"
    out=$(bash "$E/get.sh" --version v9.9.9 2>&1 </dev/null)
    has 'asked by name, it installs again' 'again' "$out"
    ok_if 'it did install' test -s "$MARKER"

    tool_version 10.0.0; rm -f "$MARKER"
    out=$(bash "$E/get.sh" 2>&1 </dev/null); rc=$?
    rc_is 'a newer installed version is not an error' 0 "$rc"
    has 'it never goes back by itself' 'is newer than v9.9.9' "$out"
    ok_if 'nothing was installed' test ! -e "$MARKER"
    out=$(bash "$E/get.sh" --version v9.9.9 2>&1 </dev/null)
    has 'going back needs the version named' 'Going back from Darban OVPN v10.0.0 to v9.9.9' "$out"
    ok_if 'it did go back' test -s "$MARKER"
}

test_get_sh_survives_a_partial_download() {
    local out rc
    fake_release
    : > "$STUB_LOG"
    head -n -1 "$E/get.sh" > "$E/cut.sh"
    out=$(bash "$E/cut.sh" 2>&1 </dev/null)
    ok_if 'without the last line nothing runs' test ! -e "$MARKER"
    if grep -q '^curl' "$STUB_LOG"; then result 0 'without the last line nothing is downloaded'; else result 1 'without the last line nothing is downloaded'; fi
    # A few lines into main, so the cut always lands inside a function.
    head -n "$(( $(grep -n '^main() {' "$E/get.sh" | cut -d: -f1) + 5 ))" "$E/get.sh" > "$E/cut.sh"
    out=$(bash "$E/cut.sh" 2>&1 </dev/null); rc=$?
    rc_not0 'cut inside a function is an error' "$rc"
    ok_if 'cut inside a function nothing runs' test ! -e "$MARKER"
    if grep -q '^curl' "$STUB_LOG"; then result 0 'cut inside a function nothing is downloaded'; else result 1 'cut inside a function nothing is downloaded'; fi
}

test_get_sh_knows_when_sudo_keeps_the_keys() {
    local P=$E/proc out REPO_SAVED=$REPO REPO RELEASE_TAG
    local -a given_args
    fake_proc() { # fake_proc PID PPID TTY COMM [FD0]
        mkdir -p "$P/$1/fd"
        printf '%s (%s) S %s %s %s %s 0 0\n' "$1" "$4" "$2" "$1" "$1" "$3" > "$P/$1/stat"
        printf '%s\n' "$4" > "$P/$1/comm"
        if [[ -n ${5:-} ]]; then ln -sfn "$5" "$P/$1/fd/0"; fi
    }
    eval "$(sed -n -e '/^keys_cannot_reach_setup() {/,/^}/p' -e '/^right_command() {/,/^}/p' "$REPO_SAVED/setup/get.sh")"
    # A login shell on the user's terminal (34816).
    fake_proc 200 1 34816 bash /dev/pts/0
    # "curl ... | sudo bash" with use_pty: sudo reads the pipe, and the command has a terminal of its own (34817).
    fake_proc 298 200 34816 sudo 'pipe:[11]'
    fake_proc 299 298 34817 sudo /dev/pts/1
    fake_proc 300 299 34817 bash 'pipe:[12]'
    ok_if 'the pipe into sudo with a terminal of its own is caught' keys_cannot_reach_setup "$P" 300
    # The same without use_pty: one terminal, and the keys arrive.
    fake_proc 310 298 34816 bash 'pipe:[12]'
    ok_if 'without use_pty it goes on' eval '! keys_cannot_reach_setup "$P" 310'
    # "sudo bash -c 'curl ... | bash'": sudo reads the terminal.
    fake_proc 398 200 34816 sudo /dev/pts/0
    fake_proc 399 398 34818 sudo /dev/pts/2
    fake_proc 400 399 34818 bash 'pipe:[13]'
    ok_if 'the documented form goes on' eval '! keys_cannot_reach_setup "$P" 400'
    # The documented form started from a script that itself runs under a sudo fed by a pipe: only the nearest
    # sudo counts.
    fake_proc 196 1 0 sudo 'pipe:[9]'
    fake_proc 197 196 0 bash 'pipe:[9]'
    fake_proc 201 197 34816 bash /dev/pts/0
    fake_proc 498 201 34816 sudo /dev/pts/0
    fake_proc 499 498 34819 sudo /dev/pts/3
    fake_proc 500 499 34819 bash 'pipe:[14]'
    ok_if 'only the nearest sudo counts' eval '! keys_cannot_reach_setup "$P" 500'
    # As root without sudo: "curl ... | bash".
    fake_proc 600 200 34816 bash 'pipe:[15]'
    ok_if 'no sudo: it goes on' eval '! keys_cannot_reach_setup "$P" 600'
    # sudo-rs names itself sudo too; a name with spaces and brackets does not confuse the reading.
    fake_proc 700 1 34816 'tmux: server (1)' /dev/pts/0
    fake_proc 701 700 34816 sudo 'pipe:[16]'
    fake_proc 702 701 34820 sudo /dev/pts/4
    fake_proc 703 702 34820 bash 'pipe:[17]'
    ok_if 'a parent with an odd name is read correctly' keys_cannot_reach_setup "$P" 703

    REPO=MohZeh/Darban-OVPN RELEASE_TAG=v1.2.3 given_args=()
    out=$(right_command)
    has 'the message names this release and the form that works' \
        "sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/download/v1.2.3/get.sh | bash'" "$out"
    RELEASE_TAG='' given_args=(--port 1195 --open-ufw)
    out=$(right_command)
    has 'the options given are kept' \
        "sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/latest/download/get.sh | bash -s -- --port 1195 --open-ufw'" "$out"
    given_args=(--dns '1.1.1.1 8.8.8.8')
    out=$(right_command)
    has 'options that need quotes become a placeholder' '| bash -s -- OPTIONS' "$out"
}

test_get_sh_from_a_pipe() {
    local out rc
    fake_release
    printf '#!/usr/bin/env bash\necho "$*" >> "$MARKER.setup"\n' > "$E/fixture/setup/server-setup.sh"
    tar -C "$E/fixture" -czf "$RELEASE/darban-ovpn.tar.gz" setup VERSION
    (cd "$RELEASE" && sha256sum darban-ovpn.tar.gz > SHA256SUMS)
    rm "$SERVER_CONF"
    out=$(cat "$E/get.sh" | setsid -w bash 2>&1); rc=$?
    rc_not0 'no terminal and no answers is an error' "$rc"
    has 'it says what to do' 'There is no terminal' "$out"
    ok_if 'no setup ran' test ! -e "$MARKER.setup"
    out=$(cat "$E/get.sh" | setsid -w bash -s -- --yes --host vpn.example.com --port 1194 2>&1); rc=$?
    rc_is 'answers need no terminal' 0 "$rc"
    grep -qx -- '--yes --host vpn.example.com --port 1194' "$MARKER.setup"; rc_is 'the answers reach the setup' 0 "$?"
    out=$(bash "$E/get.sh" --nonsense 2>&1 </dev/null); rc=$?
    rc_not0 'an unknown option is refused' "$rc"
    has 'it shows the usage' 'Usage: get.sh' "$out"
}

test_get_sh_explains_a_failed_download() {
    local out
    fake_release
    out=$(CURL_FAIL=1 bash "$E/get.sh" 2>&1 </dev/null)
    has 'no stable release' 'No stable release is published yet' "$out"
    out=$(CURL_FAIL=1 bash "$E/get.sh" --version v1.2.3 2>&1 </dev/null)
    has 'an unknown version' 'Release v1.2.3 was not found' "$out"
    out=$(CURL_FAIL=1 CURL_RC=6 bash "$E/get.sh" 2>&1 </dev/null)
    has 'no network' 'internet connection' "$out"
}

test_release_assets_know_their_version() {
    local out=$WORK/release-assets version
    version=$(cat "$REPO/VERSION")
    bash "$REPO/scripts/build-release.sh" "$out" >/dev/null 2>&1; rc_is 'the assets build' 0 "$?"
    grep -qx "RELEASE_TAG=v$version" "$out/get.sh"; rc_is 'the published script names its release' 0 "$?"
    ok_if 'the source script stays unnamed' grep -qx "RELEASE_TAG=''" "$REPO/setup/get.sh"
    bash -n "$out/get.sh"; rc_is 'the published script is valid' 0 "$?"
    if tar -tzf "$out/darban-ovpn.tar.gz" | grep -q '^tests/'; then result 0 'tests are not published'; else result 1 'tests are not published'; fi
    tar -tzf "$out/darban-ovpn.tar.gz" | grep -qx 'VERSION'; rc_is 'the archive states its version' 0 "$?"
    (cd "$out" && sha256sum --quiet -c SHA256SUMS >/dev/null); rc_is 'the checksums match' 0 "$?"
}

test_server_setup_continues_after_a_failure() {
    local out rc record
    prepare_blank_server
    record=$E/cfg/.server-setup-started
    out=$(printf '\n\n3\n' | bash "$E/setup/server-setup.sh" 2>&1)
    lacks 'a cancelled setup offers nothing to undo' 'To undo everything' "$out"
    ok_if 'a cancelled setup changes nothing' test ! -e "$record"

    out=$(FAIL_RESTART=1 setup_run --port 21194 --yes); rc=$?
    rc_not0 'a failed start is reported' "$rc"
    has 'it says how to try again' 'run the same command' "$out"
    has 'it says how to undo it' "$SETUP_ROOT/lib/remove-server.sh --yes" "$out"
    ok_if 'the way back is already installed' test -s "$SETUP_ROOT/lib/remove-server.sh"
    if grep -qx setup_complete "$record"; then result 0 'it is not recorded as finished'; else result 1 'it is not recorded as finished'; fi

    out=$(setup_run --yes); rc=$?
    rc_is 'running it again finishes' 0 "$rc"
    has 'it says it continues' 'continues from where it stopped' "$out"
    grep -q '^port 21194$' "$E/server/server.conf"; rc_is 'the earlier port stays' 0 "$?"
    grep -qx setup_complete "$record"; rc_is 'now it is recorded as finished' 0 "$?"

    out=$(setup_run --port 21194 --yes); rc=$?
    rc_not0 'a finished server is refused' "$rc"
    has 'it says why' 'already exists' "$out"
}

test_server_setup_failure_can_be_undone() {
    local out rc
    prepare_blank_server
    FAIL_RESTART=1 setup_run --port 21194 --yes >/dev/null
    install_removal_scripts
    out=$(bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null); rc=$?
    rc_is 'the undo finishes' 0 "$rc"
    ok_if 'the configuration is gone' test ! -e "$E/server/server.conf"
    ok_if 'the record is gone' test ! -e "$E/cfg"
    ok_if 'the CA is gone' test ! -e "$PKI"
}

test_server_setup_survives_a_lost_connection() {
    local pid rc attempt
    prepare_blank_server
    sed -i '1a if [[ " $* " == *" -y -q "* ]]; then sleep 2; fi' "$E/bin/apt-get"
    bash "$E/setup/server-setup.sh" --port 21194 --yes >/dev/null 2>&1 </dev/null &
    pid=$!
    for attempt in $(seq 1 100); do
        if grep -q -- ' -y -q ' "$STUB_LOG" 2>/dev/null; then break; fi
        sleep 0.1
    done
    kill -HUP "$pid" 2>/dev/null
    wait "$pid"; rc=$?
    rc_is 'a hangup does not stop the setup' 0 "$rc"
    grep -qx setup_complete "$E/cfg/.server-setup-started"; rc_is 'the setup finished' 0 "$?"
}

test_server_setup_installs_a_kernel_only_when_needed() {
    local out rc
    prepare_blank_server
    : > "$STUB_LOG"
    out=$(FAKE_OVPN=1 setup_run --port 21194 --yes); rc=$?
    rc_is 'setup finishes' 0 "$rc"
    has 'it says why no kernel is installed' 'already has the ovpn module' "$out"
    if grep -q 'linux-image' "$STUB_LOG"; then result 0 'no kernel is planned or installed'; else result 1 'no kernel is planned or installed'; fi
    if grep -q '^kernel ' "$E/cfg/.server-setup-started"; then result 0 'no kernel is recorded'; else result 1 'no kernel is recorded'; fi
    lacks 'no reboot is asked for' 'Reboot' "$(FAKE_OVPN=1 mgr welcome)"

    prepare_blank_server_again
    out=$(FAKE_OVPN=1 setup_run --port 21194 --install-kernel --yes); rc=$?
    rc_is 'asking for the kernel works' 0 "$rc"
    grep -q 'nftables linux-image-virtual-hwe-24.04' "$STUB_LOG"; rc_is 'the kernel is installed when asked' 0 "$?"
}
prepare_blank_server_again() {
    rm -rf "$PKI" "$E/cfg" "$E/server/server.conf"
    mkdir -p "$E/cfg"
    : > "$STUB_LOG"
}

test_broken_server_can_still_be_diagnosed_and_removed() {
    local out rc
    fake_release
    cp "$E/get.sh" "$E/lib/get.sh"
    mv "$PKI/ca.crt" "$E/ca.keep"

    out=$(mgr status); rc=$?
    rc_is 'diagnostics report the problem by status' 1 "$rc"
    has 'diagnostics name the problem' 'CA or OpenVPN server configuration is missing' "$out"
    has 'diagnostics go on to the rest' 'Listening on UDP' "$out"
    out=$(mgr list); rc=$?
    rc_is 'a command that needs the CA refuses' 1 "$rc"
    has 'it says where to look' 'sudo darban status' "$out"
    out=$(menu '0\n')
    has 'the menu says what is wrong' 'cannot be managed right now' "$out"
    has 'the menu offers removal' 'Remove everything' "$out"
    lacks 'the menu hides what cannot work' 'Create client' "$out"
    out=$(menu '1\n\n0\n')
    has 'the menu offers diagnostics' 'Listening on UDP' "$out"
    release_list 9.9.9
    out=$(bash "$E/manager.sh" update 2>&1 <<<'9.9.9')
    has 'an update still works' 'Updated to v9.9.9' "$out"
    has 'removing the tool is still offered' 'This removes the tool' "$(mgr uninstall)"
    has 'removing everything still answers' 'was not set up by this tool' "$(mgr remove-all)"
    mv "$E/ca.keep" "$PKI/ca.crt"

    openssl pkey -in "$PKI/private/ca.key" -aes256 -passout pass:x -out "$E/ca.enc" 2>/dev/null
    cp "$PKI/private/ca.key" "$E/ca.plain"; cp "$E/ca.enc" "$PKI/private/ca.key"
    out=$(mgr status); rc=$?
    rc_is 'a password-protected CA is reported by status' 1 "$rc"
    has 'it is named' 'CA key is encrypted' "$out"
    cp "$E/ca.plain" "$PKI/private/ca.key"

    mv "$SERVER_CONF" "$E/conf.keep"
    out=$(mgr status); rc=$?
    rc_is 'a missing server.conf is reported by status' 1 "$rc"
    lacks 'without raw errors' 'No such file' "$out"
    mv "$E/conf.keep" "$SERVER_CONF"
    mgr status >/dev/null; rc_is 'a repaired server is healthy again' 0 "$?"
}

test_status_exit_code_follows_the_checklist() {
    local out rc
    out=$(mgr status); rc=$?
    rc_is 'healthy means 0' 0 "$rc"
    if (( rc != 0 )); then printf '%s\n' "$out" | grep -F '✗' | cut -c1-150 | sed 's/^/    | /'; fi
    rm "$CRL"
    out=$(mgr status); rc=$?
    rc_is 'a problem means 1' 1 "$rc"
    has 'and the checklist shows it' "The CRL file $CRL is missing" "$out"
}

test_management_is_only_reported_when_it_works() {
    local out
    sed -i '/^management /d' "$SERVER_CONF"
    printf 'management /run/test.sock unix\n' >> "$SERVER_CONF"
    printf '#!/usr/bin/env bash\n' > "$E/bin/socat"; chmod +x "$E/bin/socat"
    has 'with socat it is available' 'single-client disconnect available' "$(mgr status)"
    rm "$E/bin/socat"
    if ! command -v socat >/dev/null; then
        has 'without socat it is not' 'Management interface: not configured' "$(mgr status)"
    fi
}

test_disconnect_advice_is_not_an_open_port() {
    local out
    sed -i '/^management /d' "$SERVER_CONF"
    out=$(printf '4\nalice\nalice\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'it advises a local socket' 'darban.sock unix' "$out"
    lacks 'it does not advise a TCP port' '7505' "$out"
}

test_lock_is_held_only_for_changes() {
    local out
    : > "$STUB_LOG"
    out=$(printf '4\nalice\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'the revoke was cancelled' 'Cancelled' "$out"
    if grep -q '^flock' "$STUB_LOG"; then result 0 'no lock while waiting for an answer'; else result 1 'no lock while waiting for an answer'; fi
    : > "$STUB_LOG"
    out=$(printf '1\n\n\n0\n' | bash "$E/manager.sh" 2>&1)
    if grep -q '^flock' "$STUB_LOG"; then result 0 'a cancelled create takes no lock'; else result 1 'a cancelled create takes no lock'; fi
    : > "$STUB_LOG"
    out=$(printf '4\nalice\nalice\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'a confirmed revoke finishes' 'alice is revoked' "$out"
    grep -q '^flock -n' "$STUB_LOG"; rc_is 'the change takes the lock' 0 "$?"
    grep -q '^flock -u' "$STUB_LOG"; rc_is 'and gives it back before asking about the session' 0 "$?"
}

test_changes_made_during_a_question_are_noticed() {
    local out
    out=$(printf '4\nalice\nalice\n\n0\n' | FLOCK_HOOK='easyrsa revoke alice' bash "$E/manager.sh" 2>&1)
    has 'a client revoked meanwhile is not revoked again' 'changed while this question was open' "$out"
    out=$(printf '1\nbob\n\n0\n' | FLOCK_HOOK='easyrsa build-client-full bob nopass' bash "$E/manager.sh" 2>&1)
    has 'a name taken meanwhile is refused' 'created by another session' "$out"
}

test_a_number_is_never_mistaken_for_a_name() {
    local out
    out=$(printf '1\n123\n\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'a name of digits only is refused' 'only digits' "$out"
    ok_if 'no such client was made' test ! -e "$PKI/issued/123.crt"
    easyrsa build-client-full 2 nopass >/dev/null 2>&1
    out=$(printf '4\n2\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'the exact name wins over the list number' 'Revoke 2 permanently' "$out"
    out=$(printf '4\n1\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'other numbers still pick from the list' 'Revoke 2 permanently' "$out"
}

test_address_setting_accepts_a_real_address_only() {
    local out
    out=$(printf '7\n1\n300.1.1.1\n\n\n0\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'an impossible IP is refused' 'Enter a hostname' "$out"
    out=$(printf '7\n1\n203.0.113.9\n2\n\n0\n0\n' | bash "$E/manager.sh" 2>&1)
    grep -qx '203.0.113.9' "$E/cfg/domain"; rc_is 'a real IP is saved' 0 "$?"
}

test_remove_everything_keeps_files_it_did_not_create() {
    local out rc
    built_server
    printf 'someone else\n' > "$E/server/other.conf"
    out=$(bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null); rc=$?
    rc_is 'the removal finishes' 0 "$rc"
    ok_if 'the other file stays' test -s "$E/server/other.conf"
    ok_if 'its own configuration is gone' test ! -e "$E/server/server.conf"
    has 'it says what stayed' 'this setup did not create them' "$out"
}

test_setup_needs_only_enter() {
    local out rc port
    prepare_blank_server
    out=$(printf '\n\n\n' | bash "$E/setup/server-setup.sh" 2>&1); rc=$?
    rc_is 'Enter at every question installs' 0 "$rc"
    has 'each question says what Enter does' 'Press Enter to use 203.0.113.50' "$out"
    has 'and how to answer otherwise' 'Or type another IP or hostname, then press Enter' "$out"
    has 'the port question too' 'A free port was picked at random' "$out"
    grep -qx '203.0.113.50' "$E/cfg/domain"; rc_is 'the detected address is used' 0 "$?"
    port=$(awk '$1=="port" {print $2}' "$E/server/server.conf")
    [[ $port =~ ^[0-9]+$ ]] && (( port >= 1024 && port <= 1999 && port != 1194 )); rc_is 'a random port from 1024 to 1999 is used, not 1194' 0 "$?"
    grep -qx setup_complete "$E/cfg/.server-setup-started"; rc_is 'the setup finished' 0 "$?"
}

test_setup_screen_is_quiet() {
    local out rc
    prepare_blank_server
    sed -i '1a echo NOISE-FROM-APT' "$E/bin/apt-get"
    out=$(printf '\n\n\n' | bash "$E/setup/server-setup.sh" 2>&1); rc=$?
    rc_is 'setup finishes' 0 "$rc"
    has 'the steps are numbered' '[5/5] Starting OpenVPN' "$out"
    lacks 'apt output stays off the screen' 'NOISE-FROM-APT' "$out"
    lacks 'the plan stays off the screen' 'adds the OpenVPN project' "$out"
    grep -q NOISE-FROM-APT "$E/setup.log"; rc_is 'apt output is in the log' 0 "$?"

    prepare_blank_server_again
    sed -i '1a echo LAST-WORDS-OF-APT' "$E/bin/systemctl"
    out=$(FAIL_RESTART=1 setup_run --port 21194 --yes); rc=$?
    rc_not0 'a failure is reported' "$rc"
    has 'it shows the end of the log' 'LAST-WORDS-OF-APT' "$out"
    has 'and what failed' 'OpenVPN did not start' "$out"
    has 'and names the log' 'setup.log' "$out"

    prepare_blank_server_again
    out=$(printf '\n\n2\n3\n' | bash "$E/setup/server-setup.sh" 2>&1)
    has 'details are one choice away' 'adds the OpenVPN project' "$out"
    has 'cancel changes nothing' 'nothing was changed' "$out"
}

test_setup_finds_the_address_behind_nat() {
    local out
    prepare_blank_server
    out=$(printf '\n\n3\n' | FAKE_LOCAL_IP=10.0.0.4 FAKE_PUBLIC_IP=198.51.100.7 bash "$E/setup/server-setup.sh" 2>&1)
    has 'the public address is the default' 'Press Enter to use 198.51.100.7' "$out"
    lacks 'without a warning about a private address' 'private address' "$out"
    out=$(printf '\n203.0.113.9\n\n3\n' | FAKE_LOCAL_IP=10.0.0.4 bash "$E/setup/server-setup.sh" 2>&1)
    has 'without an answer it says so' 'could not be detected' "$out"
    has 'and gives an example' 'Example: 203.0.113.10 or vpn.example.com' "$out"
    has 'Enter alone asks again' 'Enter a hostname such as' "$out"
    out=$(printf '\n\n3\n' | FAKE_LOCAL_IP=10.0.0.4 FAKE_PUBLIC_IP=10.9.9.9 bash "$E/setup/server-setup.sh" 2>&1)
    has 'a private answer is not trusted' 'could not be detected' "$out"
    out=$(FAKE_LOCAL_IP=10.0.0.4 FAKE_PUBLIC_IP=198.51.100.7 setup_run --port 21194 --yes)
    grep -qx '198.51.100.7' "$E/cfg/domain"; rc_is 'the unattended setup uses it too' 0 "$?"
}

test_setup_suggests_a_free_port() {
    local out
    prepare_blank_server
    printf '#!/usr/bin/env bash\nlast=${*: -1}; want=${last##*:}; for p in ${BUSY_PORTS:-}; do if [[ $p == "$want" ]]; then echo "UNCONN 0 0 0.0.0.0:$want 0.0.0.0:*"; fi; done\n' > "$E/bin/ss"
    # shuf gives the ports of $E/shuf-seq one by one, so the random choice can be tested.
    printf '#!/usr/bin/env bash\nIFS= read -r p < "%s" || exit 1; sed -i 1d "%s"; echo "$p"\n' "$E/shuf-seq" "$E/shuf-seq" > "$E/bin/shuf"
    chmod +x "$E/bin/ss" "$E/bin/shuf"
    export BUSY_PORTS='1500 1700'
    printf '1194\n1500\n1600\n' > "$E/shuf-seq"
    out=$(printf '\n1700\n70000\n\n3\n' | bash "$E/setup/server-setup.sh" 2>&1)
    has 'the suggestion says why it is not 1194' 'A free port was picked at random' "$out"
    has 'Enter takes a free random port, never 1194' 'Press Enter to use 1600' "$out"
    has 'a busy answer gets a suggestion' 'Port 1700 is already in use. Suggested: 1600' "$out"
    has 'an impossible answer gets one too' 'Enter a number from 1024 to 65535. Suggested: 1600' "$out"
    has 'the summary shows the choice' '1600/UDP' "$out"
    printf '1500\n1601\n' > "$E/shuf-seq"
    out=$(setup_run --yes)
    grep -q '^port 1601$' "$E/server/server.conf"; rc_is 'the unattended setup takes a free random port' 0 "$?"
    prepare_blank_server_again
    : > "$E/shuf-seq"
    export BUSY_PORTS='1024'
    out=$(setup_run --yes)
    grep -q '^port 1025$' "$E/server/server.conf"; rc_is 'without shuf, the first free port of the range' 0 "$?"
    unset BUSY_PORTS
    rm -f "$E/bin/shuf"
}

test_setup_firewall_question() {
    local out port
    prepare_blank_server
    out=$(printf '\n\n3\n' | bash "$E/setup/server-setup.sh" 2>&1)
    lacks 'no ufw: no question' 'ufw is active' "$out"
    printf '#!/usr/bin/env bash\necho "ufw $*" >> "$STUB_LOG"\nif [[ ${1:-} == status ]]; then echo "Status: inactive"; fi\n' > "$E/bin/ufw"; chmod +x "$E/bin/ufw"
    out=$(printf '\n\n3\n' | bash "$E/setup/server-setup.sh" 2>&1)
    lacks 'ufw off: no question' 'ufw is active' "$out"
    printf '#!/usr/bin/env bash\necho "ufw $*" >> "$STUB_LOG"\nif [[ ${1:-} == status ]]; then echo "Status: active"; fi\n' > "$E/bin/ufw"
    : > "$STUB_LOG"
    out=$(printf '\n\n\n\n' | bash "$E/setup/server-setup.sh" 2>&1)
    has 'ufw on: it explains' 'ufw is active here' "$out"
    port=$(awk '$1=="port" {print $2}' "$E/server/server.conf")
    grep -q "ufw allow $port/udp" "$STUB_LOG"; rc_is 'Enter adds the rule for the chosen port' 0 "$?"
    grep -q 'ufw route allow in on tun0 out on eth0' "$STUB_LOG"; rc_is 'Enter adds the forwarding rule' 0 "$?"
}

test_diagnostics_see_ufw_turned_on_later() {
    local out
    local port
    port=$(awk '$1=="port" {print $2}' "$SERVER_CONF")
    printf '#!/usr/bin/env bash\necho "Status: active"\n' > "$E/bin/ufw"; chmod +x "$E/bin/ufw"
    out=$(mgr status)
    has 'a missing port rule is reported' "sudo ufw allow $port/udp" "$out"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "%s/udp ALLOW Anywhere"\n' "$port" > "$E/bin/ufw"
    out=$(mgr status)
    has 'a missing forwarding rule is reported' 'sudo ufw route allow in on tun0' "$out"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "%s/udp ALLOW Anywhere"\necho "Anywhere on eth0 ALLOW FWD Anywhere on tun0"\n' "$port" > "$E/bin/ufw"
    has 'both rules are fine' 'ufw allows the VPN' "$(mgr status)"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "%s/udp DENY Anywhere"\necho "Anywhere on eth0 ALLOW FWD Anywhere on tun0"\n' "$port" > "$E/bin/ufw"
    has 'a DENY rule for the port is not an ALLOW' "sudo ufw allow $port/udp" "$(mgr status)"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "%s/udp ALLOW Anywhere"\necho "Anywhere DENY IN Anywhere on tun0"\n' "$port" > "$E/bin/ufw"
    has 'tun0 in another rule is not the forwarding rule' 'sudo ufw route allow in on tun0' "$(mgr status)"
    printf '#!/usr/bin/env bash\necho "Status: inactive"\n' > "$E/bin/ufw"
    lacks 'ufw off is not mentioned' 'ufw' "$(mgr status)"
}

test_diagnostics_check_the_live_network_rules() {
    # A stand-in for nft that answers from files: what the kernel runs, not what nat.nft says.
    local out
    printf 'server 10.8.0.0 255.255.255.0\n' >> "$SERVER_CONF"
    cat > "$E/bin/nft" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    'list table ip darban') [[ -e $E/live-post ]] ;;
    'list chain ip darban postrouting') cat "$E/live-post" 2>/dev/null ;;
    'list chain ip darban forward') cat "$E/live-forward" 2>/dev/null ;;
    'list chain ip darban input') cat "$E/live-input" 2>/dev/null ;;
    'list chain ip darban output') cat "$E/live-output" 2>/dev/null ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$E/bin/nft"
    source "$REPO/lib/common.sh"
    darban_nat_rules 10.8.0.0 eth0 > "$E/cfg/nat.nft"
    printf '\t\tip saddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280\n' > "$E/live-input"
    printf '\t\tip daddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280\n' > "$E/live-output"
    printf '\t\tip saddr 10.8.0.0/24 oifname "eth0" masquerade\n' > "$E/live-post"
    printf '\t\tip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop\n\t\tip saddr 10.8.0.0/24 ip daddr 169.254.0.0/16 drop\n\t\tip saddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280\n\t\tip daddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280\n' > "$E/live-forward"
    # The interfaces this server has, and the one of its default route.
    cat > "$E/bin/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    '-4 route show default') echo "default via 192.0.2.1 dev ${FAKE_ROUTE_IFACE:-eth0} proto dhcp" ;;
    'link show dev '*) [[ " ${FAKE_IFACES:-eth0} " == *" $4 "* ]] ;;
esac
STUB
    chmod +x "$E/bin/ip"
    out=$(mgr status)
    has 'both live rules pass' 'VPN clients are kept apart' "$out"
    has 'the TCP size rule passes' 'TCP MSS for VPN traffic is limited to 1280 in both directions' "$out"
    : > "$E/live-input"
    has 'a missing rule for connections to the server itself is reported' 'The TCP MSS rule for VPN traffic is missing or different' "$(mgr status)"
    printf '\t\tip saddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280\n' > "$E/live-input"
    sed -i '/maxseg/d' "$E/live-forward"
    out=$(mgr status)
    has 'a missing TCP size rule is reported, with the installer as the fix' 'The TCP MSS rule for VPN traffic is missing or different' "$out"
    has 'and the installer is named' '--version v' "$out"
    lacks 'and it is not called fine' 'TCP MSS for VPN traffic is limited to 1280 in both directions' "$out"
    has 'the live NAT passes' 'NAT for the VPN network 10.8.0.0/24 present' "$out"
    printf '		ip saddr 10.8.0.0/24 oifname "eth0" accept
' > "$E/live-post"
    has 'a rule without masquerade does not pass' 'NAT does not match the VPN network 10.8.0.0/24' "$(mgr status)"
    printf '		ip saddr 10.8.0.0/24 oifname "eth0" masquerade
' > "$E/live-post"
    out=$(FAKE_IFACES=ens3 FAKE_ROUTE_IFACE=ens3 mgr status)
    has 'an interface that is gone is reported' 'out through eth0, which this server no longer has' "$out"
    lacks 'and NAT is not called present' 'NAT for the VPN network 10.8.0.0/24 present' "$out"
    has 'the installer is the fix' '--version v' "$out"
    out=$(FAKE_IFACES='eth0 ens3' FAKE_ROUTE_IFACE=ens3 mgr status)
    has 'another default route is a warning' 'but the default route uses ens3' "$out"
    has 'with the exact change' 's/oifname "eth0"/oifname "ens3"/' "$out"
    : > "$E/live-forward"
    out=$(mgr status)
    lacks 'an empty chain does not pass' 'VPN clients are kept apart' "$out"
    has 'an empty chain is reported, with the reload that fixes it' 'sudo systemctl restart darban-nat.service' "$out"
    printf '\t\tip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop\n' > "$E/live-forward"
    lacks 'one missing rule does not pass' 'VPN clients are kept apart' "$(mgr status)"
    printf '\t\tip saddr 10.9.0.0/24 ip daddr 10.9.0.0/24 drop\n\t\tip saddr 10.9.0.0/24 ip daddr 169.254.0.0/16 drop\n' > "$E/live-forward"
    printf '\t\tip saddr 10.9.0.0/24 oifname "eth0" masquerade\n' > "$E/live-post"
    out=$(mgr status)
    lacks 'rules for another network do not pass' 'VPN clients are kept apart' "$out"
    has 'NAT for another network is reported' 'NAT does not match the VPN network 10.8.0.0/24' "$out"
    has 'and what it costs, true for a split tunnel too' 'cannot reach the internet through the VPN' "$out"
    darban_nat_rules 10.9.0.0 eth0 > "$E/cfg/nat.nft"
    has 'a file for another network needs the installer' '--version v' "$(mgr status)"
    rm -f "$E/live-post" "$E/live-forward"
    has 'rules that are not loaded are reported' 'The NAT rules of this tool are not loaded' "$(mgr status)"
}

test_advanced_menu_prints_only_itself() {
    # An unquoted 'download=not set' ran the set builtin, which printed every shell variable.
    local out
    out=$(menu '7\n6\n0\n0\n0\n')
    has 'the Advanced menu opens' 'Download access' "$out"
    lacks 'and prints no shell variables' 'BASH_VERSION=' "$out"
}

test_next_steps_after_a_new_setup() {
    local out rc
    prepare_blank_server
    setup_run --port 21194 --yes >/dev/null
    out=$(mgr welcome); rc=$?
    rc_is 'it works without a terminal' 0 "$rc"
    has 'it says the server is ready' 'Your VPN server is ready' "$out"
    has 'it names the firewall step' 'Open UDP 21194 in your server provider' "$out"
    has 'a new kernel needs a reboot' 'Reboot once when convenient' "$out"
    has 'it says what comes next' 'sudo darban' "$out"
    lacks 'with the module there is no reboot' 'Reboot' "$(FAKE_OVPN=1 mgr welcome)"
}

mgmt_stub() {
    # A management interface that answers with the file $E/mgmt-reply.
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$E/mgmt.sock"
    sed -i '/^management /d' "$SERVER_CONF"
    printf 'management %s unix\n' "$E/mgmt.sock" >> "$SERVER_CONF"
    printf '#!/usr/bin/env bash\ncat >/dev/null\ncat "$E/mgmt-reply"\n' > "$E/bin/socat"; chmod +x "$E/bin/socat"
    printf 'TITLE\tOpenVPN\nEND\n' > "$E/mgmt-reply"
}

test_connected_clients() {
    local out
    mgmt_stub
    has 'nobody connected is said plainly' 'No client is connected right now' "$(mgr connected)"
    lacks 'and the header counts nothing' 'connected' "$(menu '0\n' | grep -E '^  Clients')"
    printf 'TITLE\tOpenVPN\nHEADER\tCLIENT_LIST\tCommon Name\nCLIENT_LIST\talice\t198.51.100.7:51234\t10.8.0.2\t\t10\t20\t2026-11-07 10:00:00\t1\tUNDEF\t0\t0\tAES-256-GCM\nCLIENT_LIST\tUNDEF\t198.51.100.9:4\t\t\t0\t0\t2026-11-07 10:01:00\nEND\n' > "$E/mgmt-reply"
    out=$(mgr connected)
    has 'a connected client is listed' 'alice' "$out"
    has 'with its address, without the port' '198.51.100.7 ' "$out"
    has 'with how long it is connected' 'CONNECTED FOR' "$out"
    has 'and the traffic of this session, down first' '20 B / 10 B' "$out"
    has 'the client list marks it connected' 'connected' "$(mgr list | grep -E '^  alice ')"
    lacks 'a half-open session is not counted' 'UNDEF' "$out"
    has 'the header counts it' '1 connected' "$(menu '0\n')"
    has 'the menu offers it' 'Connected now' "$(menu '3\n\n0\n0\n')"
    sed -i '/^management /d' "$SERVER_CONF"
    has 'without the interface it says so' 'Not available' "$(mgr connected)"
}

test_pty_drive_reads_what_arrived_together() {
    # Two texts in one read are both found, in order; a step never matches text from before the one it follows.
    local script=$E/script out rc
    # A line without " => " only waits.
    printf 'first\nsecond\n' > "$script"
    python3 "$HERE/pty-drive.py" --timeout 5 "$script" -- bash -c 'printf "first\nsecond\n"; sleep 1' >/dev/null 2>&1; rc=$?
    rc_is 'a text that came in the same read as the step before is found' 0 "$rc"
    printf 'second\nfirst\n' > "$script"
    python3 "$HERE/pty-drive.py" --timeout 3 "$script" -- bash -c 'printf "first\nsecond\n"; sleep 4' >/dev/null 2>&1; rc=$?
    rc_is 'and a text from before the step it follows is not' 3 "$rc"
    printf 'ready => x\\r\nready => y\\r\ndone\n' > "$script"
    out=$(python3 "$HERE/pty-drive.py" --timeout 5 "$script" -- bash -c 'echo ready; read -r a; echo ready; read -r b; echo "done $a$b"' 2>&1); rc=$?
    rc_is 'after keys, a step waits for what they caused' 0 "$rc"
    has 'each answer went to its own question' 'done xy' "$out"
}

test_first_client_in_a_real_terminal() {
    # From the end of the setup to a link and a confirmed connection: Enter at every step.
    local script=$E/script out rc
    start_links_stub
    mgmt_stub
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\tclient1\t198.51.100.7:1\t10.8.0.2\t\t1\t1\t2026-11-07 10:00:00\nEND\n' > "$E/mgmt-reply"
    cat > "$script" <<'EOF'
Enter: Create a client => \r
Client name [client1] => \r
Enter: Temporary link => \r
Enter: No password => \r
Enter: Copy link and note => \r
client1 is connected from 198.51.100.7 => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" welcome 2>&1); rc=$?
    rc_is 'the whole path takes only Enter' 0 "$rc"
    has 'it ends with a link' "/l/" "$out"
    has 'and a note for the person receiving it' $'\nNote:\nYour browser will warn' "${out//$'\r'/}"
    has 'Enter copies the link and the note' 'Copied to your clipboard, if your terminal allows it.' "$out"
    has 'which says what a password would do' 'A password on the key protects the profile' "$out"
    lacks 'Enter makes no password' 'shown only now' "$out"
    if grep -q 'ENCRYPTED PRIVATE KEY' "$E/clients/client1.ovpn"; then result 0 'the key stays open without a password'; else result 1 'the key stays open without a password'; fi
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
    ok_if 'the client exists' test -s "$PKI/issued/client1.crt"
    has 'it says what the connection shows' "your provider's firewall let the VPN through" "$out"
    has 'and how to check the internet' 'open a website on that device' "$out"
    lacks 'without claiming the internet works' 'The VPN works' "$out"
}

test_first_client_on_a_public_ip_in_a_real_terminal() {
    # On a public IP the certificate question comes before the password one, as the guide says; Enter is No.
    local script=$E/script out rc
    start_links_stub
    mgmt_stub
    echo 203.0.113.9 > "$E/cfg/domain"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    chmod +x "$E/bin/certbot"
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\tclient1\t198.51.100.7:1\t10.8.0.2\t\t1\t1\t2026-11-07 10:00:00\nEND\n' > "$E/mgmt-reply"
    cat > "$script" <<'EOF'
Enter: Create a client => \r
Client name [client1] => \r
Enter: Temporary link => \r
Enter: Yes, get a certificate => 2\r
Enter: No password => \r
Enter: Copy link and note => \r
client1 is connected from 198.51.100.7 => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" welcome 2>&1); rc=$?
    rc_is 'a public IP also takes only Enter' 0 "$rc"
    has 'it offers a trusted certificate first' "Get a free Let's Encrypt certificate?" "$out"
    has 'and Enter would take it' 'Enter: Yes, get a certificate' "$out"
    has 'it ends with a link on that IP' 'https://203.0.113.9:' "$out"
    if grep -q '^certbot certonly' "$STUB_LOG" 2>/dev/null; then result 0 'choosing No gets no certificate'; else result 1 'choosing No gets no certificate'; fi
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
}

test_own_password_in_a_real_terminal() {
    # A password of your own: a word or a short phrase of at least 9 characters, in letters every keyboard types.
    local script=$E/script out rc
    start_links_stub
    cat > "$script" <<'EOF'
Choose [0-9] => 5\r
Number or name => alice\r
Enter: Temporary link => \r
Enter: No password => 2\r
Password (Enter = the suggested one) => short\r
Use at least 9 characters => سلام دنیای خوب\r
Use only English letters => blue sky 42\r
Enter: Copy link, password and note => 2\r
Press Enter to return => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" 2>&1); rc=$?
    rc_is 'a password of your own' 0 "$rc"
    out=${out//$'\r'/}
    has 'it is taken, and says so' 'Your password is used.' "$out"
    has 'it goes into the block' $'Password:\nblue sky 42\n' "$out"
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
    stop_links_stub
}

test_keep_on_server_copies_each_command_in_a_real_terminal() {
    # Keeping the file is for the admin: no password, and each command can be copied on its own.
    local script=$E/script out rc copied
    cat > "$script" <<'EOF'
Choose [0-9] => 5\r
Number or name => alice\r
Enter: Temporary link => 2\r
Enter: Windows => 2\r
Enter: Copy the command => \r
Press Enter to return => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" 2>&1); rc=$?
    rc_is 'keeping the file in a real terminal' 0 "$rc"
    lacks 'no password is asked' 'Lock the private key' "$out"
    has 'it asks which computer downloads it' 'Which computer will download it?' "$out"
    lacks 'and shows only that command' 'USERPROFILE' "$out"
    copied=$(grep -o $'\e]52;c;[A-Za-z0-9+/=]*' <<<"$out" | tail -n 1 | sed 's/^.*;//' | base64 -d 2>/dev/null)
    [[ $copied == 'scp -P '*' ~/Downloads/' ]]; rc_is 'macOS or Linux gets its command, and Enter copies it' 0 "$?"
    has 'it says what to select if copying is not allowed' 'Select the command with the mouse instead.' "$out"
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
}

test_link_block_and_copy_in_a_real_terminal() {
    # Link, password and note in one block, in the order the copy key copies them; the second option leaves
    # the password out, for sending it another way.
    local script=$E/script out rc copied link password
    start_links_stub
    mgmt_stub
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\tclient1\t198.51.100.7:1\t10.8.0.2\t\t1\t1\t2026-11-07 10:00:00\nEND\n' > "$E/mgmt-reply"
    cat > "$script" <<'EOF'
Enter: Create a client => \r
Client name [client1] => \r
Enter: Temporary link => \r
Enter: No password => 2\r
Password (Enter = the suggested one) => \r
Enter: Copy link, password and note => 2\r
client1 is connected from 198.51.100.7 => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" welcome 2>&1); rc=$?
    rc_is 'a link with a password' 0 "$rc"
    out=${out//$'\r'/}
    link=$(grep -A1 '^Link:$' <<<"$out" | tail -n 1)
    password=$(grep -A1 '^Password:$' <<<"$out" | tail -n 1)
    has 'the suggestion stands on its own line' "Suggested password:"$'\n'"$password"$'\n' "$out"
    has 'Enter takes it, and says so' 'The suggested password is used.' "$out"
    [[ $link == https://*/l/* ]]; rc_is 'the link is on the line under Link:' 0 "$?"
    [[ $password =~ ^[a-km-np-z2-9]{9}$ ]]; rc_is 'the password is on the line under Password:' 0 "$?"
    has 'the three come in one block, in this order' "Link:"$'\n'"$link"$'\n'"Password:"$'\n'"$password"$'\n'"Note:"$'\n' "$out"
    has 'the first option says what it copies' 'Copy link, password and note' "$out"
    copied=$(grep -o $'\e]52;c;[A-Za-z0-9+/=]*' <<<"$out" | tail -n 1 | sed 's/^.*;//' | base64 -d 2>/dev/null)
    has 'the second option copies the link' "Link:"$'\n'"$link" "$copied"
    lacks 'without the password' "$password" "$copied"
    has 'and the note says it comes separately' 'Its password comes to you separately.' "$copied"
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
}

test_setup_in_a_real_terminal() {
    local script=$E/script out rc
    prepare_blank_server
    cat > "$script" <<'EOF'
Server address [203.0.113.50]:  => \r
VPN port [ => 1194\r
Enter: Install now => \r
[5/5] Starting OpenVPN
OpenVPN is running on UDP 1194
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/setup/server-setup.sh" 2>&1); rc=$?
    rc_is 'the real terminal path takes only Enter' 0 "$rc"
    if (( rc != 0 )); then printf '%s\n' "$out" | tail -n 25 | cut -c1-150 | sed 's/^/    | /'; fi
    grep -qx setup_complete "$E/cfg/.server-setup-started"; rc_is 'the setup finished' 0 "$?"
    has 'the address step names a trusted certificate, not a domain, as what avoids the warning' 'the tool can get a trusted certificate' "$out"
    has 'the last check says nothing is installed yet' 'Nothing is installed yet' "$out"
}

test_download_uses_a_copy_the_user_can_read() {
    local out home=$E/home/ali
    mkdir -p "$home"
    printf '#!/usr/bin/env bash\nif [[ ${1:-} == passwd ]]; then echo "ali:x:1000:1000::%s:/bin/bash"; exit 0; fi\nexec /usr/bin/getent "$@"\n' "$home" > "$E/bin/getent"; chmod +x "$E/bin/getent"
    sed -i 's/^DOWNLOAD_SSH_USER=.*/DOWNLOAD_SSH_USER=ali/' "$E/cfg/config"
    out=$(printf '5\nalice\n2\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'the command fetches the copy' "ali@" "$out"
    has 'from the user home' "$home/alice.ovpn" "$out"
    ok_if 'the copy exists' test -s "$home/alice.ovpn"
    out=$(menu '6\n1\n2\n2\n0\n')
    has 'deleting the server copy names the user copy' "The copy made for ali is deleted too" "$out"
    ok_if 'and deletes it' test ! -e "$home/alice.ovpn"
    # A file of the same name that is not this client's profile stays.
    echo 'not a profile' > "$home/alice.ovpn"
    menu '5\nalice\n2\n\n0\n' >/dev/null
    echo 'not a profile' > "$home/alice.ovpn"
    menu '6\n1\n2\n2\n0\n' >/dev/null
    grep -q 'not a profile' "$home/alice.ovpn"; rc_is 'a file that is not the profile stays' 0 "$?"
    menu '1\nbob\n0\n' >/dev/null
    printf '5\nbob\n2\n\n0\n' | bash "$E/manager.sh" >/dev/null 2>&1
    ok_if 'bob has a user copy' test -s "$home/bob.ovpn"
    revoke_menu bob >/dev/null
    ok_if 'revoking deletes the user copy' test ! -e "$home/bob.ovpn"
}

test_link_page_guides_the_person_receiving_it() {
    local url base out
    start_links_stub
    url=$(menu '5\nalice\n1\n1\n0\n' | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
    base=${url%/l/*}
    out=$(web -A 'Mozilla/5.0 (Linux; Android 14)' -H 'Accept-Language: fa-IR,fa;q=0.9,en-US;q=0.8' "$url")
    has 'Android gets the store link' 'play.google.com/store/apps/details?id=net.openvpn.openvpn' "$out"
    has 'a Persian device gets the steps in Persian' 'برنامهٔ OpenVPN Connect را نصب کنید' "$out"
    has 'from right to left' 'dir="rtl"' "$out"
    lacks 'and not in English as well' 'Install the OpenVPN Connect app' "$out"
    out=$(web -A 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)' -H 'Accept-Language: de-DE,de;q=0.9,fa;q=0.5' "$url")
    has 'iPhone gets the App Store link' 'apps.apple.com/app/openvpn-connect' "$out"
    has 'another language first gets English' 'Install the OpenVPN Connect app' "$out"
    lacks 'and no Persian' 'برنامهٔ OpenVPN Connect را نصب کنید' "$out"
    out=$(web -A 'Mozilla/5.0 (Windows NT 10.0)' "$url")
    has 'a computer gets the download page' 'openvpn.net/client/' "$out"
    has 'no language means English' 'Press <b>Download profile</b>' "$out"
    out=$(web -H 'Accept-Language: fa' "$base/l/$(printf 'b%.0s' {1..64})")
    has 'a link that no longer works says so in Persian too' 'این لینک دیگر کار نمی‌کند' "$out"
    stop_links_stub
}

test_first_client_suggests_a_name() {
    local out
    out=$(printf 'bad name!\n\n' | bash "$E/manager.sh" welcome 2>&1)
    has 'without a terminal it only shows the next steps' 'sudo darban' "$out"
    ok_if 'and creates nothing' test ! -e "$PKI/issued/client1.crt"
}

test_link_certificate_for_a_public_ip() {
    local out
    start_links_stub
    echo 203.0.113.9 > "$E/cfg/domain"
    : > "$E/cfg/.server-setup-started"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 1\n' > "$E/bin/certbot"
    chmod +x "$E/bin/certbot"
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'a public IP is offered a trusted certificate' 'For an IP address it lasts six days' "$out"
    grep -q -- '--preferred-profile shortlived --ip-address 203.0.113.9' "$STUB_LOG"; rc_is 'certbot asks for a six-day IP certificate' 0 "$?"
    grep -q -- '--cert-name darban-ovpn-links' "$STUB_LOG"; rc_is 'under a name of its own' 0 "$?"
    if grep -q '^certbot_cert' "$E/cfg/.server-setup-started"; then result 0 'a failed request is not recorded'; else result 1 'a failed request is not recorded'; fi
    has 'it still gives a working link' "https://203.0.113.9:$LINK_TEST_PORT/l/" "$out"
    has 'and says what a password would protect' 'A password on the key protects the profile' "$out"
    menu '6\n1\n2\n0\n' >/dev/null
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    menu '5\nalice\n1\n1\n1\n0\n' >/dev/null
    grep -qx 'certbot_cert darban-ovpn-links' "$E/cfg/.server-setup-started"; rc_is 'a certificate it got is recorded' 0 "$?"
    echo 10.0.0.9 > "$E/cfg/domain"
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    lacks 'a private IP is not offered one' "Let's Encrypt" "$(menu '5\nalice\n1\n1\n0\n')"
    stop_links_stub
}

make_test_ca() {
    # A certificate authority of its own, trusted as the system's, and a certificate from it for $1 in $2/$3,
    # valid for $5 days (30 by default).
    local host=$1 dir=$2 leaf=$3 key=$4 days=${5:-30}
    if [[ ! -s $E/test-ca.pem ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/test-ca.key" -out "$E/test-ca.pem" \
            -days 60 -subj /CN=Darban-Test-Root >/dev/null 2>&1
        cp "$E/test-ca.pem" "$E/system-ca.pem"
    fi
    mkdir -p "$dir"
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$dir/$key" -out "$E/leaf.csr" -subj "/CN=$host" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "$host" > "$E/leaf.ext"
    openssl x509 -req -in "$E/leaf.csr" -CA "$E/test-ca.pem" -CAkey "$E/test-ca.key" -CAcreateserial -days "$days" \
        -extfile "$E/leaf.ext" -out "$dir/$leaf" >/dev/null 2>&1
}

served_fp() {
    timeout 5 openssl s_client -connect "127.0.0.1:$LINK_TEST_PORT" -servername vpn.example.com </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}
file_fp() { openssl x509 -in "$E/cfg/link-cert.pem" -noout -fingerprint -sha256 | sed 's/^.*=//'; }
test_a_certificate_change_reaches_open_links() {
    # Settings changes the certificate while a link is open: the running service takes it at once, without a
    # restart, and one it does not take is undone.
    local out pid old
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    menu '5\nalice\n1\n2\n1\n0\n' >/dev/null
    sleep 0.5
    pid=$(cat "$LINKS_PIDFILE")
    [[ $(served_fp) == "$(file_fp)" ]]; rc_is 'the open link serves the self-signed certificate' 0 "$?"
    ok_if 'the service says it can reload' test -s "$E/links/.reloadable"

    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem
    out=$(menu '7\n5\n3\n1\n0\n0\n')
    has 'the change reaches the open link' 'Open links use it now; no download was interrupted.' "$out"
    [[ $(served_fp) == "$(file_fp)" ]]; rc_is 'the port answers with the new certificate' 0 "$?"
    [[ $(cat "$LINKS_PIDFILE") == "$pid" ]] && kill -0 "$pid"; rc_is 'by a reload, not a restart' 0 "$?"
    grep -q 'certificate reloaded' "$E/links.log"; rc_is 'the service logs the reload' 0 "$?"

    # A reload that does not arrive: the previous pair is put back, and the port still answers with it.
    old=$(file_fp)
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem 40
    out=$(printf '7\n5\n3\n1\n0\n0\n' | FAKE_RELOAD_FAIL=1 bash "$E/manager.sh" 2>&1)
    has 'a change the service did not take is said' 'did not take the new certificate, so the previous one was put back' "$out"
    lacks 'and not called done' 'Open links use it now' "$out"
    [[ $(file_fp) == "$old" && $(served_fp) == "$old" ]]; rc_is 'the file and the port agree on the previous one' 0 "$?"
    ok_if 'no copy is left behind' test ! -e "$E/cfg/.link-cert.prev"
    [[ $(find "$E/cfg/link-cert/pairs" -mindepth 1 -maxdepth 1 | wc -l) == 1 ]]; rc_is 'and only the pair in use is kept' 0 "$?"

    # A service from before this version would end on SIGHUP: it is not sent one.
    rm -f "$E/links/.reloadable"
    : > "$STUB_LOG"
    out=$(menu '7\n5\n3\n1\n0\n0\n')
    has 'an older service is named' 'still runs the version from before the last update' "$out"
    if grep -q 'reload darban-links' "$STUB_LOG"; then result 0 'and gets no reload'; else result 1 'and gets no reload'; fi
    kill -0 "$pid"; rc_is 'and keeps running' 0 "$?"

    # No link open, no service: the next link uses the certificate.
    stop_links_stub; sleep 0.3
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem 50
    has 'without a running service it says when it applies' 'the next link uses this certificate' "$(menu '7\n5\n3\n1\n0\n0\n')"
}

test_link_certificate_screen() {
    # Two lines of state and four choices; Enter changes nothing; the rest is one level down.
    local out before
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/le-own" fullchain.pem privkey.pem
    cp "$E/le-own/fullchain.pem" "$E/cfg/link-cert.pem"; cp "$E/le-own/privkey.pem" "$E/cfg/link-key.pem"
    before=$(sha256sum < "$E/cfg/link-cert.pem")
    out=$(menu '7\n5\n\n0\n0\n')
    has 'the question says what it is for' 'What do you want to do?' "$out"
    has 'Enter keeps the certificate' 'The current certificate stays.' "$out"
    [[ $(sha256sum < "$E/cfg/link-cert.pem") == "$before" ]]; rc_is 'and nothing changed' 0 "$?"
    has 'a certificate from elsewhere offers a trusted one' 'Get a trusted one' "$out"
    has 'other certificates are one choice' 'Use another certificate' "$out"
    lacks 'the count waits for Details' 'Recorded' "$out"
    lacks 'and so does the fingerprint' 'SHA-256' "$out"

    out=$(menu '7\n5\n4\n0\n0\n')
    has 'Details show the fingerprint' "$(openssl x509 -in "$E/cfg/link-cert.pem" -noout -fingerprint -sha256 | sed 's/^.*=//')" "$out"
    has 'and the dates' 'Valid     from ' "$out"
    has 'and the count' 'Recorded' "$out"

    out=$(menu '7\n5\n3\n\n0\n0\n')
    has 'the second level names other tools' 'One another tool got (certbot, 3x-ui, acme.sh)' "$out"
    has 'and says there are two files' 'My own certificate files (fullchain and key)' "$out"
    out=$(menu '7\n5\n3\n4\n0\n0\n')
    has 'Back changes nothing' 'The current certificate stays.' "$out"
    out=$(menu '7\n5\n3\n3\n1\n0\n0\n')
    has 'switching to self-signed asks first' 'Switch the links to a self-signed certificate?' "$out"
    [[ $(sha256sum < "$E/cfg/link-cert.pem") == "$before" ]]; rc_is 'and No keeps the certificate' 0 "$?"
    out=$(menu '7\n5\n3\n3\n2\n0\n0\n')
    has 'Yes switches' 'Links use a self-signed certificate for vpn.example.com' "$out"
    has 'and Settings says so' 'self-signed, browser warning' "$(menu '7\n0\n0\n')"

    # This tool's own certificate: Renew now, with its renewal line; a private address has no Let's Encrypt row.
    mkdir -p "$E/le/live/darban-ovpn-links" "$E/le/renewal"
    cp "$E/le-own/"*.pem "$E/le/live/darban-ovpn-links/"
    echo 'authenticator = standalone' > "$E/le/renewal/darban-ovpn-links.conf"
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    ln -s "$E/le/live/darban-ovpn-links/fullchain.pem" "$E/cfg/link-cert.pem"; ln -s "$E/le/live/darban-ovpn-links/privkey.pem" "$E/cfg/link-key.pem"
    out=$(menu '7\n5\n\n0\n0\n')
    has 'its own certificate is offered a renewal' 'Renew now' "$out"
    has 'with how it stays valid' 'Renewal' "$out"
    echo 10.0.0.9 > "$E/cfg/domain"
    out=$(menu '7\n5\n\n0\n0\n')
    lacks 'a private address has no Let'"'"'s Encrypt row' 'Renew now' "$out"
    lacks 'nor a request' 'Get a trusted one' "$out"
}

test_certbot_hook_reloads_the_link_service() {
    # After a renewal, certbot's hook reloads the link service, so a download in progress finishes. An older hook
    # that restarted it is moved to the reload.
    local conf=$E/le/renewal/darban-ovpn-links.conf
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem
    mkdir -p "$E/le/renewal"
    printf 'authenticator = standalone\nrenew_hook = systemctl try-restart darban-links.service\n' > "$conf"
    menu '5\nalice\n1\n1\n0\n' >/dev/null
    grep -qx "renew_hook = $E/sbin/darban reload-links" "$conf"; rc_is 'an old hook is moved to the reload' 0 "$?"
    if grep -q 'try-restart' "$conf"; then result 0 'the restart is gone'; else result 1 'the restart is gone'; fi
    printf 'authenticator = standalone\nrenew_hook = /usr/local/bin/my-own-hook\n' > "$conf"
    menu '6\n1\n2\n0\n' >/dev/null
    menu '5\nalice\n1\n1\n0\n' >/dev/null
    grep -qx 'renew_hook = /usr/local/bin/my-own-hook' "$conf"; rc_is 'a hook someone else set stays' 0 "$?"

    # The hook itself: a reload for a service that can take one, nothing when no link is open.
    : > "$STUB_LOG"
    bash "$E/manager.sh" reload-links </dev/null >/dev/null 2>&1; rc_is 'reload-links succeeds' 0 "$?"
    grep -q 'reload darban-links.service' "$STUB_LOG"; rc_is 'and reloads the running service' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    stop_links_stub; sleep 0.3
    : > "$STUB_LOG"
    bash "$E/manager.sh" reload-links </dev/null >/dev/null 2>&1; rc_is 'with no service running it does nothing, and succeeds' 0 "$?"
    if grep -Eq 'systemctl (reload|restart) darban-links' "$STUB_LOG"; then result 0 'no reload or restart'; else result 1 'no reload or restart'; fi
}

test_a_kept_link_certificate_is_used_again() {
    # A certificate this tool got before a removal is taken back without a question or a new request.
    local out
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    : > "$E/cfg/.server-setup-started"
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    chmod +x "$E/bin/certbot"
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'the kept certificate is used' "Links use the Let's Encrypt certificate this server got earlier" "$out"
    lacks 'without the question' "Get a free Let's Encrypt certificate?" "$out"
    if grep -q '^certbot' "$STUB_LOG" 2>/dev/null; then result 0 'and without asking Let'"'"'s Encrypt'; else result 1 'and without asking Let'"'"'s Encrypt'; fi
    cmp -s "$E/cfg/link-cert.pem" "$E/le/live/darban-ovpn-links/fullchain.pem"; rc_is 'the links use a copy of it' 0 "$?"
    [[ $(cat "$E/cfg/link-cert/current/kind") == letsencrypt ]]; rc_is 'which says where it came from' 0 "$?"
    grep -qx 'certbot_cert darban-ovpn-links' "$E/cfg/.server-setup-started"; rc_is 'it is recorded again, for a later removal' 0 "$?"
    has 'the link is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    menu '6\n1\n2\n0\n' >/dev/null

    # A kept certificate for another address is named, so nobody wonders why a new one is asked for.
    echo other.example.com > "$E/cfg/domain"
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    has 'a kept certificate for another address says so' 'is for vpn.example.com, not other.example.com' "$(menu '5\nalice\n1\n2\n1\n0\n')"

    # Without certbot's renewal file, one that ends before a link says so, in hours.
    echo vpn.example.com > "$E/cfg/domain"
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem 1
    has 'a kept certificate that ends too soon names the link' 'ends in less than 25 hours, sooner than a link may last' "$(menu '5\nalice\n1\n2\n1\n0\n')"
    stop_links_stub
}

test_link_certificate_renews_and_counts_the_weekly_limit() {
    local out next
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    : > "$E/cfg/.server-setup-started"
    # A certificate of an earlier request that ends within a day: it is renewed, not requested anew.
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem 1
    mkdir -p "$E/le/renewal"; echo 'authenticator = standalone' > "$E/le/renewal/darban-ovpn-links.conf"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    chmod +x "$E/bin/certbot"
    out=$(menu '5\nalice\n1\n1\n0\n')
    grep -q 'certbot renew --non-interactive --cert-name darban-ovpn-links' "$STUB_LOG"; rc_is 'an existing certificate is renewed' 0 "$?"
    if grep -q 'certbot certonly' "$STUB_LOG"; then result 0 'and not requested anew'; else result 1 'and not requested anew'; fi
    has 'a kept certificate that ends too soon is renewed' 'ends sooner than a link may last. Renewing it' "$out"
    lacks 'without a question' "Renew the Let's Encrypt certificate this server got earlier?" "$out"
    has 'a renewal that changed nothing says so' 'Not due for renewal yet' "$out"
    ok_if 'and nothing is recorded' test ! -s "$E/varlib/link-certificates.log"
    menu '6\n1\n2\n0\n' >/dev/null

    # A renewal that brings a new certificate is named, and recorded as a renewal.
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    make_test_ca vpn.example.com "$E/renewed" fullchain.pem privkey.pem
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"\ncp "%s"/*.pem "%s"/\n' \
        "$E/renewed" "$E/le/live/darban-ovpn-links" > "$E/bin/certbot"
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'a real renewal is named' 'Renewed: the certificate for vpn.example.com is valid until' "$out"
    grep -q ' vpn.example.com renew$' "$E/varlib/link-certificates.log"; rc_is 'and recorded as a renewal' 0 "$?"
    has 'Settings counts it apart' '0 new, 1 renewed' "$(menu '7\n5\n4\n0\n0\n')"
    menu '6\n1\n2\n0\n' >/dev/null
    : > "$E/varlib/link-certificates.log"

    # A new request: certbot writes a new certificate, and the tool records it.
    rm -rf "$E/le/live/darban-ovpn-links" "$E/le/renewal" "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    make_test_ca vpn.example.com "$E/new-le" fullchain.pem privkey.pem
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"\nmkdir -p "%s"; cp "%s"/*.pem "%s"/\n' \
        "$E/le/live/darban-ovpn-links" "$E/new-le" "$E/le/live/darban-ovpn-links" > "$E/bin/certbot"
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'a new certificate is named' "New certificate from Let's Encrypt for vpn.example.com, valid until" "$out"
    grep -q -- "--deploy-hook $E/sbin/darban reload-links" "$STUB_LOG"; rc_is 'certbot is told to reload the link service, not restart it' 0 "$?"
    grep -q ' vpn.example.com new$' "$E/varlib/link-certificates.log"; rc_is 'and recorded as new' 0 "$?"
    out=$(menu '7\n5\n4\n0\n0\n')
    has 'Settings counts it' '1 new, 0 renewed in the last 7 days, by this tool for vpn.example.com' "$out"
    has 'and says who keeps the real count' "Let's Encrypt keeps the real count" "$out"
    has 'with the dates of the certificate' 'Valid     from ' "$out"
    # v1.0.0-rc.8 reads the first two fields; a line with the kind still counts there.
    [[ $(awk -v host=vpn.example.com '$2 == host && $1 ~ /^[0-9]+$/' "$E/varlib/link-certificates.log" | wc -l) == 1 ]]; rc_is 'the record still reads in v1.0.0-rc.8' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null

    # Five this week by this server's record: only a warning, since Let's Encrypt keeps the count.
    rm -rf "$E/le/live/darban-ovpn-links" "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    for next in 1 2 3 4; do echo "$(( $(date -u +%s) - next * 600 )) vpn.example.com" >> "$E/varlib/link-certificates.log"; done
    : > "$STUB_LOG"
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'the weekly limit is named' 'This server recorded 5 new certificates for vpn.example.com in the last 7 days' "$out"
    has 'with the time it may refuse until' 'so it may refuse until about' "$out"
    grep -q 'certbot certonly' "$STUB_LOG"; rc_is 'the request is still sent' 0 "$?"
    has 'Settings shows old lines as unknown' '2 new, 0 renewed, 4 of unknown kind' "$(menu '7\n5\n4\n0\n0\n')"
    has 'the link is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    menu '6\n1\n2\n0\n' >/dev/null

    # Let's Encrypt refusing for the limit: its time is shown.
    rm -rf "$E/le/live/darban-ovpn-links" "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    : > "$E/varlib/link-certificates.log"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "An unexpected error occurred: too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s, retry after 2026-11-12 04:12:00 UTC"; exit 1\n' > "$E/bin/certbot"
    has 'a refusal for the limit gives its time' 'The next one can be issued after 2026-11-12 04:12:00 UTC' "$(menu '5\nalice\n1\n1\n1\n0\n')"
    stop_links_stub
}

test_link_uses_a_certificate_already_on_the_server() {
    local out before
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem
    out=$(menu '5\nalice\n1\n1\n1\n0\n')
    has 'a trusted certificate already here is offered first' 'This server already has a trusted certificate for vpn.example.com' "$out"
    has 'and the link is made with it' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    cmp -s "$E/cfg/link-cert.pem" "$E/panel-cert/vpn.example.com/fullchain.pem"; rc_is 'the link service gets a copy it can read' 0 "$?"
    ok_if 'and a link certificate is no longer self-signed' test -s "$E/cfg/link-cert.source"
    lacks 'no browser warning note' 'The note tells the person' "$out"
    lacks 'and no note in the block' $'\nNote:\n' "$out"
    has 'Settings names where it came from' 'trusted' "$(menu '7\n0\n0\n')"
    menu '6\n1\n2\n0\n' >/dev/null

    # Renewed where it lives: the next link takes the new one, without a question.
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'a renewal there reaches the links' 'links use the new one' "$out"
    cmp -s "$E/cfg/link-cert.pem" "$E/panel-cert/vpn.example.com/fullchain.pem"; rc_is 'the new one is copied' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null

    # A renewal seen half way, a new certificate but still the old key, is refused, and the pair in use stays.
    before=$(sha256sum < "$E/cfg/link-cert.pem")
    make_test_ca vpn.example.com "$E/half" fullchain.pem privkey.pem
    cp "$E/half/fullchain.pem" "$E/panel-cert/vpn.example.com/fullchain.pem"
    out=$(menu '5\nalice\n1\n1\n0\n')
    lacks 'a certificate without its new key is not taken' 'links use the new one' "$out"
    [[ $(sha256sum < "$E/cfg/link-cert.pem") == "$before" ]]; rc_is 'and the pair in use stays as it was' 0 "$?"
    cert_key_pair_ok() { [[ $(openssl x509 -in "$E/cfg/link-cert.pem" -noout -pubkey) == "$(openssl pkey -in "$E/cfg/link-key.pem" -pubout)" ]]; }
    cert_key_pair_ok; rc_is 'its certificate and key still belong together' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    cp "$E/half/privkey.pem" "$E/panel-cert/vpn.example.com/privkey.pem"

    # A file chosen by hand: a key that does not belong is refused.
    make_test_ca vpn.example.com "$E/other" cert.pem cert.key
    out=$(menu "7\n5\n3\n2\n$E/other/cert.pem\n$E/panel-cert/vpn.example.com/privkey.pem\n0\n0\n")
    has 'a key from another certificate is refused' 'does not belong to that certificate' "$out"
    out=$(menu "7\n5\n3\n2\n$E/other/cert.pem\n\n0\n0\n")
    has 'the key next to it is suggested and used' 'Links use the trusted certificate from' "$out"
    cmp -s "$E/cfg/link-cert.pem" "$E/other/cert.pem"; rc_is 'the chosen file is used' 0 "$?"
    stop_links_stub
}

test_link_names_a_cloudflare_origin_certificate() {
    local out
    start_links_stub
    echo other.example.com > "$E/cfg/domain"
    mkdir -p "$E/acme/other.example.com_ecc"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/acme/other.example.com_ecc/other.example.com.key" \
        -out "$E/acme/other.example.com_ecc/fullchain.cer" -days 300 \
        -subj '/O=CloudFlare, Inc./OU=CloudFlare Origin SSL Certificate Authority/CN=CloudFlare Origin Certificate' \
        -addext subjectAltName=DNS:other.example.com >/dev/null 2>&1
    out=$(menu '5\nalice\n1\n2\n1\n0\n')
    has 'a Cloudflare Origin certificate is named, with the reason it is not used' 'is a Cloudflare Origin certificate' "$out"
    has "and Let's Encrypt is offered instead" "Get a free Let's Encrypt certificate?" "$out"
    if [[ -s $E/cfg/link-cert.source ]]; then result 0 'it is not used'; else result 1 'it is not used'; fi
    stop_links_stub
}

test_setup_installs_certbot_for_links() {
    local out rc
    prepare_blank_server
    : > "$STUB_LOG"
    setup_run --host vpn.example.com --port 21194 --yes >/dev/null
    grep -q -- '-y -q --no-install-recommends install certbot' "$STUB_LOG"; rc_is 'a hostname gets Ubuntu certbot during setup' 0 "$?"
    grep -qx 'package certbot' "$E/cfg/.server-setup-started"; rc_is 'and it is recorded for removal' 0 "$?"
    prepare_blank_server_again
    : > "$STUB_LOG"
    # Like the real apt-cache, it goes on writing after the Candidate line. A reader that stops there kills it
    # with SIGPIPE, and under pipefail the whole setup stopped right after "OpenVPN ... installed".
    printf '#!/usr/bin/env bash\necho "apt-cache $*" >> "$STUB_LOG"\nprintf "certbot:\\n  Installed: (none)\\n  Candidate: 2.9.0-1\\n"\nsleep 0.3\nfor i in $(seq 300); do echo "     2.9.0-1 500 http://archive.ubuntu.com/ubuntu noble/universe amd64 Packages"; done\n' > "$E/bin/apt-cache"
    out=$(setup_run --host 203.0.113.9 --port 21194 --yes); rc=$?
    rc_is 'a public IP finishes the setup' 0 "$rc"
    grep -qx setup_complete "$E/cfg/.server-setup-started"; rc_is 'and records it as complete' 0 "$?"
    grep -q 'snap install --classic certbot' "$STUB_LOG"; rc_is 'a public IP gets the Certbot snap, new enough for it' 0 "$?"
    grep -qx 'snap certbot' "$E/cfg/.server-setup-started"; rc_is 'also recorded' 0 "$?"
    prepare_blank_server_again
    FAKE_SNAP_RC=1 setup_run --host 203.0.113.9 --port 21194 --yes >/dev/null
    grep -qx setup_complete "$E/cfg/.server-setup-started"; rc_is 'a failed certbot install does not stop the setup' 0 "$?"
    prepare_blank_server_again
    : > "$STUB_LOG"
    setup_run --host 192.168.1.10 --port 21194 --yes >/dev/null
    if grep -q 'certbot' "$STUB_LOG"; then result 0 'a private address gets no certbot'; else result 1 'a private address gets no certbot'; fi
}

fake_snap() {
    # A snapd that remembers what it installed. FAKE_SNAP_RC fails every install; FAKE_SNAP_ONCE fails the first
    # one only; FAKE_SNAP_LATE fails the command but the snap arrives anyway; FAKE_SNAP_DOING shows a change in
    # progress, which a watch finishes.
    mkdir -p "$E/snapd"
    printf '#!/usr/bin/env bash\ndir=%q\n' "$E/snapd" > "$E/bin/snap"
    cat >> "$E/bin/snap" <<'STUB'
echo "snap $*" >> "$STUB_LOG"
case $1 in
    list) [[ -e $dir/$2 ]] ;;
    install)
        name=${!#}
        if [[ -n ${FAKE_SNAP_LATE:-} ]]; then touch "$dir/$name"; exit 1; fi
        if [[ -n ${FAKE_SNAP_ONCE:-} && ! -e $dir/.failed-once ]]; then touch "$dir/.failed-once"; exit 1; fi
        if [[ ${FAKE_SNAP_RC:-0} != 0 ]]; then exit "$FAKE_SNAP_RC"; fi
        touch "$dir/$name" ;;
    changes) if [[ -n ${FAKE_SNAP_DOING:-} ]]; then printf 'ID  Status  Spawn  Ready  Summary\n7   Doing   today  -      Install "certbot" snap\n'; fi ;;
    watch) if [[ -n ${FAKE_SNAP_DOING:-} ]]; then touch "$dir/certbot"; fi ;;
    remove) rm -f "$dir/$2" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$E/bin/snap"
}

snap_try() { : > "$STUB_LOG"; (source "$REPO/lib/common.sh"; darban_snap_install_certbot "$E/record") >/dev/null 2>&1; }
snap_installs() { grep -c '^snap install' "$STUB_LOG"; }
test_certbot_snap_is_owned_only_when_installed_here() {
    local record=$E/record rc
    fake_snap
    : > "$record"
    snap_try; rc_is 'a missing snap is installed' 0 "$?"
    grep -qx 'snap certbot' "$record"; rc_is 'and recorded for removal' 0 "$?"
    : > "$record"
    snap_try; rc=$?
    rc_is 'a snap already there is fine' 0 "$rc"
    [[ $(snap_installs) == 0 ]] && grep -q '^snap refresh certbot' "$STUB_LOG"; rc_is 'it is refreshed, not installed again' 0 "$?"
    if grep -q 'snap certbot' "$record"; then result 0 'and never recorded as ours'; else result 1 'and never recorded as ours'; fi
    rm -f "$E/snapd/certbot"
    FAKE_SNAP_ONCE=1 snap_try; rc_is 'one failure is tried once more' 0 "$?"
    [[ $(snap_installs) == 2 ]] && grep -qx 'snap certbot' "$record"; rc_is 'twice, then recorded' 0 "$?"
    rm -f "$E/snapd/certbot"; : > "$record"
    FAKE_SNAP_LATE=1 snap_try; rc_is 'an install that finished after the command gave up counts' 0 "$?"
    [[ $(snap_installs) == 1 ]] && grep -qx 'snap certbot' "$record"; rc_is 'no second install, and it is recorded' 0 "$?"
    rm -f "$E/snapd/certbot"; : > "$record"
    FAKE_SNAP_RC=1 FAKE_SNAP_DOING=1 snap_try; rc_is 'a change in progress is waited for' 0 "$?"
    [[ $(snap_installs) == 1 ]] && grep -q '^snap watch' "$STUB_LOG" && grep -qx 'snap certbot' "$record"; rc_is 'not asked for again, and recorded' 0 "$?"
    rm -f "$E/snapd/certbot"; : > "$record"
    FAKE_SNAP_RC=1 snap_try; rc_is 'a snap that never comes is a failure' 1 "$?"
    [[ $(snap_installs) == 2 && ! -s $record ]]; rc_is 'after two tries, with nothing recorded' 0 "$?"
    rm -f "$record"
    snap_try; rc_is 'without a record file it still installs' 0 "$?"
    ok_if 'and writes no record' test ! -e "$record"
}

test_old_certbot_is_not_used_for_an_ip() {
    local out
    start_links_stub
    echo 203.0.113.9 > "$E/cfg/domain"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 4.0.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    fake_snap
    chmod +x "$E/bin/certbot"
    out=$(printf '5\nalice\n1\n1\n1\n0\n' | FAKE_SNAP_RC=1 bash "$E/manager.sh" 2>&1)
    if grep -q '^certbot certonly' "$STUB_LOG"; then result 0 'certbot 4.0 is never asked for an IP'; else result 1 'certbot 4.0 is never asked for an IP'; fi
    grep -q 'snap install --classic certbot' "$STUB_LOG"; rc_is 'the Certbot snap is tried instead' 0 "$?"
    has 'a failed install falls back to a working link' "https://203.0.113.9:$LINK_TEST_PORT/l/" "$out"
    menu '6\n1\n2\n0\n' >/dev/null
    # Without snap there is no way to a new enough certbot, so the question is not asked at all.
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    sed -i 's/^have_snap() {.*/have_snap() { false; }/' "$E/manager.sh"
    : > "$STUB_LOG"
    out=$(menu '5
alice
1
1
1
0
')
    has 'without snap it says why' 'this server has no snap' "$out"
    lacks 'and does not offer the certificate' 'Get a free Let' "$out"
    if grep -q 'pip\|venv' "$STUB_LOG"; then result 0 'nothing comes from the Python Package Index'; else result 1 'nothing comes from the Python Package Index'; fi
    has 'the link still works' "https://203.0.113.9:$LINK_TEST_PORT/l/" "$out"
    stop_links_stub
}

test_vpn_network_change_is_all_or_nothing() {
    local out before
    echo 'server 10.8.0.0 255.255.255.0' >> "$SERVER_CONF"
    printf 'table ip darban {\n    chain postrouting {\n        ip saddr 10.8.0.0/24 oifname "eth0" masquerade\n    }\n    chain forward {\n        ip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop\n    }\n}\n' > "$E/cfg/nat.nft"
    printf '#!/usr/bin/env bash\necho "nft $*" >> "$STUB_LOG"\nif [[ -n ${FAIL_NFT:-} ]]; then exit 1; fi\n' > "$E/bin/nft"; chmod +x "$E/bin/nft"
    before=$(cat "$E/cfg/nat.nft" "$SERVER_CONF" | sha256sum)

    : > "$STUB_LOG"
    chmod 555 "$E/server"
    out=$(menu '7\n6\n3\n10.77.0.0\n2\n0\n0\n0\n')
    chmod 755 "$E/server"
    if grep -q '^nft -f' "$STUB_LOG"; then result 0 'a server.conf that cannot be prepared leaves NAT alone'; else result 1 'a server.conf that cannot be prepared leaves NAT alone'; fi
    [[ $before == "$(cat "$E/cfg/nat.nft" "$SERVER_CONF" | sha256sum)" ]]; rc_is 'and both files unchanged' 0 "$?"

    out=$(FAIL_NFT=1 menu '7\n6\n3\n10.77.0.0\n2\n0\n0\n0\n')
    has 'a refused NAT rule changes nothing' 'Nothing was changed' "$out"
    [[ $before == "$(cat "$E/cfg/nat.nft" "$SERVER_CONF" | sha256sum)" ]]; rc_is 'both files unchanged after a refused rule' 0 "$?"

    out=$(FAIL_RESTART=1 menu '7\n6\n3\n10.77.0.0\n2\n0\n0\n0\n')
    grep -q '10.8.0.0/24' "$E/cfg/nat.nft"; rc_is 'a failed restart puts NAT back' 0 "$?"

    out=$(menu '7\n6\n3\n10.77.0.0\n2\n0\n0\n0\n')
    grep -q '^server 10.77.0.0 255.255.255.0' "$SERVER_CONF"; rc_is 'a good change is applied' 0 "$?"
    [[ $(grep -o '10.77.0.0/24' "$E/cfg/nat.nft" | wc -l) == 3 ]]; rc_is 'every rule follows the new network' 0 "$?"
}

test_setup_keeps_clients_apart() {
    prepare_blank_server
    setup_run --port 21194 --yes >/dev/null
    grep -q 'ip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop' "$E/cfg/nat.nft"; rc_is 'clients cannot reach each other' 0 "$?"
    grep -q 'ip saddr 10.8.0.0/24 ip daddr 169.254.0.0/16 drop' "$E/cfg/nat.nft"; rc_is 'or the cloud metadata service' 0 "$?"
    grep -q 'ip saddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280' "$E/cfg/nat.nft"; rc_is 'TCP from clients fits in one tunnel packet' 0 "$?"
    grep -q 'ip daddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1280 tcp option maxseg size set 1280' "$E/cfg/nat.nft"; rc_is 'and TCP to them' 0 "$?"
    sed -n '/chain input/,/}/p' "$E/cfg/nat.nft" | grep -q 'ip saddr 10.8.0.0/24 tcp flags syn'; rc_is 'and TCP from clients to the server itself' 0 "$?"
    sed -n '/chain output/,/}/p' "$E/cfg/nat.nft" | grep -q 'ip daddr 10.8.0.0/24 tcp flags syn'; rc_is 'and from the server itself to clients' 0 "$?"
}

test_setup_removal_leaves_what_was_there() {
    local out rc
    prepare_blank_server
    mkdir -p "$E/clients"; echo mine > "$E/clients/notes.txt"
    echo 'deb http://example.invalid/old stable main' > "$SETUP_ROOT/sources/openvpn.list"
    cat > "$E/bin/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >> "$STUB_LOG"
if [[ ${1:-} == status ]]; then echo 'Status: active'; echo '21194/udp                  ALLOW       Anywhere'; fi
STUB
    chmod +x "$E/bin/ufw"
    sed -i "s#^OUT_DIR=.*#OUT_DIR=$E/clients#" "$E/setup/server-setup.sh"
    : > "$STUB_LOG"
    setup_run --port 21194 --open-ufw --yes >/dev/null
    if grep -q 'ufw allow 21194/udp' "$STUB_LOG"; then result 0 'an existing ufw rule is not added again'; else result 1 'an existing ufw rule is not added again'; fi
    grep -q 'ufw route allow in on tun0' "$STUB_LOG"; rc_is 'the missing rule is added' 0 "$?"
    grep -qx out_dir_existed "$E/cfg/.server-setup-started"; rc_is 'a folder that held files is recorded' 0 "$?"
    install_removal_scripts
    menu '1\nfirst\n0\n' >/dev/null
    echo later > "$E/clients/later.txt"
    : > "$STUB_LOG"
    out=$(bash "$E/lib/remove-server.sh" --yes 2>&1 </dev/null); rc=$?
    rc_is 'the removal finishes' 0 "$rc"
    if grep -q 'ufw delete allow 21194/udp' "$STUB_LOG"; then result 0 'the ufw rule that was there stays'; else result 1 'the ufw rule that was there stays'; fi
    grep -q 'ufw route delete allow in on tun0' "$STUB_LOG"; rc_is 'the rule it added goes' 0 "$?"
    ok_if 'other files in the profile folder stay' test -s "$E/clients/notes.txt"
    ok_if 'and so does one put there after the setup' test -s "$E/clients/later.txt"
    has 'the removal says what it kept' "$E/clients" "$out"
    ok_if 'its own profiles go' test ! -e "$E/clients/first.ovpn"
    grep -q 'example.invalid/old' "$SETUP_ROOT/sources/openvpn.list"; rc_is 'the repository file that was there comes back' 0 "$?"
    grep -q '^flock -w 60 9' "$STUB_LOG"; rc_is 'the removal takes the CA lock' 0 "$?"
}

test_link_store_removes_files_left_by_a_crash() {
    local dir=$WORK/linkstore
    mkdir -p "$dir"
    echo key > "$dir/aaaa.ovpn"; touch -d '2 minutes ago' "$dir/aaaa.ovpn"
    echo key > "$dir/bbbb.ovpn"
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import linkd; linkd.Store(sys.argv[2]).purge()' "$REPO/lib" "$dir"
    ok_if 'an old profile with no record is removed' test ! -e "$dir/aaaa.ovpn"
    ok_if 'one being written right now stays' test -e "$dir/bbbb.ovpn"
}

test_version_order_is_the_same_everywhere() {
    local pair a b x y
    eval "$(sed -n '/^version_is_newer() {/,/^}/p' "$REPO/setup/get.sh" | sed 's/^version_is_newer()/newer_get()/')"
    eval "$(sed -n '/^version_is_newer() {/,/^}/p' "$REPO/bin/darban" | sed 's/^version_is_newer()/newer_tool()/')"
    for pair in '1.0.0 0.9.9' '1.0.0 1.0.0-rc.1' '1.0.0-rc.2 1.0.0-rc.1' '1.0.0-rc.1 1.0.0-beta.9' '1.0.10 1.0.9' '2.0.0 10.0.0' '1.0.0 1.0.0'; do
        read -r a b <<<"$pair"
        newer_get "$a" "$b"; x=$?; newer_tool "$a" "$b"; y=$?
        rc_is "get.sh and darban agree on $a > $b" "$x" "$y"
    done
}

test_ci_scope_skips_only_documentation() {
    local dir=$WORK/scope base docs code
    scope() { (cd "$dir" && env -u GITHUB_REF GITHUB_REF=refs/heads/main "$@" bash "$REPO/scripts/ci-scope.sh"); }
    mkdir -p "$dir/docs" && git -C "$dir" init -q
    git -C "$dir" config user.email t@example.com; git -C "$dir" config user.name t
    printf 'a\n' >"$dir/README.md"; printf 'a\n' >"$dir/run.sh"
    git -C "$dir" add . && git -C "$dir" commit -qm base
    base=$(git -C "$dir" rev-parse HEAD)
    printf 'b\n' >>"$dir/README.md"; printf 'b\n' >"$dir/docs/guide.md"
    git -C "$dir" add . && git -C "$dir" commit -qm docs
    docs=$(git -C "$dir" rev-parse HEAD)
    has 'a documentation change skips the tests' 'code=false' "$(scope EVENT=push BEFORE="$base")"
    has 'a pull request is compared with its base' 'code=false' "$(scope EVENT=pull_request BASE="$base")"
    printf 'c\n' >>"$dir/run.sh"
    git -C "$dir" add . && git -C "$dir" commit -qm code
    code=$(git -C "$dir" rev-parse HEAD)
    has 'a code change runs the tests' 'code=true' "$(scope EVENT=push BEFORE="$docs")"
    has 'mixed changes run the tests' 'code=true' "$(scope EVENT=push BEFORE="$base")"
    has 'nothing to compare runs the tests' 'code=true' "$(scope EVENT=push BEFORE=0000000000000000000000000000000000000000)"
    has 'an unknown commit runs the tests' 'code=true' "$(scope EVENT=push BEFORE=1111111111111111111111111111111111111111)"
    has 'no changes at all runs the tests' 'code=true' "$(scope EVENT=push BEFORE="$code")"
    has 'a tag always runs the tests' 'code=true' "$(scope EVENT=push GITHUB_REF=refs/tags/v1.0.0 BEFORE="$base")"
    has 'the weekly run always runs the tests' 'code=true' "$(scope EVENT=schedule)"
    has 'a manual run always runs the tests' 'code=true' "$(scope EVENT=workflow_dispatch)"
}

test_guides_name_the_real_setup_items() {
    # Every "`N` ... **Label**" for a Setup item in the guides uses the number the Setup menu shows.
    local out
    out=$(python3 - "$REPO" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
code = (root / 'bin/darban').read_text(encoding='utf-8')
block = code[code.index('draw_setup() {'):code.index('setup_menu() {')]
menu = {label: num for num, label in re.findall(r"menu_item (\d) \"?\$?\(?(?:printf '%-24s %s' )?'([^']+)'", block)}
bad = []
for path in sorted((root / 'docs').glob('*/usage.md')):
    text = path.read_text(encoding='utf-8')
    for num, label in re.findall(r'`(\d)`[^`*\n]{0,20}\*\*([A-Za-z ]+?)(?::)?\*\*', text):
        for name, real in menu.items():
            if label.strip().startswith(name.split(' (')[0]) and num != real:
                bad.append(f'{path.relative_to(root)}: `{num}` {label.strip()} (menu: {real})')
print('items: ' + ', '.join(f'{v} {k}' for k, v in sorted(menu.items(), key=lambda i: i[1])))
print('\n'.join(bad) if bad else 'all match')
PY
)
    has 'the Setup menu was read' '2 Check for updates' "$out"
    has 'the guides use the Setup numbers of the menu' 'all match' "$out"
}

test_ci_skips_only_what_its_pull_request_tested() {
    local dir=$WORK/tested origin=$WORK/tested-origin.git script=$REPO/scripts/ci-already-tested.sh base pr squash other
    # REPO inside is the GitHub name the script asks the API about, not this checkout.
    tested() { (cd "$dir" && PATH="$dir/stub:$PATH" REPO=o/r REMOTE="$origin" env "$@" bash "$script" 2>&1); }
    mkdir -p "$dir/stub" && git -C "$dir" init -q && git init -q --bare "$origin"
    git -C "$dir" config user.email t@example.com; git -C "$dir" config user.name t
    printf 'a\n' >"$dir/run.sh"; git -C "$dir" add run.sh && git -C "$dir" commit -qm base
    base=$(git -C "$dir" rev-parse HEAD)
    printf 'b\n' >>"$dir/run.sh"; git -C "$dir" commit -qam change
    pr=$(git -C "$dir" rev-parse HEAD)
    git -C "$dir" push -q "$origin" "$pr:refs/pull/7/head"
    # A squash merge: a new commit on main with exactly the files of the pull request's last commit.
    squash=$(git -C "$dir" commit-tree "$pr^{tree}" -p "$base" -m 'change (#7)')
    printf 'c\n' >>"$dir/run.sh"; git -C "$dir" commit -qam more
    other=$(git -C "$dir" commit-tree "HEAD^{tree}" -p "$base" -m 'other (#7)')
    # gh answers from the environment: the merged pull request, its last commit, and its green runs.
    cat >"$dir/stub/gh" <<'STUB'
#!/usr/bin/env bash
[[ -n ${GH_FAIL:-} ]] && exit 1
case $2 in
    */commits/*/pulls) printf '%s\n' ${PRS-7} ;;
    */pulls/*) echo "$HEAD_SHA" ;;
    */runs\?*) echo "${RUNS:-1}" ;;
esac
STUB
    chmod +x "$dir/stub/gh"
    has 'the exact files its pull request tested green skip the slow tests' 'tested=true' "$(tested SHA="$squash" HEAD_SHA="$pr")"
    has 'and it says which pull request' 'Pull request #7 already tested' "$(tested SHA="$squash" HEAD_SHA="$pr")"
    has 'other files run them' 'tested=false' "$(tested SHA="$other" HEAD_SHA="$pr")"
    has 'no green run of the pull request runs them' 'tested=false' "$(tested SHA="$squash" HEAD_SHA="$pr" RUNS=0)"
    has 'a pull request whose last commit is not the one GitHub names runs them' 'tested=false' "$(tested SHA="$squash" HEAD_SHA="$base")"
    has 'a push without a pull request runs them' 'tested=false' "$(tested SHA="$squash" HEAD_SHA="$pr" PRS='')"
    has 'an API that does not answer runs them' 'tested=false' "$(tested SHA="$squash" HEAD_SHA="$pr" GH_FAIL=1)"
}

test_repo_checks_find_problems() {
    local dir=$WORK/checks out rc
    check() { (cd "$dir" && git add -A . && python3 "$REPO/scripts/check-repo.py" 2>&1); }
    mkdir -p "$dir/docs/en" "$dir/docs/fa" "$dir/setup" "$dir/bin" && git -C "$dir" init -q
    printf '# Title\n\n## Quick start\n\n[guide](docs/en/usage.md) [top](#quick-start)\n\nsudo darban status\n' >"$dir/README.md"
    printf '# Usage\n' >"$dir/docs/en/usage.md"; printf '# Usage\n' >"$dir/docs/fa/usage.md"
    printf '#!/bin/sh\n' >"$dir/setup/a.sh"; chmod +x "$dir/setup/a.sh"
    printf 'Commands:\n  status  print\nOptions:\n' >"$dir/bin/darban"; chmod +x "$dir/bin/darban"
    out=$(check); rc=$?
    rc_is 'a healthy repository passes' 0 "$rc"

    printf '[x](docs/missing.md)\n' >>"$dir/README.md"
    out=$(check); rc_not0 'a broken link fails' "$?"; has 'it names the broken link' 'broken link: docs/missing.md' "$out"
    sed -i '$d' "$dir/README.md"; printf '[x](#nowhere)\n' >>"$dir/README.md"
    out=$(check); rc_not0 'a missing heading fails' "$?"; has 'it names the heading' 'no such heading: #nowhere' "$out"
    printf '<a id="nowhere"></a>
' >>"$dir/README.md"
    out=$(check); rc_is 'an explicit anchor counts' 0 "$?"
    sed -i '$d' "$dir/README.md"
    sed -i '$d' "$dir/README.md"; printf '```\n[x](docs/missing.md)\n```\n' >>"$dir/README.md"
    out=$(check); rc_is 'a link inside a code block is ignored' 0 "$?"
    printf 'sudo darban nosuch\n' >>"$dir/README.md"
    out=$(check); rc_not0 'an unknown command fails' "$?"; has 'it names the command' 'unknown command: sudo darban nosuch' "$out"
    sed -i '$d' "$dir/README.md"
    printf '# New\n' >"$dir/docs/en/new.md"
    out=$(check); rc_not0 'a guide in one language fails' "$?"; has 'it names the guide' 'new.md exists in only one language' "$out"
    rm "$dir/docs/en/new.md"
    chmod -x "$dir/setup/a.sh"
    out=$(check); rc_not0 'a script without the executable bit fails' "$?"; has 'it names the script' 'setup/a.sh: must be executable' "$out"
    chmod +x "$dir/setup/a.sh"
    printf 'a\r\nb\r\n' >"$dir/docs/en/usage.md"
    out=$(check); rc_not0 'CRLF line endings fail' "$?"; has 'it names the file' 'usage.md: has CRLF' "$out"
}

# ---------- PR 1: revocation cleanup by certificate, and Remove everything that reports every failure ----------
plant_link() {
    # plant_link <name> [profile]: a link record as the tool writes one, without the link service. Prints its key.
    local key
    key=$(openssl rand -hex 32)
    mkdir -p "$E/links"
    printf 'name=%s\nexpires=%s\ncreated=%s\ndownloads=0\n' "$1" "$(( $(date -u +%s) + 3600 ))" "$(date -u +%s)" > "$E/links/$key.meta"
    if [[ -n ${2:-} ]]; then cp "$2" "$E/links/$key.ovpn"; fi
    printf '%s\n' "$key"
}
with_cert() {
    # with_cert <profile> <pem file>: the profile with its <cert> block replaced by the file.
    awk -v c="$2" 'BEGIN {while ((getline l < c) > 0) cert = cert l "\n"} /^<\/cert>$/ {skip = 0} !skip {print} /^<cert>$/ {printf "%s", cert; skip = 1}' "$1"
}
ca_before_links() {
    # The CA lock (fd 9) is asked for before the lock of the link files (fd 8).
    awk '/^flock (-n|-w [0-9]+) 9$/ && !ca {ca = NR} /^flock -w 10 8$/ && !ln {ln = NR} END {exit !(ca && ln && ca < ln)}' "$STUB_LOG"
}

test_revocation_finishes_even_when_the_link_service_holds_the_links() {
    local out rc key key2
    menu '5\nalice\n2\n0\n' >/dev/null
    cp "$E/clients/alice.ovpn" "$E/alice-1.ovpn"
    key=$(plant_link alice "$E/alice-1.ovpn")
    : > "$STUB_LOG"
    out=$(printf '4\nalice\nalice\n0\n' | FLOCK_FAIL='-w 10 8' bash "$E/manager.sh" 2>&1)
    has 'the CA revokes it' 'Marked revoked in the CA index' "$out"
    has 'the CRL is published all the same' 'New CRL published to OpenVPN and verified' "$out"
    has 'it says the link cleanup is unfinished' 'alice is revoked; link cleanup unfinished' "$out"
    has 'and names the next step' 'sudo darban repair-crl' "$out"
    lacks 'it does not say "try again"' 'try again' "$out"
    lacks 'no plain success' 'alice is revoked.' "$out"
    ok_if 'the server copy is deleted all the same' test ! -e "$E/clients/alice.ovpn"
    has 'the session step runs all the same' 'cannot start new connections' "$out"
    ok_if 'the link is still there' test -e "$E/links/$key.ovpn"
    ca_before_links; rc_is 'revoke takes the CA lock before the link lock' 0 "$?"
    grep -q 'revocation cleanup unfinished, links still open: alice' "$STUB_LOG"; rc_is 'it is audited' 0 "$?"

    out=$(mgr status)
    has 'the diagnostics name it' 'Revocation unfinished, link or profile still on server: alice' "$out"
    has 'the menu header names it' 'link or profile still on server: alice' "$(menu '0\n')"
    out=$(menu '1\nalice\n\n0\n')
    has 'a new certificate for the name is refused' 'its revocation is unfinished' "$out"
    ok_if 'nothing is issued' test ! -e "$PKI/issued/alice.crt"

    : > "$STUB_LOG"
    out=$(mgr repair-crl); rc=$?
    rc_is 'the repair finishes' 0 "$rc"
    has 'it ends the link' 'Open link of alice ended.' "$out"
    ok_if 'the link is gone, with all its files' test -z "$(find "$E/links" -name "$key.*")"
    ca_before_links; rc_is 'the repair takes the CA lock before the link lock' 0 "$?"
    lacks 'the diagnostics are clear' 'link or profile still on server' "$(mgr status)"
    has 'a second repair has nothing to do' 'Nothing to repair' "$(mgr repair-crl)"

    # The name again: a link of the new certificate stays, a link of the old one goes.
    out=$(menu '1\nalice\n0\n')
    has 'the name can be used again' 'Client "alice" created and verified' "$out"
    key2=$(plant_link alice "$E/clients/alice.ovpn")
    key=$(plant_link alice "$E/alice-1.ovpn")
    out=$(mgr repair-crl); rc=$?
    rc_is 'the repair finishes again' 0 "$rc"
    ok_if 'the link of the revoked certificate goes' test ! -e "$E/links/$key.meta"
    ok_if 'the link of the new certificate stays' test -e "$E/links/$key2.ovpn"
    ok_if 'the file of the new certificate stays' test -s "$E/clients/alice.ovpn"
    lacks 'the session of the new certificate is not ended' 'Disconnecting any active session of alice' "$out"
    has 'and a second repair has nothing to do' 'Nothing to repair' "$(mgr repair-crl)"
    ok_if 'the new link is still there' test -e "$E/links/$key2.ovpn"
}

test_a_share_whose_certificate_is_unknown_is_kept() {
    local out rc dir=$E/other kdamaged kother kbob korphan krevoked kexpired
    menu '1\nbob\n0\n' >/dev/null
    menu '5\nalice\n2\n0\n' >/dev/null
    cp "$E/clients/alice.ovpn" "$E/alice-1.ovpn"
    revoke_menu alice >/dev/null
    # Left behind by an earlier version, or put there by hand. The records hold no serial, as in rc.10.
    mkdir -p "$dir"
    echo garbage > "$dir/garbage.pem"
    with_cert "$E/alice-1.ovpn" "$dir/garbage.pem" > "$dir/damaged.ovpn"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$dir/ca.key" -out "$dir/ca.crt" -subj /CN=OtherCA -days 30 2>/dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$dir/alice.key" -out "$dir/alice.csr" -subj /CN=alice 2>/dev/null
    openssl x509 -req -in "$dir/alice.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial -out "$dir/alice.crt" -days 30 2>/dev/null
    with_cert "$E/alice-1.ovpn" "$dir/alice.crt" > "$dir/other-ca.ovpn"
    kdamaged=$(plant_link alice "$dir/damaged.ovpn")
    kother=$(plant_link alice "$dir/other-ca.ovpn")
    kbob=$(plant_link alice "$E/clients/bob.ovpn")
    korphan=$(plant_link alice)
    echo 'https://example.invalid/l/x' > "$E/links/$korphan.url"
    krevoked=$(plant_link alice "$E/alice-1.ovpn")

    # A certificate of this CA that expired, then was revoked: it is still known by its serial.
    cat > "$dir/ca.cnf" <<CNF
[ca]
default_ca = d
[d]
dir = $PKI
database = $PKI/index.txt
new_certs_dir = $dir
certificate = $PKI/ca.crt
private_key = $PKI/private/ca.key
serial = $PKI/serial
default_md = sha256
policy = p
unique_subject = no
[p]
commonName = supplied
CNF
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$dir/carol.key" -out "$dir/carol.csr" -subj /CN=carol 2>/dev/null
    openssl ca -batch -config "$dir/ca.cnf" -in "$dir/carol.csr" -out "$dir/carol.crt" -notext -startdate 20200101000000Z -enddate 20200201000000Z 2>/dev/null
    openssl ca -batch -config "$dir/ca.cnf" -revoke "$dir/carol.crt" 2>/dev/null
    with_cert "$E/alice-1.ovpn" "$dir/carol.crt" > "$dir/carol.ovpn"
    kexpired=$(plant_link carol "$dir/carol.ovpn")

    out=$(mgr status)
    has 'the diagnostics name the revoked one' 'link or profile still on server: alice' "$out"
    has 'and the unknown ones' 'Link or file with a certificate this tool cannot identify: alice' "$out"
    out=$(menu '1\nalice\n\n0\n')
    has 'the name stays blocked' 'its revocation is unfinished' "$out"

    out=$(mgr repair-crl); rc=$?
    rc_is 'the repair finishes' 0 "$rc"
    ok_if 'a link of the revoked certificate goes' test ! -e "$E/links/$krevoked.meta"
    ok_if 'so does one whose certificate expired before it was revoked' test ! -e "$E/links/$kexpired.meta"
    ok_if 'a link record without its profile goes, with its address' test -z "$(find "$E/links" -name "$korphan.*")"
    ok_if 'a damaged certificate stays' test -e "$E/links/$kdamaged.ovpn"
    ok_if 'one from another CA stays' test -e "$E/links/$kother.ovpn"
    ok_if 'one for another name stays' test -e "$E/links/$kbob.ovpn"
    has 'the repair names what it kept' 'holds a certificate this tool cannot identify, so it was kept' "$out"
    ok_if 'the valid client keeps its file' test -s "$E/clients/bob.ovpn"

    out=$(menu '1\nalice\n\n0\n')
    has 'the name stays blocked while one is unknown' 'cannot identify; check it, then delete it in Links and files' "$out"
    ok_if 'nothing is issued' test ! -e "$PKI/issued/alice.crt"
    # Cancelled by hand from menu 6, one at a time: the first row is always a link while one is left.
    menu '6\n1\n1\n0\n' >/dev/null; menu '6\n1\n1\n0\n' >/dev/null; menu '6\n1\n1\n0\n' >/dev/null
    ok_if 'menu 6 removes them' test -z "$(find "$E/links" -name '*.meta')"
    lacks 'the diagnostics are clear' 'cannot identify' "$(mgr status)"
    out=$(menu '1\nalice\n0\n')
    has 'then the name can be used again' 'Client "alice" created and verified' "$out"
}

test_remove_everything_reports_a_failed_certbot_removal() {
    # With the certificate kept, certbot is removed rather than purged. Each failure of that must reach the summary.
    local out rc
    built_server
    printf 'package certbot\ndep python3-certbot\n' >> "$E/cfg/.server-setup-started"
    : > "$STUB_LOG"
    out=$(FAIL_APT_REMOVE=1 AUTOREMOVE='python3-certbot' bash "$E/lib/remove-server.sh" --yes --keep-certificate 2>&1 </dev/null); rc=$?
    rc_not0 'the removal reports the failure' "$rc"
    has 'it says steps failed' 'Some steps failed' "$out"
    has 'it names the failed removal of certbot' 'remove certbot' "$out"
    has 'and of its library' 'remove python3-certbot' "$out"
    ok_if 'the record of the setup stays, so it can run again' test -s "$E/cfg/.server-setup-started"

    built_server
    printf 'package certbot\n' >> "$E/cfg/.server-setup-started"
    out=$(REMV_EXTRA_REMOVE=some-other-tool bash "$E/lib/remove-server.sh" --yes --keep-certificate 2>&1 </dev/null); rc=$?
    rc_is 'a package kept for another program is no failure' 0 "$rc"
    has 'it says what was kept' 'Kept because other software depends on them' "$out"
    has 'and why' 'certbot (removing them would also remove: some-other-tool)' "$out"
}

# ---------- PR 2: the link certificate and its key change as one pair ----------
pair_count() { find "$E/cfg/link-cert/pairs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }
pair_matches() { [[ $(openssl x509 -in "$E/cfg/link-cert.pem" -noout -pubkey) == "$(openssl pkey -in "$E/cfg/link-key.pem" -pubout)" ]]; }
pair_layout() { [[ $(readlink "$E/cfg/link-cert.pem") == link-cert/current/fullchain.pem && $(readlink "$E/cfg/link-key.pem") == link-cert/current/privkey.pem ]]; }

test_a_failed_switch_keeps_the_pair_in_use() {
    # T3: the change fails at the one rename that would put the new pair in use.
    local out before
    echo vpn.example.com > "$E/cfg/domain"
    out=$(menu '7\n5\n3\n3\n2\n0\n0\n')
    has 'a first self-signed pair is made' 'Links use a self-signed certificate for vpn.example.com' "$out"
    pair_layout; rc_is 'the names point through the pair in use' 0 "$?"
    before=$(file_fp)
    printf '#!/usr/bin/env bash\nif [[ " $* " == *".current.new "* ]]; then exit 1; fi\nexec /usr/bin/mv "$@"\n' > "$E/bin/mv"; chmod +x "$E/bin/mv"
    out=$(menu '7\n5\n3\n3\n2\n0\n0\n')
    rm -f "$E/bin/mv"
    has 'the failure is said' 'Could not create a certificate for the link.' "$out"
    lacks 'and not called done' 'Links use a self-signed certificate' "$out"
    [[ $(file_fp) == "$before" ]]; rc_is 'the pair in use stays' 0 "$?"
    pair_matches; rc_is 'its certificate and key still belong together' 0 "$?"
    [[ $(pair_count) == 1 ]]; rc_is 'and the new pair is not left behind' 0 "$?"
    ok_if 'nor the link it was renamed from' test ! -e "$E/cfg/link-cert/.current.new"
}

test_a_pair_from_an_earlier_version_is_kept_whole() {
    # T4: the files of v1.0.0-rc.10 get a folder of their own once, and what an interrupted change left is cleaned.
    local before origin gone
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem
    cp "$E/panel-cert/vpn.example.com/fullchain.pem" "$E/cfg/link-cert.pem"; cp "$E/panel-cert/vpn.example.com/privkey.pem" "$E/cfg/link-key.pem"
    printf '%s\n%s\n' "$E/panel-cert/vpn.example.com/fullchain.pem" "$E/panel-cert/vpn.example.com/privkey.pem" > "$E/cfg/link-cert.source"
    echo old > "$E/cfg/.link-cert.prev"
    before=$(file_fp)
    bash "$E/manager.sh" reload-links </dev/null >/dev/null 2>&1; rc_is 'reload-links succeeds' 0 "$?"
    pair_layout; rc_is 'the old files get a folder of their own' 0 "$?"
    [[ $(file_fp) == "$before" ]]; rc_is 'with the same certificate' 0 "$?"
    pair_matches; rc_is 'and its key' 0 "$?"
    [[ $(cat "$E/cfg/link-cert/current/kind") == copied ]]; rc_is 'still known as taken from elsewhere' 0 "$?"
    origin=$(head -n 1 "$E/cfg/link-cert.source")
    [[ $origin == "$E/panel-cert/vpn.example.com/fullchain.pem" ]]; rc_is 'with where it came from' 0 "$?"
    ok_if 'the copy of the old way is gone' test ! -e "$E/cfg/.link-cert.prev"

    # Interrupted: a half-made pair and the mark of a session that is gone; then a rename that was not finished.
    mkdir -p "$E/cfg/link-cert/pairs/HALFMADE"; echo x > "$E/cfg/link-cert/pairs/HALFMADE/fullchain.pem"
    ( exit 0 ) & gone=$!; wait "$gone"
    echo HALFMADE > "$E/cfg/link-cert/hold.$gone"
    cp --remove-destination "$(readlink -f "$E/cfg/link-cert.pem")" "$E/cfg/link-cert.pem"
    bash "$E/manager.sh" reload-links </dev/null >/dev/null 2>&1; rc_is 'the next run succeeds' 0 "$?"
    ok_if 'the half-made pair is gone' test ! -e "$E/cfg/link-cert/pairs/HALFMADE"
    ok_if 'with the mark of the session that is gone' test ! -e "$E/cfg/link-cert/hold.$gone"
    pair_layout; rc_is 'the unfinished rename is finished' 0 "$?"
    [[ $(file_fp) == "$before" ]] && pair_matches; rc_is 'and the pair is the same, whole' 0 "$?"
    [[ $(cat "$E/cfg/link-cert/current/kind") == copied ]]; rc_is 'still taken from elsewhere' 0 "$?"
    [[ $(pair_count) == 1 ]]; rc_is 'one pair is left' 0 "$?"
}

test_two_sessions_change_the_link_certificate_at_once() {
    # T5: with the real lock, each change finishes, and the pair in use is always whole.
    local round a b
    echo vpn.example.com > "$E/cfg/domain"
    rm -f "$E/bin/flock"
    menu '7\n5\n3\n3\n2\n0\n0\n' >/dev/null
    for round in 1 2 3; do
        printf '7\n5\n3\n3\n2\n0\n0\n' | bash "$E/manager.sh" > "$E/session-a.out" 2>&1 &
        a=$!
        printf '7\n5\n3\n3\n2\n0\n0\n' | bash "$E/manager.sh" > "$E/session-b.out" 2>&1 &
        b=$!
        wait "$a" "$b"
        grep -q 'Links use a self-signed certificate' "$E/session-a.out"; rc_is "round $round: the first session finishes its change" 0 "$?"
        grep -q 'Links use a self-signed certificate' "$E/session-b.out"; rc_is "round $round: and so does the second" 0 "$?"
        pair_layout && pair_matches; rc_is "round $round: the pair in use is whole" 0 "$?"
        [[ $(pair_count) == 1 ]]; rc_is "round $round: only it is left" 0 "$?"
        ok_if "round $round: no session mark is left" test -z "$(find "$E/cfg/link-cert" -maxdepth 1 -name 'hold.*')"
    done
}

test_a_certificate_only_for_clients_is_refused() {
    # T8: a trusted CA, but the certificate may only identify a client.
    local out before
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/good" fullchain.pem privkey.pem
    menu '7\n5\n3\n3\n2\n0\n0\n' >/dev/null
    before=$(file_fp)
    mkdir -p "$E/client-only"
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/client-only/cert.key" -out "$E/client-only/cert.csr" -subj /CN=vpn.example.com >/dev/null 2>&1
    printf 'subjectAltName=DNS:vpn.example.com\nextendedKeyUsage=clientAuth\n' > "$E/client-only/ext"
    openssl x509 -req -in "$E/client-only/cert.csr" -CA "$E/test-ca.pem" -CAkey "$E/test-ca.key" -CAcreateserial -days 30 \
        -extfile "$E/client-only/ext" -out "$E/client-only/cert.pem" >/dev/null 2>&1
    out=$(menu "7\n5\n3\n2\n$E/client-only/cert.pem\n\n0\n0\n")
    has 'it is refused with the reason' 'is not made for a server' "$out"
    has 'and nothing changes' 'Nothing changed' "$out"
    [[ $(file_fp) == "$before" ]]; rc_is 'the pair in use stays' 0 "$?"
    out=$(menu "7\n5\n3\n2\n$E/good/fullchain.pem\n\n0\n0\n")
    has 'a certificate for a server from the same CA is taken' 'Links use the trusted certificate from' "$out"
}

test_a_renewal_the_link_service_does_not_take_is_named() {
    # T17: this tool's Let's Encrypt pair is renewed; the service does not take it, so the one it serves is named.
    local out old new
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    : > "$E/cfg/.server-setup-started"
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem
    menu '5\nalice\n1\n1\n0\n' >/dev/null
    sleep 0.5
    old=$(file_fp)
    [[ $(served_fp) == "$old" ]]; rc_is 'the open link serves the Let'"'"'s Encrypt copy' 0 "$?"
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem 40
    out=$(FAKE_RELOAD_FAIL=1 bash "$E/manager.sh" reload-links </dev/null 2>&1); rc_not0 'a renewal the service did not take is a failure' "$?"
    has 'it is copied for the links' "renewed in Let's Encrypt" "$out"
    has 'the one put back is named, with its end' "so the previous one was put back, valid until $(cert_end_date_of "$E/cfg/link-cert.pem")" "$out"
    [[ $(file_fp) == "$old" && $(served_fp) == "$old" ]]; rc_is 'the file and the port agree on the previous one' 0 "$?"
    out=$(bash "$E/manager.sh" reload-links </dev/null 2>&1); rc_is 'the next run succeeds' 0 "$?"
    has 'and the open link takes the renewed one' 'Open links use it now' "$out"
    new=$(file_fp)
    [[ $new != "$old" && $(served_fp) == "$new" ]]; rc_is 'the port answers with the renewed one' 0 "$?"
    cmp -s "$E/cfg/link-cert.pem" "$E/le/live/darban-ovpn-links/fullchain.pem"; rc_is 'which is the one certbot renewed' 0 "$?"
    [[ $(pair_count) == 1 ]]; rc_is 'only the pair in use is kept' 0 "$?"
    stop_links_stub
}
cert_end_date_of() { date -u -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%Y-%m-%d; }

test_the_link_service_never_reads_two_pairs() {
    # X04 and T21: a pair changed while the service reads it gives one whole pair or the other, never a mix.
    local dir=$E/flip side out
    mkdir -p "$dir/pairs/a" "$dir/pairs/b"
    for side in a b; do
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$dir/pairs/$side/privkey.pem" \
            -out "$dir/pairs/$side/fullchain.pem" -days 30 -subj /CN=127.0.0.1 >/dev/null 2>&1
    done
    ln -s pairs/a "$dir/current"
    ln -s current/fullchain.pem "$dir/cert.pem"; ln -s current/privkey.pem "$dir/key.pem"
    out=$(python3 -I - "$REPO/lib" "$dir" <<'PY'
import os, sys, threading
sys.path.insert(0, sys.argv[1])
import linkd
d = sys.argv[2]
stop = False
def flip():
    side = 'b'
    while not stop:
        os.symlink('pairs/' + side, d + '/current.new')
        os.replace(d + '/current.new', d + '/current')
        side = 'a' if side == 'b' else 'b'
thread = threading.Thread(target=flip)
thread.start()
errors = 0
for _ in range(400):
    try:
        linkd.tls_context(d + '/cert.pem', d + '/key.pem')
    except Exception:
        errors += 1
stop = True
thread.join()
print(errors)
PY
)
    [[ $out == 0 ]]; rc_is 'every read gives a whole pair' 0 "$?"
}

# ---------- PR 3: this tool's hook in certbot's renewal file ----------
renew_hook() {
    # renew_hook <present|absent> <file> <hook> [older hook]...: the library's editor, run by itself.
    bash -c 'set -uo pipefail; source "$E/lib/common.sh"; darban_renew_hook "$@"' _ "$@"
}

test_the_renewal_file_is_changed_line_by_line() {
    # T11: only this tool's exact hook is added, moved or removed; everything else in the file stays as it was.
    local f=$E/renewal.conf hook='/opt/dar.ban/sbin/darban reload-links' old='systemctl try-restart darban-links.service' rc
    printf 'version = 2.9.0\r\ncert = /etc/letsencrypt/live/x/cert.pem\r\n\r\n[renewalparams]\r\nauthenticator = standalone\r\nrenew_hook = %s\r\npre_hook = %s\r\nrenew_hooks = %s\r\n' \
        "$hook" "$hook" "$hook" > "$f"
    renew_hook absent "$f" "$hook" "$old"; rc_is 'absent succeeds' 0 "$?"
    if grep -q '^renew_hook =' "$f"; then result 0 'this tool'"'"'s hook is removed'; else result 1 'this tool'"'"'s hook is removed'; fi
    grep -q "^pre_hook = $hook"$'\r'"\$" "$f"; rc_is 'another key with the same value stays' 0 "$?"
    grep -q "^renew_hooks = " "$f"; rc_is 'a key that only starts the same stays' 0 "$?"
    [[ $(grep -c $'\r$' "$f") == 7 ]]; rc_is 'Windows line ends stay on every line' 0 "$?"
    ok_if 'the file before is kept' test -s "$f.darban-backup"
    grep -q '^renew_hook' "$f.darban-backup"; rc_is 'and still names the hook' 0 "$?"
    cp "$f" "$E/after-absent"
    renew_hook absent "$f" "$hook" "$old"; rc_is 'a second absent succeeds' 0 "$?"
    cmp -s "$f" "$E/after-absent"; rc_is 'and changes nothing' 0 "$?"

    renew_hook present "$f" "$hook" "$old"; rc_is 'present succeeds' 0 "$?"
    [[ $(awk '/^\[renewalparams\]/ {getline; print; exit}' "$f") == "renew_hook = $hook"$'\r' ]]; rc_is 'it goes right under [renewalparams], with the same line end' 0 "$?"
    cp "$f" "$E/after-present"
    renew_hook present "$f" "$hook" "$old"; rc_is 'a second present succeeds' 0 "$?"
    cmp -s "$f" "$E/after-present"; rc_is 'and adds nothing' 0 "$?"

    # A dot in the path is not a pattern: a value that differs only there belongs to someone else.
    printf '[renewalparams]\nrenew_hook = /opt/darXban/sbin/darban reload-links\n' > "$f"
    renew_hook absent "$f" "$hook" "$old"
    grep -qx 'renew_hook = /opt/darXban/sbin/darban reload-links' "$f"; rc_is 'a hook that only looks like it stays' 0 "$?"
    renew_hook present "$f" "$hook" "$old"
    [[ $(grep -c '^renew_hook' "$f") == 1 ]] && grep -qx 'renew_hook = /opt/darXban/sbin/darban reload-links' "$f"; rc_is 'and present adds none beside it' 0 "$?"

    # The old hook that restarted the link service is moved to the reload.
    printf '[renewalparams]\nrenew_hook = %s\n' "$old" > "$f"
    renew_hook present "$f" "$hook" "$old"
    grep -qx "renew_hook = $hook" "$f" && ! grep -q 'try-restart' "$f"; rc_is 'the old hook becomes the reload' 0 "$?"
    printf 'version = 2.9.0\n' > "$f"
    renew_hook present "$f" "$hook" "$old"
    [[ $(tail -n 2 "$f") == "[renewalparams]"$'\n'"renew_hook = $hook" ]]; rc_is 'a file without the section gets one' 0 "$?"
    renew_hook absent "$E/no-such.conf" "$hook" "$old"; rc_is 'a missing file is no failure' 0 "$?"

    # A failed write is said, and leaves the file as it was.
    printf '[renewalparams]\nrenew_hook = %s\n' "$hook" > "$f"
    cp "$f" "$E/before-fail"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$E/bin/mv"; chmod +x "$E/bin/mv"
    renew_hook absent "$f" "$hook" "$old"; rc=$?
    rm -f "$E/bin/mv"
    rc_not0 'a write that fails is a failure' "$rc"
    cmp -s "$f" "$E/before-fail"; rc_is 'and the file is as it was' 0 "$?"
    ok_if 'with nothing left beside it' test -z "$(find "$E" -maxdepth 1 -name 'renewal.conf.??????')"
}

test_uninstall_keeps_the_certificate_and_removes_only_this_hook() {
    # T15 and Q1: the links' Let's Encrypt certificate stays and certbot keeps renewing it; only this tool's hook
    # goes. A hook of another certificate stays. Using the certificate again puts the hook back.
    local out conf=$E/le/renewal/darban-ovpn-links.conf other=$E/le/renewal/other-site.conf
    built_server
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/le/live/darban-ovpn-links" fullchain.pem privkey.pem
    mkdir -p "$E/le/renewal"
    printf '[renewalparams]\nauthenticator = standalone\n' > "$conf"
    printf '[renewalparams]\nauthenticator = standalone\nrenew_hook = /usr/local/bin/other-hook\n' > "$other"
    out=$(menu '5\nfirst\n1\n1\n0\n')
    has 'the kept certificate is used' "Links use the Let's Encrypt certificate this server got earlier" "$out"
    grep -qx "renew_hook = $E/sbin/darban reload-links" "$conf"; rc_is 'using it puts this tool'"'"'s hook in its renewal file' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    cp "$other" "$E/other.before"

    out=$(bash "$E/lib/uninstall.sh" --yes 2>&1 </dev/null); rc_is 'uninstall succeeds' 0 "$?"
    if grep -q '^renew_hook' "$conf"; then result 0 'the hook line is gone, not only the program'; else result 1 'the hook line is gone, not only the program'; fi
    ok_if 'the certificate stays' test -s "$E/le/live/darban-ovpn-links/fullchain.pem"
    cmp -s "$other" "$E/other.before"; rc_is 'the hook of another certificate stays' 0 "$?"
    has 'the summary names the certificate' "$E/le/live/darban-ovpn-links" "$out"
    has 'says certbot still renews it' 'certbot still renews it' "$out"
    has 'and how to delete it' 'sudo certbot delete --cert-name darban-ovpn-links' "$out"
    lacks 'no failure is reported' 'could not remove' "$out"

    # Installed again: the next link that uses the certificate gives the hook back. The stand-in link service
    # is started once per test: a second start would make its systemctl call itself.
    menu '5\nfirst\n1\n1\n0\n' >/dev/null
    grep -qx "renew_hook = $E/sbin/darban reload-links" "$conf"; rc_is 'the hook comes back' 0 "$?"
    menu '6\n1\n2\n0\n' >/dev/null
    stop_links_stub

    # Remove everything, keeping the certificate: the same. What it says of the renewal depends on whether the setup
    # installed certbot, which Remove everything then takes away.
    local setup_certbot=0
    if grep -Eqx '(package|snap) certbot' "$E/cfg/.server-setup-started"; then setup_certbot=1; fi
    out=$(printf '2\n1\n1\nremove-everything\n' | bash "$E/manager.sh" remove-all 2>&1)
    has 'the certificate is kept' "Kept the Let's Encrypt certificate darban-ovpn-links" "$out"
    if (( setup_certbot )); then
        has 'and says nothing renews it once its certbot is gone' 'The certbot this setup installed is removed, so nothing renews it' "$out"
    else
        has 'and certbot still renews it' 'certbot still renews it' "$out"
    fi
    if grep -q '^renew_hook' "$conf"; then result 0 'the hook line is gone after Remove everything'; else result 1 'the hook line is gone after Remove everything'; fi
    cmp -s "$other" "$E/other.before"; rc_is 'and the other hook stays' 0 "$?"
}

# ---------- PR 4: Diagnostics say what is really wrong, and the docs claim only what is true ----------
test_diagnostics_check_the_crl_as_openvpn_reads_it() {
    # N8 and T16: missing, unreadable for the user OpenVPN runs as, and close to its next update: each is named.
    local out rc
    echo 'user nobody' >> "$SERVER_CONF"
    out=$(mgr status); rc=$?
    has 'a healthy CRL is valid' 'Published CRL valid and complete' "$out"
    lacks 'and readable' 'cannot read the CRL' "$out"

    out=$(FAKE_RUNUSER_DENY=1 mgr status); rc=$?
    has 'a CRL nobody cannot read is named' 'OpenVPN runs as nobody and cannot read the CRL' "$out"
    has 'with what it means' 'every connection may be refused, or the last list it read stays in use' "$out"
    has 'and the fix' "sudo chmod 644 $CRL" "$out"
    rc_is 'it is a problem, not a warning' 1 "$rc"

    sed -i '/^user nobody$/d' "$SERVER_CONF"
    out=$(FAKE_RUNUSER_DENY=1 mgr status)
    lacks 'without a user, OpenVPN stays root and reads it' 'cannot read the CRL' "$out"

    mv "$CRL" "$E/crl.away"
    out=$(mgr status); rc=$?
    has 'a missing CRL is named' "The CRL file $CRL is missing" "$out"
    has 'with what OpenVPN then does' 'OpenVPN does not start without it, and a running one keeps the last list it read' "$out"
    rc_is 'and it is a problem' 1 "$rc"
    lacks 'it is never called harmless' 'accept' "$(grep -i 'CRL' <<<"$out")"
    mv "$E/crl.away" "$CRL"

    # A CRL whose next update is due within a week.
    if [[ -n ${DARBAN_REAL_EASYRSA:-} ]]; then
        EASYRSA_CRL_DAYS=3 easyrsa gen-crl >/dev/null 2>&1
    else
        (cd "$PKI" && openssl ca -batch -config openssl.cnf -gencrl -crldays 3 -out crl.pem 2>/dev/null)
    fi
    cp "$PKI/crl.pem" "$CRL"
    out=$(mgr status)
    has 'a CRL close to its next update is a warning' 'but its next update is due' "$out"
    has 'with what happens then' 'Once it passes, every connection is refused' "$out"
}

test_status_cut_short_stops_quietly() {
    # N4, E7 and T10: a reader that goes away ends the output, with SIGPIPE's status, and no word of an abort.
    local rc
    # With SIGPIPE as a person's shell has it: a runner may start the tests with it ignored, which no shell can undo.
    { sleep 0.5; env --default-signal=PIPE bash "$E/manager.sh" status </dev/null; } 2>"$E/status.err" | true
    rc=${PIPESTATUS[0]}
    rc_is 'the status is SIGPIPE, neither a pass nor a fail' 141 "$rc"
    lacks 'nothing is called an abort' 'aborted unexpectedly' "$(cat "$E/status.err")"
    mgr status >/dev/null; rc=$?
    [[ $rc == 0 || $rc == 1 ]]; rc_is 'read to the end, it is still a pass or a fail' 0 "$?"
}

test_diagnostics_check_the_open_link_over_https() {
    # F09 and T9: while a link is open, the service's HTTPS answer is checked; with no link, nothing is wrong.
    local out rc
    out=$(mgr status)
    has 'no link, no service: said, and no problem' 'No link is open, so the link service is not running' "$out"
    lacks 'no false alarm' 'does not answer over HTTPS' "$out"
    start_links_stub
    menu '5\nalice\n1\n1\n0\n' >/dev/null
    sleep 0.5
    out=$(mgr status)
    has 'an open link is checked over HTTPS' 'The link service answers over HTTPS on TCP' "$out"
    # A key that does not belong to the certificate: the next link would not open.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/other.key" -out "$E/other.pem" \
        -days 30 -subj /CN=127.0.0.1 >/dev/null 2>&1
    cp "$E/other.key" "$E/cfg/link-key.pem"
    out=$(mgr status); rc=$?
    has 'a pair that does not match is a problem' 'The link certificate and its key do not belong together' "$out"
    lacks 'and is not called fine' 'All checks passed' "$out"
    rc_is 'with the status of a problem' 1 "$rc"
    stop_links_stub
}

test_docs_claim_no_more_than_the_tool_does() {
    # F04 and D1: no guide says only a hash of a link stays, or that an install is verified.
    local found
    found=$(grep -rniE 'only a hash|verified install' "$REPO/README.md" "$REPO/README.fa.md" "$REPO/docs" || true)
    [[ -z $found ]]; rc_is 'no such claim is left' 0 "$?"
    if [[ -n $found ]]; then printf '%s\n' "$found" | sed 's/^/    | /'; fi
}

# ---------- connection events ----------
events_here() {
    # Connection events on in this fake server: the three lines in server.conf, the units, and the queue as
    # darban-events-setup.service makes it, owned by the user running the tests, here OpenVPN's user.
    mkdir -p "$E/events/tmp" "$E/events/new" "$E/events/work" "$E/events/bad" "$E/units"
    : > "$E/events/.mounted"
    : > "$E/units/darban-events.path"
    printf 'script-security 2\nclient-connect %s\nclient-disconnect %s\n' "$E/libexec/darban-ovpn-event" "$E/libexec/darban-ovpn-event" >> "$SERVER_CONF"
}
event() {
    # event <connect|disconnect> <name> [VAR=value]...: the real script, as OpenVPN runs it.
    local kind=$1 name=$2
    shift 2
    env -i PATH="$PATH" script_type="client-$kind" common_name="$name" trusted_ip=198.51.100.7 "$@" bash "$E/libexec/darban-ovpn-event"
}
this_boot() { local boot; read -r boot </proc/sys/kernel/random/boot_id; printf '%s' "$boot"; }
now_cs() { local up; read -r up _ </proc/uptime; up=${up/./}; printf '%s' "$((10#$up))"; }
raw_event() {
    # raw_event <file> <kind> <name> <cs> [serial] [us]: an event line as the script writes it, with chosen values.
    printf 'darban-event 1 %s %s %s %s %s 198.51.100.7 %s - - - -\n' "$2" "$3" "$(this_boot)" "$4" "${6:-${EPOCHREALTIME//[!0-9]/}}" "${5:--}" > "$E/events/new/$1"
}
queue_left() { find "$E/events/new" "$E/events/work" -mindepth 1 2>/dev/null; }
link_code() { web -o /dev/null -w '%{http_code}' "$1"; }

test_event_script_never_refuses_a_connection() {
    # E1, E1', E2, C.1 and C.13.2: the script OpenVPN runs exits 0 whatever happens, and writes one well-formed
    # line, only into a queue that is mounted and not full.
    local file line i
    event connect alice; rc_is 'no queue: it exits 0' 0 "$?"
    mkdir -p "$E/events/tmp" "$E/events/new"
    event connect alice; rc_is 'a queue without its mark: 0' 0 "$?"
    ok_if 'and nothing is written without the mark' test -z "$(find "$E/events" -mindepth 2)"
    : > "$E/events/.mounted"
    event connect 'bad name!'; rc_is 'a name OpenVPN should never give: 0' 0 "$?"
    env -i PATH="$PATH" script_type=up bash "$E/libexec/darban-ovpn-event"; rc_is 'another hook: 0' 0 "$?"
    ok_if 'and neither writes anything' test -z "$(find "$E/events" -mindepth 2)"
    event connect alice tls_serial_hex_0=0a:1B:2c; rc_is 'a connection: 0' 0 "$?"
    file=$(ls "$E/events/new")
    [[ $file =~ ^[0-9a-f-]{36}-[0-9]+-[0-9]+-[0-9]+$ ]]; rc_is 'its name is the boot, the time, the process and a random number' 0 "$?"
    line=$(cat "$E/events/new/$file")
    [[ $line =~ ^darban-event\ 1\ connect\ alice\ [0-9a-f-]{36}\ [0-9]+\ [0-9]{16}\ 198\.51\.100\.7\ 0a:1B:2c\ -\ -\ -\ -$ ]]
    rc_is 'its line holds the client, both clocks, the address and the serial' 0 "$?"
    ok_if 'and nothing is left half way' test -z "$(ls -A "$E/events/tmp")"
    rm -f "$E/events/new/"*
    event disconnect alice bytes_received=10 bytes_sent=20 time_duration=30 time_unix=1700000000 tls_serial_hex_0=zz
    line=$(cat "$E/events/new/"*)
    [[ $line == *' 198.51.100.7 - 10 20 30 1700000000' ]]; rc_is 'the end of a session holds its traffic, length and start; a bad serial is left out' 0 "$?"
    rm -f "$E/events/new/"*
    chmod 500 "$E/events/tmp"
    event connect alice; rc_is 'a folder it cannot write to: 0' 0 "$?"
    chmod 700 "$E/events/tmp"
    for i in $(seq 1 1000); do : > "$E/events/new/x$i"; done
    event connect alice; rc_is 'a full queue: 0' 0 "$?"
    [[ $(find "$E/events/new" -type f | wc -l) == 1000 ]]; rc_is 'and a full queue gets nothing more' 0 "$?"
}

test_event_worker_applies_and_sets_aside() {
    # T30, T36, T44, T58, C.12.2 and C.15.6: the worker takes each entry under a name of its own, applies a good event,
    # and sets aside with its reason anything that is not one. Nothing outside the queue is touched.
    local out target=$E/outside why pid
    events_here
    event connect alice
    event disconnect alice bytes_received=5 bytes_sent=6 time_duration=7 time_unix=1700000000
    echo keep > "$target"
    ln -s "$target" "$E/events/new/link"
    mkfifo "$E/events/new/fifo"
    raw_event hard connect bob 5; ln "$E/events/new/hard" "$E/events/hard-copy"
    head -c 600 /dev/zero | tr '\0' a > "$E/events/new/long"
    echo 'secret-content-123' > "$E/events/new/garbage"
    raw_event .hidden connect carol 5
    # An entry already in work/, from a run that stopped half way: it is applied, never overwritten.
    raw_event pending connect dave 5; mv "$E/events/new/pending" "$E/events/work/1-1"
    out=$(mgr events); rc_is 'the worker succeeds' 0 "$?"
    ok_if 'the queue is empty and nothing waits' test -z "$(queue_left)"
    has 'the client record has the connection' 'last_connect=' "$(cat "$E/varlib/clients/alice")"
    has 'and the end of the session' 'session_received=5' "$(cat "$E/varlib/clients/alice")"
    ok_if 'a hidden entry is applied too' test -s "$E/varlib/clients/carol"
    ok_if 'and the one that waited in work/' test -s "$E/varlib/clients/dave"
    ok_if 'a file with two hard links is not applied' test ! -e "$E/varlib/clients/bob"
    [[ $(cat "$target") == keep ]]; rc_is 'the target of a symbolic link is untouched' 0 "$?"
    [[ $(find "$E/events/bad" -name '*.why' | wc -l) == 5 ]]; rc_is 'five entries are set aside' 0 "$?"
    why=$(cat "$E"/events/bad/*.why)
    for reason in 'a symbolic link' 'not a regular file' 'more than one hard link' 'longer than 512 bytes' 'not an event line'; do
        has "the reason is kept: $reason" "$reason" "$why"
    done
    grep -q 'connection events set aside as malformed: 5' "$STUB_LOG"; rc_is 'they are counted in the journal' 0 "$?"
    lacks 'their content never reaches the journal' 'secret-content-123' "$(cat "$STUB_LOG")"
    raw_event old connect erin 5
    sed -i 's/ [0-9a-f-]\{36\} / 00000000-0000-0000-0000-000000000000 /' "$E/events/new/old"
    mgr events >/dev/null
    has 'an event of another boot is set aside' 'from another boot' "$(cat "$E"/events/bad/*.why)"

    # Two workers and the five-minute check at once, and a worker killed half way: every event is applied, once.
    for i in $(seq 1 40); do raw_event "e$i" connect "cc$i" $((100 + i)); done
    { mgr events & mgr sweep & mgr events & wait; } >/dev/null 2>&1
    [[ $(find "$E/varlib/clients" -name 'cc*' | wc -l) == 40 ]]; rc_is 'two workers and the check at once apply every event' 0 "$?"
    ok_if 'and leave nothing behind' test -z "$(queue_left)"
    for i in $(seq 1 200); do raw_event "k$i" connect "k$i" $((100 + i)); done
    setsid bash "$E/manager.sh" events >/dev/null 2>&1 </dev/null &
    pid=$!
    sleep 0.3
    kill -9 -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    mgr events >/dev/null
    [[ $(find "$E/varlib/clients" -name 'k*' | wc -l) == 200 ]]; rc_is 'a worker killed half way: the next run applies the rest' 0 "$?"
    ok_if 'and nothing is left' test -z "$(queue_left)"
}

test_a_connection_event_ends_only_links_made_before_it() {
    # C.12.5, C.13.3, T29 and T47: a link records when it was made by a clock NTP cannot move. A connection after
    # that ends it; one at the same hundredth, one before it, or another client's leaves it. A link of an earlier
    # boot ends at any connection, and a link without that record waits for its time.
    local url meta cs out old plain
    events_here
    start_links_stub
    out=$(menu '5\nalice\n1\n1\n0\n')
    has 'with events on it says a connection ends it' 'or until alice connects' "$out"
    url=$(grep -oE 'https://[^ ]+/l/[0-9a-f]{64}' <<<"$out")
    meta=$(ls "$E"/links/*.meta)
    cs=$(sed -n 's/^created_cs=//p' "$meta")
    [[ $(sed -n 's/^created_boot=//p' "$meta") == "$(this_boot)" && $cs =~ ^[0-9]+$ ]]; rc_is 'the link records its boot and its hundredth of a second' 0 "$?"
    [[ $(link_code "$url/file") == 200 ]]; rc_is 'the link works' 0 "$?"
    has 'a download keeps the fields the link service does not know' "created_cs=$cs" "$(cat "$meta")"
    raw_event same connect alice "$cs"; raw_event before connect alice $((cs - 1)); raw_event other connect bob $((cs + 5))
    mgr events >/dev/null
    [[ $(link_code "$url") == 200 ]]; rc_is 'the same hundredth, before it, or another client: it stays' 0 "$?"
    raw_event after connect alice $((cs + 1))
    mgr events >/dev/null
    [[ $(link_code "$url") == 410 ]]; rc_is 'a connection after it ends it' 0 "$?"
    ok_if 'and leaves no copy of the profile' test -z "$(find "$E/links" -name '*.ovpn')"
    grep -q 'temporary link ended: alice connected' "$STUB_LOG"; rc_is 'the end is in the journal' 0 "$?"

    old=$(new_link alice)
    sed -i 's/^created_boot=.*/created_boot=00000000-0000-0000-0000-000000000000/' "$(ls -t "$E"/links/*.meta | head -n 1)"
    plain=$(new_link alice)
    sed -i '/^created_/d' "$(ls -t "$E"/links/*.meta | head -n 1)"
    raw_event later connect alice "$(now_cs)"
    mgr events >/dev/null
    [[ $(link_code "$old") == 410 ]]; rc_is 'a link of an earlier boot ends' 0 "$?"
    [[ $(link_code "$plain") == 200 ]]; rc_is 'a link made before the update waits for its time' 0 "$?"
    stop_links_stub
}

test_the_link_service_leaves_connections_to_the_events() {
    # C.7.3: with connection events on, the link service does not read the management interface, so a session it
    # would have seen ends nothing; the events do.
    local url meta created
    link_mgmt_server
    events_here
    start_links_stub
    url=$(new_link alice)
    meta=$(ls "$E"/links/*.meta)
    created=$(sed -n 's/^created=//p' "$meta")
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\talice\t198.51.100.7:1\t10.8.0.2\t\t1\t1\tnow\t%s\tUNDEF\t0\t0\tAES-256-GCM\nEND\n' "$(( created + 1 ))" > "$E/mgmt-status"
    sleep 1.5
    [[ $(link_code "$url") == 200 ]]; rc_is 'the link service did not end it' 0 "$?"
    stop_links_stub
    kill "$MGMT_PID" 2>/dev/null
}

test_the_serial_of_a_connection_only_narrows() {
    # C.15.4 and T69: a serial OpenVPN gives is compared as text, in one form. It keeps the link of another
    # certificate of the name, never ends one the rule keeps, and a malformed one ends nothing.
    local url meta cs serial lower
    events_here
    start_links_stub
    url=$(new_link alice)
    meta=$(ls "$E"/links/*.meta)
    cs=$(( $(sed -n 's/^created_cs=//p' "$meta") + 1 ))
    serial=$(openssl x509 -in "$PKI/issued/alice.crt" -noout -serial | sed 's/^serial=//')
    raw_event other connect alice "$cs" 7F:00:01
    mgr events >/dev/null
    [[ $(link_code "$url") == 200 ]]; rc_is 'the serial of another certificate keeps it' 0 "$?"
    raw_event bad connect alice "$cs" not-hex
    mgr events >/dev/null
    [[ $(link_code "$url") == 200 ]]; rc_is 'a malformed serial ends nothing' 0 "$?"
    has 'and is set aside' 'not an event line' "$(cat "$E"/events/bad/*.why)"
    # The same serial as OpenVPN writes it: lower case, with colons and a leading zero.
    lower=$(printf '0%s' "$serial" | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//')
    raw_event same connect alice "$cs" "$lower"
    mgr events >/dev/null
    [[ $(link_code "$url") == 410 ]]; rc_is 'its own serial, in another form, ends it' 0 "$?"
    stop_links_stub
}

test_an_event_that_cannot_be_applied_now_waits() {
    # C.13.4, T35, T48 and T62: while the link files are held, a good event waits in work/ for its next try, however
    # often that fails, and is never called malformed. Once they are free, it ends the link.
    local url meta cs i out
    events_here
    start_links_stub
    url=$(new_link alice)
    meta=$(ls "$E"/links/*.meta)
    cs=$(( $(sed -n 's/^created_cs=//p' "$meta") + 1 ))
    raw_event go connect alice "$cs"
    for i in 1 2 3 4 5 6; do
        FLOCK_FAIL='-w 10 8' mgr events >/dev/null
        # Due again at once, as after its wait.
        sed -i 's/^\([0-9]*\) [0-9]*/\1 0/' "$E"/events/work/*.next
    done
    ok_if 'it waits in work/' test -n "$(find "$E/events/work" -name '*.next')"
    ok_if 'and is never set aside' test -z "$(ls -A "$E/events/bad")"
    has 'its tries are counted' '6 0 ' "$(cat "$E"/events/work/*.next)"
    has 'with the reason' 'the link files were busy' "$(cat "$E"/events/work/*.next)"
    ok_if 'the client record is written already' test -s "$E/varlib/clients/alice"
    [[ $(link_code "$url") == 200 ]]; rc_is 'the link is still open' 0 "$?"
    touch -d '-11 minutes' "$(find "$E/events/work" -type f ! -name '*.next')"
    out=$(mgr status)
    has 'an event waiting over 10 minutes is a problem, with why' 'waited more than 10 minutes (the last failure: the link files were busy)' "$out"
    mgr events >/dev/null
    [[ $(link_code "$url") == 410 ]]; rc_is 'once the files are free, the event ends the link' 0 "$?"
    ok_if 'and nothing waits any more' test -z "$(queue_left)"
    stop_links_stub
}

test_the_client_list_says_when_each_was_last_seen() {
    # E9, C.5 and C.15.1: LAST SEEN from the connection events, the same whatever their order or repeats; never
    # only once events are on.
    local row us
    has 'the list has the column' 'LAST SEEN' "$(mgr list)"
    row=$(mgr list | grep -E '^  alice ')
    lacks 'without events it claims nothing' 'never' "$row"
    events_here
    has 'with events on, a client not seen says so' 'never' "$(mgr list | grep -E '^  alice ')"
    us=${EPOCHREALTIME//[!0-9]/}
    printf 'darban-event 1 disconnect alice %s 9 %s 198.51.100.7 - 300 400 50 1700000100\n' "$(this_boot)" "$us" > "$E/events/new/b"
    mgr events >/dev/null
    printf 'darban-event 1 disconnect alice %s 8 %s 198.51.100.7 - 100 200 40 1700000000\n' "$(this_boot)" "$(( us - 5000000 ))" > "$E/events/new/a"
    printf 'darban-event 1 disconnect alice %s 9 %s 198.51.100.7 - 300 400 50 1700000100\n' "$(this_boot)" "$us" > "$E/events/new/b2"
    mgr events >/dev/null
    has 'an older session after a newer one changes nothing' 'session_received=300' "$(cat "$E/varlib/clients/alice")"
    has 'and the first time seen is the earliest' "first_seen=$(( us - 5000000 ))" "$(cat "$E/varlib/clients/alice")"
    has 'the end of a session says when it was seen' '1 min ago' "$(mgr list | grep -E '^  alice ')"
    mgmt_stub
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\talice\t198.51.100.7:1\t10.8.0.2\t\t1\t1\tnow\t%s\tUNDEF\t0\t0\tAES-256-GCM\nEND\n' "$(date -u +%s)" > "$E/mgmt-reply"
    has 'a client connected now says so' ' now ' "$(mgr list | grep -E '^  alice ')"
}

test_the_link_service_keeps_fields_it_does_not_know() {
    # N17 and T42: a download writes the record back with the fields darban added; and the link service knows when
    # connection events are on.
    local dir=$E/keep key out
    mkdir -p "$dir"
    key=$(printf '%s' "$(printf 'b%.0s' {1..64})" | sha256sum | awk '{print $1}')
    printf 'name=alice\nexpires=%s\ncreated=1\ndownloads=0\ncreated_boot=abc\ncreated_cs=42\ncreated_us=1700000000000000\n' "$(( $(date -u +%s) + 3600 ))" > "$dir/$key.meta"
    echo profile > "$dir/$key.ovpn"
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import linkd; print(linkd.Store(sys.argv[2]).take("b" * 64)[0])' "$REPO/lib" "$dir" >/dev/null
    out=$(cat "$dir/$key.meta")
    has 'the download is counted' 'downloads=1' "$out"
    has 'and the fields it does not know stay' 'created_cs=42' "$out"
    has 'all of them' 'created_us=1700000000000000' "$out"
    on() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import linkd; print(linkd.events_on(sys.argv[2], sys.argv[3]))' "$REPO/lib" "$SERVER_CONF" "$E/libexec/darban-ovpn-event"; }
    [[ $(on) == False ]]; rc_is 'without the lines it reads the management interface' 0 "$?"
    cp "$SERVER_CONF" "$E/conf.plain"
    events_here
    [[ $(on) == True ]]; rc_is 'with them it leaves that to the events' 0 "$?"
    # P05: the same rule as darban's. Anything else leaves it watching the management interface.
    cp "$E/conf.plain" "$SERVER_CONF"; printf 'client-connect %s\n' "$E/libexec/darban-ovpn-event" >> "$SERVER_CONF"
    [[ $(on) == False ]]; rc_is 'the connect line alone is not enough' 0 "$?"
    cp "$E/conf.plain" "$SERVER_CONF"; printf 'client-connect /other/darban-ovpn-event\nclient-disconnect /other/darban-ovpn-event\n' >> "$SERVER_CONF"
    [[ $(on) == False ]]; rc_is 'another path with the same name is not it' 0 "$?"
    cp "$E/conf.plain" "$SERVER_CONF"; events_here; printf 'client-connect %s\n' "$E/libexec/darban-ovpn-event" >> "$SERVER_CONF"
    [[ $(on) == False ]]; rc_is 'nor a line given twice' 0 "$?"
    has 'and darban says the same' 'LAST SEEN' "$(mgr list)"
    lacks 'darban does not call them on either' 'never' "$(mgr list | grep -E '^  alice ')"
}

test_the_five_minute_check() {
    # C.7, C.12.5 and C.15.5: the check ends expired links and the files a link left, ends the link of a client
    # connected with no event, but only while the clock has not jumped, starts a failed watcher again, and cleans
    # the queue.
    local key boot cs us since i name
    # Real profiles, so each link holds a certificate this tool can identify.
    for name in bob carol dave; do menu "1\n$name\n0\n" >/dev/null; done
    events_here
    mkdir -p "$E/links"
    boot=$(this_boot); cs=$(now_cs); us=${EPOCHREALTIME//[!0-9]/}
    printf 'name=alice\nexpires=1000\ncreated=1\ndownloads=0\n' > "$E/links/expired.meta"; : > "$E/links/expired.ovpn"
    : > "$E/links/left.ovpn"; touch -d '-2 minutes' "$E/links/left.ovpn"
    : > "$E/links/fresh.ovpn"
    link_record() { printf 'name=%s\nexpires=%s\ncreated=%s\ndownloads=0\ncreated_boot=%s\ncreated_cs=%s\ncreated_us=%s\n' "$2" "$(( $(date -u +%s) + 3600 ))" "$(( us / 1000000 ))" "$boot" "$cs" "$3" > "$E/links/$1.meta"; cp "$E/clients/$2.ovpn" "$E/links/$1.ovpn"; }
    link_record seen bob "$us"
    link_record jumped carol $(( us + 10000000 ))
    link_record later dave "$us"
    # The same client, with a profile whose certificate cannot be identified: it stays (C.12.4).
    link_record unknown bob "$us"; echo 'not a profile' > "$E/links/unknown.ovpn"
    mgmt_stub
    since=$(( us / 1000000 + 5 ))
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\tbob\t198.51.100.7:1\t10.8.0.2\t\t1\t1\tnow\t%s\tUNDEF\t0\t0\tAES-256-GCM\nCLIENT_LIST\tcarol\t198.51.100.8:1\t10.8.0.3\t\t1\t1\tnow\t%s\tUNDEF\t0\t0\tAES-256-GCM\nCLIENT_LIST\tdave\t198.51.100.9:1\t10.8.0.4\t\t1\t1\tnow\t%s\tUNDEF\t0\t0\tAES-256-GCM\nEND\n' \
        "$since" "$(( since + 20 ))" "$(( us / 1000000 - 100 ))" > "$E/mgmt-reply"
    : > "$E/events/tmp/half"; touch -d '-11 minutes' "$E/events/tmp/half"
    : > "$E/events/bad/old"; touch -d '-8 days' "$E/events/bad/old"
    for i in $(seq 1 105); do : > "$E/events/bad/b$i"; done
    FAKE_FAILED=darban-events.path mgr sweep >/dev/null; rc_is 'the check succeeds' 0 "$?"
    ok_if 'an expired link is gone' test ! -e "$E/links/expired.meta"
    ok_if 'with its profile' test ! -e "$E/links/expired.ovpn"
    ok_if 'a profile left without its record for a while is gone' test ! -e "$E/links/left.ovpn"
    ok_if 'one just written stays' test -e "$E/links/fresh.ovpn"
    ok_if 'a client connected after its link was made ends it' test ! -e "$E/links/seen.meta"
    ok_if 'but not while the clock has jumped since' test -e "$E/links/jumped.meta"
    ok_if 'nor with a session from before the link' test -e "$E/links/later.meta"
    ok_if 'nor a link whose certificate cannot be identified' test -e "$E/links/unknown.meta"
    grep -q 'seen by the five-minute check, with no event' "$STUB_LOG"; rc_is 'the end is in the journal' 0 "$?"
    grep -q 'systemctl reset-failed darban-events.path' "$STUB_LOG"; rc_is 'a failed watcher is reset' 0 "$?"
    grep -q 'systemctl start darban-events.path' "$STUB_LOG"; rc_is 'and started again' 0 "$?"
    ok_if 'what the script left half way is gone' test ! -e "$E/events/tmp/half"
    ok_if 'an entry set aside over a week ago is gone' test ! -e "$E/events/bad/old"
    [[ $(find "$E/events/bad" -mindepth 1 | wc -l) == 100 ]]; rc_is 'at most 100 stay set aside' 0 "$?"
}

test_diagnostics_of_connection_events() {
    # C.12.7, C.13.2, C.15.3, C.15.7, T39 and T49: what can be seen of the way from OpenVPN to this tool.
    local out
    : > "$E/units/darban-events.path" 2>/dev/null || { mkdir -p "$E/units"; : > "$E/units/darban-events.path"; }
    out=$(mgr status)
    has 'lines off: said, with why' "Connection events are off: server.conf was not made by this tool's setup" "$out"
    rm -f "$E/units/darban-events.path"
    events_here
    out=$(mgr status); rc_is 'healthy events pass' 0 "$?"
    has 'and say so' 'Connection events are seen: a link ends at the first connection' "$out"
    has 'the process limits are shown' 'Process limits of OpenVPN: LimitNPROC infinity, TasksMax 20' "$out"
    out=$(FAKE_NO_TMPFS=1 mgr status); rc_is 'a queue that is not mounted is a problem' 1 "$?"
    has 'named as such' "The event queue $E/events is not mounted" "$out"
    rm -f "$E/events/.mounted"
    has 'a mount without its folders ready is the same' 'is not mounted' "$(mgr status)"
    : > "$E/events/.mounted"
    has 'a failed watcher is a problem' 'darban-events.path is not running' "$(FAKE_FAILED=darban-events.path mgr status)"
    has 'a stopped check too' 'darban-sweep.timer is not active' "$(FAKE_FAILED=darban-sweep.timer mgr status)"
    has 'a small process limit is a problem' 'lets root run only 10 processes (LimitNPROC)' "$(FAKE_LIMITNPROC=10 mgr status)"
    raw_event x connect alice 5; touch -d '-11 minutes' "$E/events/new/x"
    has 'an event waiting over 10 minutes is a problem' '1 connection event(s) waited more than 10 minutes' "$(mgr status)"
    rm -f "$E/events/new/x"
    : > "$E/events/bad/y"
    out=$(mgr status); rc_is 'an entry set aside is only a warning' 0 "$?"
    has 'named' '1 malformed connection event(s) were set aside' "$out"
    rm -f "$E/events/bad/y"
    chmod 644 "$E/libexec/darban-ovpn-event"
    out=$(mgr status); rc_is 'a script OpenVPN cannot run is a problem' 1 "$?"
    has 'named, with its effect' 'but root cannot run it, so connections may be refused' "$out"
    chmod 755 "$E/libexec/darban-ovpn-event"
    sed -i '/^script-security/d' "$SERVER_CONF"
    has 'the lines without script-security refuse every connection' 'but script-security is not set, so OpenVPN refuses every connection' "$(mgr status)"
    printf 'script-security 2\n' >> "$SERVER_CONF"
    # A session the server lists for over a minute, with no connect event.
    mgmt_stub
    printf 'TITLE\tOpenVPN\nCLIENT_LIST\talice\t198.51.100.7:1\t10.8.0.2\t\t1\t1\tthen\t%s\tUNDEF\t0\t0\tAES-256-GCM\nEND\n' "$(( $(date -u +%s) - 120 ))" > "$E/mgmt-reply"
    out=$(mgr status); rc_is 'a session with no event is a warning' 0 "$?"
    has 'it names the client' 'Connected, but no connection event was seen: alice' "$out"
    rm -f "$E/units/darban-events.path"
    has 'units removed on purpose are not called broken' 'Connection events are not processed' "$(mgr status)"
}

test_enable_events_writes_the_lines_only_when_safe() {
    # C.1, C.9, C.14.1, C.15.3, C.15.12, T26, T41 and T43: the lines go into server.conf with one restart only when
    # every check passes; anything in the way is named, and nothing changes.
    local out before
    mkdir -p "$E/events/tmp" "$E/events/new" "$E/events/work" "$E/events/bad" "$E/units"
    : > "$E/events/.mounted"; : > "$E/units/darban-events.path"
    out=$(mgr enable-events); rc_is 'a server.conf this tool did not make: no failure' 0 "$?"
    has 'it is named' "Connection events stay off: server.conf was not made by this tool's setup" "$out"
    sed -i '1i # Created by Darban OVPN server-setup.' "$SERVER_CONF"
    before=$(cat "$SERVER_CONF")
    printf 'client-connect /usr/local/bin/other-hook\n' >> "$SERVER_CONF"
    has 'another script stays the only one' 'already runs another client-connect or client-disconnect script' "$(mgr enable-events)"
    printf '%s\n' "$before" > "$SERVER_CONF"; printf 'script-security 1\n' >> "$SERVER_CONF"
    has 'script-security 1 allows no script' 'sets script-security 1, which lets OpenVPN run no script' "$(mgr enable-events)"
    printf '%s\n' "$before" > "$SERVER_CONF"
    has 'a small process limit is named' 'lets root run only 10 processes (LimitNPROC)' "$(FAKE_LIMITNPROC=10 mgr enable-events)"
    chmod 644 "$E/libexec/darban-ovpn-event"
    has 'a script that cannot run is named' "cannot run $E/libexec/darban-ovpn-event" "$(mgr enable-events)"
    chmod 755 "$E/libexec/darban-ovpn-event"
    has 'a queue that is not mounted is named' 'is not mounted' "$(FAKE_NO_TMPFS=1 mgr enable-events)"
    [[ $(cat "$SERVER_CONF") == "$before" ]]; rc_is 'none of these changed server.conf' 0 "$?"
    lacks 'or restarted OpenVPN' 'restart openvpn' "$(cat "$STUB_LOG")"

    out=$(FAIL_RESTART=1 mgr enable-events)
    has 'a restart that fails is rolled back' 'Connection events stay off' "$out"
    lacks 'and the lines are not left' 'client-connect' "$(cat "$SERVER_CONF")"
    : > "$STUB_LOG"
    out=$(mgr enable-events); rc_is 'all clear: it succeeds' 0 "$?"
    has 'it says the restart first' 'OpenVPN restarts once' "$out"
    has 'and that events are on' 'Connection events are on: a link now ends at the first connection the server sees' "$out"
    grep -qx 'script-security 2' "$SERVER_CONF"; rc_is 'script-security 2 is written' 0 "$?"
    grep -qx "client-connect $E/libexec/darban-ovpn-event" "$SERVER_CONF"; rc_is 'the connect line is written' 0 "$?"
    grep -qx "client-disconnect $E/libexec/darban-ovpn-event" "$SERVER_CONF"; rc_is 'the disconnect line is written' 0 "$?"
    [[ $(grep -c 'restart openvpn-server@server' "$STUB_LOG") == 1 ]]; rc_is 'with one restart' 0 "$?"
    grep -qx 'script-security 2' "$E/cfg/.event-lines"; rc_is 'what it added is recorded' 0 "$?"
    : > "$STUB_LOG"
    has 'again: nothing to do' 'Connection events are on.' "$(mgr enable-events)"
    lacks 'and no restart' 'restart' "$(cat "$STUB_LOG")"
    sed -i '1d' "$SERVER_CONF"
    sed -i '/^script-security/d' "$SERVER_CONF"; printf 'script-security 3\n' >> "$SERVER_CONF"
    has 'a higher script-security of the owner stays as it is' 'Connection events are on.' "$(mgr enable-events)"
}

test_uninstall_keeps_the_event_script_and_its_lines() {
    # Q2, C.9 and C.13.8: removing only the tool takes the units and the queue of connection events away, and
    # keeps the script and its lines, so OpenVPN needs no restart. The summary says how to remove them.
    local out units=$E/fake-units before
    install_removal_scripts
    events_here
    printf 'script-security 2\n' > "$E/cfg/.event-lines"
    for unit in darban-events.path darban-sweep.timer darban-events.service darban-sweep.service darban-expire.service darban-events-setup.service 'run-darban\x2devents.mount'; do : > "$units/$unit"; done
    before=$(cat "$SERVER_CONF")
    : > "$STUB_LOG"
    out=$(bash "$E/lib/uninstall.sh" --yes 2>&1 </dev/null); rc_is 'uninstall succeeds' 0 "$?"
    ok_if 'the units of connection events are gone' test -z "$(find "$units" -name 'darban-events*' -o -name 'darban-sweep*' -o -name 'darban-expire*' -o -name 'run-darban*')"
    grep -q 'systemctl disable --now darban-events.path' "$STUB_LOG"; rc_is 'the watcher is stopped' 0 "$?"
    [[ $(grep -n 'systemctl' "$STUB_LOG" | head -n 1) == *'systemctl stop darban-expire.timer' ]]; rc_is 'the timer for kept files is stopped first' 0 "$?"
    ok_if 'the script stays' test -x "$E/libexec/darban-ovpn-event"
    [[ $(cat "$SERVER_CONF") == "$before" ]]; rc_is 'server.conf is untouched' 0 "$?"
    lacks 'OpenVPN is not restarted' 'restart openvpn' "$(cat "$STUB_LOG")"
    has 'the summary names the script' "$E/libexec/darban-ovpn-event" "$out"
    has 'and its lines' 'client-connect and client-disconnect, and script-security 2' "$out"
    has 'and how to remove them, in order' "sudo sed -i '\\#$E/libexec/darban-ovpn-event#d; /^script-security 2\$/d' $SERVER_CONF && sudo systemctl restart openvpn-server@server && sudo rm $E/libexec/darban-ovpn-event" "$out"
    event connect alice; rc_is 'the script still exits 0' 0 "$?"
}

test_restore_previous_turns_events_off_for_an_older_version() {
    # C.9, C.12.12 and C.13.8: going back to a version without connection events removes their units first, by
    # this version, and says what stays and how to remove it.
    local out backup=$E/backups-tool/20260101T000000
    mkdir -p "$E/sbin" "$backup/sbin" "$backup/lib" "$backup/units"
    printf '#!/usr/bin/env bash\nDARBAN_VERSION=1.0.0-rc.10\n' > "$backup/sbin/darban"
    echo 'old unit' > "$backup/units/darban-crl.timer"
    events_here
    for unit in darban-sweep.timer darban-events.service darban-sweep.service darban-expire.service darban-events-setup.service 'run-darban\x2devents.mount'; do : > "$E/units/$unit"; done
    out=$(menu '9\n4\n1\n0\n0\n')
    has 'it says the older version does not use them' 'v1.0.0-rc.10 does not use connection events' "$out"
    has 'and what stays' "These stay, so connections keep working: $E/libexec/darban-ovpn-event" "$out"
    ok_if 'nothing is removed on No' test -e "$E/units/darban-events.path"
    out=$(menu '9\n4\n2\n')
    has 'it restores' 'Restored v1.0.0-rc.10' "$out"
    ok_if 'the units of connection events are gone' test -z "$(find "$E/units" -name 'darban-events*' -o -name 'darban-sweep*' -o -name 'darban-expire*' -o -name 'run-darban*')"
    ok_if 'the script stays' test -x "$E/libexec/darban-ovpn-event"
    grep -q 'client-connect' "$SERVER_CONF"; rc_is 'and its lines' 0 "$?"
}

# ---------- connection events: round 17 ----------
link_cs() { echo $(( $(sed -n 's/^created_cs=//p' "$1") + 1 )); }

test_an_event_is_read_once() {
    # C.13.1 and P03: its checks, its order and what is applied all come from one read. A change to the file after
    # it, as a writer that kept the file open could make, changes nothing.
    events_here
    raw_event a connect alice 5
    cat > "$E/mutate.sh" <<'SH'
for f in "$E"/events/work/*; do
    [[ $f == *.next ]] || sed -i 's/ alice / mallory /; s/ [0-9a-f-]\{36\} / 00000000-0000-0000-0000-000000000000 /' "$f"
done
SH
    # The stand-in flock runs the hook when the worker takes the CA lock: after it read and sorted, before it applies.
    FLOCK_HOOK="bash $E/mutate.sh" mgr events >/dev/null
    ok_if 'what was read is applied' test -s "$E/varlib/clients/alice"
    ok_if 'what the file says afterwards is not' test ! -e "$E/varlib/clients/mallory"
}

test_a_run_stops_at_its_limit_and_starts_again() {
    # C.15.5 and P04: a run applies at most its limit, also of what already waited in work/, and leaves its mark in
    # new/, so the path unit starts the next run, which applies the rest.
    local i
    events_here
    for i in $(seq 1 12); do raw_event "w$i" connect "bulk$i" $((100 + i)); mv "$E/events/new/w$i" "$E/events/work/old-$i"; done
    TEST_EVENT_MAX=5 mgr events >/dev/null
    [[ $(find "$E/varlib/clients" -name 'bulk*' | wc -l) == 5 ]]; rc_is 'one run applies no more than its limit' 0 "$?"
    ok_if 'and leaves its mark for the next run' test -e "$E/events/new/.darban-rerun"
    TEST_EVENT_MAX=5 mgr events >/dev/null
    TEST_EVENT_MAX=5 mgr events >/dev/null
    [[ $(find "$E/varlib/clients" -name 'bulk*' | wc -l) == 12 ]]; rc_is 'the next runs apply the rest' 0 "$?"
    ok_if 'the mark is gone once nothing is left' test ! -e "$E/events/new/.darban-rerun"
    ok_if 'and was never taken for an event' test -z "$(ls -A "$E/events/bad")"
}

test_a_claim_never_overwrites_an_entry() {
    # C.15.6, T44, T58 and P17: when the name a run would give is taken, the entry gets the next one; neither is lost.
    events_here
    raw_event first connect dave 5; mv "$E/events/new/first" "$E/events/work/fixed-1"
    raw_event second connect erin 6
    TEST_EVENT_RUN=fixed mgr events >/dev/null
    ok_if 'the entry already there is applied, not overwritten' test -s "$E/varlib/clients/dave"
    ok_if 'and the new one under the next name' test -s "$E/varlib/clients/erin"
    ok_if 'and nothing is left' test -z "$(queue_left)"
}

test_workers_take_turns_on_the_real_lock() {
    # C.6: with the real flock for the CA lock, two workers and the five-minute check at once apply every event.
    local i
    events_here
    mkdir -p "$E/realflock"; ln -s /usr/bin/flock "$E/realflock/flock"
    for i in $(seq 1 60); do raw_event "l$i" connect "lk$i" $((100 + i)); done
    ( PATH="$E/realflock:$PATH"; mgr events & mgr events & mgr sweep & wait ) >/dev/null 2>&1
    [[ $(find "$E/varlib/clients" -name 'lk*' | wc -l) == 60 ]]; rc_is 'every event is applied' 0 "$?"
    ok_if 'and nothing is left' test -z "$(queue_left)"
    ok_if 'and none waits for the lock' test -z "$(find "$E/events/work" -name '*.next')"
}

test_an_event_never_ends_a_link_it_cannot_identify() {
    # C.12.4 and P08: a link whose certificate this tool cannot identify is not ended by a connection; it stays until
    # its time is up or it is deleted in menu 6, and the diagnostics name it.
    local url meta ovpn
    events_here
    start_links_stub
    url=$(new_link alice)
    meta=$(ls "$E"/links/*.meta); ovpn=${meta%.meta}.ovpn
    awk '/^<cert>/ {print; print "MIIBbroken"; skip=1; next} /^<\/cert>/ {skip=0} !skip' "$ovpn" > "$E/broken.ovpn"
    cat "$E/broken.ovpn" > "$ovpn"
    raw_event go connect alice "$(link_cs "$meta")"
    mgr events >/dev/null
    [[ $(link_code "$url") == 200 ]]; rc_is 'the connection does not end it' 0 "$?"
    has 'the diagnostics name it' 'certificate this tool cannot identify: alice' "$(mgr status)"
    stop_links_stub
}

test_a_name_issued_again_starts_unseen() {
    # P09: LAST SEEN is of the certificate the name has now, so a name issued again has not been seen yet.
    events_here
    menu '1\nbob\n0\n' >/dev/null
    event connect bob
    mgr events >/dev/null
    has 'a connection is seen' '1 min ago' "$(mgr list | grep -E '^  bob ')"
    revoke_menu bob >/dev/null
    menu '1\nbob\n0\n' >/dev/null
    has 'issued again, the name is not seen yet' 'never' "$(mgr list | grep -E '^  bob ')"
}

test_connection_serials_in_the_form_openvpn_gives_them() {
    # T69, C.15.4 and P16: the serials OpenVPN 2.7.9 gave in PR 0, as it writes them: 16 bytes, lower case, with
    # colons. The script keeps them as given, another certificate's serial keeps the link, and its own, in the same
    # form, ends it.
    local url meta s line own
    events_here
    start_links_stub
    url=$(new_link alice)
    meta=$(ls "$E"/links/*.meta)
    for s in 1c:d3:30:8b:d7:80:fa:18:19:46:39:7b:15:e8:3e:f8 77:ca:ad:24:66:a4:ec:65:31:04:76:60:01:6b:5b:a7 7e:4b:6c:9b:a2:27:47:ca:a6:4e:50:9a:cd:9f:39:0e; do
        rm -f "$E/events/new/"*
        event connect alice tls_serial_hex_0="$s"
        line=$(cat "$E/events/new/"*)
        [[ $line == *" 198.51.100.7 $s - - - -" ]]; rc_is "the script keeps $s as OpenVPN gives it" 0 "$?"
        mgr events >/dev/null
    done
    [[ $(link_code "$url") == 200 ]]; rc_is 'the serial of another certificate keeps the link' 0 "$?"
    own=$(openssl x509 -in "$PKI/issued/alice.crt" -noout -serial | sed 's/^serial=//' | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//')
    event connect alice tls_serial_hex_0="$own"
    mgr events >/dev/null
    [[ $(link_code "$url") == 410 ]]; rc_is 'its own serial, in that form, ends it' 0 "$?"
    stop_links_stub
}

test_a_forged_event_reaches_no_further_than_its_client() {
    # P07, as the owner accepted it: a line another program of OpenVPN's user writes can end that client's link and
    # change its record; nothing else. A name that is not one goes nowhere.
    local a b
    events_here
    menu '1\nbob\n0\n' >/dev/null
    start_links_stub
    a=$(new_link alice)
    b=$(new_link bob)
    raw_event forged connect alice 999999999
    printf 'darban-event 1 connect ../../outside %s 5 %s 198.51.100.7 - - - - -\n' "$(this_boot)" "${EPOCHREALTIME//[!0-9]/}" > "$E/events/new/path"
    mgr events >/dev/null
    [[ $(link_code "$a") == 410 ]]; rc_is "the forged line ends that client's link" 0 "$?"
    [[ $(link_code "$b") == 200 ]]; rc_is "and no other client's" 0 "$?"
    ok_if 'it changes only that record' test ! -e "$E/varlib/clients/bob"
    ok_if 'a name that is a path is set aside' test -n "$(grep -l 'not an event line' "$E"/events/bad/*.why)"
    ok_if 'and writes nothing outside the record folder' test ! -e "$E/outside"
    stop_links_stub
}

# ---------- files kept on the server ----------
record_of() { sed -n "s/^$2=//p" "$E/clients/$1.share"; }
kept_cs() { echo $(( $(record_of "$1" created_cs) + 1 )); }
expire_unit() { mkdir -p "$E/units"; : > "$E/units/darban-expire.service"; }
share_event() {
    # share_event <file> <name> <cs> <share>: a connection as the script writes it when the profile names its share.
    printf 'darban-event 1 connect %s %s %s %s 198.51.100.7 - - - - - %s\n' "$2" "$(this_boot)" "$3" "${EPOCHREALTIME//[!0-9]/}" "$4" > "$E/events/new/$1"
}

test_a_kept_file_has_a_record_and_a_time() {
    # D3, C.10, C.12.13, C.13.5 and I14: a file kept on the server is a share like a link. Its record says when it
    # goes, which certificate it holds and where it points, so the tool never reads the file again.
    local out now expires
    expire_unit
    menu '1\nbob\n0\n' >/dev/null
    ok_if 'the file has a record beside it' test -s "$E/clients/bob.share"
    # Without a terminal, creating a client stops at its download panel; sharing it again says when it goes.
    has 'keeping it says when it goes' 'It is deleted in 24 h, or when bob connects.' "$(menu '5\nbob\n2\n0\n')"
    now=$(date -u +%s); expires=$(record_of bob expires)
    (( expires > now + 86400 - 120 && expires <= now + 86400 )); rc_is 'which expires after the hours of Settings' 0 "$?"
    [[ $(record_of bob serial) == "$(serial_of "$PKI/issued/bob.crt" | sed 's/^0*//')" ]]; rc_is 'it names the certificate in the file' 0 "$?"
    has 'and where the file points' 'remote=remote vpn.example.com 1194' "$(cat "$E/clients/bob.share")"
    [[ $(record_of bob share_id) =~ ^[0-9a-f]{16}$ ]]; rc_is 'and has an identity of its own' 0 "$?"
    grep -q -- "systemd-run --quiet --unit=darban-expire --on-calendar=@$expires --timer-property=AccuracySec=1s" "$STUB_LOG"
    rc_is 'one timer is set for its time' 0 "$?"
    lacks 'no profile names its share while the flag is off' 'UV_DARBAN_SHARE' "$(cat "$E/clients/bob.ovpn")"
    # A read of the file would move its access time: menu 6, its commands, Diagnostics and a name check leave it.
    touch -a -d '@1000000000' "$E/clients/bob.ovpn"
    out=$(menu '6\n\n0\n')
    has 'menu 6 shows the time a file has left' '24 h left' "$(grep -A2 'FILES ON THE SERVER' <<<"$out")"
    has 'and that it was not read yet' 'not read yet' "$out"
    has 'it says when a file goes' 'A file on the server goes the same way.' "$out"
    out=$(menu '6\n1\n1\n0\n')
    has 'the commands come again' 'USERPROFILE' "$out"
    has 'with the address from the record' 'vpn.example.com:1194/UDP' "$out"
    mgr status >/dev/null
    menu '1\nbob\n0\n' >/dev/null
    [[ $(stat -c %X "$E/clients/bob.ovpn") == 1000000000 ]]; rc_is 'and none of them read the file' 0 "$?"
    touch -a -d "@$(( $(date -u +%s) + 5 ))" "$E/clients/bob.ovpn"
    out=$(menu '6\n\n0\n')
    has 'a file read after it was made says so' 'file read' "$out"
    has 'with what that means' 'file read: the file was read after it was made; Darban cannot tell by whom.' "$out"
    out=$(FAKE_ATIME=noatime menu '6\n\n0\n')
    lacks 'without access times nothing is claimed' 'file read' "$out"
    lacks 'either way' 'not read yet' "$out"
    has 'Settings says what the time is for' 'A link or a file kept on the server is removed after this time' "$(menu '7\n3\n\n0\n0\n')"
}

test_a_connection_deletes_the_kept_file_made_before_it() {
    # E3, E4, T29, T38 and T61: a connection after the file was made deletes it, with its record; one at the same
    # hundredth, one before it, one holding another certificate, or another client's leaves it. The timer then
    # waits for the next file.
    local cs
    events_here; expire_unit
    menu '1\nbob\n0\n' >/dev/null
    menu '1\ncarol\n0\n' >/dev/null
    cs=$(record_of bob created_cs)
    raw_event same connect bob "$cs"
    raw_event before connect bob $(( cs - 1 ))
    raw_event serial connect bob $(( cs + 1 )) 0BADC0DE
    raw_event other connect dave $(( cs + 1 ))
    mgr events >/dev/null
    ok_if 'a connection at the same hundredth, before it, or with another certificate leaves it' test -s "$E/clients/bob.ovpn"
    : > "$STUB_LOG"
    raw_event after connect bob $(( cs + 1 )) "$(serial_of "$PKI/issued/bob.crt")"
    mgr events >/dev/null
    ok_if 'a connection after it deletes the file' test ! -e "$E/clients/bob.ovpn"
    ok_if 'with its record' test ! -e "$E/clients/bob.share"
    ok_if "another client's file stays" test -s "$E/clients/carol.ovpn"
    grep -q 'profile deleted from server: .*/bob.ovpn, bob connected' "$STUB_LOG"; rc_is 'the journal says why' 0 "$?"
    grep -q "systemd-run .*--on-calendar=@$(record_of carol expires) " "$STUB_LOG"; rc_is 'the timer now waits for the next file' 0 "$?"
    has 'and the client record has the connection' 'last_connect=' "$(cat "$E/varlib/clients/bob")"
    # A file of an earlier boot is older than any event in the queue.
    sed -i 's/^created_boot=.*/created_boot=00000000-0000-0000-0000-000000000000/' "$E/clients/carol.share"
    raw_event boot connect carol 5
    mgr events >/dev/null
    ok_if 'a file of an earlier boot goes at any connection' test ! -e "$E/clients/carol.ovpn"
}

test_the_share_a_profile_names_only_narrows() {
    # E7, C.11 and C.12.4 bullet 5: a connection that names another share leaves the file or link; one that names
    # this share, or none, ends it. The script passes the name on from a connection only, and it never reaches past
    # its own client.
    local id cs url meta
    events_here
    menu '1\nbob\n0\n' >/dev/null
    id=$(record_of bob share_id); cs=$(kept_cs bob)
    share_event other bob "$cs" 0123456789abcdef
    mgr events >/dev/null
    ok_if 'a connection naming another share leaves the file' test -s "$E/clients/bob.ovpn"
    share_event this bob "$cs" "$id"
    mgr events >/dev/null
    ok_if 'one naming its own share deletes it' test ! -e "$E/clients/bob.ovpn"
    rm -f "$E/events/new/"*
    event connect alice UV_DARBAN_SHARE=0123456789abcdef
    [[ $(cat "$E/events/new/"*) == *' - - - - 0123456789abcdef' ]]; rc_is 'the script writes the share a connection names' 0 "$?"
    rm -f "$E/events/new/"*
    event connect alice 'UV_DARBAN_SHARE=../x'
    [[ $(cat "$E/events/new/"*) == *' - - - -' ]]; rc_is 'and leaves out one that is not a share' 0 "$?"
    rm -f "$E/events/new/"*
    event disconnect alice UV_DARBAN_SHARE=0123456789abcdef
    lacks 'the end of a session names none' '0123456789abcdef' "$(cat "$E/events/new/"*)"
    rm -f "$E/events/new/"*
    # With the flag, a profile names its share, and a link made from it keeps the name.
    echo 'SHARE_ID_IN_PROFILE=yes' >> "$E/cfg/config"
    menu '1\ncarol\n0\n' >/dev/null
    id=$(record_of carol share_id)
    has 'with the flag a profile names its share' $'setenv UV_DARBAN_SHARE '"$id"$'\npush-peer-info' "$(cat "$E/clients/carol.ovpn")"
    start_links_stub
    url=$(new_link carol)
    meta=$(ls "$E"/links/*.meta)
    id=$(sed -n 's/^share_id=//p' "$meta")
    has 'the link holds the same name as its profile' "setenv UV_DARBAN_SHARE $id" "$(cat "${meta%.meta}.ovpn")"
    share_event other carol "$(link_cs "$meta")" 0123456789abcdef
    share_event alien alice "$(link_cs "$meta")" "$id"
    mgr events >/dev/null
    [[ $(link_code "$url") == 200 ]]; rc_is "another share, or carol's share named by another client, leaves the link" 0 "$?"
    share_event this carol "$(link_cs "$meta")" "$id"
    mgr events >/dev/null
    [[ $(link_code "$url") == 410 ]]; rc_is 'its own share ends it' 0 "$?"
    stop_links_stub
}

test_the_timer_for_kept_files() {
    # C.13.5, T50 and T63: the check deletes a file whose time is up; a timer left from a file shared again never
    # deletes the newer one, because the check reads every time from the records. A timer that cannot be set leaves
    # the file to the five-minute check, with a warning and a yellow line in Diagnostics.
    local out
    expire_unit
    menu '1\nbob\n0\n' >/dev/null
    sed -i "s/^expires=.*/expires=$(( $(date -u +%s) - 1 ))/" "$E/clients/bob.share"
    : > "$STUB_LOG"
    mgr sweep >/dev/null; rc_is 'the check succeeds' 0 "$?"
    ok_if 'a file whose time is up goes' test ! -e "$E/clients/bob.ovpn"
    ok_if 'with its record' test ! -e "$E/clients/bob.share"
    grep -q 'profile deleted from server: .*/bob.ovpn, its time was up' "$STUB_LOG"; rc_is 'the journal says why' 0 "$?"
    menu '5\nbob\n2\n0\n' >/dev/null
    ok_if 'shared again, the file is back' test -s "$E/clients/bob.ovpn"
    mgr sweep >/dev/null
    ok_if 'and the check of the old timer leaves it' test -s "$E/clients/bob.ovpn"
    grep -q 'systemctl stop darban-expire.timer' "$STUB_LOG"; rc_is 'the old timer is stopped before a new one is set' 0 "$?"
    out=$(FAIL_SYSTEMD_RUN=1 menu '1\ncarol\n0\n')
    has 'a timer that cannot be set is said' 'the five-minute check deletes it once its time is up' "$out"
    ok_if 'and the file is still made' test -s "$E/clients/carol.share"
    out=$(FAKE_FAILED=darban-expire.timer mgr status)
    has 'Diagnostics then warn' 'The timer that deletes a kept file at its time is not set' "$out"
    lacks 'only then' 'The timer that deletes a kept file at its time is not set' "$(mgr status)"
}

test_a_file_from_before_gets_its_whole_time() {
    # L1, L7 and E6: a file kept by an earlier version has no record. The first check gives it one, with the whole
    # time of Settings, once in the journal. So does a file something else rewrote. A file of a name the CA does
    # not know, a symbolic link and any other file stay untouched, and a record without its file goes.
    local now expires
    menu '1\nbob\n0\n' >/dev/null
    rm -f "$E/clients/bob.share"
    echo keep > "$E/clients/stranger.ovpn"
    echo mine > "$E/outside"; ln -s "$E/outside" "$E/clients/carol.ovpn"
    echo orphan > "$E/clients/ghost.share"
    : > "$STUB_LOG"
    mgr sweep >/dev/null
    ok_if 'a file from before gets a record' test -s "$E/clients/bob.share"
    now=$(date -u +%s); expires=$(record_of bob expires)
    (( expires > now + 86400 - 120 && expires <= now + 86400 )); rc_is 'with the whole time from now' 0 "$?"
    [[ -n $(record_of bob serial) ]]; rc_is 'and the certificate it holds' 0 "$?"
    [[ $(grep -c 'profile kept on the server from before' "$STUB_LOG") == 1 ]]; rc_is 'said once in the journal' 0 "$?"
    mgr sweep >/dev/null
    [[ $(grep -c 'profile kept on the server from before' "$STUB_LOG") == 1 ]]; rc_is 'and not again' 0 "$?"
    ok_if 'a file of a name the CA does not know gets none' test ! -e "$E/clients/stranger.share"
    [[ $(cat "$E/clients/stranger.ovpn") == keep ]]; rc_is 'and is untouched' 0 "$?"
    ok_if 'a symbolic link gets none' test ! -e "$E/clients/carol.share"
    [[ $(cat "$E/outside") == mine ]]; rc_is 'and its target is untouched' 0 "$?"
    ok_if 'a record without its file goes' test ! -e "$E/clients/ghost.share"
    sed -i 's/^expires=.*/expires=1/' "$E/clients/bob.share"
    echo '# changed elsewhere' >> "$E/clients/bob.ovpn"
    mgr sweep >/dev/null
    ok_if 'a file rewritten by something else is not deleted by a record of the old one' test -s "$E/clients/bob.ovpn"
    (( $(record_of bob expires) > now )); rc_is 'it gets its whole time again' 0 "$?"
}

test_a_thousand_kept_files() {
    # T50 and T63 at scale: a thousand files kept on the server, in one check, then all due at once.
    local i serial start took
    mkdir -p "$E/units"; : > "$E/units/darban-expire.service"
    start=$(( $(date -u +%s) + 7200 ))
    for i in $(seq 1 1000); do
        serial=$(printf '%X' $(( 70000 + i )))
        printf 'V\t351231235959Z\t\t%s\tunknown\t/CN=k%s\n' "$serial" "$i" >> "$PKI/index.txt"
        echo "profile $i" > "$E/clients/k$i.ovpn"
        printf 'share_id=%016x\nname=k%s\nserial=%s\ncreated=%s\nexpires=%s\nremote=remote vpn.example.com 1194\nfile=%s\n' \
            "$i" "$i" "$serial" "$(date -u +%s)" "$(( start + i ))" "$(stat -c '%i:%Y:%s' "$E/clients/k$i.ovpn")" > "$E/clients/k$i.share"
    done
    : > "$STUB_LOG"
    SECONDS=0
    mgr sweep >/dev/null; rc_is 'the check of a thousand files succeeds' 0 "$?"
    took=$SECONDS
    printf '    a thousand files not due: %s s\n' "$took"
    (( took < 60 )); rc_is 'within a minute' 0 "$?"
    [[ $(find "$E/clients" -name 'k*.ovpn' | wc -l) == 1000 ]]; rc_is 'and none of them goes before its time' 0 "$?"
    grep -q -- "--on-calendar=@$(( start + 1 )) " "$STUB_LOG"; rc_is 'the timer is set for the earliest' 0 "$?"
    sed -i 's/^expires=.*/expires=1/' "$E"/clients/k*.share
    SECONDS=0
    mgr sweep >/dev/null
    took=$SECONDS
    printf '    a thousand files due at once: %s s\n' "$took"
    [[ $(find "$E/clients" -name 'k*' | wc -l) == 0 ]]; rc_is 'a thousand files due at once all go' 0 "$?"
    (( took < 120 )); rc_is 'within two minutes' 0 "$?"
}

# ---------- backup and restore of the CA ----------
AGE_KEY=age1$(printf 'q%.0s' $(seq 1 58))
template_server() {
    # The server folder as this tool's setup writes it, so a backup holds what a real one holds.
    cp "$PKI/ca.crt" "$E/server/ca.crt"
    cp "$PKI/private/server_abc123.key" "$E/server/server.key"
    cat > "$SERVER_CONF" <<CONF
# Created by Darban OVPN server-setup.
port 1194
proto udp4
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
ca ca.crt
cert server.crt
key server.key
tls-crypt tls-crypt.key
crl-verify $E/server/crl.pem
dh none
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
keepalive 10 60
explicit-exit-notify 1
persist-key
persist-tun
user nobody
group nogroup
management /run/openvpn-server/darban.sock unix
verb 3
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
CONF
}
backup_key_set() { printf 'BACKUP_RECIPIENT=%s\n' "$AGE_KEY" > "$E/cfg/backup.conf"; }
backups() { find "$E/pki-backups" -maxdepth 1 -name 'darban-pki-*.tar.age' 2>/dev/null | wc -l; }
manifest_value() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(v if not isinstance(v, (list, dict)) else json.dumps(v))' "$E/pki-backups/latest.manifest.json" "$1"; }
ca_fp() { openssl x509 -in "$PKI/ca.crt" -noout -fingerprint -sha256 | sed 's/^[^=]*=//'; }
opened_backup() {
    # opened_backup <out.tar>: the newest backup, opened as the owner would, with the stand-in of age.
    age -d -i key.txt -o "$1" "$E/pki-backups/latest.tar.age"
}
restore_run() { bash "$E/manager.sh" restore "$@" 2>&1; }
# The systemctl stand-in remembers whether OpenVPN's unit was stopped or disabled.
unit_on() { [[ ! -e $E/unit-state/openvpn-server@server.service.stopped && ! -e $E/unit-state/openvpn-server@server.service.disabled ]]; }
unit_running() { [[ ! -e $E/unit-state/openvpn-server@server.service.stopped ]]; }
unit_enabled() { [[ ! -e $E/unit-state/openvpn-server@server.service.disabled ]]; }
craft() {
    # craft <good tar> <out tar> <case> [file]: a changed copy of an archive. With "keep-manifest" the checksums
    # stay as they were; otherwise manifest.json follows the change.
    python3 - "$@" <<'PY'
import hashlib, io, json, sys, tarfile
good, out, case = sys.argv[1:4]
extra = sys.argv[4] if len(sys.argv) > 4 else ''
src = tarfile.open(good)
members = [(m, src.extractfile(m).read() if m.isreg() else b'') for m in src.getmembers()]
manifest = json.loads(dict((m.name, d) for m, d in members)['manifest.json'])
def regular(name, data, mode=0o600):
    info = tarfile.TarInfo(name); info.size = len(data); info.mode = mode
    return info, data
result = [(m, d) for m, d in members if m.name != 'manifest.json']
keep = False
if case == 'extra':
    result.append(regular('pki/evil.sh', b'#!/bin/sh\n'))
elif case == 'symlink':
    info = tarfile.TarInfo('clients/link'); info.type = tarfile.SYMTYPE; info.linkname = '/etc/shadow'; result.append((info, b''))
elif case == 'hardlink':
    info = tarfile.TarInfo('clients/hard'); info.type = tarfile.LNKTYPE; info.linkname = 'pki/ca.crt'; result.append((info, b''))
elif case == 'duplicate':
    result.append(regular('darban/domain', b'evil.example.com\n'))
elif case == 'big':
    result.append(regular('clients/big', b'x' * (1024 * 1024 + 1)))
elif case == 'absolute':
    result.append(regular('/etc/cron.d/evil', b'* * * * * root sh\n'))
elif case == 'dotdot':
    result.append(regular('clients/../../evil', b'x\n'))
elif case == 'up':
    result = [(m, d + b'up /bin/sh\n') if m.name == 'server/server.conf' else (m, d) for m, d in result]
elif case == 'tamper':
    result = [(m, d + b'\n') if m.name == 'pki/serial' else (m, d) for m, d in result]
    keep = True
elif case == 'dupserial':
    result = [(m, d + d.splitlines(True)[-1]) if m.name == 'pki/index.txt' else (m, d) for m, d in result]
elif case == 'nocrl':
    result = [(m, d) for m, d in result if m.name != 'pki/crl.pem']
elif case == 'badcrl':
    result = [(m, b'not a crl\n') if m.name == 'pki/crl.pem' else (m, d) for m, d in result]
elif case == 'crl':
    data = open(extra, 'rb').read()
    result = [(m, data) if m.name == 'pki/crl.pem' else (m, d) for m, d in result]
if not keep:
    manifest['members'] = {m.name: {'sha256': hashlib.sha256(d).hexdigest(), 'size': len(d)} for m, d in result if m.isreg()}
with tarfile.open(out, 'w', format=tarfile.PAX_FORMAT) as tar:
    data = json.dumps(manifest).encode()
    if case != 'noschema':
        info = tarfile.TarInfo('manifest.json'); info.size = len(data); tar.addfile(info, io.BytesIO(data))
    for m, d in result:
        if m.isreg():
            m.size = len(d); tar.addfile(m, io.BytesIO(d))
        else:
            tar.addfile(m)
PY
}
backed_up_server() {
    # A server of this tool's template with a key, two clients and one backup, opened in $E/backup.tar.
    template_server
    backup_key_set
    menu '1\nbob\n0\n' >/dev/null
    menu '1\ncarol\n0\n' >/dev/null
    (cd "$E" && opened_backup "$E/backup.tar")
}

test_backup_now_makes_an_encrypted_archive_and_its_manifest() {
    # D5, C.8 and C.12.11: Backup now asks for the owner's public key once, then makes one archive of the closed
    # list, encrypted for that key, with a manifest beside it; it says where it is and that it is on this server.
    local out dir list
    template_server
    out=$(menu "8\n4\n$AGE_KEY\n0\n0\n")
    has 'it says what it holds' 'encrypted with age' "$out"
    has 'it says how to make a key' 'age-keygen -o darban-backup.key' "$out"
    has 'it makes one' 'Backup made:' "$out"
    has 'it shows the CA fingerprint' "$(ca_fp)" "$out"
    has 'and says the copy is on this server' 'This copy is on this server. To recover from a lost server you need a copy elsewhere and your private key.' "$out"
    has 'with how to restore it' 'sudo darban restore darban-pki.tar --ca-fingerprint' "$out"
    grep -q "^BACKUP_RECIPIENT=$AGE_KEY$" "$E/cfg/backup.conf"; rc_is 'the public key is kept' 0 "$?"
    grep -q -- "age -r $AGE_KEY -o " "$STUB_LOG"; rc_is 'the archive is encrypted for that key' 0 "$?"
    [[ $(backups) == 1 ]]; rc_is 'one backup is there' 0 "$?"
    dir=$E/pki-backups
    has 'the folder is readable by root only' 'folder 700' "folder $(stat -c %a "$dir")"
    has 'and so is the archive' 'archive 600' "archive $(stat -c %a "$(readlink -f "$dir/latest.tar.age")")"
    [[ $(manifest_value schema) == 1 && $(manifest_value encryption) == recipient ]]; rc_is 'the manifest has its schema and how it is locked' 0 "$?"
    [[ $(manifest_value ca_fingerprint) == "$(ca_fp | tr -d : | tr 'A-F' 'a-f')" ]]; rc_is 'and the CA fingerprint' 0 "$?"
    [[ $(manifest_value archive_sha256) == "$(sha256sum "$(readlink -f "$dir/latest.tar.age")" | cut -d' ' -f1)" ]]; rc_is 'and the checksum of the archive' 0 "$?"
    list=$(manifest_value paths)
    for path in pki/private/ca.key pki/index.txt pki/issued/alice.crt server/server.conf server/tls-crypt.key darban/config darban/domain; do
        has "it holds $path" "\"$path\"" "$list"
    done
    lacks 'never the NAT file' 'nat.nft' "$list"
    lacks 'nor the backup settings' 'backup.conf' "$list"
    (cd "$E" && opened_backup "$E/opened.tar")
    has 'the opened archive holds its manifest too' 'manifest.json' "$(tar -tf "$E/opened.tar")"
    has 'Diagnostics name the newest backup' 'Newest backup of the CA' "$(mgr status)"
}

test_backups_follow_changes_of_the_ca() {
    # D5: with a key set, a backup after each change to the CA and daily, never a copy of one that did not change,
    # the newest 14 kept. A failure never fails the change, and Diagnostics name it. Hooks get the two paths.
    local i out
    template_server
    menu '1\nbob\n0\n' >/dev/null
    [[ $(backups) == 0 ]]; rc_is 'without a key, nothing is made by itself' 0 "$?"
    has 'and Diagnostics say how to set one' 'No backup key is set' "$(mgr status)"
    backup_key_set
    menu '1\ncarol\n0\n' >/dev/null
    [[ $(backups) == 1 ]]; rc_is 'a new client makes a backup' 0 "$?"
    mgr backup-auto daily >/dev/null
    [[ $(backups) == 1 ]]; rc_is 'the daily one makes none when nothing changed' 0 "$?"
    revoke_menu carol >/dev/null
    [[ $(backups) == 2 ]]; rc_is 'a revocation makes one' 0 "$?"
    mkdir -p "$E/varlib/clients"
    for i in $(seq 1 15); do printf 'first_seen=%s\n' "$i" > "$E/varlib/clients/zz$i"; mgr backup-auto daily >/dev/null; done
    has 'the newest 14 are kept' 'kept 14' "kept $(backups): $(ls "$E/pki-backups")"
    ok_if 'and the latest is one of them' test -e "$(readlink -f "$E/pki-backups/latest.tar.age")"
    out=$(FAIL_AGE=1 menu '1\ndave\n0\n')
    has 'a failed backup is said' 'The automatic backup of the CA failed' "$out"
    ok_if 'and the client is still made' test -s "$E/clients/dave.ovpn"
    has 'Diagnostics then warn' 'The last automatic backup failed' "$(mgr status)"
    mkdir -m 700 "$E/cfg/backup-hooks"
    printf '#!/bin/sh\necho "$1 $2" > %s\n' "$E/hook-ran" > "$E/cfg/backup-hooks/deliver"; chmod 700 "$E/cfg/backup-hooks/deliver"
    printf '#!/bin/sh\ntouch %s\n' "$E/loose-ran" > "$E/cfg/backup-hooks/loose"; chmod 755 "$E/cfg/backup-hooks/loose"
    printf '#!/bin/sh\nexit 3\n' > "$E/cfg/backup-hooks/broken"; chmod 700 "$E/cfg/backup-hooks/broken"
    menu '1\nerin\n0\n' >/dev/null
    for i in $(seq 1 20); do [[ -s $E/hook-ran ]] && break; sleep 0.25; done
    has 'a hook gets the archive and its manifest' "$(readlink -f "$E/pki-backups/latest.tar.age") $(readlink -f "$E/pki-backups/latest.manifest.json")" "$(cat "$E/hook-ran" 2>/dev/null)"
    ok_if 'a hook others could change does not run' test ! -e "$E/loose-ran"
    for i in $(seq 1 20); do [[ -s $E/pki-backups/.hooks-failed ]] && break; sleep 0.25; done
    has 'a hook that fails is named in Diagnostics' 'A backup hook failed: broken' "$(mgr status)"
}

test_restore_puts_the_ca_back() {
    # D5, C.8, C.12.10, C.13.6 and C.16.5: a restore puts the CA, the clients and the server files of the backup back,
    # with server.conf written again from the template. OpenVPN is off from the first rename to the end. What it
    # replaced is kept for 30 days, and the restored CA issues clients again. C.16.1: once a client was issued after
    # the backup, the backup is older than the CA in use, and it is refused without any change.
    local out fp before until
    backed_up_server
    fp=$(ca_fp)
    before=$(cat "$PKI/index.txt")
    echo 'custom 1' >> "$SERVER_CONF"
    : > "$STUB_LOG"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'the restore succeeds' 0 "$?"
    has 'it says what it restores' 'Clients' "$out"
    has 'and that OpenVPN stays off' 'OpenVPN stays off from the first change until the end' "$out"
    has 'it is done' 'Restored the backup of' "$out"
    until=$(date -u -d '+30 days' +%Y-%m-%d)
    has 'it says until when what it replaced is kept' "until $until, then deleted" "$out"
    [[ $(cat "$PKI/index.txt") == "$before" ]]; rc_is 'the CA index is the one of the backup' 0 "$?"
    lacks 'server.conf comes from the template' 'custom 1' "$(cat "$SERVER_CONF")"
    has 'with the routing of the backup' 'push "redirect-gateway def1 bypass-dhcp"' "$(cat "$SERVER_CONF")"
    ok_if 'no journal is left' test ! -e "$E/varlib/restore.journal"
    ok_if 'what it replaced is kept' test -n "$(find "$E/pki-backups" -maxdepth 2 -path '*pre-restore-*/pki' -type d)"
    ok_if 'with the time it is kept from' test -s "$(find "$E/pki-backups" -maxdepth 2 -path '*pre-restore-*/.restored' | head -n1)"
    [[ $(grep -n 'systemctl disable --now openvpn-server@server.service' "$STUB_LOG" | cut -d: -f1 | head -n1) -lt $(grep -n 'systemctl start openvpn-server@server.service' "$STUB_LOG" | cut -d: -f1 | tail -n1) ]]
    rc_is 'OpenVPN is turned off first and on at the end' 0 "$?"
    [[ $(grep -n 'systemctl start openvpn-server@server.service' "$STUB_LOG" | cut -d: -f1 | tail -n1) -lt $(grep -n 'systemctl enable openvpn-server@server.service' "$STUB_LOG" | cut -d: -f1 | tail -n1) ]]
    rc_is 'and enabled at boot only after the commit' 0 "$?"
    ok_if 'it runs, and is enabled at boot' unit_on
    out=$(bash "$E/manager.sh" restore "$E/backup.tar" 2>&1 </dev/null); rc_is 'without an anchor it refuses' 2 "$?"
    has 'and says what to give' '--ca-fingerprint' "$out"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-from "$E/clients/bob.ovpn" 2>&1); rc_is 'a profile from a device is an anchor too' 0 "$?"
    menu '1\nfrank\n0\n' >/dev/null
    ok_if 'the restored CA issues a client' test -s "$E/clients/frank.ovpn"
    maintain --check >/dev/null; rc_is 'and its CRL passes its checks' 0 "$?"
    before=$(cat "$PKI/index.txt" "$SERVER_CONF" "$CRL")
    : > "$STUB_LOG"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'a backup older than the CA in use is refused' 1 "$?"
    has 'it says so' 'this backup is older than the CA in use here' "$out"
    has 'and names the client issued since, with its serial' 'frank (serial ' "$out"
    has 'and what to do' 'Use a newer backup, or keep the CA in use.' "$out"
    has 'and that nothing changed' 'Nothing on this server was changed.' "$out"
    [[ $(cat "$PKI/index.txt" "$SERVER_CONF" "$CRL") == "$before" && ! -e $E/varlib/restore.journal ]]; rc_is 'and nothing did' 0 "$?"
    lacks 'OpenVPN was not touched' 'systemctl disable' "$(cat "$STUB_LOG")"
}

test_a_restore_refuses_before_changing_anything() {
    # T51, T64, C.13.6, C.14.5, C.15.10 and C.16.4: an archive with any member outside the closed list, a link, a
    # member twice, one too large, a path out of place, a server.conf with another directive, a member that does not
    # match its checksum, no manifest and so no schema, or another CA, is refused before anything changes.
    local fp kind out snapshot
    backed_up_server
    fp=$(ca_fp)
    snapshot=$(cat "$PKI/index.txt" "$SERVER_CONF")
    for kind in extra:'not one a backup holds' symlink:'not a regular file' hardlink:'not a regular file' duplicate:'appears twice' \
        big:'larger than' absolute:'not allowed' dotdot:'not allowed' up:'line 25, up' tamper:'does not match its checksum' \
        noschema:'has no manifest.json' dupserial:'names a certificate twice'; do
        craft "$E/backup.tar" "$E/bad.tar" "${kind%%:*}"
        : > "$STUB_LOG"
        out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/bad.tar" --ca-fingerprint "$fp" 2>&1); rc_is "${kind%%:*}: refused" 1 "$?"
        has "${kind%%:*}: with why" "${kind#*:}" "$out"
        has "${kind%%:*}: and that nothing changed" 'Nothing on this server was changed.' "$out"
        [[ $(cat "$PKI/index.txt" "$SERVER_CONF") == "$snapshot" && ! -e $E/varlib/restore.journal ]]; rc_is "${kind%%:*}: nothing changed" 0 "$?"
        lacks "${kind%%:*}: OpenVPN was not touched" 'systemctl disable' "$(cat "$STUB_LOG")"
        ok_if "${kind%%:*}: nothing reached /etc" test ! -e /etc/cron.d/evil
    done
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$(printf '%064d' 0)" 2>&1); rc_is 'another CA: refused' 1 "$?"
    has 'it says so' 'not the CA you named' "$out"
}

test_a_restore_never_brings_back_a_revoked_client() {
    # I13, T22, T33, C.8, C.16.1 and C.16.2: a client this server revoked after the backup is never valid again. The
    # CA index names it, and the CRL of the same CA when the index cannot be read. Only when neither can tell, the
    # restore says what cannot be known, asks for the server name, and Diagnostics warn until the owner acknowledges.
    local fp out host snapshot
    backed_up_server
    fp=$(ca_fp)
    revoke_menu bob >/dev/null
    snapshot=$(cat "$PKI/index.txt" "$CRL" "$SERVER_CONF")
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'refused' 1 "$?"
    has 'as a backup older than the CA in use' 'this backup is older than the CA in use here' "$out"
    has 'it names the client revoked since, with its serial' 'bob (serial ' "$out"
    [[ $(cat "$PKI/index.txt" "$CRL" "$SERVER_CONF") == "$snapshot" && ! -e $E/varlib/restore.journal ]]; rc_is 'and nothing changed' 0 "$?"
    cp "$CRL" "$E/crl.saved"
    rm -f "$CRL"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'without a CRL the index still tells' 1 "$?"
    has 'and names it' 'bob (serial ' "$out"
    cp "$E/crl.saved" "$CRL"
    tail -n 1 "$PKI/index.txt" >> "$PKI/index.txt"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'an index with a serial twice: the CRL still tells' 1 "$?"
    has 'and names it' 'bob (serial ' "$out"
    lacks 'without asking for the server name' 'cannot be known' "$out"
    printf 'not a record\n' >> "$PKI/index.txt"
    rm -f "$CRL"
    host=$(hostname -s | tr -cd 'A-Za-z0-9.-'); host=${host:-server}
    out=$(printf 'wrong\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1)
    has 'with neither, it cannot know' 'Revocations and certificates issued after' "$out"
    has 'and says why' 'its index cannot be read' "$out"
    ok_if 'a wrong name restores nothing' test ! -e "$E/varlib/restore-unverified"
    out=$(printf '%s\n' "$host" | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'the server name restores it' 0 "$?"
    ok_if 'and leaves the warning' test -s "$E/varlib/restore-unverified"
    has 'Diagnostics warn' 'revocations and certificates issued after it cannot be known' "$(mgr status)"
    has 'until it is acknowledged' 'Acknowledged.' "$(restore_run --acknowledge)"
    lacks 'then they do not' 'revocations and certificates issued after it cannot be known' "$(mgr status)"
}

test_a_restore_rejects_bad_crl_signatures() {
    # A parseable but unsigned CRL must neither be repaired silently inside the archive, nor count as evidence
    # of this server's revocations. Exercise both paths on OpenSSL 3.0 as well as newer versions in CI. C.16.2: with
    # a readable index of the same CA, a bad live CRL needs no unknowable path, and a revocation since is still refused.
    local fp out before
    backed_up_server
    fp=$(ca_fp)
    before=$(sha256sum "$CRL" "$PKI/index.txt" "$SERVER_CONF")
    openssl crl -in "$CRL" -badsig -out "$E/bad-signature.pem"
    craft "$E/backup.tar" "$E/bad-crl.tar" crl "$E/bad-signature.pem"
    : > "$STUB_LOG"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/bad-crl.tar" --ca-fingerprint "$fp" 2>&1)
    rc_is 'an archive with a bad CRL signature is refused' 1 "$?"
    has 'the archive signature failure is named' 'the CRL in the backup is not signed by its CA' "$out"
    [[ $(sha256sum "$CRL" "$PKI/index.txt" "$SERVER_CONF") == "$before" ]]; rc_is 'the live files stay unchanged' 0 "$?"
    ok_if 'no restore journal is created' test ! -e "$E/varlib/restore.journal"
    lacks 'OpenVPN is not touched' 'systemctl disable' "$(cat "$STUB_LOG")"
    cp "$E/bad-signature.pem" "$CRL"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1)
    rc_is 'a bad live CRL with a readable index restores on the usual question' 0 "$?"
    lacks 'the index tells what happened since' 'cannot be known' "$out"
    has 'the restore finishes' 'Restored the backup of' "$out"
    ok_if 'and leaves no warning' test ! -e "$E/varlib/restore-unverified"
    revoke_menu bob >/dev/null
    openssl crl -in "$CRL" -badsig -out "$E/bad-again.pem"
    cp "$E/bad-again.pem" "$CRL"
    before=$(sha256sum "$CRL" "$PKI/index.txt" "$SERVER_CONF")
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1)
    rc_is 'a revocation since is refused, though the live CRL is bad' 1 "$?"
    has 'and named' 'bob (serial ' "$out"
    [[ $(sha256sum "$CRL" "$PKI/index.txt" "$SERVER_CONF") == "$before" ]]; rc_is 'with nothing changed' 0 "$?"
}

test_a_restore_that_stops_finishes_or_goes_back() {
    # T65, C.12.10, C.13.7, C.15.8 and C.16.9: a restore stopped after any rename leaves OpenVPN off; Diagnostics say
    # so, the CRL timer leaves the CRL alone, and the next run of this tool finishes it. Before the commit, --rollback
    # puts back what was there, the settings and client records it added included. After the commit it is not
    # undone; a cleanup that stopped is finished, each step once, and keeps what the restore replaced whole.
    local fp step out id kept
    backed_up_server
    fp=$(ca_fp)
    # A client record only the backup has: the restore adds it, and a rollback takes it away again.
    mkdir -p "$E/varlib/clients"; printf 'first_seen=5\n' > "$E/varlib/clients/carol"
    mgr backup-auto test >/dev/null
    (cd "$E" && opened_backup "$E/backup.tar")
    rm -f "$E/varlib/clients/carol"
    for step in 1 2 3 4; do
        : > "$PKI/old-pki"; : > "$E/server/old-server"
        : > "$STUB_LOG"
        printf '2\n' | DARBAN_TEST_RESTORE_STOP=$step bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1; rc_is "stopped after rename $step" 99 "$?"
        ok_if "after rename $step a journal is left" test -s "$E/varlib/restore.journal"
        lacks "after rename $step OpenVPN is not started" 'systemctl start openvpn' "$(cat "$STUB_LOG")"
        has "after rename $step Diagnostics say so" 'A restore is unfinished' "$(mgr status)"
        out=$(maintain --check 2>&1); rc_is "after rename $step the CRL timer leaves it alone" 1 "$?"
        mgr list >/dev/null
        ok_if "after rename $step the next run finishes it" test ! -e "$E/varlib/restore.journal"
        ok_if "after rename $step the backup is in place" test ! -e "$PKI/old-pki" -a ! -e "$E/server/old-server"
        ok_if "after rename $step OpenVPN is on again, and enabled at boot" unit_on
    done
    # A step before the commit fails: everything the restore did is undone, and checked.
    rm -f "$E/varlib/clients/carol" "$E/cfg/domain"
    : > "$PKI/old-pki"; : > "$E/server/old-server"
    out=$(printf '2\n' | DARBAN_TEST_RESTORE_FAIL=commit bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'a restore that fails before the commit' 1 "$?"
    has 'is undone' 'The restore was undone' "$out"
    ok_if 'the CA and the server files are as they were' test -e "$PKI/old-pki" -a -e "$E/server/old-server"
    ok_if 'a client record it added is taken away again' test ! -e "$E/varlib/clients/carol"
    ok_if 'and a setting that was not there before' test ! -e "$E/cfg/domain"
    ok_if 'and no journal is left' test ! -e "$E/varlib/restore.journal"
    echo vpn.example.com > "$E/cfg/domain"
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=3 bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    has 'a stopped restore can be undone' 'The restore was undone' "$(restore_run --rollback)"
    ok_if 'and the CA is as it was' test -e "$PKI/old-pki" -a -e "$E/server/old-server" -a ! -e "$E/varlib/restore.journal"
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=1 bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    id=$(sed -n 's/^id=//p' "$E/varlib/restore.journal")
    rm -rf "$PKI.restore-$id"
    : > "$STUB_LOG"
    out=$(restore_run --resume); rc_is 'a state no step explains stops' 1 "$?"
    has 'and says what to look at' 'cannot go on' "$out"
    lacks 'with OpenVPN still off' 'systemctl enable' "$(cat "$STUB_LOG")"
    has 'it can still be undone' 'The restore was undone' "$(restore_run --rollback)"
    ok_if 'back to what was there' test -e "$PKI/old-pki" -a -e "$E/server/old-server"
    # The cleanup after the commit fails, twice: the restore is done and stays done.
    : > "$STUB_LOG"
    out=$(printf '2\n' | DARBAN_TEST_RESTORE_FAIL=keep-server bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'a cleanup that fails after the commit' 1 "$?"
    has 'says the restore is done and the cleanup is not' 'but the cleanup is unfinished' "$out"
    ok_if 'and OpenVPN runs, enabled at boot' unit_on
    has 'Diagnostics say only the cleanup is left' 'its cleanup is unfinished' "$(mgr status)"
    out=$(restore_run --rollback); rc_is 'after the commit it is not undone' 1 "$?"
    has 'and says so' 'so it is not undone' "$out"
    ok_if 'the restored CA stays' test ! -e "$PKI/old-pki"
    out=$(DARBAN_TEST_RESTORE_FAIL=keep-server restore_run --resume); rc_is 'a cleanup that fails again' 1 "$?"
    out=$(restore_run --resume); rc_is 'then finishes' 0 "$?"
    has 'and says so' 'The restore is finished.' "$out"
    kept=$(find "$E/pki-backups" -path '*pre-restore-*/server/old-server' | head -n1)
    ok_if 'what it replaced is kept whole' test -n "$kept" -a -e "${kept%/server/old-server}/pki/old-pki" -a -s "${kept%/server/old-server}/.restored"
    ok_if 'and nothing is left beside the live folders' test ! -e "$PKI.pre-restore" -a ! -e "$E/server.pre-restore" -a ! -e "$E/varlib/restore.journal"
}

test_a_restore_with_a_crl_missing_unreadable_or_expired() {
    # T14, C.8 bullet 5, C.14.4 and C.15.2: each is said apart, and a new CRL of the restored CA is in place before
    # OpenVPN starts.
    local fp kind out
    backed_up_server
    fp=$(ca_fp)
    # A CRL of this CA that has just expired, from a config of its own: the real Easy-RSA keeps no openssl.cnf.
    printf '[ca]\ndefault_ca = d\n[d]\ndatabase = %s/index.txt\ncertificate = %s/ca.crt\nprivate_key = %s/private/ca.key\ndefault_md = sha256\n' \
        "$PKI" "$PKI" "$PKI" > "$E/short-crl.cnf"
    openssl ca -batch -config "$E/short-crl.cnf" -gencrl -crlsec 1 -out "$E/short-crl.pem" 2>/dev/null
    ok_if 'an expired CRL of this CA is made for the test' test -s "$E/short-crl.pem"
    sleep 2
    for kind in nocrl:'The backup has no CRL' badcrl:'cannot be read' crl:'has expired'; do
        craft "$E/backup.tar" "$E/crl.tar" "${kind%%:*}" "$E/short-crl.pem"
        out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/crl.tar" --ca-fingerprint "$fp" 2>&1); rc_is "${kind%%:*}: restored" 0 "$?"
        has "${kind%%:*}: said apart" "${kind#*:}" "$out"
        maintain --check >/dev/null; rc_is "${kind%%:*}: a new CRL is in place" 0 "$?"
        [[ $(stat -c %a "$CRL") == 644 ]]; rc_is "${kind%%:*}: readable by OpenVPN" 0 "$?"
    done
}

test_a_restore_checks_again_under_the_lock() {
    # C.16.1 and C.16.9: what was checked before the question is checked again under the CA lock. A client revoked in
    # another session while the question is open refuses the restore; a restore that waited while another one
    # stopped half way is refused. Neither changes anything.
    local fp out snapshot i
    backed_up_server
    fp=$(ca_fp)
    mkfifo "$E/answer"
    ( bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" <"$E/answer" >"$E/race.out" 2>&1; echo "$?" > "$E/race.rc" ) &
    exec 7>"$E/answer"
    for i in $(seq 1 100); do grep -q 'Restore the backup of' "$E/race.out" 2>/dev/null && break; sleep 0.1; done
    revoke_menu bob >/dev/null
    snapshot=$(cat "$PKI/index.txt" "$SERVER_CONF")
    printf '2\n' >&7; exec 7>&-
    wait
    rc_is 'a revocation while the question was open refuses it' 1 "$(cat "$E/race.rc")"
    has 'it says what changed' 'this server changed while the question was open' "$(cat "$E/race.out")"
    has 'and names it' 'bob (serial ' "$(cat "$E/race.out")"
    [[ $(cat "$PKI/index.txt" "$SERVER_CONF") == "$snapshot" && ! -e $E/varlib/restore.journal ]]; rc_is 'and nothing changed' 0 "$?"
    # The newest backup knows that revocation. One restore waits at its question while another stops half way.
    (cd "$E" && opened_backup "$E/backup2.tar")
    rm -f "$E/answer" "$E/race.rc"; mkfifo "$E/answer"
    ( bash "$E/manager.sh" restore "$E/backup2.tar" --ca-fingerprint "$fp" <"$E/answer" >"$E/race2.out" 2>&1; echo "$?" > "$E/race.rc" ) &
    exec 7>"$E/answer"
    for i in $(seq 1 100); do grep -q 'Restore the backup of' "$E/race2.out" 2>/dev/null && break; sleep 0.1; done
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=2 bash "$E/manager.sh" restore "$E/backup2.tar" --ca-fingerprint "$fp" >/dev/null 2>&1; rc_is 'the other restore stops half way' 99 "$?"
    printf '2\n' >&7; exec 7>&-
    wait
    rc_is 'the one that waited is refused' 1 "$(cat "$E/race.rc")"
    has 'it says why' 'A restore is unfinished' "$(cat "$E/race2.out")"
    has 'and that it changed nothing' 'Nothing on this server was changed.' "$(cat "$E/race2.out")"
    has 'the first one is the one finished' 'The restore is finished.' "$(restore_run --resume)"
}

test_a_restore_moves_no_folder_while_openvpn_runs() {
    # C.16.9: OpenVPN off now and at boot is proven before the first rename. When it does not stop, nothing is moved,
    # and what was prepared is taken away.
    local fp out snapshot
    backed_up_server
    fp=$(ca_fp)
    snapshot=$(cat "$PKI/index.txt" "$SERVER_CONF" "$CRL")
    out=$(printf '2\n' | FAKE_STOP_FAILS=1 bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'refused' 1 "$?"
    has 'it says OpenVPN did not stop' 'OpenVPN did not stop' "$out"
    has 'and that no folder was moved' 'No folder was moved' "$out"
    [[ $(cat "$PKI/index.txt" "$SERVER_CONF" "$CRL") == "$snapshot" ]]; rc_is 'nothing changed' 0 "$?"
    ok_if 'no journal and nothing prepared is left' test ! -e "$E/varlib/restore.journal" -a -z "$(compgen -G "$PKI.restore-*")" -a -z "$(compgen -G "$E/server.restore-*")"
    ok_if 'nothing was set aside' test ! -e "$PKI.pre-restore" -a ! -e "$E/server.pre-restore"
}

test_a_job_that_waited_for_a_killed_restore_changes_nothing() {
    # C.16.9: the CRL job and the daily backup check the journal once they hold the CA lock, so one that waited while
    # a restore was killed changes nothing.
    local fp out before count
    backed_up_server
    fp=$(ca_fp)
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=2 bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    # As if the restore had not begun when the job started: its journal appears while the job waits for the lock.
    mv "$E/varlib/restore.journal" "$E/journal.saved"
    before=$(sha256sum "$CRL" "$PKI/crl.pem" 2>/dev/null)
    out=$(FLOCK_HOOK="cp '$E/journal.saved' '$E/varlib/restore.journal'" maintain --renew); rc_is 'the CRL job that waited is refused' 1 "$?"
    has 'it says why' 'A restore is unfinished, so nothing is changed' "$out"
    [[ $(sha256sum "$CRL" "$PKI/crl.pem" 2>/dev/null) == "$before" ]]; rc_is 'and the CRL is untouched' 0 "$?"
    rm -f "$E/varlib/restore.journal"
    count=$(backups)
    # Something changed, so the daily backup would make one.
    mkdir -p "$E/varlib/clients"; printf 'first_seen=9\n' > "$E/varlib/clients/zz-new"
    out=$(FLOCK_HOOK="cp '$E/journal.saved' '$E/varlib/restore.journal'" mgr backup-auto daily)
    [[ $(backups) == "$count" ]]; rc_is 'the daily backup that waited makes none' 0 "$?"
    mv "$E/journal.saved" "$E/varlib/restore.journal"
    has 'the restore is then finished' 'The restore is finished.' "$(restore_run --resume)"
}

test_a_backup_hook_that_ignores_its_time_is_killed() {
    # R18-10: a hook that ignores the end of its time is killed soon after, and named as failed.
    local start took
    template_server
    backup_key_set
    sed -i 's/^BACKUP_HOOK_SECONDS=.*/BACKUP_HOOK_SECONDS=1/' "$E/manager.sh"
    mkdir -m 700 "$E/cfg/backup-hooks"
    printf '#!/bin/bash\ntrap "" TERM\nsleep 60\n' > "$E/cfg/backup-hooks/stubborn"; chmod 700 "$E/cfg/backup-hooks/stubborn"
    start=$(date +%s)
    mgr backup-auto daily >/dev/null
    took=$(( $(date +%s) - start ))
    (( took < 40 )); rc_is "the hook is killed soon after its time (took ${took}s)" 0 "$?"
    has 'and named as failed' 'A backup hook failed: stubborn' "$(mgr status)"
}

test_a_restore_says_when_nat_did_not_come_back() {
    # R18-12: a restore whose NAT rules did not load says so, and does not end as if all were well.
    local fp out
    backed_up_server
    fp=$(ca_fp)
    printf 'table ip darban {\n    chain postrouting {\n        ip saddr 10.8.0.0/24 oifname "eth0" masquerade\n    }\n    chain forward {\n        ip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop\n    }\n}\n' > "$E/cfg/nat.nft"
    printf '#!/usr/bin/env bash\necho "nft $*" >> "$STUB_LOG"\nif [[ $1 == -f ]]; then exit 1; fi\n' > "$E/bin/nft"; chmod +x "$E/bin/nft"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'it ends with a failure' 1 "$?"
    has 'the CA is restored' 'Restored the backup of' "$out"
    has 'and it says NAT is not loaded' 'The NAT rules are not loaded' "$out"
    ok_if 'the restore itself is finished' test ! -e "$E/varlib/restore.journal"
}

test_what_a_restore_replaced_is_deleted_after_30_days() {
    # C.16.5: kept 30 days after its restore, with a warning in Diagnostics from 7 days before. Never deleted while a
    # restore is unfinished, without a readable time, with a time in the future, or with a link in it.
    local fp dir now
    backed_up_server
    fp=$(ca_fp)
    printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    dir=$(find "$E/pki-backups" -maxdepth 1 -name 'pre-restore-*' -type d | head -n1)
    ok_if 'what it replaced is kept' test -d "$dir/pki"
    has 'Diagnostics say when it goes' 'it is deleted in 30 days' "$(mgr status)"
    mgr sweep >/dev/null
    ok_if 'a sweep keeps it within its time' test -d "$dir"
    now=$(date -u +%s)
    echo $(( now - 25 * 86400 )) > "$dir/.restored"
    has 'Diagnostics warn 7 days before' 'is deleted in 5 day(s)' "$(mgr status)"
    echo $(( now + 86400 )) > "$dir/.restored"
    mgr sweep >/dev/null
    ok_if 'a time in the future keeps it' test -d "$dir"
    has 'and Diagnostics say why' 'a restore time in the future' "$(mgr status)"
    echo $(( now - 31 * 86400 )) > "$dir/.restored"
    ln -s /etc "$dir/pki/link"
    mgr sweep >/dev/null
    ok_if 'a link in it keeps it' test -d "$dir"
    rm -f "$dir/pki/link"
    rm -f "$dir/.restored"
    mgr sweep >/dev/null
    ok_if 'no time keeps it' test -d "$dir"
    has 'and Diagnostics say why' 'did not finish its cleanup' "$(mgr status)"
    echo $(( now - 31 * 86400 )) > "$dir/.restored"
    printf 'id=x\n' > "$E/varlib/restore.journal"
    mgr sweep >/dev/null
    ok_if 'an unfinished restore keeps it' test -d "$dir"
    rm -f "$E/varlib/restore.journal"
    mgr sweep >/dev/null
    ok_if 'after 30 days it is deleted' test ! -e "$dir"
}

real_flock() { mkdir -p "$E/realflock"; ln -sf /usr/bin/flock "$E/realflock/flock"; }
wait_for() { local i; for i in $(seq 1 150); do if eval "$1"; then return 0; fi; sleep 0.1; done; return 1; }
paused_restore() {
    # paused_restore <step> <out> [VAR=value]...: a restore, with the real lock, that waits at <step> holding what it
    # holds until $E/paused is deleted. Its status lands in <out>.rc.
    local step=$1 out=$2 fp
    shift 2
    fp=$(ca_fp)
    rm -f "$E/paused"
    ( printf '2\n' | env PATH="$E/realflock:$PATH" DARBAN_TEST_RESTORE_WAIT="$step" DARBAN_TEST_RESTORE_WAIT_FILE="$E/paused" "$@" \
        bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >"$out" 2>&1; echo "$?" >"$out.rc" ) &
    wait_for '[[ -e $E/paused ]]'
}

test_a_resume_or_rollback_that_waited_decides_under_the_lock() {
    # R24-A01 and C.16.9, with the real lock: --resume and --rollback decide from the journal they read once they hold
    # the CA lock. One that waited while another restore finished changes nothing and says so; a rollback that waited
    # never undoes a restore that was committed meanwhile.
    local kind
    backed_up_server
    real_flock
    for kind in --resume --rollback; do
        paused_restore swapped "$E/first.out"; rc_is "$kind: the first restore holds the lock half way" 0 "$?"
        ( env PATH="$E/realflock:$PATH" bash "$E/manager.sh" restore "$kind" >"$E/second.out" 2>&1; echo "$?" >"$E/second.out.rc" ) &
        wait_for 'grep -q "waiting up to" "$E/second.out" 2>/dev/null'; rc_is "$kind: the second one waits for the lock" 0 "$?"
        rm -f "$E/paused"
        wait
        rc_is "$kind: the first restore finishes" 0 "$(cat "$E/first.out.rc")"
        has "$kind: the one that waited says what happened meanwhile" 'while this waited' "$(cat "$E/second.out")"
        lacks "$kind: and undoes nothing" 'The restore was undone' "$(cat "$E/second.out")"
        ok_if "$kind: OpenVPN runs, enabled at boot" unit_on
        ok_if "$kind: no journal is left" test ! -e "$E/varlib/restore.journal"
    done
    # The first restore is committed, and then its cleanup fails.
    : > "$PKI/old-pki"
    paused_restore swapped "$E/first.out" DARBAN_TEST_RESTORE_FAIL=keep-pki
    ( env PATH="$E/realflock:$PATH" bash "$E/manager.sh" restore --rollback >"$E/second.out" 2>&1; echo "$?" >"$E/second.out.rc" ) &
    wait_for 'grep -q "waiting up to" "$E/second.out" 2>/dev/null'
    rm -f "$E/paused"
    wait
    rc_is 'the first restore is committed, with its cleanup unfinished' 1 "$(cat "$E/first.out.rc")"
    rc_is 'a rollback that waited is refused' 1 "$(cat "$E/second.out.rc")"
    has 'and says why' 'so it is not undone' "$(cat "$E/second.out")"
    ok_if 'the restored CA stays' test ! -e "$PKI/old-pki"
    ok_if 'and OpenVPN runs' unit_running
    has 'the cleanup is then finished' 'The restore is finished.' "$(restore_run --resume)"
}

test_a_restore_stopped_once_openvpn_started_is_off_after_a_reboot() {
    # R24-A03, C.15.8 and C.16.9: before the commit, OpenVPN is started but not enabled at boot, so a crash there
    # leaves it off after a reboot, and Diagnostics say it may be running. The journal never goes back a state; the
    # restore can be finished, twice from the same point, or undone.
    local fp out
    backed_up_server
    fp=$(ca_fp)
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=after:started bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    rc_is 'stopped once OpenVPN was started' 99 "$?"
    ok_if 'OpenVPN is not enabled at boot' test -e "$E/unit-state/openvpn-server@server.service.disabled"
    has 'Diagnostics say it may be running' 'OpenVPN may be running with the restored files' "$(mgr status)"
    out=$(DARBAN_TEST_RESTORE_STOP=after:started restore_run --resume); rc_is 'a resume stopped at the same point' 99 "$?"
    grep -qx 'state=starting' "$E/varlib/restore.journal"; rc_is 'the journal stays at starting, never an earlier state' 0 "$?"
    out=$(restore_run --resume); rc_is 'the next resume finishes it' 0 "$?"
    has 'and says so' 'The restore is finished.' "$out"
    ok_if 'OpenVPN runs, enabled at boot' unit_on
    : > "$PKI/old-pki"
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=after:started bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    has 'from the same point it can be undone' 'The restore was undone' "$(restore_run --rollback)"
    ok_if 'the CA is as it was' test -e "$PKI/old-pki"
    ok_if 'and OpenVPN runs, enabled at boot' unit_on
}

test_a_rollback_says_undone_only_once_it_is() {
    # R24-A02 and C.16.9: a rollback that cannot put OpenVPN or the NAT rules back says what is left, keeps the
    # journal, and no resume finishes the restore forward from there; the next rollback finishes it.
    local fp out
    backed_up_server
    fp=$(ca_fp)
    : > "$PKI/old-pki"
    out=$(printf '2\n' | DARBAN_TEST_RESTORE_FAIL=commit FAKE_START_FAILS=1 bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1)
    rc_is 'a restore whose rollback cannot start OpenVPN' 1 "$?"
    lacks 'is not called undone' 'The restore was undone' "$out"
    lacks 'nor said to be undone before it is' 'It is undone now' "$out"
    has 'it names what was not put back' 'OpenVPN as it was' "$out"
    ok_if 'the CA is back' test -e "$PKI/old-pki"
    ok_if 'the journal stays' test -s "$E/varlib/restore.journal"
    has 'Diagnostics say a rollback is unfinished' 'A rollback of a restore is unfinished' "$(mgr status)"
    out=$(restore_run --resume); rc_is 'a resume does not finish it forward' 1 "$?"
    has 'and says why' 'not finished forward' "$out"
    ok_if 'so the CA stays as it was' test -e "$PKI/old-pki"
    out=$(restore_run --rollback); rc_is 'the next rollback finishes' 0 "$?"
    has 'and says so' 'The restore was undone' "$out"
    ok_if 'OpenVPN runs, enabled at boot' unit_on
    ok_if 'and no journal is left' test ! -e "$E/varlib/restore.journal"
    # NAT rules that do not load again.
    printf 'table ip darban {\n    chain postrouting {\n        ip saddr 10.8.0.0/24 oifname "eth0" masquerade\n    }\n    chain forward {\n        ip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop\n    }\n}\n' > "$E/cfg/nat.nft"
    printf '#!/usr/bin/env bash\necho "nft $*" >> "$STUB_LOG"\nif [[ $1 == -f ]]; then exit 1; fi\n' > "$E/bin/nft"; chmod +x "$E/bin/nft"
    out=$(printf '2\n' | DARBAN_TEST_RESTORE_FAIL=commit bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1)
    has 'NAT rules that do not load again are named' 'the NAT rules' "$out"
    lacks 'and the rollback is not called done' 'The restore was undone' "$out"
    ok_if 'the journal stays' test -s "$E/varlib/restore.journal"
    printf '#!/usr/bin/env bash\necho "nft $*" >> "$STUB_LOG"\n' > "$E/bin/nft"
    has 'once NAT loads, the rollback finishes' 'The restore was undone' "$(restore_run --rollback)"
}

test_a_restore_that_cannot_put_a_client_record_back_is_undone() {
    # R24-A04 and C.16.8: a client record only the backup has comes back, or the restore is not done.
    local fp out before
    backed_up_server
    fp=$(ca_fp)
    mkdir -p "$E/varlib/clients"; printf 'first_seen=5\n' > "$E/varlib/clients/carol"
    mgr backup-auto test >/dev/null
    (cd "$E" && opened_backup "$E/backup.tar")
    rm -rf "$E/varlib/clients"; : > "$E/varlib/clients"
    : > "$PKI/old-pki"
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'refused' 1 "$?"
    has 'it says which record' 'the record of when carol was seen could not be put back' "$out"
    has 'and the restore is undone' 'The restore was undone' "$out"
    ok_if 'the CA is as it was' test -e "$PKI/old-pki"
    ok_if 'and OpenVPN runs, enabled at boot' unit_on
    rm -f "$E/varlib/clients"
}

test_a_restore_stopped_after_its_commit_finishes_each_step_once() {
    # R24-A-gap-1, R21-01 and C.16.9: a restore stopped after each step of its cleanup is finished by the next resume,
    # and a second finds nothing; what it replaced is kept whole, the config it replaced too, and OpenVPN runs.
    local fp point id dest
    backed_up_server
    fp=$(ca_fp)
    for point in committed enabled kept-pki kept-server kept-config kept-domain restored cleaned; do
        printf '# before %s\n' "$point" >> "$E/cfg/config"
        printf '2\n' | DARBAN_TEST_RESTORE_STOP=after:$point bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
        rc_is "$point: stopped there" 99 "$?"
        id=$(sed -n 's/^id=//p' "$E/varlib/restore.journal")
        has "$point: Diagnostics say only the cleanup is left" 'its cleanup is unfinished' "$(mgr status)"
        has "$point: the next resume finishes it" 'The restore is finished.' "$(restore_run --resume)"
        has "$point: a second finds nothing to do" 'No restore is unfinished.' "$(restore_run --resume)"
        dest=$E/pki-backups/pre-restore-$id
        ok_if "$point: what it replaced is kept whole" test -s "$dest/pki/index.txt" -a -s "$dest/server/server.conf" -a -s "$dest/.restored"
        grep -qx "# before $point" "$dest/darban/config"; rc_is "$point: the config it replaced is kept as it was" 0 "$?"
        lacks "$point: and the restored one is in place" "# before $point" "$(cat "$E/cfg/config")"
        ok_if "$point: OpenVPN runs, enabled at boot" unit_on
        ok_if "$point: nothing is left beside the live folders" test ! -e "$PKI.pre-restore" -a ! -e "$E/server.pre-restore"
    done
}

test_a_job_that_waited_on_the_real_lock_finds_the_journal() {
    # R24-A-gap-2 and C.16.9, with the real lock: the CRL job and the daily backup start before a restore makes its
    # journal, wait for the lock, and once the restore stops half way, as a crash would, change nothing.
    local fp count before
    backed_up_server
    fp=$(ca_fp)
    real_flock
    before=$(sha256sum "$CRL")
    paused_restore locked "$E/first.out" DARBAN_TEST_RESTORE_STOP=2
    ( env PATH="$E/realflock:$PATH" bash "$E/crl-maintain" --renew >"$E/job.out" 2>&1; echo "$?" >"$E/job.out.rc" ) &
    wait_for 'grep -q "waiting up to" "$E/job.out" 2>/dev/null'; rc_is 'the CRL job waits for the lock' 0 "$?"
    rm -f "$E/paused"
    wait
    rc_is 'the restore stops half way' 99 "$(cat "$E/first.out.rc")"
    rc_is 'the CRL job is refused' 1 "$(cat "$E/job.out.rc")"
    has 'and says why' 'A restore is unfinished, so nothing is changed' "$(cat "$E/job.out")"
    [[ $(sha256sum "$CRL") == "$before" ]]; rc_is 'and the CRL is untouched' 0 "$?"
    has 'the restore is then finished' 'The restore is finished.' "$(restore_run --resume)"
    mkdir -p "$E/varlib/clients"; printf 'first_seen=9\n' > "$E/varlib/clients/zz-new"
    count=$(backups)
    paused_restore locked "$E/first.out" DARBAN_TEST_RESTORE_STOP=2
    ( env PATH="$E/realflock:$PATH" bash "$E/manager.sh" backup-auto daily >"$E/job.out" 2>&1; echo "$?" >"$E/job.out.rc" ) &
    wait_for 'grep -q "waiting up to" "$E/job.out" 2>/dev/null'; rc_is 'the daily backup waits for the lock' 0 "$?"
    rm -f "$E/paused"
    wait
    [[ $(backups) == "$count" ]]; rc_is 'and makes none' 0 "$?"
    has 'it says why' 'A restore is unfinished, so nothing is changed' "$(cat "$E/job.out")"
    has 'the restore is then finished' 'The restore is finished.' "$(restore_run --resume)"
}

test_a_restore_known_by_the_server_ca_only_still_checks_the_crl() {
    # R24-A-gap-7 and C.16.1: when only the server's CA, or the CRL, shows the same CA, the CRL of that CA still names
    # a revocation since the backup; without it, the restore says what cannot be known.
    local fp out
    backed_up_server
    fp=$(ca_fp)
    revoke_menu bob >/dev/null
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/other-ca.key" -out "$PKI/ca.crt" \
        -days 30 -subj /CN=other >/dev/null 2>&1
    out=$(printf '2\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1); rc_is 'refused by the CRL of the same CA' 1 "$?"
    has 'and it names the client' 'bob (serial ' "$out"
    rm -f "$CRL"
    out=$(printf 'wrong\n' | bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" 2>&1)
    has 'without the CRL it cannot know' 'Revocations and certificates issued after' "$out"
    ok_if 'and a wrong name changes nothing' test ! -e "$E/varlib/restore.journal"
}

test_a_waiting_resume_or_rollback_acts_only_on_its_own_restore() {
    # R26-A01, with the real lock: a --resume or --rollback that waited does nothing when the restore it was asked
    # for is gone and another one began meanwhile, says so, and leaves that one as it is.
    local fp kind id snapshot
    backed_up_server
    fp=$(ca_fp)
    real_flock
    mkdir -p "$E/run"
    for kind in --rollback --resume; do
        printf '2\n' | DARBAN_TEST_RESTORE_STOP=2 bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
        id=$(sed -n 's/^id=//p' "$E/varlib/restore.journal")
        rm -f "$E/held"
        ( /usr/bin/flock 9; : > "$E/held"; while [[ -e $E/held ]]; do sleep 0.1; done ) 9>>"$E/run/lock" &
        wait_for '[[ -e $E/held ]]'
        ( env PATH="$E/realflock:$PATH" bash "$E/manager.sh" restore "$kind" >"$E/second.out" 2>&1; echo "$?" >"$E/second.out.rc" ) &
        wait_for 'grep -q "waiting up to" "$E/second.out" 2>/dev/null'; rc_is "$kind: it waits for the lock" 0 "$?"
        # Meanwhile the restore it was asked for is gone, and another one began.
        cp "$E/varlib/restore.journal" "$E/journal.first"
        sed -i "s/^id=.*/id=${id}x/" "$E/varlib/restore.journal"
        snapshot=$(cat "$E/varlib/restore.journal")
        rm -f "$E/held"
        wait
        rc_is "$kind: it is refused" 1 "$(cat "$E/second.out.rc")"
        has "$kind: it says another restore began" 'another restore' "$(cat "$E/second.out")"
        [[ $(cat "$E/varlib/restore.journal") == "$snapshot" ]]; rc_is "$kind: and leaves that one as it is" 0 "$?"
        cp "$E/journal.first" "$E/varlib/restore.journal"
        has "$kind: the first restore is then undone" 'The restore was undone' "$(restore_run --rollback)"
    done
}

test_a_client_record_a_stopped_restore_left_half_written_is_written_whole() {
    # R26-A02 and C.16.8: a client record this restore adds is written whole on every try, so one left half written
    # by a stop is not taken as done.
    local fp
    backed_up_server
    fp=$(ca_fp)
    mkdir -p "$E/varlib/clients"; printf 'first_seen=5\nlast_connect=7\n' > "$E/varlib/clients/carol"
    mgr backup-auto test >/dev/null
    (cd "$E" && opened_backup "$E/backup.tar")
    rm -f "$E/varlib/clients/carol"
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=after:ledger-noted bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    rc_is 'stopped once the record was noted' 99 "$?"
    # What a stop half way through writing it leaves.
    : > "$E/varlib/clients/carol"
    has 'the resume finishes the restore' 'The restore is finished.' "$(restore_run --resume)"
    grep -qx 'first_seen=5' "$E/varlib/clients/carol"; rc_is 'and the record is written whole' 0 "$?"
}

test_a_rollback_stopped_half_way_is_finished_by_the_next() {
    # R26-A03 and C.16.9: a rollback stopped between its moves leaves the journal "undoing": nothing finishes the
    # restore forward from there, and the next rollback finishes, after being stopped again too.
    local fp out
    backed_up_server
    fp=$(ca_fp)
    : > "$PKI/old-pki"; : > "$E/server/old-server"
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=after:started bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    rc_is 'a restore stopped once OpenVPN was started' 99 "$?"
    out=$(DARBAN_TEST_RESTORE_STOP=after:undo-moved-server restore_run --rollback); rc_is 'its rollback stops between two moves' 99 "$?"
    grep -qx 'state=undoing' "$E/varlib/restore.journal"; rc_is 'the journal says undoing' 0 "$?"
    has 'Diagnostics say a rollback is unfinished' 'A rollback of a restore is unfinished' "$(mgr status)"
    out=$(restore_run --resume); rc_is 'a resume does not finish it forward' 1 "$?"
    out=$(DARBAN_TEST_RESTORE_STOP=after:undo-pki restore_run --rollback); rc_is 'the next rollback stops later' 99 "$?"
    out=$(restore_run --rollback); rc_is 'and the one after finishes' 0 "$?"
    has 'it says so' 'The restore was undone' "$out"
    ok_if 'the CA and the server files are as they were' test -e "$PKI/old-pki" -a -e "$E/server/old-server"
    ok_if 'and OpenVPN runs, enabled at boot' unit_on
}

test_a_rollback_that_cannot_put_settings_or_records_back_keeps_its_journal() {
    # R26-A03 (A-L3): a rollback that cannot put the settings, or a client record, back names it, keeps the journal
    # and says nothing is undone; once that is fixed, the next rollback finishes.
    local fp out
    if (( EUID == 0 )); then result 1 'skipped: root writes into a folder whatever its mode'; return 0; fi
    backed_up_server
    fp=$(ca_fp)
    mkdir -p "$E/varlib/clients"; printf 'first_seen=5\n' > "$E/varlib/clients/carol"
    mgr backup-auto test >/dev/null
    (cd "$E" && opened_backup "$E/backup.tar")
    rm -f "$E/varlib/clients/carol"
    printf '2\n' | DARBAN_TEST_RESTORE_STOP=after:started bash "$E/manager.sh" restore "$E/backup.tar" --ca-fingerprint "$fp" >/dev/null 2>&1
    chmod 555 "$E/cfg" "$E/varlib/clients"
    out=$(restore_run --rollback); rc_is 'settings and a client record that cannot be put back' 1 "$?"
    chmod 755 "$E/cfg" "$E/varlib/clients"
    has 'the settings are named' "$E/cfg/config" "$out"
    has 'and the client record' "$E/varlib/clients/carol" "$out"
    lacks 'and nothing is called undone' 'The restore was undone' "$out"
    ok_if 'the journal stays' test -s "$E/varlib/restore.journal"
    out=$(restore_run --rollback); rc_is 'once both are fixed, the rollback finishes' 0 "$?"
    has 'and says so' 'The restore was undone' "$out"
    ok_if 'the record it added is gone' test ! -e "$E/varlib/clients/carol"
}

two_homes() {
    # Two SSH users with homes of their own, ali and bea; root has none here.
    mkdir -p "$E/home/ali" "$E/home/bea"
    cat > "$E/bin/getent" <<STUB
#!/usr/bin/env bash
if [[ \${1:-} == passwd ]]; then
    case \${2:-} in
        ali) echo "ali:x:1000:1000::$E/home/ali:/bin/bash" ;;
        bea) echo "bea:x:1001:1001::$E/home/bea:/bin/bash" ;;
        *) exit 2 ;;
    esac
    exit 0
fi
exec /usr/bin/getent "\$@"
STUB
    chmod +x "$E/bin/getent"
}
ssh_user() { sed -i "s/^DOWNLOAD_SSH_USER=.*/DOWNLOAD_SSH_USER=$1/" "$E/cfg/config"; }
keep_file() { printf '5\n%s\n2\n\n0\n' "$1" | bash "$E/manager.sh" 2>&1; }
copies() { find "$E/clients" -maxdepth 1 -name '.homecopy.*' | wc -l; }

test_each_copy_for_the_ssh_user_goes_with_its_share() {
    # R22-06 and C.16: every copy made for an SSH user is recorded until it goes, in any home and for any user, and
    # it ends with its share: when its time is up, when it is shared again, or when it becomes a link.
    two_homes
    ssh_user ali
    keep_file alice >/dev/null
    ok_if 'ali gets a copy' test -s "$E/home/ali/alice.ovpn"
    ssh_user bea
    menu '6\n1\n1\n0\n' >/dev/null
    ok_if 'with bea as the user now, bea gets a copy of the same share' test -s "$E/home/bea/alice.ovpn"
    ok_if 'and the copy of ali stays known' test -s "$E/home/ali/alice.ovpn"
    [[ $(copies) == 2 ]]; rc_is 'two copies are recorded' 0 "$?"
    ssh_user root
    sed -i 's/^expires=.*/expires=1/' "$E/clients/alice.share"
    mgr sweep >/dev/null
    ok_if 'when its time is up, both copies go, whoever the user is now' test ! -e "$E/home/ali/alice.ovpn" -a ! -e "$E/home/bea/alice.ovpn"
    [[ $(copies) == 0 ]]; rc_is 'and so do their records' 0 "$?"
    ssh_user ali
    keep_file alice >/dev/null
    ok_if 'a new share gets a new copy' test -s "$E/home/ali/alice.ovpn"
    ssh_user bea
    keep_file alice >/dev/null
    ok_if 'sharing again ends the copy of the share before' test ! -e "$E/home/ali/alice.ovpn"
    ok_if 'and the new share has its copy' test -s "$E/home/bea/alice.ovpn"
    start_links_stub
    menu '5\nalice\n1\n1\n0\n' >/dev/null
    stop_links_stub
    ok_if 'a share that becomes a link ends its copy' test ! -e "$E/home/bea/alice.ovpn"
    [[ $(copies) == 0 ]]; rc_is 'and its record' 0 "$?"
}

test_a_revocation_ends_every_copy_of_its_certificate() {
    # R18-03 and C.16: a revocation deletes every recorded copy of the certificate, in any home, and the file of that
    # name in the home of the user set now when it holds that certificate. At expiry, such a file of another user,
    # which this tool did not make, stays.
    two_homes
    ssh_user ali
    keep_file alice >/dev/null
    cp "$E/home/ali/alice.ovpn" "$E/home/bea/alice.ovpn"
    ssh_user bea
    sed -i 's/^expires=.*/expires=1/' "$E/clients/alice.share"
    mgr sweep >/dev/null
    ok_if 'at expiry the copy this tool made goes' test ! -e "$E/home/ali/alice.ovpn"
    ok_if 'and a file bea made with the same certificate stays' test -s "$E/home/bea/alice.ovpn"
    revoke_menu alice >/dev/null
    ok_if 'a revocation deletes it, since it holds the revoked certificate' test ! -e "$E/home/bea/alice.ovpn"
    menu '1\nbob\n0\n' >/dev/null
    ssh_user ali
    keep_file bob >/dev/null
    ok_if 'ali gets a copy of bob' test -s "$E/home/ali/bob.ovpn"
    ssh_user bea
    revoke_menu bob >/dev/null
    ok_if 'a revocation deletes the copy made for ali, with bea as the user now' test ! -e "$E/home/ali/bob.ovpn"
    [[ $(copies) == 0 ]]; rc_is 'and its record' 0 "$?"
}

test_a_copy_never_writes_over_or_deletes_what_is_not_its_own() {
    # R20-02, R22-07 and R22-08: a file already there, a link, a second name of another file, or a home that is a
    # link is never written over; a copy changed after it was made, even with its time of modification set back, or
    # replaced just before it is deleted, is kept and named.
    local out other copy mtime
    two_homes
    ssh_user ali
    echo 'mine' > "$E/home/ali/alice.ovpn"
    out=$(keep_file alice)
    has 'a file of the same name stays, and says so' 'is not a copy this tool made for this share, so it was left as it is' "$out"
    grep -qx mine "$E/home/ali/alice.ovpn"; rc_is 'and it is unchanged' 0 "$?"
    copy=$(compgen -G "$E/home/ali/alice-*.ovpn" | head -n1)
    ok_if 'the copy gets a name of its own' test -s "$copy"
    has 'and the command fetches it' "$copy" "$out"
    menu '6\n1\n2\n2\n0\n' >/dev/null
    ok_if 'deleting the share deletes that copy' test ! -e "$copy"
    grep -qx mine "$E/home/ali/alice.ovpn"; rc_is 'and not the file that was there' 0 "$?"
    rm -f "$E/home/ali/alice.ovpn"
    echo 'other' > "$E/other"
    ln -s "$E/other" "$E/home/ali/alice.ovpn"
    keep_file alice >/dev/null
    grep -qx other "$E/other"; rc_is 'a link of that name is not followed' 0 "$?"
    ok_if 'and stays a link' test -L "$E/home/ali/alice.ovpn"
    rm -f "$E/home/ali/alice.ovpn" "$E/home/ali"/alice-*.ovpn
    ln "$E/other" "$E/home/ali/alice.ovpn"
    keep_file alice >/dev/null
    grep -qx other "$E/other"; rc_is 'a second name of another file is not written over' 0 "$?"
    rm -f "$E/home/ali"/alice*.ovpn
    mv "$E/home/ali" "$E/home/ali-real"; ln -s "$E/home/ali-real" "$E/home/ali"
    out=$(keep_file alice)
    has 'a home that is a link gets no copy' 'has no home directory of its own here' "$out"
    ok_if 'and nothing is written where it points' test -z "$(compgen -G "$E/home/ali-real/alice*.ovpn")"
    rm -f "$E/home/ali"; mv "$E/home/ali-real" "$E/home/ali"
    # A copy changed in place, with its size kept and its time of modification set back.
    keep_file alice >/dev/null
    copy=$E/home/ali/alice.ovpn
    mtime=$(stat -c %Y "$copy")
    sleep 1.1
    printf '#' | dd of="$copy" bs=1 seek=0 conv=notrunc 2>/dev/null
    touch -m -d "@$mtime" "$copy"
    sed -i 's/^expires=.*/expires=1/' "$E/clients/alice.share"
    mgr sweep >/dev/null
    ok_if 'a copy changed after it was made stays' test -s "$copy"
    rm -f "$copy"
    # Replaced between the question and the deletion.
    keep_file alice >/dev/null
    out=$(DARBAN_TEST_HOME_COPY_HOOK='rm -f "$1"; echo foreign > "$1"' menu '6\n1\n2\n2\n0\n')
    grep -qx foreign "$copy"; rc_is 'a file put there just before the deletion stays' 0 "$?"
    has 'and is named' 'changed since this tool made it, so it was kept' "$out"
    rm -f "$copy"
    menu '1\nbob\n0\n' >/dev/null
    keep_file bob >/dev/null
    DARBAN_TEST_HOME_COPY_HOOK='rm -f "$1"; echo foreign > "$1"' revoke_menu bob >/dev/null
    grep -qx foreign "$E/home/ali/bob.ovpn"; rc_is 'at a revocation too, a file that is not the certificate stays' 0 "$?"
}

test_a_changed_copy_stays_known_until_it_is_gone() {
    # R24-B01 and R24-B03: a copy that changed after it was made is kept, and so is its record. Diagnostics name it;
    # a revocation with another SSH user set still deletes it when it holds the revoked certificate, and a file that
    # holds nothing of this CA stays, named, never blocking a revocation. Once it is deleted, it is forgotten.
    local copy out
    two_homes
    ssh_user ali
    keep_file alice >/dev/null
    copy=$E/home/ali/alice.ovpn
    echo '# my note' >> "$copy"
    sed -i 's/^expires=.*/expires=1/' "$E/clients/alice.share"
    mgr sweep >/dev/null
    ok_if 'at expiry the changed copy stays' test -s "$copy"
    [[ $(copies) == 1 ]]; rc_is 'and so does its record' 0 "$?"
    has 'Diagnostics name it' 'changed after it was made, so it was kept' "$(mgr status)"
    ssh_user bea
    revoke_menu alice >/dev/null
    ok_if 'a revocation, with bea as the user now, deletes it: it holds the revoked certificate' test ! -e "$copy"
    [[ $(copies) == 0 ]]; rc_is 'and its record goes' 0 "$?"
    lacks 'Diagnostics no longer name it' 'changed after it was made' "$(mgr status)"
    menu '1\nbob\n0\n' >/dev/null
    ssh_user ali
    keep_file bob >/dev/null
    echo 'not a profile any more' > "$E/home/ali/bob.ovpn"
    sed -i 's/^expires=.*/expires=1/' "$E/clients/bob.share"
    mgr sweep >/dev/null
    ssh_user bea
    out=$(revoke_menu bob)
    grep -qx 'not a profile any more' "$E/home/ali/bob.ovpn"; rc_is 'a file that holds nothing of this CA stays' 0 "$?"
    lacks 'and leaves no revocation unfinished' 'Revocation unfinished' "$(menu '0\n')"
    has 'it is still named' 'changed after it was made, so it was kept' "$(mgr status)"
    rm -f "$E/home/ali/bob.ovpn"
    mgr sweep >/dev/null
    [[ $(copies) == 0 ]]; rc_is 'once deleted, it is forgotten' 0 "$?"
}

test_a_copy_that_could_not_be_written_leaves_nothing() {
    # R24-B02: a copy whose writing fails half way is removed, so nothing half written stays in that home, and the
    # next share makes it under its own name.
    local out
    two_homes
    ssh_user ali
    out=$(export DARBAN_TEST_COPY_FAIL=write; keep_file alice)
    has 'it says so' 'Could not make a copy for ali' "$out"
    ok_if 'and nothing half written stays' test -z "$(compgen -G "$E/home/ali/alice*.ovpn")"
    [[ $(copies) == 0 ]]; rc_is 'nor a record' 0 "$?"
    keep_file alice >/dev/null
    ok_if 'the next share makes the copy under its own name' test -s "$E/home/ali/alice.ovpn"
}

test_a_copy_recorded_by_the_version_before_is_adopted() {
    # R24-B-gap-5: a copy named in the record of its share, as the version before this one recorded it, is recorded
    # by the next check, and ends with its share.
    local copy
    two_homes
    keep_file alice >/dev/null
    copy=$E/home/ali/alice.ovpn
    cp "$E/clients/alice.ovpn" "$copy"
    printf 'home=%s\nhome_file=%s\n' "$copy" "$(stat -c '%i:%Y:%s' "$copy")" >> "$E/clients/alice.share"
    ssh_user ali
    mgr sweep >/dev/null
    [[ $(copies) == 1 ]]; rc_is 'the copy is recorded' 0 "$?"
    sed -i 's/^expires=.*/expires=1/' "$E/clients/alice.share"
    mgr sweep >/dev/null
    ok_if 'and ends with its share' test ! -e "$copy"
}

test_the_download_panel_never_reads_a_file_without_a_record() {
    # R18-06: the download commands come from the record; without one, the kept file is not read, so its access
    # time still tells whether it was fetched.
    local before out
    keep_file alice >/dev/null
    rm -f "$E/clients/alice.share"
    touch -a -d '2000-01-01 00:00:00' "$E/clients/alice.ovpn"
    before=$(stat -c %X "$E/clients/alice.ovpn")
    sed '$ s/^main "\$@"$/:/' "$E/manager.sh" > "$E/manager-lib.sh"
    out=$(bash -c 'source "$1"; download_panel "$2" Profile all' _ "$E/manager-lib.sh" "$E/clients/alice.ovpn" 2>&1)
    has 'the panel is shown' 'Server' "$out"
    has 'where it points is not known without a record' 'unknown' "$out"
    [[ $(stat -c %X "$E/clients/alice.ovpn") == "$before" ]]; rc_is 'the file is not read' 0 "$?"
}

mapfile -t TESTS < <(declare -F | awk '$3 ~ /^test_/ {print $3}' | sort)
for t in "${TESTS[@]}"; do
    [[ -z $FILTER || $t == *"$FILTER"* ]] || continue
    CURRENT=$t
    printf '%s\n' "$t"
    fresh
    "$t"
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf 'Failed:\n'; printf '  %s\n' "${FAILED[@]}"; exit 1; fi

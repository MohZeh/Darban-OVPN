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
revoke_menu() { menu "3\n$1\n$1\n0\n"; }
# Restores the index as a backup would, including the files the revocation moved away.
snapshot_index() { cp "$PKI/index.txt" "$E/index.before"; cp "$PKI/issued/alice.crt" "$E/alice.crt"; cp "$PKI/private/alice.key" "$E/alice.key"; }
restore_index() { cp "$E/index.before" "$PKI/index.txt"; cp "$E/alice.crt" "$PKI/issued/alice.crt"; cp "$E/alice.key" "$PKI/private/alice.key"; }
# Runs the library's CRL check by itself, for states the entry points refuse earlier.
lib_verify() { bash -c 'set -uo pipefail; source "$E/lib/common.sh"; darban_verify_crl "$E/server/crl.pem"' 2>&1; }

test_create_and_revoke_baseline() {
    local out rc serial
    out=$(menu '2\nbob\n0\n')
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

    out=$(menu '2\nbob\n0\n')
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
    out=$(menu '4\njohn.doe\n3\n1\n1\n0\n')
    has 're-export works' 'Profile for "john.doe" rebuilt' "$out"
    ok_if 'profile written' test -s "$E/clients/john.doe.ovpn"
    has 'download offers it' 'john.doe' "$(menu '4\n\n0\n')"
    out=$(revoke_menu john.doe)
    has 'revoke works' 'john.doe is revoked.' "$out"
    ok_if 'CRL lists it' crl_lists "$CRL" "$serial"
    out=$(menu '2\nnew.dotted\n\n0\n')
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
    out=$(menu '4\nalice\n3\n1\n1\n0\n')
    has 're-export works' 'Profile for "alice" rebuilt' "$out"
    grep -q "$(openssl x509 -in "$PKI/issued/alice.crt" -outform PEM | sed -n 2p)" "$E/clients/alice.ovpn"
    rc_is 'the profile holds the new certificate' 0 "$?"
    out=$(revoke_menu alice)
    has 'revoke works' 'alice is revoked.' "$out"
    ok_if 'CRL lists the new serial' crl_lists "$CRL" "$new_serial"
    ok_if 'CRL keeps the old serial' crl_lists "$CRL" "$old_serial"
    rc_is 'both records are revoked' RR "$(state_row alice)"
    out=$(menu '3\n0\n')
    has 'nothing left to revoke' 'No clients are available' "$out"
}

test_stale_certificate_file_is_refused_with_a_reason() {
    local out
    cp "$PKI/issued/alice.crt" "$E/old.crt"
    easyrsa revoke alice; publish_now
    easyrsa build-client-full alice nopass
    # The file on disk is the OLD, revoked certificate, while the index lists a new valid one.
    cp "$E/old.crt" "$PKI/issued/alice.crt"
    out=$(menu '3\n0\n')
    has 'revoke explains (C-02)' 'is not the certificate the CA lists as valid' "$out"
    out=$(menu '4\n0\n')
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
    out=$(menu '3\n\n0\n')
    has 'picker still offers alice' 'alice' "$out"
    has 'picker gives the reasons apart' 'Valid, but not available for this action:' "$out"
    has 'picker explains bob' 'bob: pki/issued/bob.crt is missing' "$out"
    out=$(menu '3\nbob\n\n0\n')
    has 'a blocked name cannot be picked' 'is not in the list above' "$out"
}

test_failed_crl_after_revoke_can_be_finished() {
    local out rc serial
    menu '4\nalice\n3\n1\n1\n0\n' >/dev/null
    ok_if 'export exists' test -s "$E/clients/alice.ovpn"
    serial=$(serial_of "$PKI/issued/alice.crt")
    out=$(printf '3\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" 2>&1)
    has 'the failure is urgent (R-03)' 'OpenVPN can still accept it' "$out"
    has 'the next step is named' 'sudo darban repair-crl' "$out"
    lacks 'no false success' 'alice is revoked.' "$out"
    rc_is 'the CA already marked it' R "$(state_row alice)"

    out=$(menu '0\n')
    has 'header names the client after a restart' 'NOT blocked yet: alice' "$out"
    has 'list names the client' 'NOT blocked yet: alice' "$(mgr list)"
    has 'status names the client' 'NOT blocked yet: alice' "$(mgr status)"
    has 'revoke menu points to the repair' 'Finish this first' "$(menu '3\n0\n')"

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
    printf '3\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" >/dev/null 2>&1
    out=$(menu '8\n2\n\n0\n')
    has 'menu item exists' 'Repair CRL / finish a revocation' "$out"
    has 'menu item repairs' 'The CRL is repaired.' "$out"
}

test_timer_repair_leaves_a_visible_unfinished_revocation() {
    local out rc
    menu '4\nalice\n3\n1\n1\n0\n' >/dev/null
    printf '3\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" >/dev/null 2>&1
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

    out=$(menu '2\nalice\n0\n')
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

    out=$(menu '2\nalice\n\n0\n')
    has 'a name with a valid certificate is refused' 'it still has a valid certificate' "$out"

    out=$(revoke_menu alice)
    has 'the new certificate can be revoked too' 'alice is revoked.' "$out"
    rc_is 'both records are revoked' RR "$(state_row alice)"
    ok_if 'the CRL lists both serials' crl_lists "$CRL" "$new"
}

test_name_reuse_requires_a_finished_revocation() {
    local out
    menu '4\nalice\n3\n1\n1\n0\n' >/dev/null
    printf '3\nalice\nalice\n0\n' | FAIL_GENCRL=1 bash "$E/manager.sh" >/dev/null 2>&1
    out=$(menu '2\nalice\n\n0\n')
    has 'refused while the old certificate is not blocked' 'the published CRL has a problem' "$out"
    ok_if 'nothing issued' test ! -e "$PKI/issued/alice.crt"

    maintain --auto >/dev/null
    out=$(menu '2\nalice\n\n0\n')
    has 'refused while the revocation is unfinished' 'its revocation is unfinished' "$out"
    mgr repair-crl >/dev/null

    mkdir -p "$PKI/reqs"; : > "$PKI/reqs/alice.req"
    out=$(menu '2\nalice\n\n0\n')
    has 'refused while an old request file exists' 'pki/reqs/alice.req is still there' "$out"
    rm "$PKI/reqs/alice.req"

    out=$(menu '2\nalice\n0\n')
    has 'allowed once everything is finished' 'Client "alice" created and verified' "$out"
}

test_name_reuse_asks_only_when_server_settings_exist() {
    local out
    revoke_menu alice >/dev/null
    mkdir -p "$E/server/ccd"; echo 'ifconfig-push 10.8.0.50 255.255.255.0' > "$E/server/ccd/alice"
    echo 'client-config-dir ccd' >> "$SERVER_CONF"
    out=$(menu '2\nalice\n1\n\n0\n')
    has 'the settings file is named' 'ccd/alice and will apply to the new certificate' "$out"
    ok_if 'answering No issues nothing' test ! -e "$PKI/issued/alice.crt"
    rc_is 'answering No leaves the index alone' R "$(state_row alice)"
    out=$(menu '2\nalice\n2\n0\n')
    has 'answering Yes issues it' 'Client "alice" created and verified' "$out"
}

test_case_warning_only_for_valid_clients() {
    local out
    if [[ ! -e "$PKI/issued/ALICE.crt" ]]; then
        out=$(menu '2\nALICE\n1\n\n0\n')
        has 'warns about a valid client with the same letters' 'differing only in letter case: alice' "$out"
    fi
    revoke_menu alice >/dev/null
    out=$(menu '2\nAlice\n0\n')
    lacks 'a revoked client does not cause the warning' 'letter case' "$out"
    has 'the client is created' 'Client "Alice" created and verified' "$out"
}

test_list_hides_revoked_unless_asked() {
    local out rc
    menu '2\nbob\n0\n' >/dev/null
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
    has 'revoke sits with clients' '3  Revoke client' "$out"
    has 'sharing has its own group' 'SHARE' "$out"
    has 'sharing is in that group' '4  Share a profile' "$out"
    has 'active links are in that group' '5  Active links' "$out"
    has 'delete is in that group' '6  Delete server copy' "$out"
    out=$(menu '7\n0\n0\n')
    has 'settings holds the address' 'Server address' "$out"
    lacks 'settings no longer holds maintenance' 'Restart OpenVPN' "$out"
    out=$(menu '8\n1\n0\n0\n')
    has 'maintenance runs diagnostics' 'Revocation (CRL)' "$out"
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
out=''; url=''
while (( $# )); do case $1 in -o) out=$2; shift 2 ;; --proto|--proto-redir|--tlsv1.2|--retry|--max-time) if [[ $1 == --tlsv1.2 ]]; then shift; else shift 2; fi ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "curl $url" >> "$STUB_LOG"
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
if [[ " $* " == *" -s "* ]]; then
    case " $* " in
      *" purge "*) on=0; for a; do if (( on )); then echo "Remv $a"; fi; [[ $a == purge ]] && on=1; done; if [[ -n ${REMV_EXTRA:-} ]]; then echo "Remv $REMV_EXTRA"; fi ;;
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
    printf '#!/usr/bin/env bash\necho "snap $*" >> "$STUB_LOG"\nexit ${FAKE_SNAP_RC:-0}\n' > "$E/bin/snap"
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
    out=$(menu '2\nfirst\n0\n')
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
        -e "s#^SETUP_LOG=.*#SETUP_LOG=$E/setup.log#" -e "s#^LOCK_FILE=.*#LOCK_FILE=$E/run/lock#" "$REPO/setup/remove-server.sh" > "$E/lib/remove-server.sh"
    sed -e "s#^LIB=.*#LIB=$E/fake-lib#" -e "s#^SBIN=.*#SBIN=$E/fake-sbin#" -e "s#^UNITS=.*#UNITS=$E/fake-units#" \
        -e 's/^\[\[ \$EUID == 0 \]\] .*/:/' "$REPO/setup/uninstall.sh" > "$E/lib/uninstall.sh"
}
built_server() {
    prepare_blank_server
    # nftables was already on this server, so the setup must not count it as its own.
    INSTALLED_PKGS=nftables setup_run --port 21194 --yes >/dev/null
    install_removal_scripts
    menu '2\nfirst\n0\n' >/dev/null
}

test_remove_everything_removes_only_what_setup_added() {
    local out rc log
    built_server
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
    for path in "$PKI" "$E/server" "$E/clients" "$E/cfg" "$SETUP_ROOT/sources/openvpn.list" "$SETUP_ROOT/keyrings/key.asc" "$SETUP_ROOT/sysctl/darban.conf" "$SETUP_ROOT/modules/darban.conf" "$SETUP_ROOT/units/nat.service" "$E/fake-sbin/darban" "$E/fake-units/darban-crl.timer" "$E/tool-backups"; do
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
    out=$(menu '7\n3\n0\n0\n0\n')
    has 'settings offers Advanced' '3  Advanced' "$out"
    has 'it shows the routing' 'full tunnel' "$out"
    has 'it shows the DNS' '1.1.1.1 8.8.8.8' "$out"
    has 'it shows the network' '10.8.0.0/24' "$out"
    has 'it shows the ciphers' 'AES-256-GCM' "$out"

    : > "$STUB_LOG"
    out=$(menu '7\n3\n2\n9.9.9.9 8.8.4.4\n1\n0\n0\n0\n')
    has 'option 1 changes nothing' 'Cancelled; nothing changed' "$out"
    if conf_has 'DNS 9.9.9.9'; then result 0 'the DNS stays after No'; else result 1 'the DNS stays after No'; fi
    if grep -q 'systemctl restart' "$STUB_LOG"; then result 0 'no restart after No'; else result 1 'no restart after No'; fi
    out=$(menu '7\n3\n2\nnot-an-ip\n\n0\n0\n0\n')
    has 'a bad DNS is asked again' 'Enter one or two IPv4 addresses' "$out"

    out=$(menu '7\n3\n2\n9.9.9.9 8.8.4.4\n2\n0\n0\n0\n')
    has 'the DNS change is confirmed' 'Applied: DNS 9.9.9.9 8.8.4.4' "$out"
    conf_has 'dhcp-option DNS 9.9.9.9'; rc_is 'the new DNS is in server.conf' 0 "$?"
    if conf_has 'dhcp-option DNS 1.1.1.1'; then result 0 'the old DNS is gone'; else result 1 'the old DNS is gone'; fi
    grep -q 'systemctl restart' "$STUB_LOG"; rc_is 'OpenVPN was restarted' 0 "$?"
    grep -q 'server.conf changed: DNS' "$STUB_LOG"; rc_is 'the change is audited' 0 "$?"

    out=$(menu '7\n3\n1\n2\n0\n0\n0\n')
    has 'split tunnel is applied' 'Applied: split tunnel' "$out"
    if conf_has 'redirect-gateway'; then result 0 'split: no redirect'; else result 1 'split: no redirect'; fi
    if conf_has 'dhcp-option DNS'; then result 0 'split: no DNS push'; else result 1 'split: no DNS push'; fi
    out=$(menu '7\n3\n2\n0\n0\n0\n')
    has 'split: DNS is explained, not asked' 'keep their own DNS' "$out"
    out=$(menu '7\n3\n1\n2\n0\n0\n0\n')
    has 'full tunnel is applied' 'Applied: full tunnel' "$out"
    conf_has 'redirect-gateway'; rc_is 'full: redirect is back' 0 "$?"
    conf_has 'dhcp-option DNS 1.1.1.1'; rc_is 'full: default DNS is back' 0 "$?"

    out=$(menu '7\n3\n3\n8.8.8.0\n\n0\n0\n0\n')
    has 'a public network is asked again' 'Enter a private network' "$out"
    out=$(menu '7\n3\n3\n172.20.5.0\n0\n0\n0\n')
    has 'an overlapping network is refused' 'overlaps the existing route 172.20.0.0/16' "$out"
    out=$(menu '7\n3\n3\n10.50.0.0\n2\n0\n0\n0\n')
    has 'the network change is confirmed' 'Applied: VPN network 10.50.0.0/24' "$out"
    conf_has '^server 10.50.0.0 255.255.255.0'; rc_is 'server.conf has the new network' 0 "$?"
    grep -q 'ip saddr 10.50.0.0/24' "$E/cfg/nat.nft"; rc_is 'NAT follows the new network' 0 "$?"

    out=$(menu '7\n3\n4\nBF-CBC\n\n0\n0\n0\n')
    has 'a non-AEAD cipher is refused' 'Use only the allowed names' "$out"
    out=$(menu '7\n3\n4\nAES-256-GCM\n2\n0\n0\n0\n')
    has 'the ciphers change' 'Applied: data ciphers AES-256-GCM' "$out"
    conf_has '^data-ciphers AES-256-GCM$'; rc_is 'one data-ciphers line remains' 0 "$?"
    out=$(menu '7\n3\n5\n10 5\n\n0\n0\n0\n')
    has 'a too short timeout is refused' 'at least twice the first' "$out"
    out=$(menu '7\n3\n5\n15 90\n2\n0\n0\n0\n')
    conf_has '^keepalive 15 90$'; rc_is 'keepalive changes' 0 "$?"
    out=$(menu '7\n3\n6\n4\n2\n0\n0\n0\n')
    conf_has '^verb 4$'; rc_is 'log detail changes' 0 "$?"

    before=$(cat "$SERVER_CONF")
    cp "$E/cfg/nat.nft" "$E/nat.before"
    fail_restart_when 'keepalive 20 120'
    out=$(menu '7\n3\n5\n20 120\n2\n0\n0\n0\n')
    has 'a service that does not come back is rolled back' 'Rolled back' "$out"
    has 'it says nothing changed' 'Nothing was changed' "$out"
    [[ $before == "$(cat "$SERVER_CONF")" ]]; rc_is 'server.conf is exactly as before' 0 "$?"
    fail_restart_when '^server 10.60.0.0'
    out=$(menu '7\n3\n3\n10.60.0.0\n2\n0\n0\n0\n')
    [[ $before == "$(cat "$SERVER_CONF")" ]]; rc_is 'a failed network change restores server.conf' 0 "$?"
    cmp -s "$E/cfg/nat.nft" "$E/nat.before"; rc_is 'a failed network change restores NAT' 0 "$?"
}

test_advanced_network_needs_nat_from_this_tool() {
    local out
    echo 'server 10.8.0.0 255.255.255.0' >> "$SERVER_CONF"
    out=$(menu '7\n3\n3\n0\n0\n0\n')
    has 'an existing server keeps its own NAT' 'was not set up by this tool' "$out"
    sed -i '/^server /d' "$SERVER_CONF"
    out=$(menu '7\n3\n3\n0\n0\n0\n')
    has 'another layout is refused' 'another layout' "$out"
}

test_advanced_download_access_and_client_lifetime() {
    local out end days
    echo '# my note' >> "$E/cfg/config"
    out=$(menu '7\n3\n7\nsrv.example.com\n2200\n\n0\n0\n0\n')
    has 'download access is saved' 'Saved: root@srv.example.com:2200' "$out"
    grep -q '^DOWNLOAD_SSH_HOST=srv.example.com$' "$E/cfg/config"; rc_is 'the host is in the file' 0 "$?"
    grep -q '^DOWNLOAD_SSH_PORT=2200$' "$E/cfg/config"; rc_is 'the port is in the file' 0 "$?"
    grep -q '^# my note$' "$E/cfg/config"; rc_is 'other lines stay' 0 "$?"
    out=$(menu '7\n3\n7\nbad_host!\n\n99999\n\nBAD USER\n\n0\n0\n0\n')
    has 'a bad host is asked again' 'Enter a hostname or an IPv4 address' "$out"
    has 'a bad port is asked again' 'from 1 to 65535' "$out"
    has 'a bad user is asked again' 'valid Linux user name' "$out"
    out=$(menu '7\n3\n8\n5000\n0\n0\n0\n')
    has 'a bad lifetime is refused' 'Nothing changed' "$out"
    out=$(menu '7\n3\n8\n100\n0\n0\n0\n')
    has 'the lifetime is saved' 'New clients last: 100 days' "$out"
    out=$(menu '2\nshortlived\n0\n')
    has 'a client is created' 'Client "shortlived" created' "$out"
    end=$(openssl x509 -in "$PKI/issued/shortlived.crt" -noout -enddate | sed 's/notAfter=//')
    days=$(( ($(date -u -d "$end" +%s) - $(date -u +%s)) / 86400 ))
    (( days >= 98 && days <= 100 )); rc_is "the new client lasts 100 days (got $days)" 0 "$?"
    out=$(menu '7\n3\n8\n0\n0\n0\n0\n')
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
    python3 -I "$REPO/lib/linkd.py" --dir "$E/links" --cert "$E/cfg/link-cert.pem" --key "$E/cfg/link-key.pem" --host "\$LINK_HOST" --port "\$LINK_PORT" --server-conf "$SERVER_CONF" --interval 0.2 --idle-exit 1 >>"$E/links.log" 2>&1 </dev/null &
    echo \$! > "$LINKS_PIDFILE"
    exit 0
fi
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
new_link() { menu "4\n${1:-alice}\n1\n1\n${2:-1}\n0\n" | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}'; }

test_temporary_link_end_to_end() {
    local url base out head code
    start_links_stub
    out=$(menu '4\nalice\n1\n1\n1\n0\n')
    has 'the link is shown' "https://127.0.0.1:$LINK_TEST_PORT/l/" "$out"
    has 'it says how long it works' 'until alice first connects, at most 24 hours' "$out"
    has 'it says the first connection ends it' 'The link stops working once alice connects for the first time' "$out"
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

    has 'active links shows it not downloaded' 'not downloaded' "$(menu '5\n\n0\n')"
    head=$(web -D - -o "$E/got.ovpn" "$url/file")
    has 'the file type is what OpenVPN clients expect' 'application/x-openvpn-profile' "$head"
    has 'it downloads under the client name' 'alice.ovpn' "$head"
    grep -q '<key>' "$E/got.ovpn"; rc_is 'the real profile arrives' 0 "$?"
    grep -qx 'setenv FRIENDLY_NAME "alice"' "$E/got.ovpn"; rc_is 'the profile carries the client name for the app' 0 "$?"
    out=$(menu '5\n\n0\n')
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
    local url meta created attempt
    link_mgmt_server
    start_links_stub
    url=$(new_link alice)
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
    has 'active links drops an expired link' 'No active links' "$(menu '5\n0\n')"

    url=$(new_link alice 2)
    out=$(menu '5\n1\n0\n')
    has 'a link can be cancelled' 'cancelled' "$out"
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 410 ]]; rc_is 'a cancelled link is refused' 0 "$?"
    ok_if 'a cancelled link leaves no copy' test -z "$(find "$E/links" -name '*.ovpn')"

    url=$(new_link alice 3)
    revoke_menu alice >/dev/null
    [[ $(web -o /dev/null -w '%{http_code}' "$url") == 410 ]]; rc_is 'revoking a client ends its links' 0 "$?"
    ok_if 'revoking leaves no copy' test -z "$(find "$E/links" -name '*.ovpn')"
    stop_links_stub
}

test_link_server_ends_when_idle() {
    local url pid second attempt
    start_links_stub
    url=$(new_link alice)
    pid=$(cat "$LINKS_PIDFILE")
    kill -0 "$pid"; rc_is 'the server runs while a link exists' 0 "$?"
    sleep 2
    kill -0 "$pid"; rc_is 'it stays up while the link is waiting' 0 "$?"
    menu '5\n1\n0\n' >/dev/null
    for attempt in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then result 0 'it ends when no link is left'; else result 1 'it ends when no link is left'; fi
    stop_links_stub
}

test_share_questions() {
    local out
    out=$(menu '4\nalice\n4\n0\n')
    has 'Later keeps the file' 'Kept on the server' "$out"
    ok_if 'the file is on the server' test -s "$E/clients/alice.ovpn"
    out=$(menu '4\nalice\n3\n1\n2\n0\n')
    # shellcheck disable=SC2088  # The literal text the tool prints.
    has 'only the chosen command is shown' '~/Downloads/' "$out"
    lacks 'other commands are not shown' 'USERPROFILE' "$out"
    lacks 'sftp is not shown' 'sftp://' "$out"
    out=$(menu '4\nalice\n3\n1\n3\n0\n')
    has 'sftp can be chosen' 'sftp://root@' "$out"
    lacks 'scp is not shown then' 'scp -P' "$out"
    out=$(menu '2\nbob\n0\n')
    has 'a script still gets every command' 'USERPROFILE' "$out"
    has 'a script gets every command, sftp too' 'sftp://' "$out"
}

test_share_password() {
    local out password
    out=$(menu '4\nalice\n3\n2\n1\n0\n')
    has 'the password is shown once' 'shown only now' "$out"
    password=$(grep -A1 'shown only now' <<<"$out" | tail -n 1)
    [[ $password =~ ^[a-km-np-z2-9]{9}$ ]]; rc_is 'the password is nine characters in one piece, without look-alike characters' 0 "$?"
    grep -q 'ENCRYPTED PRIVATE KEY' "$E/clients/alice.ovpn"; rc_is 'the key in the profile is locked' 0 "$?"
    if grep -q 'BEGIN PRIVATE KEY' "$E/clients/alice.ovpn"; then result 0 'no open key in the profile'; else result 1 'no open key in the profile'; fi
    sed -n '/<key>/,/<\/key>/p' "$E/clients/alice.ovpn" | sed '1d;$d' > "$E/locked.key"
    openssl pkey -in "$E/locked.key" -passin "pass:$password" -noout 2>/dev/null; rc_is 'the password opens it' 0 "$?"
    openssl asn1parse -in "$E/locked.key" 2>/dev/null | grep -q 'INTEGER *:0927C0'; rc_is 'guessing it is slowed by 600000 rounds' 0 "$?"
    openssl pkey -in "$E/locked.key" -passin pass:wrong -noout 2>/dev/null; rc_not0 'a wrong password does not' "$?"
    grep -q 'BEGIN PRIVATE KEY' "$PKI/private/alice.key"; rc_is 'the key in the PKI stays usable' 0 "$?"
    if grep -rq "$password" "$E/stub.log"; then result 0 'the password is not logged'; else result 1 'the password is not logged'; fi
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
    out=$(menu '4\nalice\n1\n1\n1\n0\n')
    has 'a link port another program took is named' "TCP $port, the port for links, is now used by python3" "$out"
    lacks 'and no link is made' '/l/' "$out"
    out=$(menu "7\n3\n9\n$port\n0\n0\n0\n")
    has 'the setting refuses a port in use, and names the program' "TCP $port is already used by python3" "$out"
    kill "$pid" 2>/dev/null
}

test_share_qr_and_link_port() {
    local out
    start_links_stub
    printf '#!/usr/bin/env bash\necho "qrencode $*" >> "$STUB_LOG"; echo QRCODE-DRAWN\n' > "$E/bin/qrencode"
    chmod +x "$E/bin/qrencode"
    out=$(menu '4\nalice\n2\n1\n1\n0\n')
    has 'the QR code is drawn' 'QRCODE-DRAWN' "$out"
    grep -q 'qrencode -t ANSIUTF8 https://127.0.0.1' "$STUB_LOG"; rc_is 'the QR holds the link' 0 "$?"
    stop_links_stub

    out=$(menu '7\n3\n9\nabc\n\n0\n0\n0\n')
    has 'a bad link port is asked again' 'from 1 to 65535' "$out"
    out=$(menu '7\n3\n9\n30123\n0\n0\n0\n')
    has 'the link port is saved' 'Saved: TCP 30123' "$out"
    grep -q '^LINK_PORT=30123$' "$E/cfg/config"; rc_is 'it is in the file' 0 "$?"
}

test_link_certificate_for_a_hostname() {
    local out before
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    out=$(menu '4\nalice\n1\n2\n1\n1\n0\n')
    has 'a hostname offers a trusted certificate' "Let's Encrypt" "$out"
    has 'declining falls back to a self-signed certificate' 'no trusted certificate' "$out"
    has 'the link uses the hostname' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    openssl x509 -in "$E/cfg/link-cert.pem" -noout -checkhost vpn.example.com | grep -q 'does match'; rc_is 'the certificate fits the hostname' 0 "$?"
    menu '5\n1\n0\n' >/dev/null
    before=$(sha256sum < "$E/cfg/link-cert.pem")
    out=$(menu '4\nalice\n1\n2\n1\n1\n0\n')
    has 'a self-signed certificate is offered a trusted one again' "Let's Encrypt" "$out"
    [[ $(sha256sum < "$E/cfg/link-cert.pem") == "$before" ]]; rc_is 'declining keeps the current self-signed certificate' 0 "$?"
    has 'and the link is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    menu '5\n1\n0\n' >/dev/null

    # A trusted certificate valid for weeks is not asked about again.
    mkdir -p "$E/le"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/le/privkey.pem" -out "$E/le/fullchain.pem" \
        -days 30 -subj /CN=vpn.example.com -addext subjectAltName=DNS:vpn.example.com >/dev/null 2>&1
    mv "$E/cfg/link-cert.pem" "$E/cfg/link-cert.self"; mv "$E/cfg/link-key.pem" "$E/cfg/link-key.self"
    ln -s "$E/le/fullchain.pem" "$E/cfg/link-cert.pem"; ln -s "$E/le/privkey.pem" "$E/cfg/link-key.pem"
    out=$(menu '4\nalice\n1\n1\n1\n0\n')
    lacks 'a usable trusted certificate is not asked about again' "Let's Encrypt" "$out"
    has 'and the link is made with it' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    menu '5\n1\n0\n' >/dev/null
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    mv "$E/cfg/link-cert.self" "$E/cfg/link-cert.pem"; mv "$E/cfg/link-key.self" "$E/cfg/link-key.pem"

    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 2.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 1\n' > "$E/bin/certbot"
    chmod +x "$E/bin/certbot"
    out=$(menu '4\nalice\n1\n1\n1\n1\n0\n')
    has 'a failed request explains itself' 'certbot could not get a certificate' "$out"
    has 'and still gives a working link' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    grep -q 'certbot certonly --standalone' "$STUB_LOG"; rc_is 'certbot was asked' 0 "$?"
    menu '5
1
0
' >/dev/null

    # A trusted certificate with less than a day left, and a renewal that fails: the one that still works stays.
    mkdir -p "$E/le"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/le/privkey.pem" -out "$E/le/fullchain.pem"         -days 1 -subj /CN=vpn.example.com -addext subjectAltName=DNS:vpn.example.com >/dev/null 2>&1
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    ln -s "$E/le/fullchain.pem" "$E/cfg/link-cert.pem"; ln -s "$E/le/privkey.pem" "$E/cfg/link-key.pem"
    out=$(menu '4
alice
1
1
1
2
0
')
    has 'a trusted certificate that still works stays' 'The current trusted certificate stays' "$out"
    menu '5
1
0
' >/dev/null
    out=$(menu '4
alice
1
1
1
1
2
0
')
    has 'a link longer than the certificate is refused' 'The link certificate ends before 24 hours are over' "$out"
    has 'and a shorter one is made' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    has 'for the time chosen after it' 'until alice first connects, at most 1 hour' "$out"
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
test_update_knows_pre_releases() {
    local out
    fake_release
    cp "$E/get.sh" "$E/lib/get.sh"
    printf 'Fixed things.\n\033[31mno escape\n' > "$RELEASE/RELEASE-NOTES.txt"
    set_installed_version 1.0.0-beta.1
    echo 1.0.0 > "$RELEASE/VERSION"
    out=$(menu '9\n2\n1\n0\n0\n')
    has 'the final release is newer than its beta' 'Install v1.0.0' "$out"
    has 'its notes are shown' 'Fixed things.' "$out"
    if [[ $out == *$'\033'* ]]; then result 0 'escape codes in notes are removed'; else result 1 'escape codes in notes are removed'; fi
    echo 1.0.0-rc.1 > "$RELEASE/VERSION"
    has 'an rc is newer than a beta' 'Install v1.0.0-rc.1' "$(menu '9\n2\n1\n0\n0\n')"
    echo 1.0.0-alpha.1 > "$RELEASE/VERSION"
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

test_update_notice_in_the_header() {
    local out attempt
    fake_release
    set_installed_version 1.0.0
    lacks 'nothing is checked when it is off' 'Update available' "$(menu '0\n')"
    ok_if 'no check was made' test ! -e "$E/cfg/.latest-version"

    has 'Setup shows it is off' 'Daily update notice' "$(menu '9\n0\n0\n')"
    menu '9\n3\n0\n0\n' >/dev/null
    if grep -q '^UPDATE_CHECK=no' "$E/cfg/config"; then result 0 'the setting can be turned on'; else result 1 'the setting can be turned on'; fi
    menu '0\n' >/dev/null
    for attempt in 1 2 3 4 5 6 7 8 9 10; do [[ -s $E/cfg/.latest-version ]] && break; sleep 0.3; done
    ok_if 'a background check stored the version' test -s "$E/cfg/.latest-version"
    grep -Eq 'Update available: v9\.9\.9 .{1,3} Setup .{1,3} 2$' <<<"$(menu '0\n')"; rc_is 'the header announces it, with the Setup item to use' 0 "$?"
    ok_if 'nothing was installed by the notice' test ! -e "$MARKER"
    grep -c 'releases/latest/download/VERSION' "$STUB_LOG" > "$E/calls.before"
    menu '0\n' >/dev/null; sleep 0.5
    [[ $(grep -c 'releases/latest/download/VERSION' "$STUB_LOG") == "$(cat "$E/calls.before")" ]]; rc_is 'it checks at most once a day' 0 "$?"

    echo 'bad; version' > "$E/cfg/.latest-version"
    lacks 'a damaged stored version is ignored' 'Update available' "$(menu '0\n')"
    echo 0.0.1 > "$E/cfg/.latest-version"
    lacks 'an older version is not announced' 'Update available' "$(menu '0\n')"

    rm -f "$E/cfg/.latest-version"
    CURL_FAIL=1 bash "$E/manager.sh" </dev/null >/dev/null 2>&1
    for attempt in 1 2 3 4 5 6 7 8 9 10; do [[ -e $E/cfg/.latest-version ]] && break; sleep 0.3; done
    ok_if 'a failed check is remembered too' test -e "$E/cfg/.latest-version"
    lacks 'no internet shows nothing' 'Update available' "$(menu '0\n')"

    menu '9\n3\n0\n0\n' >/dev/null
    grep -q '^UPDATE_CHECK=no' "$E/cfg/config"; rc_is 'the setting can be turned off' 0 "$?"
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
    has 'and the checklist shows it' 'Published CRL problem' "$out"
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
    out=$(printf '3\nalice\nalice\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'it advises a local socket' 'darban.sock unix' "$out"
    lacks 'it does not advise a TCP port' '7505' "$out"
}

test_lock_is_held_only_for_changes() {
    local out
    : > "$STUB_LOG"
    out=$(printf '3\nalice\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'the revoke was cancelled' 'Cancelled' "$out"
    if grep -q '^flock' "$STUB_LOG"; then result 0 'no lock while waiting for an answer'; else result 1 'no lock while waiting for an answer'; fi
    : > "$STUB_LOG"
    out=$(printf '2\n\n\n0\n' | bash "$E/manager.sh" 2>&1)
    if grep -q '^flock' "$STUB_LOG"; then result 0 'a cancelled create takes no lock'; else result 1 'a cancelled create takes no lock'; fi
    : > "$STUB_LOG"
    out=$(printf '3\nalice\nalice\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'a confirmed revoke finishes' 'alice is revoked' "$out"
    grep -q '^flock -n' "$STUB_LOG"; rc_is 'the change takes the lock' 0 "$?"
    grep -q '^flock -u' "$STUB_LOG"; rc_is 'and gives it back before asking about the session' 0 "$?"
}

test_changes_made_during_a_question_are_noticed() {
    local out
    out=$(printf '3\nalice\nalice\n\n0\n' | FLOCK_HOOK='easyrsa revoke alice' bash "$E/manager.sh" 2>&1)
    has 'a client revoked meanwhile is not revoked again' 'changed while this question was open' "$out"
    out=$(printf '2\nbob\n\n0\n' | FLOCK_HOOK='easyrsa build-client-full bob nopass' bash "$E/manager.sh" 2>&1)
    has 'a name taken meanwhile is refused' 'created by another session' "$out"
}

test_a_number_is_never_mistaken_for_a_name() {
    local out
    out=$(printf '2\n123\n\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'a name of digits only is refused' 'only digits' "$out"
    ok_if 'no such client was made' test ! -e "$PKI/issued/123.crt"
    easyrsa build-client-full 2 nopass >/dev/null 2>&1
    out=$(printf '3\n2\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'the exact name wins over the list number' 'Revoke 2 permanently' "$out"
    out=$(printf '3\n1\n1\n\n0\n' | bash "$E/manager.sh" 2>&1)
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
    'list table ip mzx_openvpn') exit 1 ;;
    'list chain ip darban postrouting') cat "$E/live-post" 2>/dev/null ;;
    'list chain ip darban forward') cat "$E/live-forward" 2>/dev/null ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$E/bin/nft"
    source "$REPO/lib/common.sh"
    darban_nat_rules 10.8.0.0 eth0 > "$E/cfg/nat.nft"
    printf '\t\tip saddr 10.8.0.0/24 oifname "eth0" masquerade\n' > "$E/live-post"
    printf '\t\tip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop\n\t\tip saddr 10.8.0.0/24 ip daddr 169.254.0.0/16 drop\n\t\tip saddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1300 tcp option maxseg size set 1300\n\t\tip daddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1300 tcp option maxseg size set 1300\n' > "$E/live-forward"
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
    has 'the TCP size rule passes' 'TCP through the VPN fits in one packet' "$out"
    sed -i '/maxseg/d' "$E/live-forward"
    out=$(mgr status)
    has 'a missing TCP size rule is reported, with the installer as the fix' 'websites may not open on some networks' "$out"
    has 'and the installer is named' '--version v' "$out"
    lacks 'and it is not called fine' 'TCP through the VPN fits in one packet' "$out"
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
    out=$(menu '7\n3\n0\n0\n0\n')
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
    lacks 'a half-open session is not counted' 'UNDEF' "$out"
    has 'the header counts it' '1 connected' "$(menu '0\n')"
    has 'the menu offers it' 'Connected now' "$(menu '8\n4\n\n0\n0\n')"
    sed -i '/^management /d' "$SERVER_CONF"
    has 'without the interface it says so' 'Not available' "$(mgr connected)"
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
Enter: 24 hours => \r
client1 is connected from 198.51.100.7 => \r
Choose [0-9] => 0\r
EOF
    out=$(NO_COLOR=1 python3 "$HERE/pty-drive.py" --timeout 30 "$script" -- bash "$E/manager.sh" welcome 2>&1); rc=$?
    rc_is 'the whole path takes only Enter' 0 "$rc"
    has 'it ends with a link' "/l/" "$out"
    has 'and a note for the person receiving it' 'Send this note with the link' "$out"
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
Enter: 24 hours => \r
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
    out=$(printf '4\nalice\n3\n1\n2\n\n0\n' | bash "$E/manager.sh" 2>&1)
    has 'the command fetches the copy' "ali@" "$out"
    has 'from the user home' "$home/alice.ovpn" "$out"
    ok_if 'the copy exists' test -s "$home/alice.ovpn"
    out=$(menu '6\nalice\n2\n0\n')
    has 'deleting the server copy names the user copy' "The copy made for ali is deleted too" "$out"
    ok_if 'and deletes it' test ! -e "$home/alice.ovpn"
    # A file of the same name that is not this client's profile stays.
    echo 'not a profile' > "$home/alice.ovpn"
    menu '4\nalice\n3\n1\n2\n\n0\n' >/dev/null
    echo 'not a profile' > "$home/alice.ovpn"
    menu '6\nalice\n2\n0\n' >/dev/null
    grep -q 'not a profile' "$home/alice.ovpn"; rc_is 'a file that is not the profile stays' 0 "$?"
    menu '2\nbob\n0\n' >/dev/null
    printf '4\nbob\n3\n1\n2\n\n0\n' | bash "$E/manager.sh" >/dev/null 2>&1
    ok_if 'bob has a user copy' test -s "$home/bob.ovpn"
    revoke_menu bob >/dev/null
    ok_if 'revoking deletes the user copy' test ! -e "$home/bob.ovpn"
}

test_link_page_guides_the_person_receiving_it() {
    local url base out
    start_links_stub
    url=$(menu '4\nalice\n1\n1\n1\n0\n' | grep -oE 'https://[^ ]+/l/[0-9a-f]{64}')
    base=${url%/l/*}
    out=$(web -A 'Mozilla/5.0 (Linux; Android 14)' -H 'Accept-Language: fa-IR,fa;q=0.9,en-US;q=0.8' "$url")
    has 'Android gets the store link' 'play.google.com/store/apps/details?id=net.openvpn.openvpn' "$out"
    has 'a Persian device gets the steps in Persian' 'اپ OpenVPN Connect را نصب کن' "$out"
    has 'from right to left' 'dir="rtl"' "$out"
    lacks 'and not in English as well' 'Install the OpenVPN Connect app' "$out"
    out=$(web -A 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)' -H 'Accept-Language: de-DE,de;q=0.9,fa;q=0.5' "$url")
    has 'iPhone gets the App Store link' 'apps.apple.com/app/openvpn-connect' "$out"
    has 'another language first gets English' 'Install the OpenVPN Connect app' "$out"
    lacks 'and no Persian' 'اپ OpenVPN Connect را نصب کن' "$out"
    out=$(web -A 'Mozilla/5.0 (Windows NT 10.0)' "$url")
    has 'a computer gets the download page' 'openvpn.net/client/' "$out"
    has 'no language means English' 'Press <b>Download profile</b>' "$out"
    out=$(web -H 'Accept-Language: fa' "$base/l/$(printf 'b%.0s' {1..64})")
    has 'a link that no longer works says so in Persian too' 'این لینک دیگر معتبر نیست' "$out"
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
    out=$(menu '4\nalice\n1\n1\n1\n1\n0\n')
    has 'a public IP is offered a trusted certificate' 'For an IP address it lasts six days' "$out"
    grep -q -- '--preferred-profile shortlived --ip-address 203.0.113.9' "$STUB_LOG"; rc_is 'certbot asks for a six-day IP certificate' 0 "$?"
    grep -q -- '--cert-name darban-ovpn-links' "$STUB_LOG"; rc_is 'under a name of its own' 0 "$?"
    if grep -q '^certbot_cert' "$E/cfg/.server-setup-started"; then result 0 'a failed request is not recorded'; else result 1 'a failed request is not recorded'; fi
    has 'it still gives a working link' "https://203.0.113.9:$LINK_TEST_PORT/l/" "$out"
    has 'and says what a password would protect' 'A password on the key protects the profile' "$out"
    menu '5\n1\n0\n' >/dev/null
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 5.9.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    menu '4\nalice\n1\n1\n1\n1\n0\n' >/dev/null
    grep -qx 'certbot_cert darban-ovpn-links' "$E/cfg/.server-setup-started"; rc_is 'a certificate it got is recorded' 0 "$?"
    echo 10.0.0.9 > "$E/cfg/domain"
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    lacks 'a private IP is not offered one' "Let's Encrypt" "$(menu '4\nalice\n1\n1\n1\n0\n')"
    stop_links_stub
}

make_test_ca() {
    # A certificate authority of its own, trusted as the system's, and a certificate from it for $1 in $2/$3.
    local host=$1 dir=$2 leaf=$3 key=$4
    if [[ ! -s $E/test-ca.pem ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$E/test-ca.key" -out "$E/test-ca.pem" \
            -days 60 -subj /CN=Darban-Test-Root >/dev/null 2>&1
        cp "$E/test-ca.pem" "$E/system-ca.pem"
    fi
    mkdir -p "$dir"
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$dir/$key" -out "$E/leaf.csr" -subj "/CN=$host" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "$host" > "$E/leaf.ext"
    openssl x509 -req -in "$E/leaf.csr" -CA "$E/test-ca.pem" -CAkey "$E/test-ca.key" -CAcreateserial -days 30 \
        -extfile "$E/leaf.ext" -out "$dir/$leaf" >/dev/null 2>&1
}

test_link_uses_a_certificate_already_on_the_server() {
    local out
    start_links_stub
    echo vpn.example.com > "$E/cfg/domain"
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem
    out=$(menu '4\nalice\n1\n1\n1\n1\n0\n')
    has 'a trusted certificate already here is offered first' 'This server already has a trusted certificate for vpn.example.com' "$out"
    has 'and the link is made with it' "https://vpn.example.com:$LINK_TEST_PORT/l/" "$out"
    cmp -s "$E/cfg/link-cert.pem" "$E/panel-cert/vpn.example.com/fullchain.pem"; rc_is 'the link service gets a copy it can read' 0 "$?"
    ok_if 'and a link certificate is no longer self-signed' test -s "$E/cfg/link-cert.source"
    lacks 'no browser warning note' 'Send this note with the link' "$out"
    has 'Settings names where it came from' 'trusted' "$(menu '7\n0\n0\n')"
    menu '5\n1\n0\n' >/dev/null

    # Renewed where it lives: the next link takes the new one, without a question.
    make_test_ca vpn.example.com "$E/panel-cert/vpn.example.com" fullchain.pem privkey.pem
    out=$(menu '4\nalice\n1\n1\n1\n0\n')
    has 'a renewal there reaches the links' 'links use the new one' "$out"
    cmp -s "$E/cfg/link-cert.pem" "$E/panel-cert/vpn.example.com/fullchain.pem"; rc_is 'the new one is copied' 0 "$?"
    menu '5\n1\n0\n' >/dev/null

    # A file chosen by hand: a key that does not belong is refused.
    make_test_ca vpn.example.com "$E/other" cert.pem cert.key
    out=$(menu "7\n4\n2\n$E/other/cert.pem\n$E/panel-cert/vpn.example.com/privkey.pem\n0\n0\n")
    has 'a key from another certificate is refused' 'does not belong to that certificate' "$out"
    out=$(menu "7\n4\n2\n$E/other/cert.pem\n\n0\n0\n")
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
    out=$(menu '4\nalice\n1\n2\n1\n1\n0\n')
    has 'a Cloudflare Origin certificate is named, with the reason it is not used' 'is a Cloudflare Origin certificate' "$out"
    has "and Let's Encrypt is offered instead" "Get a free Let's Encrypt certificate?" "$out"
    if [[ -s $E/cfg/link-cert.source ]]; then result 0 'it is not used'; else result 1 'it is not used'; fi
    stop_links_stub
}

test_setup_installs_certbot_for_links() {
    prepare_blank_server
    : > "$STUB_LOG"
    setup_run --host vpn.example.com --port 21194 --yes >/dev/null
    grep -q -- '-y -q --no-install-recommends install certbot' "$STUB_LOG"; rc_is 'a hostname gets Ubuntu certbot during setup' 0 "$?"
    grep -qx 'package certbot' "$E/cfg/.server-setup-started"; rc_is 'and it is recorded for removal' 0 "$?"
    prepare_blank_server_again
    : > "$STUB_LOG"
    setup_run --host 203.0.113.9 --port 21194 --yes >/dev/null
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

test_old_certbot_is_not_used_for_an_ip() {
    local out
    start_links_stub
    echo 203.0.113.9 > "$E/cfg/domain"
    printf '#!/usr/bin/env bash\nif [[ $1 == --version ]]; then echo "certbot 4.0.0"; exit 0; fi\necho "certbot $*" >> "$STUB_LOG"; exit 0\n' > "$E/bin/certbot"
    printf '#!/usr/bin/env bash\necho "snap $*" >> "$STUB_LOG"; exit 1\n' > "$E/bin/snap"
    chmod +x "$E/bin/certbot" "$E/bin/snap"
    out=$(menu '4\nalice\n1\n1\n1\n1\n0\n')
    if grep -q '^certbot certonly' "$STUB_LOG"; then result 0 'certbot 4.0 is never asked for an IP'; else result 1 'certbot 4.0 is never asked for an IP'; fi
    grep -q 'snap install --classic certbot' "$STUB_LOG"; rc_is 'the Certbot snap is tried instead' 0 "$?"
    has 'a failed install falls back to a working link' "https://203.0.113.9:$LINK_TEST_PORT/l/" "$out"
    menu '5
1
0
' >/dev/null
    # Without snap there is no way to a new enough certbot, so the question is not asked at all.
    rm -f "$E/cfg/link-cert.pem" "$E/cfg/link-key.pem"
    sed -i 's/^have_snap() {.*/have_snap() { false; }/' "$E/manager.sh"
    : > "$STUB_LOG"
    out=$(menu '4
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
    out=$(menu '7\n3\n3\n10.77.0.0\n2\n0\n0\n0\n')
    chmod 755 "$E/server"
    if grep -q '^nft -f' "$STUB_LOG"; then result 0 'a server.conf that cannot be prepared leaves NAT alone'; else result 1 'a server.conf that cannot be prepared leaves NAT alone'; fi
    [[ $before == "$(cat "$E/cfg/nat.nft" "$SERVER_CONF" | sha256sum)" ]]; rc_is 'and both files unchanged' 0 "$?"

    out=$(FAIL_NFT=1 menu '7\n3\n3\n10.77.0.0\n2\n0\n0\n0\n')
    has 'a refused NAT rule changes nothing' 'Nothing was changed' "$out"
    [[ $before == "$(cat "$E/cfg/nat.nft" "$SERVER_CONF" | sha256sum)" ]]; rc_is 'both files unchanged after a refused rule' 0 "$?"

    out=$(FAIL_RESTART=1 menu '7\n3\n3\n10.77.0.0\n2\n0\n0\n0\n')
    grep -q '10.8.0.0/24' "$E/cfg/nat.nft"; rc_is 'a failed restart puts NAT back' 0 "$?"

    out=$(menu '7\n3\n3\n10.77.0.0\n2\n0\n0\n0\n')
    grep -q '^server 10.77.0.0 255.255.255.0' "$SERVER_CONF"; rc_is 'a good change is applied' 0 "$?"
    [[ $(grep -o '10.77.0.0/24' "$E/cfg/nat.nft" | wc -l) == 3 ]]; rc_is 'every rule follows the new network' 0 "$?"
}

test_setup_keeps_clients_apart() {
    prepare_blank_server
    setup_run --port 21194 --yes >/dev/null
    grep -q 'ip saddr 10.8.0.0/24 ip daddr 10.8.0.0/24 drop' "$E/cfg/nat.nft"; rc_is 'clients cannot reach each other' 0 "$?"
    grep -q 'ip saddr 10.8.0.0/24 ip daddr 169.254.0.0/16 drop' "$E/cfg/nat.nft"; rc_is 'or the cloud metadata service' 0 "$?"
    grep -q 'ip saddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1300 tcp option maxseg size set 1300' "$E/cfg/nat.nft"; rc_is 'TCP from clients fits in one tunnel packet' 0 "$?"
    grep -q 'ip daddr 10.8.0.0/24 tcp flags syn tcp option maxseg size > 1300 tcp option maxseg size set 1300' "$E/cfg/nat.nft"; rc_is 'and TCP to them' 0 "$?"
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
    menu '2\nfirst\n0\n' >/dev/null
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

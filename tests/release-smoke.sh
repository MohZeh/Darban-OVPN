#!/usr/bin/env bash
# Runs the command users are told to run, against a published release, in a real terminal.
# Only for a disposable machine, such as a CI runner. Needs passwordless sudo.
#   release-smoke.sh --i-know vX.Y.Z [earlier-tag]
# With an earlier tag, that release is installed first, so the new one is a real update.
set -Eeuo pipefail
[[ ${1:-} == --i-know && -n ${2:-} ]] || { echo 'This reconfigures the machine. Usage: release-smoke.sh --i-know vX.Y.Z [earlier-tag]' >&2; exit 2; }
tag=$2
earlier=${3:-}
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
LOG=$(mktemp -d)
url() { printf 'https://github.com/MohZeh/Darban-OVPN/releases/download/%s/get.sh' "$1"; }
one_line() { printf "sudo bash -c 'curl -fsSL %s | bash'" "$(url "$1")"; }
# Releases before v1.0.0-rc.2 documented "curl ... | sudo bash", which cannot take the answers on Ubuntu.
# They are installed with the form that works, so an update from them can still be tested.
in_terminal() {
    # in_terminal <name> <command>: types the command into an interactive shell, as a person does over SSH, and
    # answers it from $LOG/<name>.keys. The shell then exits with the command's own status.
    { printf 'SMOKE$ => %s\\r\n' "$2"; cat "$LOG/$1.keys"; printf 'SMOKE$ => exit\\r\n'; } > "$LOG/$1.script"
    PS1='SMOKE$ ' python3 tests/pty-drive.py --timeout 600 "$LOG/$1.script" -- bash --norc --noprofile -i | tee "$LOG/$1.log"
}
new_install() {
    cat > "$LOG/new.keys" <<'EOF'
Server address [ => 127.0.0.1\r
VPN port [ => \r
Enter: Install now => \r
Enter: Create a client => 1\r
Choose [0-9] => 0\r
EOF
    in_terminal new "$(one_line "$1")"
}

first=${earlier:-$tag}
new_install "$first"
[[ $(sudo darban version) == "${first#v}" ]]
sudo darban status >/dev/null
echo "PASS: the one-line command installed $first."

if [[ -n $earlier ]]; then
    printf 'Updating Darban OVPN from\n' > "$LOG/update.keys"
    in_terminal update "$(one_line "$tag")"
    [[ $(sudo darban version) == "${tag#v}" ]]
    sudo systemctl is-active --quiet openvpn-server@server.service
    sudo darban status >/dev/null
    echo "PASS: the same command updated $earlier to $tag."
fi

printf 'is already up to date\n' > "$LOG/again.keys"
in_terminal again "$(one_line "$tag")"
echo 'PASS: running it again changes nothing.'

# The old form on a server that needs no questions: an update changes nothing, and nothing waits for keys.
printf 'is already up to date\n' > "$LOG/old.keys"
in_terminal old "curl -fsSL $(url "$tag") | sudo bash"
echo 'PASS: the old form still works where nothing is asked.'

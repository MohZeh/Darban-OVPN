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
url() { printf 'https://github.com/MohZeh/darban-ovpn/releases/download/%s/get.sh' "$1"; }
one_line() { printf 'curl -fsSL %s | sudo bash' "$(url "$1")"; }
in_terminal() {
    # in_terminal <name> <shell command>: answers it from $LOG/<name>.keys in a real terminal.
    python3 tests/pty-drive.py --timeout 600 "$LOG/$1.keys" -- bash -c "$2" | tee "$LOG/$1.log"
}
new_install() {
    cat > "$LOG/new.keys" <<'EOF'
Server address => 127.0.0.1\r
VPN port [1194] => \r
Enter: Install now => \r
Your VPN server is ready
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

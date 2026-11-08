#!/usr/bin/env bash
# Installs or updates Darban OVPN from a published release, after verifying it.
#
#   sudo bash -c 'curl -fsSL https://github.com/MohZeh/Darban-OVPN/releases/latest/download/get.sh | bash'
#   sudo bash -c 'curl ... | bash -s -- --version vX.Y.Z'
#   sudo bash -c 'curl ... | bash -s -- --yes --host vpn.example.com --port 1194'
#
# curl runs inside sudo on purpose. With "curl ... | sudo bash", sudo reads the pipe and, on Ubuntu, runs the
# command in a terminal of its own, so the keys pressed never reach the questions.
#
# All the work starts from the last line, so a partial download cannot run half of this script.
# The checksum comes from the same release, so it catches a damaged download, not a compromised account.
set -Eeuo pipefail
umask 077
REPO=MohZeh/Darban-OVPN
ARCHIVE=darban-ovpn.tar.gz
SERVER_CONF=/etc/openvpn/server/server.conf
TOOL=/usr/local/sbin/darban
SETUP_RECORD=/etc/darban/.server-setup-started
INSTALL_RECORD=/usr/local/lib/darban/.installed
# The release this copy belongs to. scripts/build-release.sh fills it in; empty means the latest release.
RELEASE_TAG=''
USAGE='Usage: get.sh [--version vX.Y.Z] [--host NAME|IP] [--port N] [--subnet A.B.C.0] [--dns "IP [IP]"] [--split-tunnel] [--open-ufw] [--install-kernel] [--yes]'
tag=''
base=''
work=''
setup_args=()
given_args=()

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; }
version_is_newer() {
    # version_is_newer A B: true when A is newer. sort -V alone would put 1.0.0-rc.1 after 1.0.0.
    local a=$1 b=$2 base_a=${1%%-*} base_b=${2%%-*}
    [[ $a != "$b" ]] || return 1
    if [[ $base_a != "$base_b" ]]; then
        [[ $(printf '%s\n%s\n' "$base_a" "$base_b" | sort -V | tail -n 1) == "$base_a" ]]
        return
    fi
    # The same base: a final release is newer than any pre-release of it.
    if [[ $a == "$base_a" ]]; then return 0; fi
    if [[ $b == "$base_b" ]]; then return 1; fi
    [[ $(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1) == "$a" ]]
}
fetch() {
    local rc=0
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 120 -o "$work/$1" "$base/$1" || rc=$?
    (( rc == 0 )) && return 0
    # curl reports an HTTP error as 22: the server answered, and the file is not there.
    if (( rc == 22 )) && [[ -z $tag ]]; then
        die "No stable release is published yet. Choose a version from https://github.com/$REPO/releases and use: --version vX.Y.Z"
    fi
    if (( rc == 22 )); then die "Release $tag was not found: https://github.com/$REPO/releases"; fi
    die "Could not download $1 from $base. Check the internet connection of this server."
}
needs_server_setup() {
    # A setup that stopped half way continues; a server with the tool already installed is never touched.
    [[ -e $SERVER_CONF ]] || return 0
    [[ -e $SETUP_RECORD && ! -e $TOOL ]] && ! grep -qx setup_complete "$SETUP_RECORD"
}
run_server_setup() {
    local script=$1
    [[ -f $script ]] || die 'The archive has no setup/server-setup.sh; nothing was installed.'
    if [[ -t 0 ]]; then
        bash "$script" "${setup_args[@]}"
    elif [[ " ${setup_args[*]} " == *' --yes '* ]]; then
        bash "$script" "${setup_args[@]}" </dev/null
    elif { : </dev/tty; } 2>/dev/null; then
        # Started from a pipe: the questions must read the terminal, not the rest of the pipe.
        bash "$script" "${setup_args[@]}" </dev/tty
    else
        die "There is no terminal to answer the setup questions. Connect with a normal SSH session, or give the answers: sudo bash -c 'curl ... | bash -s -- --yes --host YOUR_ADDRESS --port 1194'"
    fi
}
keys_cannot_reach_setup() {
    # keys_cannot_reach_setup PROC PID: true when PID runs under "curl ... | sudo bash" and that sudo gave it a
    # terminal of its own (use_pty, the Ubuntu default): sudo then reads the pipe and never passes on the keys,
    # so the first question would wait forever. Without use_pty both share one terminal, and the keys arrive.
    local proc=$1 pid=$2 top='' stat name own_tty='' top_tty=''
    local -a fields
    while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
        stat=$(cat "$proc/$pid/stat" 2>/dev/null) || return 1
        read -r -a fields <<<"${stat##*) }"
        [[ -n $own_tty ]] || own_tty=${fields[4]}
        name=$(cat "$proc/$pid/comm" 2>/dev/null) || name=''
        # The nearest sudo: with use_pty it runs as two processes, and the outer one holds the user's input.
        if [[ $name == sudo || $name == sudo-rs || $name == sudo.ws ]]; then
            top=$pid top_tty=${fields[4]}
        elif [[ -n $top ]]; then
            break
        fi
        pid=${fields[1]}
    done
    [[ -n $top && $(readlink "$proc/$top/fd/0" 2>/dev/null) == pipe:* && $top_tty != "$own_tty" ]]
}
right_command() {
    # The form that works, with this copy's own address and the options it was given.
    local url=https://github.com/$REPO/releases/latest/download/get.sh arg
    if [[ -n $RELEASE_TAG ]]; then url=https://github.com/$REPO/releases/download/$RELEASE_TAG/get.sh; fi
    for arg in "${given_args[@]}"; do
        [[ $arg =~ ^[A-Za-z0-9._:/=-]+$ ]] || { printf "sudo bash -c 'curl -fsSL %s | bash -s -- OPTIONS'\n" "$url"; return 0; }
    done
    if (( ${#given_args[@]} )); then
        printf "sudo bash -c 'curl -fsSL %s | bash -s -- %s'\n" "$url" "${given_args[*]}"
    else
        printf "sudo bash -c 'curl -fsSL %s | bash'\n" "$url"
    fi
}
welcome() {
    # The next steps of a new server, and the offer to create its first client.
    if [[ " ${setup_args[*]} " == *' --yes '* ]]; then
        "$TOOL" welcome </dev/null
    elif [[ -t 0 ]]; then
        "$TOOL" welcome
    elif { : </dev/tty; } 2>/dev/null; then
        "$TOOL" welcome </dev/tty
    else
        "$TOOL" welcome </dev/null
    fi
}
main() {
    local requested='' version installed='' expected new_server=0
    given_args=("$@")
    while (( $# )); do
        case $1 in
            --version) (( $# >= 2 )) || die "$USAGE"; requested=$2; shift 2 ;;
            --host|--port|--subnet|--dns) (( $# >= 2 )) || die "$USAGE"; setup_args+=("$1" "$2"); shift 2 ;;
            --split-tunnel|--open-ufw|--install-kernel|--yes) setup_args+=("$1"); shift ;;
            *) die "$USAGE" ;;
        esac
    done
    tag=${requested:-$RELEASE_TAG}
    if [[ -n $tag && ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then die "Not a release version: $tag"; fi
    [[ $EUID == 0 ]] || die 'Run with sudo/root.'
    local cmd
    for cmd in curl tar sha256sum mktemp grep sort; do
        command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
    done
    # Before anything is downloaded: a new server asks questions, and this form could never take the answers.
    if [[ ! -t 0 && " ${setup_args[*]} " != *' --yes '* ]] && needs_server_setup && keys_cannot_reach_setup /proc "$$"; then
        printf 'ERROR: Started as "curl ... | sudo bash", sudo keeps the keys you press from the setup questions. Nothing was installed. Run this instead:\n\n  %s\n' "$(right_command)" >&2
        exit 1
    fi
    if [[ -n $tag ]]; then
        base=https://github.com/$REPO/releases/download/$tag
    else
        base=https://github.com/$REPO/releases/latest/download
    fi

    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT

    printf 'Downloading %s...\n' "${tag:-the latest release}"
    fetch "$ARCHIVE"
    fetch SHA256SUMS
    # Exactly one line must describe the archive; nothing is unpacked or run before it matches.
    expected=$(grep -E "^[0-9a-f]{64}  $ARCHIVE\$" "$work/SHA256SUMS" || true)
    [[ -n $expected && $(wc -l <<<"$expected") == 1 ]] || die 'SHA256SUMS has no single entry for the archive; nothing was installed.'
    (cd "$work" && sha256sum --quiet -c - <<<"$expected") || die 'Checksum mismatch; nothing was installed.'
    printf 'Checksum verified.\n'

    mkdir "$work/release"
    tar --no-same-owner -xzf "$work/$ARCHIVE" -C "$work/release"
    [[ -f $work/release/setup/install.sh ]] || die 'The archive has no setup/install.sh; nothing was installed.'
    version=$(cat "$work/release/VERSION" 2>/dev/null || true)
    valid_version "$version" || die 'The archive does not state a valid version; nothing was installed.'

    if [[ -e $TOOL ]]; then installed=$("$TOOL" version 2>/dev/null || true); fi
    if ! valid_version "$installed"; then
        if [[ -e $TOOL ]]; then printf 'Updating Darban OVPN to v%s\n' "$version"; else printf 'Installing Darban OVPN v%s\n' "$version"; fi
    elif [[ $installed == "$version" ]]; then
        if [[ -n $requested ]]; then
            printf 'Installing Darban OVPN v%s again\n' "$version"
        elif [[ $(cat "$INSTALL_RECORD" 2>/dev/null) == "$version" ]]; then
            printf 'Darban OVPN v%s is already up to date. Nothing was changed.\n' "$installed"
            return 0
        else
            # The last install stopped before its end, so it is done again.
            printf 'Repairing the installation of Darban OVPN v%s\n' "$version"
        fi
    elif version_is_newer "$version" "$installed"; then
        printf 'Updating Darban OVPN from v%s to v%s\n' "$installed" "$version"
    else
        if [[ -z $requested ]]; then
            printf 'Darban OVPN v%s is newer than v%s. Nothing was changed. To go back to that version, use: --version v%s\n' "$installed" "$version" "$version"
            return 0
        fi
        printf 'Going back from Darban OVPN v%s to v%s\n' "$installed" "$version"
    fi

    if needs_server_setup; then
        run_server_setup "$work/release/setup/server-setup.sh"
        # A cancelled setup leaves no finished server, and the installer has nothing to manage.
        if needs_server_setup; then return 0; fi
        new_server=1
    fi
    bash "$work/release/setup/install.sh" </dev/null
    if (( new_server )); then welcome; fi
}
main "$@"

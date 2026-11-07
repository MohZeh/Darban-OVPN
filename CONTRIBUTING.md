# Contributing

Bug reports and focused improvements are welcome. For a larger change, please open an issue first, so we can agree on the approach.

## Project layout

```text
bin/       the darban menu and the CRL maintainer
lib/       shared checks, terminal interface, link service
setup/     get.sh, server-setup.sh, install.sh, uninstall.sh, remove-server.sh
systemd/   units for CRL renewal and temporary links
scripts/   release build
tests/     automated tests
docs/      guides in English and Persian
```

## Running the tests

On Linux, from the repository root. These use only a temporary directory and synthetic data:

```bash
bash tests/run-tests.sh
python3 tests/run-tty-tests.py
```

Pass part of a test name to run a subset: `bash tests/run-tests.sh temporary_link`.

`tests/acceptance-ci.sh` **reconfigures the machine it runs on**. Use it only on a disposable Ubuntu 24.04 or 26.04 machine. `tests/release-smoke.sh` does the same with a published release, and `tests/vm-reboot.sh` runs inside a virtual machine and needs KVM.

## Before opening a pull request

- Add a test that fails without your change.
- Run `bash scripts/lint.sh`. It needs [ShellCheck](https://www.shellcheck.net/) and checks scripts, file modes and documentation links.
- Update the guides in both `docs/en` and `docs/fa`, and `CHANGELOG.md`, when behavior changes.
- Keep a pull request to one purpose.
- Never include real keys, profiles, addresses or tokens, including in test data.

## Design rules

- **Fail closed.** If a check cannot run, treat the result as a failure.
- **Tell the truth.** Never report success, or "nothing changed", without knowing it.
- **Ask before changing a server, and keep a way back.** The safe answer is always the default.
- **Add no dependency without a clear need.** Install it only when it is used.

## Commit messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/): `fix: keep revoked serials when republishing the CRL`.

## Releases

Set the same version in `VERSION` and `DARBAN_VERSION` in `bin/darban`, add its section to `CHANGELOG.md`, and push a tag such as `v1.2.0` or `v1.2.0-rc.1`. The workflow tests the code and publishes the release. A tag with a suffix becomes a pre-release, which is never offered as an update.

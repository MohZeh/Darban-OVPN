# Contributing

Bug reports and focused improvements are welcome. For a larger change, please open an issue first, so we can agree on the approach.

## Project layout

```text
bin/       the darban menu and the CRL maintainer
lib/       shared checks, terminal interface, link service
lib/darban/  the parts of the darban menu: paths.sh, backup.sh, restore.sh
setup/     get.sh, server-setup.sh, install.sh, uninstall.sh, remove-server.sh
systemd/   units for CRL renewal and temporary links
scripts/   release build
tests/     automated tests
docs/      guides in English and Persian
```

`bin/darban` keeps only its version, the help and the reading of its arguments. It sources its parts in `lib/darban/` in one fixed order, `paths.sh` first and `config.sh` second, then the other parts, then its screens in `lib/darban/screens/`, by absolute path: `setup/install.sh` places them in `/usr/local/lib/darban/modules/`, before `bin/darban` itself, and the release archive carries them. The tests source a copy of `paths.sh` whose paths point into a fake server. Each function is defined in one file only. Outside a function, only `paths.sh` and `config.sh` assign globals, and `bin/darban` only `DARBAN_VERSION`; every other module only defines functions. `scripts/check-modules.py` checks all of this in Lint, and for a pull request titled `refactor:` it also checks that the set of functions stays the same.

## Running the tests

On Linux, from the repository root. These use only a temporary directory and synthetic data:

```bash
bash tests/run-tests.sh
python3 tests/run-tty-tests.py
```

Pass part of a test name to run a subset: `bash tests/run-tests.sh temporary_link`. `DARBAN_TEST_PART=2/4` runs the second of four parts of the suite, as CI does on four runners side by side.

`tests/acceptance-ci.sh` **reconfigures the machine it runs on**. Use it only on a disposable Ubuntu 24.04 or 26.04 machine. After the install it runs two parts; `1` or `2` after `--i-know` runs only one, as CI does on two runners. `tests/release-smoke.sh` does the same with a published release, and `tests/vm-reboot.sh` runs inside a virtual machine and needs KVM. `tests/scale-ci.sh` also reconfigures its machine: after a real setup it fills the CA with fake clients and writes how long the everyday commands take to the CI summary. CI runs it weekly, and on a pull request with the label `scale`, from its next push.

## Before opening a pull request

- Add a test that fails without your change.
- Run `bash scripts/lint.sh`. It needs [ShellCheck](https://www.shellcheck.net/) and checks scripts, file modes and documentation links.
- Update the guides in both `docs/en` and `docs/fa`, and `CHANGELOG.md`, when behavior changes.
- Keep a pull request to one purpose.
- A draft pull request runs Lint and the unit tests, and has no **CI result**, only "Draft result: Lint and unit tests", so it cannot merge. The acceptance and other slow tests start when it is marked ready for review.
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

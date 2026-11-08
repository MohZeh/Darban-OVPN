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

### What to run locally, and what CI runs

Run locally what gives a fast answer about your change. Leave the full suites to CI: it is the reference, and it covers more than one machine can.

| Where | What | When |
|---|---|---|
| Your machine | `bash scripts/lint.sh`, and the tests for the part you changed | While working, before each push |
| CI, on every pull request and every push to `main` | Lint, both test suites on Ubuntu 24.04 and 26.04, and the real install with real VPN traffic on both | Always, unless only documentation changed |
| CI, weekly and on release tags | A reboot in a virtual machine on both versions | Automatically |
| Release workflow | All of the above, then publishing, checking the published files, and the one-line install from them | On a version tag |

A change that touches only `*.md` files, `docs/` or `LICENSE` skips the slow jobs. Lint still runs.

When a test passes locally but fails in CI, reproduce the CI conditions locally before pushing a fix. For example, a release run sets `GITHUB_REF` to the tag, and tests must not depend on such variables from their environment.

`tests/acceptance-ci.sh` **reconfigures the machine it runs on**. Use it only on a disposable Ubuntu 24.04 or 26.04 machine. `tests/release-smoke.sh` does the same with a published release, and `tests/vm-reboot.sh` runs inside a virtual machine and needs KVM.

## Working with GitHub

- **`main` is always releasable.** Every change reaches it through a pull request, and only after the `CI result` check passes. Nobody pushes to `main` directly, and nobody force-pushes it.
- **One branch per purpose**, named for it: `fix/crl-shrink`, `docs/sharing-password`, `ci/reboot-test`.
- **A pull request is merged when** CI is green, the checklist is done, and the description says how the change was tested.
- **Keep the history readable.** Squash a pull request into one Conventional Commit when it is one change; keep separate commits only when each one stands on its own.
- **Never rewrite published history.** A pushed commit on `main` is fixed by a new commit, not by changing the old one.
- **Security problems** go through [private reporting](SECURITY.md), never an issue or pull request.

## Before opening a pull request

- Add a test that fails without your change.
- Run `bash scripts/lint.sh`. It needs [ShellCheck](https://www.shellcheck.net/) and checks scripts, file modes and documentation links.
- Run the tests for the part you changed. CI runs the rest.
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

- **Tag only a commit on `main` whose CI is green.** The workflow refuses a tag that is not on `main` or does not match `VERSION`.
- **Every release starts as a pre-release.** A stable version becomes the latest release only after the one-line install from its published files passes.
- **If the workflow fails before publishing,** nothing was released: fix the cause on `main`, then move the tag to the fixed commit and push it again.
- **Once a release is published, its tag never moves and is never deleted.** A problem in it is fixed by a new version.

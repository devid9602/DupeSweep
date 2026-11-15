# Contributing to DupeSweep

Thank you for helping. This page explains how changes get into DupeSweep.

## How changes are accepted

- `main` (released code) and `develop` are protected. **Nobody can push to them directly**, including maintainers.
- Every change goes through a **pull request**, which needs:
  - all automated checks to pass: tests on Windows, macOS and Linux, the dependency vulnerability audit,
    CodeQL code scanning and dependency review;
  - an approving review from the code owner (@devid9602). A new push dismisses earlier approvals;
  - every review conversation resolved.
- Pull requests are merged with **squash merge**, so `main` keeps a clean, linear history.
- Release tags (`v*`) can only be created by the owner.

## Making a change

1. **Fork** the repository and create a branch from `main` (for example `fix/heic-orientation`).
2. Set up the project:
   ```bash
   python -m pip install --require-hashes -r requirements-dev.lock   # Python 3.12
   python -m pytest -q
   ```
3. Keep the change focused. Add or update tests, especially for anything that moves or deletes files.
4. Open a pull request against `main` and fill in the template.

### Rules that keep users' photos safe

- Never add code that deletes, moves or overwrites user files without an explicit confirmation step, and make sure
  Safe Mode blocks it.
- Never make network connections. DupeSweep is fully offline.
- Detection changes must keep every test in `tests/test_engine.py` passing, including the look-alike tests that guard
  against false positives.

## Dependencies

Version ranges live in `requirements*.txt`. CI and release builds install the exact, hash-checked versions in
`requirements*.lock`. To change a dependency:

1. Edit the range in `requirements.txt`, `requirements-build.txt` or `requirements-dev.txt`.
2. Regenerate the locks with `./tools/update_locks.sh` (needs `python -m pip install uv`).
3. Commit both files. The dependency review and audit checks run on your pull request.

The Mac builds must keep running on **macOS 12 Monterey**. The release build checks this and fails if a dependency
needs a newer macOS.

## GitHub Actions

- Pin every action to a full commit SHA, with the version in a comment.
- Give each job only the permissions it needs. The default token is read-only.
- Never use `pull_request_target`, and never put `${{ }}` expressions directly inside `run:` scripts. Pass them
  through `env:` instead.

## Licensing of contributions

By submitting a pull request, you confirm that you wrote the change (or have the right to submit it) and agree that
it is released under this project's licence ([LICENSE](LICENSE)).

## Reporting security problems

Please don't open public issues for security problems. See [SECURITY.md](SECURITY.md).

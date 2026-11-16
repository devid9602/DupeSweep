# Security policy

DupeSweep works directly on people's photo collections, so security and data safety come first.

## Supported versions

| Version | Supported |
|---|---|
| Latest release | Yes – security fixes are released as a new version |
| Older releases | No – please update to the latest release |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub instead:
**[Report a vulnerability](https://github.com/devid9602/DupeSweep/security/advisories/new)**
(Security tab → *Report a vulnerability*).

Please include what you found, how to reproduce it, the affected version and operating system, and the impact you
expect (for example, a file could be deleted or moved without confirmation).

What to expect:
- an acknowledgement within 7 days;
- an assessment and, if confirmed, a fix plan within 30 days;
- credit in the release notes if you'd like it.

## What counts as a security issue

- Any way files could be moved, deleted or overwritten without the user's explicit confirmation, or while Safe Mode is on.
- Code execution through a crafted image file or folder name.
- Tampering with the release builds or the build pipeline.
- Leaks of data outside the user's computer (DupeSweep makes no network connections).

## How releases are protected

- Release files are built only by GitHub Actions from a version tag on `main`. Only the owner can create those tags, and
  publishing needs the owner's approval.
- Every dependency is installed at an exact version with a SHA-256 hash check.
- Each release includes `SHA256SUMS.txt` and a signed build provenance attestation. You can check that a download was
  built by this repository with the [GitHub CLI](https://cli.github.com/):

  ```
  gh attestation verify DupeSweep-Windows-x64.zip --repo devid9602/DupeSweep
  ```

# Changelog

All notable changes to DupeSweep are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [1.0.1] – 2026-11-15

### Fixed
- **The Mac downloads now run on macOS 12 Monterey and later.** The 1.0.0 Mac builds bundled libraries that needed
  macOS 14–15. Every release build now checks this and fails if any part needs a newer macOS.
- The Windows test run failed because of a path separator in the test generator. The app itself was unaffected.

### Security
- Dependencies are installed at exact versions with SHA-256 hash checks (`requirements*.lock`).
- GitHub Actions are pinned to commit SHAs, and every job runs with least-privilege permissions.
- Releases include `SHA256SUMS.txt` and signed build provenance. Publishing needs the owner's approval, and only
  happens for tags on `main`.
- Added CodeQL code scanning, dependency review, a weekly dependency vulnerability audit, OpenSSF Scorecard and
  Dependabot.
- Added a security policy, contribution guide, code owners, and issue and pull request templates.

## [1.0.0] – 2026-11-15

First public release: detection of exact duplicates and edited versions (resized, re-compressed, converted,
colour-edited, cropped, rotated), recommended originals, Safe Mode, quarantine with restore, CSV report, and
builds for Windows, macOS and Linux.

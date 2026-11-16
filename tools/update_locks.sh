#!/usr/bin/env bash
# Regenerates the hash-locked dependency files for every OS (Windows, macOS, Linux) and Python 3.12.
# Requires uv:  python -m pip install uv
set -euo pipefail
cd "$(dirname "$0")/.."
common=(--universal --python-version 3.12 --generate-hashes --quiet)
uv pip compile "${common[@]}" requirements.txt -o requirements.lock
uv pip compile "${common[@]}" requirements-build.txt -o requirements-build.lock
uv pip compile "${common[@]}" requirements-dev.txt -o requirements-dev.lock
echo "Updated requirements.lock, requirements-build.lock, requirements-dev.lock"

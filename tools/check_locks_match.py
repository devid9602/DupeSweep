"""Fails if a pinned version in a lock file doesn't satisfy the ranges in the matching requirements file.

Usage: python tools/check_locks_match.py
Catches a range bump (for example from Dependabot) that contradicts the locks, before the locks are regenerated.
"""
import re
import sys

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

PAIRS = [("requirements.txt", "requirements.lock"), ("requirements-build.txt", "requirements-build.lock"),
         ("requirements-dev.txt", "requirements-dev.lock")]
PLATFORMS = {
    "macOS Intel": {"sys_platform": "darwin", "platform_machine": "x86_64", "platform_system": "Darwin", "os_name": "posix"},
    "macOS Apple Silicon": {"sys_platform": "darwin", "platform_machine": "arm64", "platform_system": "Darwin", "os_name": "posix"},
    "Windows": {"sys_platform": "win32", "platform_machine": "AMD64", "platform_system": "Windows", "os_name": "nt"},
    "Linux": {"sys_platform": "linux", "platform_machine": "x86_64", "platform_system": "Linux", "os_name": "posix"},
}
PIN = re.compile(r"^([A-Za-z0-9_.\-]+)==([^\s;\\]+)(?:\s*;\s*(.+?))?\s*\\?$")


def requirements(path):
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#")[0].strip()
        if line.startswith("-r "):
            out += requirements(line.split()[1])
        elif line and not line.startswith("-"):
            out.append(Requirement(line))
    return out


def main():
    problems = []
    for src, lock in PAIRS:
        pins = {}
        for line in open(lock, encoding="utf-8"):
            m = PIN.match(line.strip())
            if m:
                pins.setdefault(canonicalize_name(m.group(1)), []).append((m.group(2), m.group(3)))
        for req in requirements(src):
            for platform, env in PLATFORMS.items():
                env = {"python_version": "3.12", "python_full_version": "3.12.8", "implementation_name": "cpython", **env}
                if req.marker and not req.marker.evaluate(env):
                    continue
                versions = [v for v, mk in pins.get(canonicalize_name(req.name), [])
                            if mk is None or Requirement("x; " + mk).marker.evaluate(env)]
                if not any(req.specifier.contains(v, prereleases=True) for v in versions):
                    problems.append(f"  {lock} ({platform}): {src} asks for '{req}', lock has {versions or 'nothing'}")
    if problems:
        print("Version ranges and lock files disagree:\n" + "\n".join(problems))
        print("Fix the range, or regenerate the locks with tools/update_locks.sh and check the result.")
        sys.exit(1)
    print("OK – every lock file satisfies its requirement ranges on all platforms.")


if __name__ == "__main__":
    main()

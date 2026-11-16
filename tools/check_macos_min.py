"""Fails if any compiled file inside a macOS app needs a newer macOS than the supported minimum.

Usage: python tools/check_macos_min.py dist/DupeSweep.app 12.0
A wheel's file name doesn't guarantee the libraries inside it, so the finished app itself is checked.
"""
import os
import sys

from macholib.mach_o import LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX
from macholib.MachO import MachO

MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"}


def min_versions(path):
    try:
        with open(path, "rb") as f:
            if f.read(4) not in MAGICS:
                return []
        headers = MachO(path).headers
    except Exception:
        return []
    out = []
    for h in headers:
        for lc, cmd, _ in h.commands:
            if lc.cmd == LC_BUILD_VERSION:
                out.append(cmd.minos)
            elif lc.cmd == LC_VERSION_MIN_MACOSX:
                out.append(cmd.version)
    return out


def main():
    app, limit = sys.argv[1], sys.argv[2]
    major, minor = (int(x) for x in limit.split("."))
    allowed = (major << 16) | (minor << 8)
    checked, bad = 0, []
    for root, _, files in os.walk(app):
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            for v in min_versions(path):
                checked += 1
                if v > allowed:
                    bad.append(f"  needs macOS {v >> 16}.{(v >> 8) & 0xFF}: {os.path.relpath(path, app)}")
    print(f"Checked {checked} compiled files in {app} against macOS {limit}.")
    if bad:
        print("These files need a newer macOS than supported:\n" + "\n".join(sorted(set(bad))))
        sys.exit(1)
    if checked == 0:
        print("No compiled files found – is the path right?")
        sys.exit(1)
    print("OK – every file runs on macOS", limit)


if __name__ == "__main__":
    main()

"""Runs the real window headless: scan, Safe Mode, confirm dialog, quarantine, restore."""
import os
import subprocess
import sys

import pytest

pytest.importorskip("PySide6")


def test_window_end_to_end(library, tmp_path):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", PYTHONPATH=os.pathsep.join([os.getcwd(), os.environ.get("PYTHONPATH", "")]))
    r = subprocess.run([sys.executable, os.path.join("tests", "gui_smoke.py"), os.path.join(library, "library"), str(tmp_path)],
                       env=env, capture_output=True, text=True, timeout=900)
    assert r.returncode == 0 and "ALL GUI CHECKS PASSED" in r.stdout, r.stdout[-3000:] + r.stderr[-3000:]

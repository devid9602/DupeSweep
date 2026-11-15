"""Small JSON settings file (detection settings, Safe Mode, quarantine folder, last folders)."""
from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict

from .matcher import Settings


def config_path() -> str:
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~\\AppData\\Roaming")
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "DupeSweep", "settings.json")


class Config:
    def __init__(self, path: str | None = None):
        self.path = path or config_path()
        self.settings = Settings()
        self.safe_mode = True
        self.quarantine_root: str | None = None
        self.folders: list = []            # [path, recursive]
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
            known = {k: v for k, v in d.get("settings", {}).items() if k in asdict(self.settings)}
            self.settings = Settings(**known)
            self.safe_mode = bool(d.get("safe_mode", True))
            self.quarantine_root = d.get("quarantine_root")
            self.folders = [f for f in d.get("folders", []) if isinstance(f, list) and len(f) == 2 and os.path.isdir(f[0])]
        except (OSError, ValueError, TypeError):
            pass

    def save(self) -> None:
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump({"settings": asdict(self.settings), "safe_mode": self.safe_mode,
                           "quarantine_root": self.quarantine_root, "folders": self.folders}, f, indent=1)
        except OSError:
            pass

"""Quarantine: move files out of the library (keeping their folder structure) and back again."""
from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import uuid
from dataclasses import dataclass, asdict
from typing import Iterable, List, Optional, Sequence, Tuple


@dataclass
class Item:
    id: str
    original_path: str
    quarantined_path: str
    kept_original: Optional[str]
    date: str
    size: int


def default_root() -> str:
    pictures = os.path.join(os.path.expanduser("~"), "Pictures")
    return os.path.join(pictures if os.path.isdir(pictures) else os.path.expanduser("~"), "DupeSweep Quarantine")


def unique_path(path: str, suffix: str = "") -> str:
    """A path that doesn't exist yet: name, 'name<suffix>', 'name<suffix> 2', …"""
    base, ext = os.path.splitext(path)
    n = 1
    while True:
        cand = f"{base}{suffix}{'' if n == 1 else f' {n}'}{ext}"
        if not os.path.exists(cand):
            return cand
        n += 1


class QuarantineStore:
    MANIFEST = "quarantine-manifest.json"

    def __init__(self, root: Optional[str] = None):
        self.root = os.path.abspath(root or default_root())
        self.items: List[Item] = []
        self.load()

    def set_root(self, root: str) -> None:
        self.root = os.path.abspath(root)
        self.load()

    def load(self) -> None:
        try:
            with open(os.path.join(self.root, self.MANIFEST), encoding="utf-8") as f:
                self.items = [Item(**d) for d in json.load(f)]
        except (OSError, ValueError, TypeError):
            self.items = []
        self.items = [i for i in self.items if os.path.exists(i.quarantined_path)]

    def _save(self) -> None:
        os.makedirs(self.root, exist_ok=True)
        tmp = os.path.join(self.root, self.MANIFEST + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump([asdict(i) for i in self.items], f, indent=1, ensure_ascii=False)
        os.replace(tmp, os.path.join(self.root, self.MANIFEST))

    @staticmethod
    def _relative(path: str) -> str:
        drive, tail = os.path.splitdrive(os.path.abspath(path))
        parts = [p for p in tail.replace("\\", "/").split("/") if p]
        if drive:
            parts.insert(0, drive.replace(":", "").replace("\\", "_").replace("/", "_").strip("_") or "drive")
        return os.path.join(*parts)

    def quarantine(self, files: Sequence[Tuple[str, int, Optional[str]]]):
        """files: (path, size, kept original path). Returns (moved items, failure messages)."""
        batch = os.path.join(self.root, dt.datetime.now().strftime("%Y-%m-%d %H.%M.%S"))
        moved, failures = [], []
        for path, size, kept in files:
            if kept and not os.path.exists(kept):
                failures.append(f"{path}: its original is missing – skipped for safety")
                continue
            if kept and os.path.exists(path) and os.path.samefile(path, kept):
                failures.append(f"{path}: is the original itself – skipped")
                continue
            dest = os.path.join(batch, self._relative(path))
            try:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if os.path.exists(dest):
                    dest = unique_path(dest)
                shutil.move(path, dest)
                moved.append(Item(uuid.uuid4().hex, os.path.abspath(path), dest, kept,
                                  dt.datetime.now().isoformat(timespec="seconds"), size))
            except OSError as e:
                failures.append(f"{path}: {e}")
        self.items.extend(moved)
        self._save()
        return moved, failures

    def restore(self, ids: Iterable[str]):
        """Moves quarantined files back. Never overwrites: a taken name gets ' (restored)' appended."""
        ids = set(ids)
        restored, failures, remaining = [], [], []
        for item in self.items:
            if item.id not in ids:
                remaining.append(item)
                continue
            dest = item.original_path
            try:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if os.path.exists(dest):
                    dest = unique_path(dest, " (restored)")
                shutil.move(item.quarantined_path, dest)
                restored.append(dest)
            except OSError as e:
                failures.append(f"{item.original_path}: {e}")
                remaining.append(item)
        self.items = remaining
        self._clean()
        self._save()
        return restored, failures

    def delete_permanently(self, ids: Iterable[str]):
        ids = set(ids)
        deleted, failures, remaining = 0, [], []
        for item in self.items:
            if item.id not in ids:
                remaining.append(item)
                continue
            try:
                os.remove(item.quarantined_path)
                deleted += 1
            except OSError as e:
                failures.append(f"{item.original_path}: {e}")
                remaining.append(item)
        self.items = remaining
        self._clean()
        self._save()
        return deleted, failures

    def _clean(self) -> None:
        for dirpath, dirnames, filenames in os.walk(self.root, topdown=False):
            if dirpath == self.root:
                continue
            if not [f for f in os.listdir(dirpath) if f != ".DS_Store"]:
                shutil.rmtree(dirpath, ignore_errors=True)

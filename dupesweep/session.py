"""Scan results plus the user's choices. No GUI code here, so every safety rule can be tested directly."""
from __future__ import annotations

import csv
import datetime as dt
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

from . import grouping
from .engine import Report, auto_marks
from .grouping import Group, ImageInfo
from .quarantine import QuarantineStore

RULES = ["Recommended (best quality)", "Highest resolution", "Oldest file", "Newest file",
         "Largest file size", "Shortest path", "Inside preferred folder"]
FILTERS = ["All groups", "Needs review", "Confirmed duplicates", "Across folders"]


class SafeModeError(RuntimeError):
    """Raised when an action that moves or deletes files is attempted while Safe Mode is on."""


@dataclass
class UIGroup:
    group: Group
    marked: Set[int] = field(default_factory=set)
    override: bool = False

    @property
    def original(self) -> int:
        return self.group.original


class Session:
    def __init__(self, quarantine: Optional[QuarantineStore] = None, safe_mode: bool = True):
        self.quarantine = quarantine or QuarantineStore()
        self.safe_mode = safe_mode
        self.images: List[ImageInfo] = []
        self.groups: List[UIGroup] = []
        self.folders: List[Tuple[str, int, int]] = []
        self.relabeler = None
        self.stats = None
        self.removed: Set[str] = set()

    # -- loading -------------------------------------------------------------
    def load(self, report: Report) -> None:
        self.images, self.stats, self.relabeler = report.images, report.stats, report.relabeler
        self.folders = list(report.folders)
        self.removed = set()
        self.groups = [UIGroup(g, auto_marks(g)) for g in report.groups]
        self._recount()

    def _recount(self) -> None:
        count: Dict[str, int] = {}
        dups: Dict[str, int] = {}
        for im in self.images:
            if im.path not in self.removed:
                count[im.folder] = count.get(im.folder, 0) + 1
        for g in self.groups:
            for m in g.group.members[1:]:
                f = self.images[m.index].folder
                dups[f] = dups.get(f, 0) + 1
        self.folders = [(f, count.get(f, 0), dups.get(f, 0)) for f, _, _ in self.folders]

    # -- queries --------------------------------------------------------------
    @property
    def marked_count(self) -> int:
        return sum(len(g.marked) for g in self.groups)

    @property
    def marked_bytes(self) -> int:
        return sum(self.images[i].size for g in self.groups for i in g.marked)

    def visible(self, flt: str = "All groups", search: str = "", folder: Optional[str] = None) -> List[UIGroup]:
        out = []
        q = search.lower().strip()
        for g in self.groups:
            labels = [m.label for m in g.group.members[1:]]
            if flt == "Needs review" and not (g.group.manual_review or grouping.POSSIBLE in labels):
                continue
            if flt == "Confirmed duplicates" and (g.group.manual_review or not any(l in grouping.CONFIRMED_LABELS for l in labels)):
                continue
            if flt == "Across folders" and g.group.scope == "Same folder":
                continue
            paths = [self.images[i].path for i in g.group.indices()]
            if q and not any(q in p.lower() for p in paths):
                continue
            if folder is not None and not any(os.path.dirname(p) == folder for p in paths):
                continue
            out.append(g)
        return out

    # -- choosing originals ----------------------------------------------------
    def _relabel(self, g: UIGroup, original: Optional[int]) -> None:
        forced = None if original is None or original == g.group.recommended else original
        g.group = self.relabeler.build_group(g.group.indices(), forced)
        g.override = forced is not None
        g.marked = auto_marks(g.group)

    def set_original(self, g: UIGroup, index: int) -> None:
        self._relabel(g, index)
        self._recount()

    def reset_original(self, g: UIGroup) -> None:
        self._relabel(g, None)
        self._recount()

    def apply_rule(self, rule: str, preferred_folder: Optional[str] = None) -> None:
        im = self.images

        def better(i):          # larger image, larger file, shorter path
            return (-im[i].meta.pixels, -im[i].size, len(im[i].path))

        for g in self.groups:
            idx = g.group.indices()
            if rule == RULES[0]:
                pick = None
            elif rule == "Highest resolution":
                pick = min(idx, key=better)
            elif rule == "Oldest file":
                pick = min(idx, key=lambda i: (im[i].mtime, better(i)))
            elif rule == "Newest file":
                pick = min(idx, key=lambda i: (-im[i].mtime, better(i)))
            elif rule == "Largest file size":
                pick = min(idx, key=lambda i: (-im[i].size, better(i)))
            elif rule == "Shortest path":
                pick = min(idx, key=lambda i: (len(im[i].path), better(i)))
            else:
                inside = [i for i in idx if preferred_folder and im[i].path.startswith(preferred_folder.rstrip("/\\") + os.sep)]
                pick = min(inside or idx, key=better)
            self._relabel(g, pick)
        self._recount()

    # -- selection ---------------------------------------------------------------
    def toggle(self, g: UIGroup, index: int) -> bool:
        if index == g.original:               # the original can never be selected
            return False
        g.marked ^= {index}
        return True

    def select_all(self, g: UIGroup) -> None:
        g.marked = {i for i in g.group.indices() if i != g.original}

    def clear(self, g: UIGroup) -> None:
        g.marked = set()

    def _confirmed(self, g: UIGroup):
        return [m.index for m in g.group.members[1:] if m.label in grouping.CONFIRMED_LABELS and m.confidence >= grouping.HIGH]

    def select_confirmed(self, folder: Optional[str] = None) -> None:
        for g in self.groups:
            for i in self._confirmed(g):
                if folder is None or self.images[i].folder == folder:
                    g.marked.add(i)

    def clear_all(self, folder: Optional[str] = None) -> None:
        for g in self.groups:
            g.marked = set() if folder is None else {i for i in g.marked if self.images[i].folder != folder}

    # -- actions -------------------------------------------------------------------
    def marked_files(self) -> List[Tuple[str, int, str]]:
        out = []
        for g in self.groups:
            kept = self.images[g.original].path
            out += [(self.images[i].path, self.images[i].size, kept) for i in sorted(g.marked) if i != g.original]
        return out

    def _require_unsafe(self) -> None:
        if self.safe_mode:
            raise SafeModeError("Safe Mode is on – no files were moved or deleted.")

    def quarantine_marked(self):
        self._require_unsafe()
        moved, failures = self.quarantine.quarantine(self.marked_files())
        self._drop({m.original_path for m in moved})
        return moved, failures

    def trash_marked(self):
        self._require_unsafe()
        from send2trash import send2trash
        done, failures = set(), []
        for path, _, kept in self.marked_files():
            if not os.path.exists(kept):
                failures.append(f"{path}: its original is missing – skipped for safety")
                continue
            try:
                send2trash(path)
                done.add(path)
            except Exception as e:      # noqa: BLE001 - report any failure to the user
                failures.append(f"{path}: {e}")
        self._drop(done)
        return sorted(done), failures

    def restore(self, ids):
        return self.quarantine.restore(ids)          # restoring is always safe

    def delete_permanently(self, ids):
        self._require_unsafe()
        return self.quarantine.delete_permanently(ids)

    def _drop(self, paths: Set[str]) -> None:
        if not paths:
            return
        paths = {os.path.abspath(p) for p in paths}
        self.removed |= paths
        kept: List[UIGroup] = []
        for g in self.groups:
            remaining = [i for i in g.group.indices() if os.path.abspath(self.images[i].path) not in paths]
            if len(remaining) == len(g.group.members):
                kept.append(g)
                continue
            if len(remaining) < 2:
                continue
            forced = g.original if (g.override and g.original in remaining) else None
            ng = UIGroup(self.relabeler.build_group(remaining, forced), set(), forced is not None)
            ng.marked = {i for i in g.marked if i in remaining and i != ng.original}
            kept.append(ng)
        self.groups = kept
        self._recount()

    # -- report ---------------------------------------------------------------------
    def export_csv(self, path: str) -> None:
        with open(path, "w", newline="", encoding="utf-8-sig") as f:      # BOM so Excel reads non-English paths
            w = csv.writer(f)
            w.writerow(["group", "group_status", "scope", "label", "action", "confidence", "similarity_pct",
                        "detection_method", "notes", "filename", "folder", "path", "format", "width", "height",
                        "size_bytes", "modified", "kept_original_path"])
            for n, g in enumerate(self.groups, 1):
                status = ("MANUAL REVIEW: " + (g.group.review_reason or "")) if g.group.manual_review else "OK"
                kept = self.images[g.original].path
                for m in g.group.members:
                    im = self.images[m.index]
                    action = "KEEP (original)" if m.index == g.original else ("SELECTED FOR REMOVAL" if m.index in g.marked else "KEEP")
                    w.writerow([n, status, g.group.scope, m.label, action, grouping.CONFIDENCE_NAMES[m.confidence],
                                round(m.similarity * 100), m.method, "; ".join(m.notes), im.name, im.folder, im.path,
                                im.meta.format, im.meta.width, im.meta.height, im.size,
                                dt.datetime.fromtimestamp(im.mtime).isoformat(timespec="seconds"), kept])

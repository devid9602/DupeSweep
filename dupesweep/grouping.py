"""Confidence rules, original-image selection and duplicate-group building."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

import numpy as np

from . import imaging, matcher
from .fingerprint import Fingerprint
from .imaging import Meta
from .matcher import PairMatch, Settings

NONE, LOW, MEDIUM, HIGH, EXACT = 0, 1, 2, 3, 4
CONFIDENCE_NAMES = {NONE: "None", LOW: "Low", MEDIUM: "Medium", HIGH: "High", EXACT: "Certain"}

ORIGINAL = "ORIGINAL"
EXACT_DUP = "EXACT DUPLICATE"
VISUAL = "VISUAL DUPLICATE"
EDITED = "EDITED VERSION"
POSSIBLE = "POSSIBLE MATCH"
CONFIRMED_LABELS = (EXACT_DUP, VISUAL, EDITED)
_ORDER = {ORIGINAL: 0, EXACT_DUP: 1, VISUAL: 2, EDITED: 3, POSSIBLE: 4}
_COPY_MARKERS = ("copy", "kopie", "(1)", "(2)", "(3)", "duplicate", "backup", " - ", "_edited", "-edited", "export")


@dataclass
class ImageInfo:
    index: int
    path: str
    size: int
    mtime: float
    meta: Meta = field(default_factory=Meta)
    sha: Optional[str] = None

    @property
    def name(self) -> str:
        return os.path.basename(self.path)

    @property
    def folder(self) -> str:
        return os.path.dirname(self.path)


@dataclass
class Member:
    index: int
    label: str
    confidence: int
    similarity: float
    method: str
    notes: List[str]


@dataclass
class Group:
    members: List[Member]            # members[0] is the original
    recommended: int                 # image index recommended by the engine
    manual_review: bool
    review_reason: Optional[str]
    scope: str                       # "Same folder" / "Nested subfolders" / "Across folders"
    reasons: List[str]

    @property
    def original(self) -> int:
        return self.members[0].index

    def indices(self) -> List[int]:
        return [m.index for m in self.members]


def confidence(m: PairMatch, a: Meta, b: Meta, s: Settings) -> Tuple[int, Optional[str]]:
    """How sure we are that two images are the same photograph, plus a note when evidence disagrees."""
    def passes(t):
        return m.score >= t and m.ssim >= t - 0.02 and m.p10 >= t - 0.42

    c = HIGH if passes(s.high) else MEDIUM if passes(s.medium) else LOW if passes(s.low) else NONE
    if c == NONE:
        return NONE, None
    note, meta_conflict = None, False
    if c == HIGH and m.coverage < 0.95 and m.score < s.high + 0.05:
        c, note = MEDIUM, "Only part of the frame matches – verify it is the same photograph"
    if c == HIGH and m.fine > s.max_fine:
        c, note = MEDIUM, "At full detail part of the picture differs (moved subject or a different moment) – verify"
    if c == HIGH and m.local > s.max_local:
        c, note = MEDIUM, "Part of the picture differs (moved subject or local edit) – verify"
    ta, tb = a.capture_seconds, b.capture_seconds
    if ta is not None and tb is not None:
        both_sub = bool(a.subsec and b.subsec)
        dt = abs(ta - tb)
        if (dt > 0.005) if both_sub else (dt >= 1):
            note, meta_conflict = "EXIF capture times differ – likely a different shot (burst or re-take)", True
        elif both_sub and c == MEDIUM and a.model == b.model and m.local <= s.max_local and m.fine <= s.max_fine:
            c = HIGH
    if not meta_conflict and a.model and b.model and a.model != b.model:
        note, meta_conflict = f"Taken with different cameras ({a.model} vs {b.model})", True
    if meta_conflict:
        c = MEDIUM if (c == HIGH and m.score >= 0.95) else min(c, LOW)
    if m.low_detail and not meta_conflict:
        same_capture = ta is not None and ta == tb
        if not same_capture and c > LOW:
            c, note = LOW, "Very little detail – can't confirm visually, please verify"
    return c, note


def _quality(m: Meta) -> float:
    if m.format in ("PNG", "TIFF", "BMP", "RAW"):
        return 1.0
    if m.format == "JPEG":
        return (m.jpeg_quality or 85) / 100
    return {"HEIC": 0.90, "AVIF": 0.85, "WEBP": 0.80, "GIF": 0.40}.get(m.format, 0.75)


class Relabeler:
    """Describes group members; re-labels a group when the user picks a different original."""

    def __init__(self, images: List[ImageInfo], rep_of: List[int], fingerprints: Dict[int, Fingerprint],
                 settings: Settings, pair_store=None, fine_source: Optional[Callable[[int], Optional[np.ndarray]]] = None):
        self.images, self.rep_of, self.fps, self.settings = images, rep_of, fingerprints, settings
        self.pair_store, self.fine_source = pair_store, fine_source
        self.matches: Dict[Tuple[int, int], PairMatch] = {}
        self.views: dict = {}
        self._fine: Dict[int, np.ndarray] = {}
        self.details = {k: matcher.detail(f) for k, f in fingerprints.items()}

    # -- pair access -------------------------------------------------------
    def low_detail(self, a: int, b: int) -> bool:
        return min(self.details.get(a, 1), self.details.get(b, 1)) < matcher.LOW_DETAIL

    def remember(self, a: int, b: int, m: PairMatch) -> None:
        m.low_detail = self.low_detail(a, b)
        self.matches[(a, b)] = m

    def _fine_image(self, i: int):
        g = self._fine.get(i)
        if g is None and self.fine_source is not None:
            g = self.fine_source(i)
            if g is not None:
                if len(self._fine) > 300:
                    self._fine.pop(next(iter(self._fine)))
                self._fine[i] = g
        return g

    def match(self, a: int, b: int) -> Optional[PairMatch]:
        """Alignment of representative `b` against reference `a` (computed on demand, cached)."""
        m = self.matches.get((a, b))
        if m is not None:
            return m
        if self.pair_store is not None:
            m = self.pair_store.get_pair(self.images[a], self.images[b])
            if m is not None:
                self.remember(a, b, m)
                return m
        fa, fb = self.fps.get(a), self.fps.get(b)
        if fa is None or fb is None:
            return None
        m = matcher.compare(fa, fb, self.settings, self.views, a, b)
        if m.refined and m.score >= self.settings.medium - 0.05:
            ga, gb = self._fine_image(a), self._fine_image(b)
            if ga is not None and gb is not None:
                m.fine = fine_check(ga, gb, m)
        self.remember(a, b, m)
        if self.pair_store is not None:
            self.pair_store.put_pair(self.images[a], self.images[b], m)
        return m

    def confidence(self, a: int, b: int):
        if a == b:
            return EXACT, None, None
        m = self.match(a, b)
        if m is None:
            return NONE, None, None
        c, note = confidence(m, self.images[a].meta, self.images[b].meta, self.settings)
        return c, m, note

    # -- original selection ------------------------------------------------
    def _is_cropped(self, rep: int, reps: List[int]) -> bool:
        s = self.settings
        for other in reps:
            if other == rep:
                continue
            m = self.matches.get((other, rep))
            if m and m.other_inside and m.coverage < 0.95 and m.score >= s.medium:
                return True
            m = self.matches.get((rep, other))
            if m and not m.other_inside and m.coverage < 0.95 and m.score >= s.medium:
                return True
        return False

    def choose_original(self, members: List[int]):
        """Scores every distinct version. Returns (index, manual_review, reason, reasons)."""
        im = self.images
        reps = sorted({self.rep_of[i] for i in members})
        max_px = max(1, max(im[r].meta.pixels for r in reps))
        max_sharp = max(1e-6, max((self.fps[r].stats[5] for r in reps if r in self.fps), default=1e-6))
        scored = []
        for r in reps:
            m = im[r].meta
            camera = 1.0 if m.has_camera_evidence else (0.5 if m.dto else 0.0)
            unedited = 0.0 if m.edited_by_software else 1.0
            if self._is_cropped(r, reps):
                unedited -= 0.5
            sharp = (self.fps[r].stats[5] if r in self.fps else 0.0) / max_sharp
            scored.append((0.40 * m.pixels / max_px + 0.20 * _quality(m) + 0.20 * camera + 0.15 * unedited + 0.05 * sharp, r))
        scored.sort(key=lambda t: (-t[0], im[t[1]].path))
        best = scored[0][1]
        copies = [i for i in members if self.rep_of[i] == best]

        def penalty(i):
            p = im[i].path.lower()
            return (sum(1 for k in _COPY_MARKERS if k in p), len(p.replace("\\", "/").split("/")), p)

        pick = min(copies, key=penalty)
        m = im[best].meta
        reasons = []
        if m.pixels >= max_px:
            reasons.append(f"highest resolution ({m.width}×{m.height})")
        if m.is_lossless:
            reasons.append(f"lossless {m.format}")
        elif m.jpeg_quality:
            reasons.append(f"JPEG quality ~{m.jpeg_quality}")
        if m.has_camera_evidence:
            reasons.append("original camera EXIF" + (f" ({m.model})" if m.model else ""))
        if not m.edited_by_software:
            reasons.append("no editing software recorded")
        review, why = False, None
        if len(scored) >= 2 and scored[0][0] - scored[1][0] < 0.05:
            review, why = True, f"Two versions are almost equally good: {im[scored[0][1]].name} and {im[scored[1][1]].name}"
        elif m.pixels < int(max_px * 0.98):
            big = next((r for r in reps if im[r].meta.pixels == max_px), best)
            review, why = True, f"A higher-resolution version ({im[big].name}) exists but looks edited or upscaled"
        return pick, review, why, reasons

    # -- describing --------------------------------------------------------
    def describe(self, o: int, i: int) -> Member:
        im = self.images
        ro, ri = self.rep_of[o], self.rep_of[i]
        img, orig = im[i], im[o]
        if i == o:
            return Member(i, ORIGINAL, EXACT, 1.0, "Recommended original", [])
        if ro == ri:
            notes = ["byte-for-byte identical"]
            if img.name != orig.name:
                notes.append("different filename")
            if img.folder != orig.folder:
                notes.append("different folder")
            return Member(i, EXACT_DUP, EXACT, 1.0, "SHA-256 identical", notes)
        c, m, conflict = self.confidence(ro, ri)
        if m is None:
            return Member(i, POSSIBLE, LOW, 0.0, "Not comparable", ["could not be compared"])
        notes, edited = [], False
        if m.quarter_turns:
            notes.append(f"rotated {m.quarter_turns * 90}°"); edited = True
        if abs(m.angle) >= 1:
            notes.append(f"tilted {abs(m.angle):.0f}°"); edited = True
        if m.coverage < 0.95:
            pct = round((1 - m.coverage) * 100)
            notes.append(f"cropped (~{pct}% removed)" if m.other_inside else f"shows ~{pct}% more of the scene than the original")
            edited = True
        fa, fb = self.fps.get(ro), self.fps.get(ri)
        if fa and fb:
            a, b = fa.stats, fb.stats
            if abs(b[0] - a[0]) > 0.03:
                notes.append("brighter" if b[0] > a[0] else "darker"); edited = True
            cr = b[1] / max(a[1], 1e-3)
            if cr > 1.08:
                notes.append("more contrast"); edited = True
            elif cr < 0.92:
                notes.append("less contrast"); edited = True
            shift = 0.0
            if m.coverage >= 0.9:
                ref, oth = (fa, fb) if m.other_inside else (fb, fa)
                rcb, rcr = ref.chroma_maps(0)
                ocb, ocr = oth.chroma_maps(m.quarter_turns if m.other_inside else (4 - m.quarter_turns) % 4)
                shift = float((np.abs(rcb - ocb) + np.abs(rcr - ocr)).mean())
            if a[4] > 0.02 and b[4] < a[4] * 0.3:
                notes.append("black & white"); edited = True
            elif shift > 0.025 or abs(b[2] - a[2]) > 0.015 or abs(b[3] - a[3]) > 0.015 or (a[4] > 0.01 and abs(b[4] / a[4] - 1) > 0.15):
                notes.append("colours changed / filter"); edited = True
        pr = img.meta.pixels / max(1, orig.meta.pixels)
        if pr < 0.95 and m.coverage >= 0.95:
            notes.append(f"resized to {round(pr ** 0.5 * 100)}%")
        if pr > 1.05:
            notes.append("larger than the original (upscaled?)")
        if img.meta.format != orig.meta.format:
            notes.append(f"converted {orig.meta.format} → {img.meta.format}")
        if img.meta.jpeg_quality and img.meta.jpeg_quality < (orig.meta.jpeg_quality or 100) - 10:
            notes.append(f"re-compressed (quality ~{img.meta.jpeg_quality})")
        if orig.meta.has_exif and not img.meta.has_exif:
            notes.append("metadata stripped")
        if img.meta.edited_by_software and img.meta.software:
            notes.append(f"exported by {img.meta.software}")
        if 0.01 < m.local <= self.settings.max_local:
            notes.append("small local differences"); edited = True
        if conflict:
            notes.append(conflict)
        method = f"pHash Δ{m.hash_distance} → aligned SSIM {round(m.ssim * 100)}%"
        if m.quarter_turns:
            method += " · rotation-invariant"
        if m.coverage < 0.95:
            method += " · crop search"
        if abs(m.angle) >= 1:
            method += " · angle search"
        label = (EDITED if edited else VISUAL) if c >= HIGH else POSSIBLE
        return Member(i, label, LOW if c == NONE else c, m.score, method, notes)

    def build_group(self, members: List[int], forced_original: Optional[int] = None) -> Group:
        pick, review, why, reasons = self.choose_original(members)
        o = pick if forced_original is None else forced_original
        described = [self.describe(o, i) for i in members]
        described.sort(key=lambda d: (_ORDER.get(d.label, 9), -d.similarity, self.images[d.index].path))
        if forced_original is not None and forced_original != pick:
            review, why = False, None
        if forced_original is None and len({self.rep_of[i] for i in members}) == 1:
            review, why = False, None            # only identical copies – any of them is the original
        return Group(described, pick, review, why, self.scope(members), reasons)

    def scope(self, members: List[int]) -> str:
        folders = sorted({self.images[i].folder for i in members}, key=len)
        if len(folders) <= 1:
            return "Same folder"
        top = folders[0].rstrip("/\\") + os.sep
        return "Nested subfolders" if all(f.startswith(top) for f in folders[1:]) else "Across folders"


def fine_check(ga: np.ndarray, gb: np.ndarray, m: PairMatch) -> float:
    rb = imaging.rotate(gb, m.quarter_turns)
    return matcher.fine_local_difference(ga, rb, m) if m.other_inside else matcher.fine_local_difference(rb, ga, m)


def build_groups(reps: List[int], copies: Dict[int, List[int]], edges: List[Tuple[int, int, int, float]], R: Relabeler) -> List[Group]:
    """Turns verified pair matches (a, b, confidence, score) into groups without chaining weak links."""
    parent = {r: r for r in reps}

    def find(x):
        r = x
        while parent[r] != r:
            r = parent[r]
        while parent[x] != r:
            parent[x], x = r, parent[x]
        return r

    for a, b, c, _ in edges:
        if c >= HIGH:
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[max(ra, rb)] = min(ra, rb)
    comps: Dict[int, List[int]] = {}
    for r in reps:
        comps.setdefault(find(r), []).append(r)

    def images_of(rs):
        return [i for r in rs for i in copies.get(r, [r])]

    groups: List[List[int]] = []
    free = set()
    # Star check: every member must match the chosen original directly.
    for _, comp in sorted(comps.items()):
        if len(comp) == 1:
            (groups.append(comp) if len(copies.get(comp[0], [])) > 1 else free.add(comp[0]))
            continue
        keep = comp
        for _ in range(2):
            orig = R.rep_of[R.choose_original(images_of(keep))[0]]
            verified = [r for r in keep if r == orig or R.confidence(orig, r)[0] >= MEDIUM]
            if len(verified) == len(keep):
                break
            free.update(r for r in keep if r not in verified)
            keep = verified
        if len(keep) == 1 and len(copies.get(keep[0], [])) <= 1:
            free.add(keep[0])
        else:
            groups.append(keep)

    neighbours: Dict[int, List[int]] = {}
    for a, b, c, _ in edges:
        if c >= LOW:
            neighbours.setdefault(a, []).append(b)
            neighbours.setdefault(b, []).append(a)

    def attach(cands):
        group_of = {r: gi for gi, g in enumerate(groups) for r in g}
        originals: Dict[int, int] = {}
        for f in sorted(cands):
            if f not in free:
                continue
            best = None
            for gi in {group_of[n] for n in neighbours.get(f, []) if n in group_of}:
                o = originals.get(gi)
                if o is None:
                    o = originals[gi] = R.rep_of[R.choose_original(images_of(groups[gi]))[0]]
                c, m, _ = R.confidence(o, f)
                if c >= LOW and m is not None and (best is None or m.score > best[1]):
                    best = (gi, m.score)
            if best:
                groups[best[0]].append(f)
                free.discard(f)
                group_of[f] = best[0]

    attach(list(free))
    loose = sorted((e for e in edges if e[2] >= LOW and e[0] in free and e[1] in free), key=lambda e: -e[3])
    for a, b, _, _ in loose:
        if a in free and b in free:
            groups.append([a, b])
            free.discard(a)
            free.discard(b)
    attach(list(free))

    out = [R.build_group(images_of(g)) for g in groups]
    out.sort(key=lambda g: (-len(g.members), R.images[g.recommended].path))
    return out

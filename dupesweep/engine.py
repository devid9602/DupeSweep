"""The five-stage scan pipeline: discovery → exact duplicates → fingerprints → validation → groups."""
from __future__ import annotations

import hashlib
import json
import multiprocessing as mp
import os
import sqlite3
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import fingerprint as fpmod
from . import grouping, imaging, matcher
from .fingerprint import Fingerprint
from .grouping import Group, ImageInfo, Relabeler
from .imaging import Meta
from .matcher import PairMatch, Settings

STAGES = ["", "Discovering files", "Finding exact duplicates", "Analysing images",
          "Comparing similar images", "Building duplicate groups"]
_SKIP_DIR_SUFFIXES = (".photoslibrary", ".app", ".bundle", ".framework", ".lrdata", ".aplibrary")
_SKIP_DIR_NAMES = {"$recycle.bin", "system volume information", "__macosx"}


# ---------------------------------------------------------------- control & progress

class Control:
    """Pause / resume / cancel, shared between the UI and the scan."""

    def __init__(self):
        self._run = threading.Event()
        self._run.set()
        self.cancelled = False
        self._paused_total = 0.0
        self._pause_start: Optional[float] = None

    def pause(self):
        if self._run.is_set():
            self._run.clear()
            self._pause_start = time.time()

    def resume(self):
        if not self._run.is_set():
            if self._pause_start:
                self._paused_total += time.time() - self._pause_start
            self._pause_start = None
            self._run.set()

    def cancel(self):
        self.cancelled = True
        self._run.set()

    @property
    def paused(self) -> bool:
        return not self._run.is_set()

    def checkpoint(self) -> bool:
        """Blocks while paused. False once cancelled."""
        self._run.wait()
        return not self.cancelled

    def active(self, since: float) -> float:
        p = self._paused_total + ((time.time() - self._pause_start) if self._pause_start else 0)
        return max(0.0, time.time() - since - p)


@dataclass
class Progress:
    stage: int = 0
    name: str = ""
    done: int = 0
    total: int = 0
    folder: str = ""
    folder_index: int = 0
    folder_count: int = 0
    elapsed: float = 0.0
    eta: Optional[float] = None
    paused: bool = False


@dataclass
class Stats:
    discovered: int = 0
    valid: int = 0
    skipped: List[Tuple[str, str]] = field(default_factory=list)
    cache_hits: int = 0
    exact_groups: int = 0
    pairs_screened: int = 0
    candidates: int = 0
    validated: int = 0
    stage_seconds: List[Tuple[str, float]] = field(default_factory=list)
    seconds: float = 0.0


@dataclass
class Report:
    images: List[ImageInfo]
    groups: List[Group]
    folders: List[Tuple[str, int, int]]          # (path, images, duplicates)
    stats: Stats
    cancelled: bool
    relabeler: Optional[Relabeler]


# ---------------------------------------------------------------- cache

def default_cache_path() -> str:
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Caches")
    else:
        base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "DupeSweep", "cache-v1.sqlite")


class Cache:
    """Remembers fingerprints and pair verdicts so unchanged files are never analysed twice."""

    def __init__(self, path: Optional[str]):
        self.path = path
        self._lock = threading.Lock()
        if path:
            os.makedirs(os.path.dirname(path), exist_ok=True)
        self.db = sqlite3.connect(path or ":memory:", check_same_thread=False)
        self.db.execute("CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER, mtime REAL, "
                        "meta TEXT, sha TEXT, fp BLOB, failed INTEGER, v INTEGER)")
        self.db.execute("CREATE TABLE IF NOT EXISTS pairs (a TEXT, b TEXT, s TEXT, data TEXT, PRIMARY KEY (a, b, s))")
        self.settings_key = ""

    def get_file(self, path: str, size: int, mtime: float):
        with self._lock:
            row = self.db.execute("SELECT size, mtime, meta, sha, fp, failed, v FROM files WHERE path=?", (path,)).fetchone()
        if not row or row[0] != size or abs(row[1] - mtime) > 0.001 or row[6] != fpmod.VERSION:
            return None
        meta = Meta(**json.loads(row[2])) if row[2] else None
        fp = Fingerprint.from_bytes(row[4]) if row[4] else None
        return {"meta": meta, "sha": row[3], "fp": fp, "failed": bool(row[5])}

    def put_file(self, path, size, mtime, meta: Optional[Meta], sha, fp: Optional[Fingerprint], failed: bool):
        with self._lock:
            self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?,?)",
                            (path, size, mtime, json.dumps(meta.to_dict()) if meta else None, sha,
                             fp.to_bytes() if fp else None, int(failed), fpmod.VERSION))

    @staticmethod
    def _key(img: ImageInfo) -> str:
        return hashlib.blake2b(f"{img.path}|{img.size}|{img.mtime:.3f}".encode("utf-8", "surrogatepass"), digest_size=10).hexdigest()

    def get_pair(self, a: ImageInfo, b: ImageInfo) -> Optional[PairMatch]:
        with self._lock:
            row = self.db.execute("SELECT data FROM pairs WHERE a=? AND b=? AND s=?", (self._key(a), self._key(b), self.settings_key)).fetchone()
        return PairMatch.from_list(json.loads(row[0])) if row else None

    def put_pair(self, a: ImageInfo, b: ImageInfo, m: PairMatch):
        with self._lock:
            self.db.execute("INSERT OR REPLACE INTO pairs VALUES (?,?,?,?)",
                            (self._key(a), self._key(b), self.settings_key, json.dumps([round(float(x), 5) for x in m.to_list()])))

    def commit(self):
        with self._lock:
            self.db.commit()

    def clear(self):
        with self._lock:
            self.db.execute("DELETE FROM files")
            self.db.execute("DELETE FROM pairs")
            self.db.commit()

    def close(self):
        with self._lock:
            self.db.commit()
            self.db.close()


# ---------------------------------------------------------------- worker functions (run in other processes)

_W: dict = {"settings": Settings(), "views": {}, "gray": {}}


def _init_worker(settings_dict: dict):
    _W["settings"] = Settings(**settings_dict)
    _W["views"], _W["gray"] = {}, {}


def sha256_file(path: str) -> Optional[str]:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def analyse_file(path: str):
    """Returns (meta dict | None, fingerprint bytes | None)."""
    meta = imaging.read_metadata(path)
    if meta is None:
        return None, None
    rgb = imaging.load_rgb(path)
    fp = fpmod.make(rgb) if rgb is not None else None
    return meta.to_dict(), (fp.to_bytes() if fp else None)


def _gray(path: str):
    g = _W["gray"].get(path)
    if g is None:
        g = imaging.load_gray(path)
        if g is not None:
            if len(_W["gray"]) > 48:
                _W["gray"].pop(next(iter(_W["gray"])))
            _W["gray"][path] = g
    return g


def compare_task(task):
    """(a, b, fpA bytes, fpB bytes, pathA, pathB) → (a, b, PairMatch list)."""
    a, b, fa, fb, pa, pb = task
    s: Settings = _W["settings"]
    if len(_W["views"]) > 1500:
        _W["views"].clear()
    A, B = Fingerprint.from_bytes(fa), Fingerprint.from_bytes(fb)
    m = matcher.compare(A, B, s, _W["views"], pa, pb)
    if m.refined and m.score >= s.medium - 0.05:
        ga, gb = _gray(pa), _gray(pb)
        if ga is not None and gb is not None:
            m.fine = grouping.fine_check(ga, gb, m)
    return a, b, m.to_list()


# ---------------------------------------------------------------- engine

class ScanEngine:
    def __init__(self, settings: Settings, cache: Optional[Cache] = None, workers: Optional[int] = None,
                 exclude: Sequence[str] = ()):
        self.settings = settings.normalised()
        self.cache = cache or Cache(None)
        self.cache.settings_key = self.settings.key()
        self.workers = workers if workers is not None else max(1, min(os.cpu_count() or 1, 8))
        self.exclude = [os.path.normcase(os.path.realpath(p)) for p in exclude]
        self._pool = None

    # -- parallel map with pause / cancel ---------------------------------
    def _map(self, func, items: list, control: Control, tick: Callable[[int], None]) -> Optional[list]:
        out: list = []
        if not items:
            return out
        use_pool = self.workers > 1 and len(items) >= 24
        if use_pool and self._pool is None:
            try:
                self._pool = mp.get_context("spawn").Pool(self.workers, initializer=_init_worker,
                                                          initargs=(self.settings.__dict__.copy(),))
            except Exception:
                self.workers, use_pool = 1, False
        if not use_pool:
            _W["settings"] = self.settings
        batch = max(1, self.workers * 6) if use_pool else 4
        for i in range(0, len(items), batch):
            if not control.checkpoint():
                return None
            part = items[i:i + batch]
            out.extend(self._pool.map(func, part, chunksize=max(1, len(part) // (self.workers * 2))) if use_pool
                       else [func(x) for x in part])
            tick(len(out))
        return out

    def _close_pool(self, terminate=False):
        if self._pool is not None:
            (self._pool.terminate if terminate else self._pool.close)()
            self._pool.join()
            self._pool = None

    # -- discovery -----------------------------------------------------------
    def _discover(self, roots, control, emit):
        seen, folders, found = set(), set(), []
        for root, recursive in roots:
            base = os.path.abspath(root)
            for dirpath, dirnames, filenames in os.walk(base):
                if control.cancelled:
                    break
                keep = []
                for d in sorted(dirnames):
                    full = os.path.normcase(os.path.realpath(os.path.join(dirpath, d)))
                    if (not recursive or d.startswith(".") or d.lower() in _SKIP_DIR_NAMES
                            or d.lower().endswith(_SKIP_DIR_SUFFIXES) or any(full == e or full.startswith(e + os.sep) for e in self.exclude)):
                        continue
                    keep.append(d)
                dirnames[:] = keep
                folders.add(dirpath)
                emit(len(found), dirpath)
                for name in filenames:
                    if name.startswith(".") or os.path.splitext(name)[1][1:].lower() not in imaging.IMAGE_EXTENSIONS:
                        continue
                    path = os.path.join(dirpath, name)
                    real = os.path.normcase(os.path.realpath(path))
                    if real in seen:
                        continue
                    try:
                        st = os.stat(path)
                    except OSError:
                        continue
                    if not os.path.isfile(path):
                        continue
                    seen.add(real)
                    found.append((path, st.st_size, st.st_mtime))
        found.sort(key=lambda f: (os.path.dirname(f[0]), os.path.basename(f[0])))
        return found, sorted(folders)

    # -- main ------------------------------------------------------------------
    def run(self, roots: Sequence[Tuple[str, bool]], control: Optional[Control] = None,
            on_progress: Optional[Callable[[Progress], None]] = None) -> Report:
        control = control or Control()
        try:
            return self._run(list(roots), control, on_progress or (lambda p: None))
        finally:
            self._close_pool(terminate=control.cancelled)
            self.cache.commit()

    def _run(self, roots, control, on_progress) -> Report:
        s = self.settings
        t0 = time.time()
        stats = Stats()
        state = {"stage": 0, "total": 0, "start": t0, "last": 0.0, "folder": "", "order": {}, "count": 0}

        def emit(done, folder=None, force=False):
            now = time.time()
            if not force and now - state["last"] < 0.1 and done < state["total"]:
                return
            state["last"] = now
            if folder is not None:
                state["folder"] = folder
            p = Progress(state["stage"], STAGES[state["stage"]], done, state["total"], state["folder"],
                         state["order"].get(state["folder"], 0), state["count"], control.active(t0), None, control.paused)
            active = control.active(state["start"])
            if done > 0 and p.total > done and active > 0.5:
                p.eta = active / done * (p.total - done)
            on_progress(p)

        def begin(stage, total):
            if state["stage"] and state["stage"] != stage:
                stats.stage_seconds.append((STAGES[state["stage"]], control.active(state["start"])))
            if state["stage"] != stage:
                state["start"] = time.time()
            state["stage"], state["total"] = stage, total
            emit(0, force=True)

        def partial(images=(), folders=()):
            stats.seconds = control.active(t0)
            return Report(list(images), [], [(f, 0, 0) for f in folders], stats, True, None)

        # Stage 1 – discovery
        begin(1, 0)
        found, folders = self._discover(roots, control, lambda n, f: emit(n, f))
        stats.discovered = len(found)
        state["order"] = {f: i + 1 for i, f in enumerate(folders)}
        state["count"] = len(folders)
        if control.cancelled:
            return partial(folders=folders)
        n = len(found)
        cached = [self.cache.get_file(*f) for f in found]
        stats.cache_hits = sum(1 for c in cached if c)

        # Stage 2 – exact duplicates (SHA-256 inside equal file sizes)
        by_size: Dict[int, List[int]] = {}
        for i, f in enumerate(found):
            by_size.setdefault(f[1], []).append(i)
        multi = [i for g in by_size.values() if len(g) > 1 for i in g]
        sha: Dict[int, Optional[str]] = {i: cached[i]["sha"] for i in multi if cached[i] and cached[i]["sha"]}
        need = [i for i in multi if i not in sha]
        begin(2, len(need))
        res = self._map(sha256_file, [found[i][0] for i in need], control,
                        lambda d: emit(d, os.path.dirname(found[need[min(d, len(need)) - 1]][0])))
        if res is None:
            return partial(folders=folders)
        for i, h in zip(need, res):
            sha[i] = h
        rep = list(range(n))
        first: Dict[str, int] = {}
        for i in multi:
            h = sha.get(i)
            if h:
                rep[i] = first.setdefault(h, i)

        # Stage 3 – metadata + fingerprint of every distinct file
        reps = [i for i in range(n) if rep[i] == i]
        metas: Dict[int, Optional[Meta]] = {}
        fps: Dict[int, Optional[Fingerprint]] = {}
        todo = []
        for i in reps:
            c = cached[i]
            if c and (c["failed"] or (c["meta"] and c["fp"])):
                metas[i], fps[i] = c["meta"], c["fp"]
            else:
                todo.append(i)
        begin(3, len(todo))
        res = self._map(analyse_file, [found[i][0] for i in todo], control,
                        lambda d: emit(d, os.path.dirname(found[todo[min(d, len(todo)) - 1]][0])))
        done_n = len(res) if res is not None else 0
        for i, r in zip(todo, res or []):
            metas[i] = Meta(**r[0]) if r[0] else None
            fps[i] = Fingerprint.from_bytes(r[1]) if r[1] else None
        for i in range(n):          # persist what we know (also after a cancel, so the next scan resumes)
            r = rep[i]
            unchanged = cached[i] is not None and cached[i]["sha"] == sha.get(i) and (i != r or i not in todo)
            if r in metas and not unchanged:
                self.cache.put_file(found[i][0], found[i][1], found[i][2], metas[r], sha.get(i), fps.get(r) if i == r else None,
                                    metas[r] is None)
        self.cache.commit()
        if res is None or done_n < len(todo):
            return partial(folders=folders)

        images: List[ImageInfo] = []
        new_index: Dict[int, int] = {}
        for i, (path, size, mtime) in enumerate(found):
            m = metas.get(rep[i])
            if m is None:
                stats.skipped.append((path, "unreadable or corrupted image"))
                continue
            new_index[i] = len(images)
            images.append(ImageInfo(len(images), path, size, mtime, m, sha.get(i)))
        stats.valid = len(images)
        rep_of = [0] * len(images)
        copies: Dict[int, List[int]] = {}
        for i, ni in new_index.items():
            rep_of[ni] = new_index[rep[i]]
            copies.setdefault(rep_of[ni], []).append(ni)
        rep_idx = sorted(copies)
        stats.exact_groups = sum(1 for c in copies.values() if len(c) > 1)
        fp_of: Dict[int, Fingerprint] = {}
        for i in reps:
            if i in new_index and fps.get(i) is not None:
                fp_of[new_index[i]] = fps[i]
            elif i in new_index and s.find_similar:
                stats.skipped.append((found[i][0], "could not decode pixels (visual check skipped)"))

        relabeler = Relabeler(images, rep_of, fp_of, s, pair_store=self.cache,
                              fine_source=lambda k: imaging.load_gray(images[k].path))
        edges: List[Tuple[int, int, int, float]] = []

        # Stage 4 – candidate index + validation
        if s.find_similar and len(fp_of) > 1:
            fr = sorted(fp_of)
            R = len(fr)
            ph = np.array([fp_of[k].p_hash for k in fr], dtype=np.uint64)
            ch = np.array([fp_of[k].center_hash for k in fr], dtype=np.uint64)
            P = np.stack([matcher.probes(fp_of[k]) for k in fr])
            det = np.array([relabeler.details[k] for k in fr], dtype=np.float32)
            begin(4, R)
            cands: List[Tuple[int, int]] = []
            for i in range(R - 1):
                if i % 64 == 0:
                    if not control.checkpoint():
                        return partial(images, folders)
                    emit(i, images[fr[i]].folder)
                d = np.bitwise_count(ph[i, 0] ^ ph[i + 1:]).astype(np.int16)
                hd = d[:, 0].copy()
                q = np.zeros(len(hd), dtype=np.int8)
                if s.detect_rotation:
                    for k in (1, 2, 3):
                        better = d[:, k] < hd - 2
                        hd[better] = d[better, k]
                        q[better] = k
                dc = np.bitwise_count(ch[i] ^ ch[i + 1:]).astype(np.int16)
                t1 = (hd <= 28) | (dc <= 26)
                if not t1.any():
                    continue
                low = np.minimum(det[i], det[i + 1:]) < matcher.LOW_DETAIL
                rot = q != 0
                ok = t1 & rot & (hd <= np.where(low, 4, 12))
                idx = np.nonzero(t1 & ~rot)[0]
                if idx.size:
                    Pj = P[i + 1:][idx]
                    ps = np.maximum.reduce([Pj[:, 0] @ P[i, 0], Pj[:, 1] @ P[i, 0], Pj[:, 2] @ P[i, 0],
                                            Pj[:, 0] @ P[i, 1], Pj[:, 0] @ P[i, 2]])
                    h, c, lo = hd[idx], dc[idx], low[idx]
                    strong = (h <= 10) | (c <= 10)
                    good = np.where(lo, (h <= 4) & (c <= 6) & (ps >= 0.9),
                                    (strong & (ps >= 0.6)) | (ps >= 0.8) | (((h <= 20) | (c <= 18)) & (ps >= 0.7)))
                    ok[idx[good]] = True
                for j in np.nonzero(ok)[0]:
                    cands.append((fr[i], fr[i + 1 + int(j)]))
            stats.pairs_screened = R * (R - 1) // 2
            stats.candidates = len(cands)

            begin(4, len(cands))
            tasks = []
            for a, b in cands:
                m = self.cache.get_pair(images[a], images[b])
                if m is not None:
                    relabeler.remember(a, b, m)
                else:
                    tasks.append((a, b, fp_of[a].to_bytes(), fp_of[b].to_bytes(), images[a].path, images[b].path))
            base_done = len(cands) - len(tasks)
            res = self._map(compare_task, tasks, control,
                            lambda d: emit(base_done + d, images[tasks[min(d, len(tasks)) - 1][0]].folder))
            if res is None:
                self.cache.commit()
                return partial(images, folders)
            for a, b, v in res:
                m = PairMatch.from_list(v)
                relabeler.remember(a, b, m)
                self.cache.put_pair(images[a], images[b], m)
            for a, b in cands:
                m = relabeler.matches[(a, b)]
                if m.refined:
                    stats.validated += 1
                c, _ = grouping.confidence(m, images[a].meta, images[b].meta, s)
                if c >= grouping.LOW:
                    edges.append((a, b, c, m.score))

        # Stage 5 – groups
        begin(5, 1)
        groups = grouping.build_groups(rep_idx, copies, edges, relabeler)
        counts: Dict[str, int] = {}
        dups: Dict[str, int] = {}
        for im in images:
            counts[im.folder] = counts.get(im.folder, 0) + 1
        for g in groups:
            for m in g.members[1:]:
                f = images[m.index].folder
                dups[f] = dups.get(f, 0) + 1
        emit(1, force=True)
        stats.stage_seconds.append((STAGES[5], control.active(state["start"])))
        stats.seconds = control.active(t0)
        return Report(images, groups, [(f, counts.get(f, 0), dups.get(f, 0)) for f in folders], stats, False, relabeler)


def auto_marks(g: Group) -> set:
    """Only confirmed, high-confidence duplicates in groups whose original is certain are pre-selected."""
    if g.manual_review:
        return set()
    return {m.index for m in g.members[1:] if m.label in grouping.CONFIRMED_LABELS and m.confidence >= grouping.HIGH}

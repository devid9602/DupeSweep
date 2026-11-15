"""Aligns two fingerprints (crop / rotation / tilt search) and measures how alike they are."""
from __future__ import annotations

from dataclasses import dataclass, asdict, field
from typing import List, Optional, Tuple

import numpy as np

from . import imaging
from .fingerprint import Fingerprint, hamming

PROBE_SCALES = (1.0, 0.88, 0.76)
LOW_DETAIL = 0.04          # below this `detail`, an image is treated as featureless
FINE_CUT = 0.5             # a window "disagrees" below this structure correlation (full-detail check)


@dataclass
class Settings:
    """User-tunable detection settings."""
    find_similar: bool = True
    detect_rotation: bool = True
    max_crop: float = 0.25           # largest crop tolerated per side
    high: float = 0.80               # ≥ → same photograph, high confidence
    medium: float = 0.70             # ≥ → likely, needs verification
    low: float = 0.60                # ≥ → possible match
    max_local: float = 0.025         # share of disagreeing regions allowed for "high" (64 px)
    max_fine: float = 0.035          # same, measured in the full-detail re-check

    def normalised(self) -> "Settings":
        s = Settings(**asdict(self))
        s.medium = min(s.medium, s.high)
        s.low = min(s.low, s.medium)
        return s

    def key(self) -> str:
        return f"v1|{self.max_crop:.3f}|{int(self.detect_rotation)}"


@dataclass
class PairMatch:
    quarter_turns: int = 0       # clockwise quarter turns applied to `other` to align it with `ref`
    angle: float = 0.0           # residual tilt, degrees
    coverage: float = 1.0        # area of the smaller frame / the larger (1 = not cropped)
    other_inside: bool = True    # True: `other` is (a crop of) `ref`
    ncc: float = 0.0
    structure: float = 0.0
    p10: float = 0.0             # 10th-percentile window
    ssim: float = 0.0
    local: float = 0.0           # share of informative windows that disagree
    hash_distance: int = 64
    score: float = 0.0
    refined: bool = False
    fx: float = 1.0
    cx: float = 0.5
    cy: float = 0.5
    fine: float = -1.0           # share of disagreeing regions at full detail (-1 = not checked)
    low_detail: bool = False

    def to_list(self) -> list:
        return [self.quarter_turns, self.angle, self.coverage, int(self.other_inside), self.ncc, self.structure,
                self.p10, self.ssim, self.local, self.hash_distance, self.score, int(self.refined),
                self.fx, self.cx, self.cy, self.fine]

    @classmethod
    def from_list(cls, v: list) -> "PairMatch":
        return cls(int(v[0]), v[1], v[2], bool(v[3]), v[4], v[5], v[6], v[7], v[8], int(v[9]), v[10], bool(v[11]),
                   v[12], v[13], v[14], v[15])


class View:
    """Pre-scaled views of one fingerprint in one orientation."""
    __slots__ = ("t64", "t32", "t16", "aspect")

    def __init__(self, fp: Fingerprint, quarter_turns: int = 0):
        base = imaging.box_blur3(imaging.rotate(fp.thumb_image(), quarter_turns))
        self.t64 = base
        self.t32 = imaging.resize(base, 32, 32)
        self.t16 = imaging.resize(base, 16, 16)
        self.aspect = 1.0 / fp.aspect if quarter_turns % 2 == 1 else fp.aspect


def detail(fp: Fingerprint) -> float:
    """Fine structure relative to contrast; near zero for sky, fog, blank walls, gradients."""
    t = fp.thumb_image()
    b = imaging.box_blur3(t)
    ti, bi = t[2:-2, 2:-2], b[2:-2, 2:-2]
    return float(np.abs(ti - bi).mean() / (ti.std() + 0.02))


def probes(fp: Fingerprint) -> np.ndarray:
    """(3, 256) zero-mean unit-norm 16×16 vectors of the frame and of centred 88% / 76% crops."""
    base = imaging.box_blur3(fp.thumb_image())
    out = []
    for s in PROBE_SCALES:
        g = base if s >= 0.999 else imaging.crop(base, (1 - s) / 2, (1 - s) / 2, (1 + s) / 2, (1 + s) / 2)
        v = imaging.resize(g, 16, 16).ravel().astype(np.float32)
        v = v - v.mean()
        n = float(np.sqrt((v * v).sum()))
        out.append(v / n if n > 1e-6 else v)
    return np.stack(out)


def best_rotation(a: Fingerprint, b: Fingerprint, allow: bool) -> Tuple[int, int]:
    best_q, best_d = 0, hamming(a.p_hash[0], b.p_hash[0])
    if allow:
        for q in (1, 2, 3):
            d = hamming(a.p_hash[0], b.p_hash[q])
            if d < best_d - 2:
                best_d, best_q = d, q
    return best_q, best_d


# ---------------------------------------------------------------- alignment

@dataclass
class _Frame:
    fx_min: float
    fx_max: float
    ref_aspect: float
    mov_aspect: float

    def fy(self, fx):
        return fx * self.ref_aspect / self.mov_aspect


def _frame(ref: View, mov: View, max_crop: float) -> Optional[_Frame]:
    min_dim = 1 - max_crop
    fx_max = min(1.0, 1.03 * mov.aspect / ref.aspect)
    fx_min = max(min_dim, min_dim * mov.aspect / ref.aspect)
    if fx_min > fx_max + 1e-4:
        return None
    return _Frame(min(fx_min, fx_max), fx_max, ref.aspect, mov.aspect)


def _centres(extent: float, step: float) -> List[float]:
    if extent >= 0.995:
        return [0.5]
    lo, hi = extent / 2, 1 - extent / 2
    r, c = [], lo
    while c < hi - 1e-4:
        r.append(c)
        c += step
    r.append(hi)
    return r


def _coarse_placements(f: _Frame, step: float, c_step: float) -> np.ndarray:
    fxs, v = [], f.fx_max
    while v > f.fx_min + 1e-4:
        fxs.append(v)
        v -= step
    fxs.append(f.fx_min)
    out = []
    for fx in fxs:
        fy = min(1.0, f.fy(fx))
        for cx in _centres(fx, c_step):
            for cy in _centres(fy, c_step):
                out.append((fx, cx, cy, 0.0))
    return np.array(out, dtype=np.float32)


_GRID: dict = {}


def _grid(n: int):
    g = _GRID.get(n)
    if g is None:
        c = ((np.arange(n, dtype=np.float32) + 0.5) / n - 0.5)
        g = _GRID[n] = (np.repeat(c, n)[None, :], np.tile(c, n)[None, :])      # dy, dx (unit) as (1, n²)
    return g


def _warp(ref: np.ndarray, n: int, f: _Frame, P: np.ndarray):
    """Samples `ref` at K placements on an n×n grid. Returns values (K, n²) and validity (K, n²)."""
    P = np.asarray(P, dtype=np.float32).reshape(-1, 4)
    fx, cx, cy, th = P[:, 0:1], P[:, 1:2], P[:, 2:3], P[:, 3:4] * np.float32(np.pi / 180)
    k = fx * np.float32(f.ref_aspect / f.mov_aspect)
    ct, st = np.cos(th), np.sin(th)
    dy, dx = _grid(n)
    dx = dx * np.float32(f.mov_aspect)
    xa = cx + (k / np.float32(f.ref_aspect)) * (ct * dx - st * dy)
    ya = cy + k * (st * dx + ct * dy)
    valid = (np.abs(xa - 0.5) <= 0.515) & (np.abs(ya - 0.5) <= 0.515)
    H, W = ref.shape
    x = np.clip(xa * W - 0.5, 0, W - 1.001)
    y = np.clip(ya * H - 0.5, 0, H - 1.001)
    x0 = x.astype(np.int32)
    y0 = y.astype(np.int32)
    wx, wy = x - x0, y - y0
    i00 = y0 * W + x0
    flat = ref.ravel()
    a, b = flat.take(i00), flat.take(i00 + 1)
    c2, d = flat.take(i00 + W), flat.take(i00 + W + 1)
    top = a + (b - a) * wx
    return top + ((c2 + (d - c2) * wx) - top) * wy, valid


def _ncc(vals: np.ndarray, mov: np.ndarray, valid: np.ndarray):
    """Batched NCC over valid pixels. Returns (ncc, invalid fraction)."""
    m = valid.astype(np.float32)
    c = m.sum(1)
    cs = np.maximum(c, 1)
    ma = (vals * m).sum(1) / cs
    mb = (mov[None, :] * m).sum(1) / cs
    x = (vals - ma[:, None]) * m
    y = (mov[None, :] - mb[:, None]) * m
    sab, saa, sbb = (x * y).sum(1), (x * x).sum(1), (y * y).sum(1)
    flat_a, flat_b = saa < 1e-9, sbb < 1e-9
    ncc = sab / np.sqrt(np.maximum(saa * sbb, 1e-18))
    ncc = np.where(flat_a | flat_b, np.where(flat_a & flat_b, 1.0, 0.0), ncc)
    n2 = vals.shape[1]
    too_few = c < n2 / 2
    return np.where(too_few, -1.0, ncc), np.where(too_few, 1.0, 1 - c / n2)


def _penalised(ref, mov, f, P):
    ncc, invalid = _ncc(*_swap(_warp(ref, mov.shape[0], f, P), mov))
    return ncc - np.maximum(0, invalid - 0.02) * 2


def _swap(wv, mov):
    vals, valid = wv
    return vals, mov.ravel(), valid


def _clamp(P: np.ndarray, f: _Frame) -> np.ndarray:
    P = P.copy()
    P[:, 0] = np.clip(P[:, 0], f.fx_min, f.fx_max)
    fy = np.minimum(1.0, f.fy(P[:, 0]))
    P[:, 1] = np.minimum(np.maximum(P[:, 1], P[:, 0] / 2 - 0.01), 1 - P[:, 0] / 2 + 0.01)
    P[:, 2] = np.minimum(np.maximum(P[:, 2], fy / 2 - 0.01), 1 - fy / 2 + 0.01)
    P[:, 3] = np.clip(P[:, 3], -6, 6)
    return P


def _refine(ref, mov, f, start, steps, rounds):
    """Steepest coordinate descent over (fx, cx, cy, tilt)."""
    p = _clamp(np.array([start], dtype=np.float32), f)[0]
    s = float(_penalised(ref, mov, f, p[None])[0])
    sf, sc, st = steps
    for _ in range(rounds):
        for _ in range(6):
            d = np.array([sf, sc, sc, st], dtype=np.float32)
            cand = np.repeat(p[None], 8, axis=0)
            for k in range(4):
                cand[2 * k, k] += d[k]
                cand[2 * k + 1, k] -= d[k]
            cand = _clamp(cand, f)
            v = _penalised(ref, mov, f, cand)
            i = int(np.argmax(v))
            if v[i] > s + 1e-5:
                s, p = float(v[i]), cand[i]
            else:
                break
        sf, sc, st = sf / 2, sc / 2, st / 2
    return p, s


def _is_identity(p, f: _Frame) -> bool:
    return abs(p[0] - f.fx_max) < 1e-3 and abs(p[1] - 0.5) < 0.01 and abs(p[2] - 0.5) < 0.01 and abs(f.fy(p[0]) - 1) < 0.02


def _coarse(ref: View, mov: View, f: _Frame):
    P = _coarse_placements(f, 0.04, 0.035)
    ncc, _ = _ncc(*_swap(_warp(ref.t32, 16, f, P), mov.t16))
    order = np.argsort(-ncc)
    seeds = []
    for i in order:
        if len(seeds) >= 2:
            break
        p = P[i]
        if not any(abs(s[0] - p[0]) < 0.03 and abs(s[1] - p[1]) < 0.04 and abs(s[2] - p[2]) < 0.04 for s in seeds):
            seeds.append(p)
    return seeds, float(ncc[order[0]]) if len(order) else -1.0


def _window_scores(r, mov, rz, mz, valid, n, win) -> np.ndarray:
    """Structure correlation of every informative window."""
    g = n // win

    def blocks(a):
        return a.reshape(g, win, g, win).transpose(0, 2, 1, 3).reshape(g * g, win * win)

    v = blocks(valid.astype(np.float32))
    c = v.sum(1)
    ok = c >= win * win * 2 / 3
    cs = np.maximum(c, 1)
    A, B = blocks(rz), blocks(mz)
    ma, mb = (A * v).sum(1) / cs, (B * v).sum(1) / cs
    da, db = (A - ma[:, None]) * v, (B - mb[:, None]) * v
    vab, vaa, vbb = (da * db).sum(1), (da * da).sum(1), (db * db).sum(1)
    sd_a, sd_b = np.sqrt(vaa / cs), np.sqrt(vbb / cs)
    raw_a, raw_b = (blocks(r) * v).sum(1) / cs, (blocks(mov) * v).sum(1) / cs
    flat = 0.10
    both_flat = (sd_a < flat) & (sd_b < flat)
    one_flat = ~both_flat & ((sd_a < flat * 0.5) | (sd_b < flat * 0.5))
    clipped = ((sd_a < flat * 0.5) & ((raw_a > 0.9) | (raw_a < 0.08))) | ((sd_b < flat * 0.5) & ((raw_b > 0.9) | (raw_b < 0.08)))
    corr = vab / np.sqrt(np.maximum(vaa * vbb, 1e-18))
    corr = corr * (1 - np.minimum(1, np.abs(ma - mb) / 1.5) * 0.5)
    s = np.where(both_flat, 1 - np.minimum(1, np.abs(ma - mb) / 0.5), np.where(one_flat, 0.0, corr))
    keep = ok & ~(one_flat & clipped)
    return np.clip(s[keep], -1, 1)


def _zscore(v, valid):
    m = valid
    c = max(int(m.sum()), 1)
    mean = float(v[m].sum()) / c if m.any() else 0.0
    sd = np.sqrt(max(1e-4, float((v[m] ** 2).sum()) / c - mean * mean)) if m.any() else 1.0
    return ((v - mean) / sd).astype(np.float32)


def _ssim(a, b, valid, n) -> float:
    L = 6.0
    c1, c2 = (0.01 * L) ** 2, (0.03 * L) ** 2
    sw = np.lib.stride_tricks.sliding_window_view
    A = sw(a.reshape(n, n), (8, 8))[::4, ::4].reshape(-1, 64)
    B = sw(b.reshape(n, n), (8, 8))[::4, ::4].reshape(-1, 64)
    V = sw(valid.reshape(n, n).astype(np.float32), (8, 8))[::4, ::4].reshape(-1, 64)
    c = V.sum(1)
    ok = c >= 40
    if not ok.any():
        return 0.0
    cs = np.maximum(c, 1)
    ma, mb = (A * V).sum(1) / cs, (B * V).sum(1) / cs
    da, db = (A - ma[:, None]) * V, (B - mb[:, None]) * V
    vaa, vbb, vab = (da * da).sum(1) / cs, (db * db).sum(1) / cs, (da * db).sum(1) / cs
    s = ((2 * ma * mb + c1) * (2 * vab + c2)) / ((ma * ma + mb * mb + c1) * (vaa + vbb + c2))
    return float(s[ok].mean())


def _measure(ref64, mov64, f: _Frame, p) -> PairMatch:
    n = mov64.shape[0]
    vals, valid = _warp(ref64, n, f, p[None])
    r, valid = vals[0], valid[0]
    m = PairMatch()
    fy = min(1.0, float(f.fy(p[0])))
    m.coverage, m.angle = float(p[0]) * fy, float(p[3])
    m.fx, m.cx, m.cy = float(p[0]), float(p[1]), float(p[2])
    if valid.sum() <= n * n / 2:
        return m
    mov = mov64.ravel()
    m.ncc = float(_ncc(r[None], mov, valid[None])[0][0])
    rz, mz = _zscore(r, valid), _zscore(mov, valid)
    # Clipped highlights / shadows carry no detail – leave them out of the regional comparison.
    informative = valid & ~((r > 0.96) | (mov > 0.96) | (r < 0.03) | (mov < 0.03))
    scores = _window_scores(r, mov, rz, mz, informative, n, 8)
    if scores.size:
        m.structure = float(scores.mean())
        srt = np.sort(scores)
        m.p10 = float(srt[min(srt.size - 1, srt.size // 10)])
        m.local = float((scores < 0.35).sum()) / scores.size
    m.ssim = _ssim(rz, mz, valid, n)
    m.score = float(np.clip(0.30 * m.ncc + 0.25 * m.ssim + 0.25 * m.structure + 0.20 * max(m.p10, 0), 0, 1))
    return m


def compare(a: Fingerprint, b: Fingerprint, settings: Settings, views=None, ka=None, kb=None) -> PairMatch:
    """Full comparison: coarse search over rotations/directions, early rejection, refinement of the best."""
    def view(fp, key, q):
        if views is None or key is None:
            return View(fp, q)
        v = views.get((key, q))
        if v is None:
            v = views[(key, q)] = View(fp, q)
        return v

    hint, hd = best_rotation(a, b, settings.detect_rotation)
    turns = [hint] + ([0] if hint != 0 else [])
    va = view(a, ka, 0)
    trials = []
    for q in turns:
        vb = view(b, kb, q)
        for inside in (True, False):
            ref, mov = (va, vb) if inside else (vb, va)
            f = _frame(ref, mov, settings.max_crop)
            if f is None:
                continue
            seeds, best = _coarse(ref, mov, f)
            trials.append((best, ref, mov, f, q, inside, seeds))
    result = PairMatch(hash_distance=hd)
    if not trials:
        return result
    trials.sort(key=lambda t: -t[0])
    top = trials[0]
    result.ncc = top[0]
    if top[0] < 0.65:                 # clearly different – skip refinement (true matches score ≥ 0.87 here)
        return result
    identity = bool(top[6]) and _is_identity(top[6][0], top[3])
    to_refine = [top] if (identity and top[0] >= 0.95) else [t for t in trials if t[0] >= top[0] - 0.03][:2]
    for best, ref, mov, f, q, inside, seeds in to_refine:
        bp = seeds[0] if seeds else np.array([f.fx_max, 0.5, 0.5, 0.0], dtype=np.float32)
        if not (_is_identity(bp, f) and best >= 0.97):
            bs = -2.0
            for s in seeds:
                p, sc = _refine(ref.t64, mov.t32, f, s, (0.02, 0.02, 2.0), 3)
                if sc > bs:
                    bs, bp = sc, p
        fp_, _ = _refine(ref.t64, mov.t64, f, bp, (0.006, 0.006, 0.6), 1)
        m = _measure(ref.t64, mov.t64, f, fp_)
        m.quarter_turns, m.other_inside, m.hash_distance, m.refined = q, inside, hd, True
        if m.score > result.score or not result.refined:
            result = m
        if result.score < settings.low - 0.15:
            break               # far below every threshold – the other direction can't rescue it
    return result


def fine_local_difference(ref: np.ndarray, mov: np.ndarray, m: PairMatch) -> float:
    """Full-detail re-check at 128 px: share of regions that disagree (moved subject / different moment).
    `ref` and `mov` are upright luma images; `mov` is already rotated to match."""
    n = 128
    ref_b = imaging.box_blur3(ref)
    mov_b = imaging.box_blur3(imaging.resize(mov, n, n))
    f = _Frame(max(0.3, m.fx - 0.03), min(1.2, m.fx + 0.03), ref.shape[1] / ref.shape[0], mov.shape[1] / mov.shape[0])
    p, _ = _refine(ref_b, mov_b, f, (m.fx, m.cx, m.cy, m.angle), (0.004, 0.004, 0.4), 2)
    vals, valid = _warp(ref_b, n, f, p[None])
    r, valid = vals[0], valid[0].copy()
    if valid.sum() <= n * n / 2:
        return 1.0
    mv = mov_b.ravel()
    valid &= ~((r > 0.96) | (mv > 0.96) | (r < 0.03) | (mv < 0.03))     # clipped highlights / shadows
    scores = _window_scores(r, mv, _zscore(r, valid), _zscore(mv, valid), valid, n, 8)
    if scores.size < 16:
        return 0.0
    return float((scores < FINE_CUT).sum()) / scores.size

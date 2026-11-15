"""Perceptual fingerprints: aHash, dHash, wHash, pHash (4 rotations), centre hash, thumbnail, colour map."""
from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import List, Optional, Tuple

import numpy as np

from . import imaging

VERSION = 1
THUMB = 64
_DCT = np.array([[np.cos(np.pi * (2 * n + 1) * k / 64.0) for n in range(32)] for k in range(8)], dtype=np.float32)
_BITS = (np.uint64(1) << np.arange(64, dtype=np.uint64))


@dataclass
class Fingerprint:
    a_hash: int
    d_hash: int
    w_hash: int
    p_hash: Tuple[int, int, int, int]     # image rotated 0°, 90°, 180°, 270° clockwise
    center_hash: int
    thumb: bytes                          # 64×64 luma, aspect squashed
    cmap: bytes                           # 8×8 Cb then 8×8 Cr (128 = neutral)
    stats: Tuple[float, float, float, float, float, float]   # meanY, stdY, meanCb, meanCr, chroma, sharpness
    aspect: float

    _FMT = "<8Q7f"

    def thumb_image(self) -> np.ndarray:
        return np.frombuffer(self.thumb, dtype=np.uint8).reshape(THUMB, THUMB).astype(np.float32) / 255.0

    def chroma_maps(self, quarter_turns: int = 0):
        a = (np.frombuffer(self.cmap, dtype=np.uint8).astype(np.float32) - 128) / 254
        return imaging.rotate(a[:64].reshape(8, 8), quarter_turns), imaging.rotate(a[64:].reshape(8, 8), quarter_turns)

    def to_bytes(self) -> bytes:
        head = struct.pack(self._FMT, self.a_hash, self.d_hash, self.w_hash, self.center_hash, *self.p_hash,
                           *self.stats, self.aspect)
        return head + self.thumb + self.cmap

    @classmethod
    def from_bytes(cls, b: bytes) -> "Fingerprint":
        n = struct.calcsize(cls._FMT)
        v = struct.unpack(cls._FMT, b[:n])
        return cls(v[0], v[1], v[2], tuple(v[4:8]), v[3], b[n:n + THUMB * THUMB], b[n + THUMB * THUMB:],
                   tuple(v[8:14]), v[14])


def _pack(bits: np.ndarray) -> int:
    return int((_BITS[bits.ravel().astype(bool)]).sum(dtype=np.uint64))


def a_hash(t64: np.ndarray) -> int:
    b = imaging.resize(t64, 8, 8)
    return _pack(b > b.mean())


def d_hash(g: np.ndarray) -> int:
    s = imaging.resize(g, 9, 8)
    return _pack(s[:, :8] > s[:, 1:])


def w_hash(t64: np.ndarray) -> int:
    ll = t64.reshape(8, 8, 8, 8).mean(axis=(1, 3))        # Haar LL band of three levels
    c = ll - ll.mean()
    return _pack(c > np.median(c))


def p_hash32(g32: np.ndarray) -> int:
    coef = (_DCT @ g32 @ _DCT.T).ravel()
    bits = coef > np.median(coef[1:])
    bits[0] = False
    return _pack(bits)


def make(rgb: np.ndarray) -> Optional[Fingerprint]:
    """Builds the fingerprint from decoded RGB pixels (≤ ~256 px)."""
    if rgb.shape[0] < 4 or rgb.shape[1] < 4:
        return None
    a = rgb.astype(np.float32) / 255.0
    y = (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]).astype(np.float32)
    cb = (a[..., 2] - y) * 0.564
    cr = (a[..., 0] - y) * 0.713
    std = float(y.std())
    lap = np.abs(4 * y[1:-1, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:] - y[:-2, 1:-1] - y[2:, 1:-1])
    sharp = float(lap.mean()) / (std + 0.02) if lap.size else 0.0
    stats = (float(y.mean()), std, float(cb.mean()), float(cr.mean()), float(np.sqrt(cb * cb + cr * cr).mean()), sharp)
    t64 = imaging.resize(y, 64, 64)
    t32 = imaging.resize(y, 32, 32)
    ph = tuple(p_hash32(imaging.rotate(t32, q)) for q in range(4))
    center = imaging.resize(imaging.crop(y, 0.15, 0.15, 0.85, 0.85), 32, 32)
    cmap = np.concatenate([imaging.resize(cb, 8, 8).ravel(), imaging.resize(cr, 8, 8).ravel()])
    return Fingerprint(a_hash(t64), d_hash(y), w_hash(t64), ph, p_hash32(center),
                       np.clip(np.rint(t64 * 255), 0, 255).astype(np.uint8).tobytes(),
                       np.clip(np.rint(cmap * 254 + 128), 0, 255).astype(np.uint8).tobytes(),
                       stats, rgb.shape[1] / rgb.shape[0])


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")

"""Image decoding, metadata and small array helpers (Pillow + NumPy)."""
from __future__ import annotations

import io
import os
from dataclasses import dataclass, asdict
from typing import Optional

import numpy as np
from PIL import Image, ImageOps

try:  # HEIC / HEIF / AVIF
    import pillow_heif
    pillow_heif.register_heif_opener()
except Exception:  # pragma: no cover - optional
    pillow_heif = None
try:  # camera RAW (uses the embedded preview)
    import rawpy
except Exception:  # pragma: no cover - optional
    rawpy = None

Image.MAX_IMAGE_PIXELS = 400_000_000

RAW_EXTENSIONS = {"dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "raw", "srw", "pef"}
IMAGE_EXTENSIONS = {"jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "avif", "gif", "tif", "tiff", "bmp", "webp"} | RAW_EXTENSIONS
DECODE_SIDE = 256

_FORMATS = {"JPEG": "JPEG", "MPO": "JPEG", "PNG": "PNG", "HEIF": "HEIC", "AVIF": "AVIF", "WEBP": "WEBP",
            "TIFF": "TIFF", "GIF": "GIF", "BMP": "BMP"}
_EDITORS = ("photoshop", "lightroom", "adobe", "gimp", "snapseed", "pixelmator", "affinity", "luminar",
            "capture one", "darktable", "rawtherapee", "picasa", "instagram", "vsco", "canva", "facetune",
            "photos ", "paint.net", "acdsee", "polarr", "picsart", "afterlight", "fotor", "photoscape",
            "irfanview", "xnview", "preview", "skylum", "on1 ", "dxo", "faststone")
_STD_LUMA = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
             14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
             49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]


@dataclass
class Meta:
    """Header-level facts about an image file."""
    width: int = 0
    height: int = 0
    format: str = ""
    make: Optional[str] = None
    model: Optional[str] = None
    software: Optional[str] = None
    dto: Optional[str] = None          # EXIF DateTimeOriginal "YYYY:MM:DD HH:MM:SS"
    subsec: Optional[str] = None
    jpeg_quality: Optional[int] = None

    @property
    def pixels(self) -> int:
        return self.width * self.height

    @property
    def has_exif(self) -> bool:
        return bool(self.dto or self.make or self.model)

    @property
    def is_lossless(self) -> bool:
        return self.format in ("PNG", "TIFF", "BMP", "RAW")

    @property
    def has_camera_evidence(self) -> bool:
        return bool((self.make or self.model) and self.dto)

    @property
    def edited_by_software(self) -> bool:
        s = (self.software or "").lower()
        return bool(s) and any(e in s for e in _EDITORS)

    @property
    def capture_seconds(self) -> Optional[float]:
        d = self.dto
        if not d or len(d) < 19:
            return None
        try:
            p = [float(x) for x in d.replace(":", " ").split()[:6]]
        except ValueError:
            return None
        if len(p) < 6 or p[0] <= 1900:
            return None
        t = ((p[0] - 1970) * 372 + (p[1] - 1) * 31 + (p[2] - 1)) * 86400 + p[3] * 3600 + p[4] * 60 + p[5]
        if self.subsec:
            digits = "".join(c for c in self.subsec if c.isdigit())
            if digits:
                t += float("0." + digits)
        return t

    def to_dict(self) -> dict:
        return asdict(self)


def _clean(v) -> Optional[str]:
    if v is None:
        return None
    if isinstance(v, bytes):
        v = v.decode("utf-8", "ignore")
    s = str(v).strip().strip("\x00").strip()
    return s or None


def _jpeg_quality(im) -> Optional[int]:
    q = getattr(im, "quantization", None)
    if not q:
        return None
    table = q.get(0) or next(iter(q.values()))
    target = sum(table)
    best, best_diff = 50, 1 << 60
    for quality in range(1, 101):
        scale = 5000 // quality if quality < 50 else 200 - 2 * quality
        s = sum(min(255, max(1, (v * scale + 50) // 100)) for v in _STD_LUMA)
        if abs(s - target) < best_diff:
            best_diff, best = abs(s - target), quality
    return best


def _open(path: str) -> Image.Image:
    ext = os.path.splitext(path)[1][1:].lower()
    if ext in RAW_EXTENSIONS and rawpy is not None:
        with rawpy.imread(path) as raw:
            thumb = raw.extract_thumb()
        if thumb.format == rawpy.ThumbFormat.JPEG:
            return Image.open(io.BytesIO(thumb.data))
        return Image.fromarray(thumb.data)
    return Image.open(path)


def read_metadata(path: str) -> Optional[Meta]:
    """Dimensions (upright), format and EXIF. None if the file can't be read."""
    try:
        with _open(path) as im:
            ext = os.path.splitext(path)[1][1:].lower()
            m = Meta(format="RAW" if ext in RAW_EXTENSIONS else _FORMATS.get(im.format or "", (im.format or ext).upper()))
            w, h = im.size
            exif = im.getexif()
            if exif.get(0x0112, 1) in (5, 6, 7, 8):
                w, h = h, w
            m.width, m.height = w, h
            m.make, m.model, m.software = _clean(exif.get(0x010F)), _clean(exif.get(0x0110)), _clean(exif.get(0x0131))
            try:
                ifd = exif.get_ifd(0x8769)
            except Exception:
                ifd = {}
            m.dto, m.subsec = _clean(ifd.get(0x9003)), _clean(ifd.get(0x9291))
            if m.format == "JPEG":
                m.jpeg_quality = _jpeg_quality(im)
            return m if w > 0 and h > 0 else None
    except Exception:
        return None


def load_rgb(path: str, max_side: int = DECODE_SIDE) -> Optional[np.ndarray]:
    """Upright RGB pixels (uint8, H×W×3), longest side ≤ max_side, composited over white."""
    try:
        with _open(path) as im:
            try:
                im.draft("RGB", (max_side * 2, max_side * 2))     # fast reduced JPEG decoding
            except Exception:
                pass
            im = ImageOps.exif_transpose(im)
            if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
                im = im.convert("RGBA")
                bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
                im = Image.alpha_composite(bg, im)
            elif im.mode.startswith("I;16") or im.mode == "I":
                a = np.asarray(im, dtype=np.float32)
                im = Image.fromarray(np.clip(a / max(1.0, float(a.max())) * 255, 0, 255).astype(np.uint8))
            im = im.convert("RGB")
            w, h = im.size
            s = max_side / max(w, h)
            if s < 1:
                im = im.resize((max(1, round(w * s)), max(1, round(h * s))), Image.BOX)
            a = np.asarray(im, dtype=np.uint8)
            return a if a.shape[0] >= 4 and a.shape[1] >= 4 else None
    except Exception:
        return None


def load_gray(path: str, max_side: int = DECODE_SIDE) -> Optional[np.ndarray]:
    rgb = load_rgb(path, max_side)
    return None if rgb is None else luma(rgb)


def luma(rgb: np.ndarray) -> np.ndarray:
    a = rgb.astype(np.float32) / 255.0
    return (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]).astype(np.float32)


def resize(g: np.ndarray, w: int, h: int) -> np.ndarray:
    """Area-average downscale (bilinear when enlarging). Aspect ratio is not preserved."""
    if g.shape == (h, w):
        return g
    up = g.shape[1] < w or g.shape[0] < h
    im = Image.fromarray(np.ascontiguousarray(g, dtype=np.float32), mode="F")
    return np.asarray(im.resize((w, h), Image.BILINEAR if up else Image.BOX), dtype=np.float32)


def rotate(g: np.ndarray, quarter_turns: int) -> np.ndarray:
    """Rotate clockwise by quarter turns."""
    q = quarter_turns % 4
    return g if q == 0 else np.ascontiguousarray(np.rot90(g, k=-q))


def crop(g: np.ndarray, x0: float, y0: float, x1: float, y1: float) -> np.ndarray:
    h, w = g.shape
    ax = max(0, min(w - 1, int(x0 * w)))
    ay = max(0, min(h - 1, int(y0 * h)))
    bx = max(ax + 1, min(w, int(np.ceil(x1 * w))))
    by = max(ay + 1, min(h, int(np.ceil(y1 * h))))
    return g[ay:by, ax:bx]


def box_blur3(g: np.ndarray) -> np.ndarray:
    """3×3 mean with shrinking windows at the borders."""
    p = np.pad(g, 1)
    c = np.pad(np.ones_like(g), 1)
    s = np.zeros_like(g)
    n = np.zeros_like(g)
    h, w = g.shape
    for dy in range(3):
        for dx in range(3):
            s += p[dy:dy + h, dx:dx + w]
            n += c[dy:dy + h, dx:dx + w]
    return s / n

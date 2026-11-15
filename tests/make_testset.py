"""Builds a test photo library covering every detection scenario, with ground truth.

Variants of 9 sample photographs (exact copy, resized, tone, filter, compression, format conversion,
crop, rotation, tilt + editor export, nested copy) plus look-alike negatives and unrelated images.
usage: python -m tests.make_testset OUT_DIR [N_DISTRACTORS]
"""
import os, sys, json, shutil, random
import numpy as np
from PIL import Image, ImageEnhance, ImageOps, ImageFilter
import pillow_heif
pillow_heif.register_heif_opener()
import skimage, sklearn.datasets as skd


def build(OUT, NDIST=40):
    LIB = os.path.join(OUT, 'library')
    shutil.rmtree(OUT, ignore_errors=True); os.makedirs(LIB)
    rng = random.Random(7)

    SKD = os.path.join(os.path.dirname(skimage.__file__), 'data')
    SKL = os.path.join(os.path.dirname(skd.__file__), 'images')
    def load(name):
        p = os.path.join(SKL, name) if name in ('china.jpg', 'flower.jpg') else os.path.join(SKD, name)
        return Image.open(p).convert('RGB')

    def upscale(im, long_side=2400):
        w, h = im.size; s = long_side / max(w, h)
        return im.resize((round(w * s), round(h * s)), Image.LANCZOS)

    def exif_for(dto, model='Canon EOS 80D', software=None, subsec='12'):
        ex = Image.Exif()
        ex[0x010F] = 'Canon'; ex[0x0110] = model
        if software: ex[0x0131] = software
        ifd = ex.get_ifd(0x8769); ifd[0x9003] = dto; ifd[0x9291] = subsec
        return ex

    truth = {'files': {}, 'expect_groups': [], 'expect_separate': []}
    def save(im, rel, quality=92, fmt='JPEG', exif=None, role=None, photo=None):
        path = os.path.join(LIB, rel); os.makedirs(os.path.dirname(path), exist_ok=True)
        kw = {}
        if fmt == 'JPEG': kw = dict(quality=quality, subsampling=0 if quality >= 90 else 2)
        if fmt == 'WEBP': kw = dict(quality=quality)
        if fmt == 'HEIF': kw = dict(quality=quality)
        if exif is not None and fmt in ('JPEG', 'WEBP', 'HEIF', 'PNG'): kw['exif'] = exif.tobytes()
        im.save(path, fmt, **kw)
        truth['files'][rel] = {'photo': photo, 'role': role}
        return rel

    def tone(im, b=1.0, c=1.0, s=1.0):
        im = ImageEnhance.Brightness(im).enhance(b); im = ImageEnhance.Contrast(im).enhance(c)
        return ImageEnhance.Color(im).enhance(s)

    def sepia(im):
        g = np.asarray(ImageOps.grayscale(im), dtype=np.float32) / 255
        rgb = np.stack([g * 1.07 + 0.08, g * 0.95 + 0.03, g * 0.72], -1)
        return Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8))

    def teal_orange(im):
        a = np.asarray(im, dtype=np.float32) / 255
        a = a ** np.array([0.85, 1.0, 1.2]); a[..., 2] = a[..., 2] * 0.85 + 0.12
        return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))

    def crop_frac(im, f, cx=0.5, cy=0.5):
        w, h = im.size; cw, ch = w * f, h * f
        x0 = (w - cw) * cx; y0 = (h - ch) * cy
        return im.crop((round(x0), round(y0), round(x0 + cw), round(y0 + ch)))

    def rotate_small(im, deg):
        w, h = im.size; r = im.rotate(deg, resample=Image.BICUBIC, expand=False)
        return crop_frac(r, 0.90)            # editors auto-crop the rotated borders

    def resize(im, s): w, h = im.size; return im.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)

    # ---------------------------------------------------------------- positives
    photos = [('coffee.png', 'P01'), ('astronaut.png', 'P02'), ('chelsea.png', 'P03'), ('rocket.jpg', 'P04'),
              ('china.jpg', 'P05'), ('flower.jpg', 'P06'), ('hubble_deep_field.jpg', 'P07'), ('ihc.png', 'P08')]
    for n, (src, pid) in enumerate(photos):
        base = upscale(load(src))
        dto = f'2023:0{1 + n % 9}:1{n} 10:2{n}:3{n}'
        group = []
        orig = save(base, f'Camera/2023/IMG_{1000+n}.JPG', quality=95, exif=exif_for(dto), role='original', photo=pid); group.append(orig)
        # S1 exact copy, different name & folder
        p = os.path.join(LIB, f'Backup/Phone dump/photo_{n:03d}.jpg'); os.makedirs(os.path.dirname(p), exist_ok=True)
        shutil.copyfile(os.path.join(LIB, orig), p); rel = os.path.relpath(p, LIB)
        truth['files'][rel] = {'photo': pid, 'role': 'exact'}; group.append(rel)
        # S2 resized
        group.append(save(resize(base, 0.4), f'Exports/Small/{pid}_small.jpg', quality=85, role='resized', photo=pid))
        # S3 brightness/contrast
        group.append(save(tone(base, 1.25, 1.3), f'Edited/{pid}_bright.jpg', quality=90, exif=exif_for(dto, software='Adobe Lightroom 6.0'), role='tone', photo=pid))
        # S4 colour filter
        flt = sepia(base) if n % 2 == 0 else teal_orange(base)
        group.append(save(flt, f'Edited/Filters/{pid}_filter.jpg', quality=88, role='filter', photo=pid))
        # S5 heavy JPEG compression, EXIF stripped (messenger style)
        group.append(save(resize(base, 0.66), f'WhatsApp Images/IMG-2023-WA{n:04d}.jpg', quality=35, role='compressed', photo=pid))
        # S6 format conversions (WEBP / HEIC / PNG)
        group.append(save(base, f'Converted/{pid}.webp', 80, fmt='WEBP', role='webp', photo=pid))
        if n % 2 == 0:
            group.append(save(resize(base, 0.5), f'Converted/{pid}.heic', 70, fmt='HEIF', role='heic', photo=pid))
        # S7 slight crop
        group.append(save(crop_frac(base, 0.88, 0.4, 0.55), f'Edited/{pid}_crop.jpg', quality=90, role='crop', photo=pid))
        # S8 rotated 90 + small rotation exported from an editor
        group.append(save(base.transpose(Image.ROTATE_270), f'Edited/{pid}_rot90.jpg', quality=90, role='rot90', photo=pid))
        group.append(save(rotate_small(tone(base, 1.05, 1.1, 1.15), 3.0), f'Exports/Photoshop/{pid}_export.jpg', quality=85,
                          exif=exif_for(dto, software='Adobe Photoshop CC 2019 (Macintosh)'), role='rot_small', photo=pid))
        # S9 same photograph in nested folders
        group.append(save(base, f'Albums/2023/Trip/Day 2/{pid}_dup.jpg', quality=80, role='nested', photo=pid))
        truth['expect_groups'].append({'photo': pid, 'original': orig, 'members': group})

    # PNG original -> JPG conversion (S6 PNG->JPG)
    base = upscale(load('chelsea.png').transpose(Image.FLIP_LEFT_RIGHT), 1800)
    pngo = save(base, 'Scans/cat_scan.png', fmt='PNG', role='original', photo='P09')
    jp = save(base, 'Converted/cat_scan.jpg', quality=88, role='png2jpg', photo='P09')
    truth['expect_groups'].append({'photo': 'P09', 'original': pngo, 'members': [pngo, jp]})

    # ---------------------------------------------------------------- negatives (S10)
    neg = []
    mL = upscale(load('motorcycle_left.png'), 2000); mR = upscale(load('motorcycle_right.png'), 2000)
    neg.append([save(mL, 'Garage/moto_a.jpg', 92, exif=exif_for('2022:05:01 09:00:01', subsec='10'), role='neg', photo='N1a'),
                save(mR, 'Garage/moto_b.jpg', 92, exif=exif_for('2022:05:01 09:00:03', subsec='55'), role='neg', photo='N1b')])
    # burst-like: same background, subject moved
    # realistic burst: own scene (mirrored + reframed coffee), subject moves between frames, sub-second EXIF times
    cof = crop_frac(upscale(load('coffee.png').transpose(Image.FLIP_LEFT_RIGHT), 1800), 0.8, 0.3, 0.6)
    a = np.asarray(cof).copy(); b = a.copy()
    patch = np.asarray(upscale(load('astronaut.png'), 1600).crop((520, 160, 820, 460)))
    a[500:800, 150:450] = patch; b[520:820, 330:630] = patch      # subject moved ~180 px
    neg.append([save(Image.fromarray(a), 'Burst/burst_1.jpg', 92, exif=exif_for('2023:07:04 18:30:05', subsec='10'), role='neg', photo='N2a'),
                save(Image.fromarray(b), 'Burst/burst_2.jpg', 92, exif=exif_for('2023:07:04 18:30:05', subsec='43'), role='neg', photo='N2b')])
    # same burst without metadata (e.g. after a messenger strips EXIF) – visual check alone must hold
    neg.append([save(Image.fromarray(a), 'Burst/no_exif_1.jpg', 90, role='neg', photo='N2a'),
                save(Image.fromarray(b), 'Burst/no_exif_2.jpg', 90, role='neg', photo='N2b')])
    # similar backgrounds: non-overlapping halves of the same scene
    ch = upscale(load('china.jpg'), 2400); w, h = ch.size
    neg.append([save(ch.crop((0, 0, w // 2, h)), 'Landscapes/left.jpg', 92, role='neg', photo='N3a'),
                save(ch.crop((w // 2, 0, w, h)), 'Landscapes/right.jpg', 92, role='neg', photo='N3b')])
    for t in ('gravel.png', 'grass.png', 'brick.png'):
        im = upscale(load(t), 1600); w, h = im.size
        neg.append([save(im.crop((0, 0, w // 2, h // 2)), f'Textures/{t[:-4]}_1.jpg', 90, role='neg', photo=t + 'a'),
                    save(im.crop((w // 2, h // 2, w, h)), f'Textures/{t[:-4]}_2.jpg', 90, role='neg', photo=t + 'b')])
    # same sky/space style
    hb = upscale(load('hubble_deep_field.jpg'), 2400); w, h = hb.size
    neg.append([save(hb.crop((0, 0, w // 2, h // 2)), 'Space/field_1.jpg', 90, role='neg', photo='N4a'),
                save(hb.crop((w // 2, h // 2, w, h)), 'Space/field_2.jpg', 90, role='neg', photo='N4b')])
    # Mac-self-test-style burst: small patch from another photo moved by 12% of the width, no EXIF
    sc = crop_frac(upscale(load('astronaut.png').transpose(Image.FLIP_LEFT_RIGHT), 1800), 0.8, 0.3, 0.6)
    W2, H2 = sc.size; side = W2 // 6
    pt = upscale(load('rocket.jpg'), 1200); pw, ph = pt.size
    patch2 = pt.crop((pw // 3, ph // 3, pw // 3 + min(pw, ph) // 4, ph // 3 + min(pw, ph) // 4)).resize((side, side))
    b1 = sc.copy(); b1.paste(patch2, (int(W2 * 0.15), int(H2 * 0.35)))
    b2 = sc.copy(); b2.paste(patch2, (int(W2 * 0.27), int(H2 * 0.33)))
    neg.append([save(b1, 'Burst/small_move_1.jpg', 92, role='neg', photo='N6a'), save(b2, 'Burst/small_move_2.jpg', 92, role='neg', photo='N6b')])
    # Same scene, subject region shifted ~3% (person moved slightly between two shots), no EXIF
    base3 = upscale(crop_frac(load('motorcycle_right.png'), 0.6, 0.0, 0.0), 1600); a3 = np.asarray(base3).copy(); b3 = a3.copy()
    h3, w3 = a3.shape[:2]; y0, y1, x0, x1 = int(h3 * .15), int(h3 * .75), int(w3 * .2), int(w3 * .6); dx = int(w3 * 0.03)
    b3[y0:y1, x0 + dx:x1 + dx] = a3[y0:y1, x0:x1]
    c3 = Image.fromarray(b3).transpose(Image.FLIP_TOP_BOTTOM); d3 = Image.fromarray(a3).transpose(Image.FLIP_TOP_BOTTOM)
    neg.append([save(d3, 'Pets/shot_1.jpg', 92, role='neg', photo='N7a'), save(c3, 'Pets/shot_2.jpg', 92, role='neg', photo='N7b')])
    truth['expect_separate'] = neg

    # ---------------------------------------------------------------- distractors (distinct images)
    srcs = ['coins.png', 'moon.png', 'camera.png', 'retina.jpg', 'horse.png', 'color.png', 'cell.png', 'logo.png', 'text.png', 'page.png']
    for i in range(NDIST):
        rs = np.random.RandomState(i)
        kind = i % 3
        if kind == 0:   # random smooth blobs
            z = rs.rand(6, 8, 3); im = Image.fromarray((z * 255).astype(np.uint8)).resize((1200, 900), Image.BICUBIC)
            im = im.filter(ImageFilter.GaussianBlur(3))
            arr = np.asarray(im).astype(np.float32) + rs.randn(900, 1200, 3) * 6
            im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
        elif kind == 1:  # random rectangles
            arr = np.full((900, 1200, 3), rs.randint(0, 255, 3), np.uint8)
            for _ in range(12):
                x, y = rs.randint(0, 1100), rs.randint(0, 800); arr[y:y + rs.randint(30, 300), x:x + rs.randint(30, 300)] = rs.randint(0, 255, 3)
            im = Image.fromarray(arr)
        else:            # different regions of other sample images
            s = load(srcs[i % len(srcs)]); w, h = s.size; f = 0.5
            x0 = rs.randint(0, int(w * (1 - f)) + 1); y0 = rs.randint(0, int(h * (1 - f)) + 1)
            im = upscale(s.crop((x0, y0, x0 + int(w * f), y0 + int(h * f))), 1200)
        save(im, f'Misc/Batch {i // 20}/random_{i:04d}.jpg', 88, role='distractor', photo=f'D{i}')

    # a corrupted file and an unsupported file
    open(os.path.join(LIB, 'Misc/broken.jpg'), 'wb').write(b'\xff\xd8\xff\xe0 not really a jpeg')
    open(os.path.join(LIB, 'Misc/notes.txt'), 'w').write('hello')

    with open(os.path.join(OUT, 'truth.json'), 'w') as f:
        json.dump(truth, f, indent=1)
    return truth


if __name__ == '__main__':
    t = build(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 40)
    print('images:', len(t['files']), 'groups:', len(t['expect_groups']), 'negative pairs:', len(t['expect_separate']))

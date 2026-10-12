"""Draws OOO's app icon: the brand's loop seen end-on, one O drawn round and
round in ember light, on pitch.dog's night.

    python3 scripts/make-icon.py Resources/Icons/ooo-loop.svg Resources/Icons/OOO.png

The loop is pitch.dog's OOO avatar (Resources/Icons/ooo-loop.svg). The icon is
kept in the repository as Resources/Icons/OOO.png, so building the app needs
none of this; run it again only when the loop changes. Needs numpy, scipy and
Pillow.
"""
import re, sys, numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

SS = 4                      # samples a pixel, each way
S = 1024
src = open(sys.argv[1]).read()
src = re.sub(r'<metadata>.*?</metadata>', '', src, flags=re.S)
d = re.findall(r'<path[^>]*d="([^"]*)"', src)[0]
VB = 1681.0
polys = []
for sub in re.split(r'M', d)[1:]:
    pts = re.findall(r'(-?[\d.]+),(-?[\d.]+)', sub)
    polys.append(np.array([[float(x), float(y)] for x, y in pts]))
allp = np.vstack(polys)
lo, hi = allp.min(0), allp.max(0)
ctr = (lo + hi) / 2
span = (hi - lo).max()

def superellipse_mask(n_px, rect, n=5.0):
    x0, y0, w, h = rect
    yy, xx = np.mgrid[0:n_px, 0:n_px].astype(np.float32) + 0.5
    u = (xx - (x0 + w / 2)) / (w / 2)
    v = (yy - (y0 + h / 2)) / (h / 2)
    r = np.abs(u) ** n + np.abs(v) ** n
    return r

def render(loop_frac=0.58, glow=0.55, pool=0.15, lift=-0.010):
    N = S * SS
    body = (100 * SS, 100 * SS, 824 * SS, 824 * SS)
    r = superellipse_mask(N, body)
    # antialiased body coverage
    edge = 1.0 / (824 * SS / 2) * 5.0
    cov = np.clip((1 - r) / edge + 0.5, 0, 1)
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) / N
    # night ground, a little lighter towards the top
    night = np.array([11, 12, 14], np.float32) / 255
    top = np.array([24, 24, 28], np.float32) / 255
    g = np.clip((0.9 - yy) / 0.8, 0, 1)[..., None]
    ground = night + (top - night) * g ** 1.6
    # the loop
    scale = loop_frac * 824 * SS / span
    cx, cy = N / 2, N / 2 + lift * N
    img = Image.new('L', (N, N), 0)
    dr = ImageDraw.Draw(img)
    for p in polys:
        q = (p - ctr) * scale + [cx, cy]
        dr.polygon([tuple(x) for x in q], fill=255)
    line = np.asarray(img, np.float32) / 255
    small = line.reshape(S, SS, S, SS).mean((1, 3))
    ember = np.array([255, 106, 69], np.float32) / 255
    # light: the line's own glow, and a warm pool inside the circle
    halo = ndimage.gaussian_filter(small, 14) * glow + ndimage.gaussian_filter(small, 46) * glow * 0.8
    yy1, xx1 = np.mgrid[0:S, 0:S].astype(np.float32)
    rad = np.hypot(xx1 - S / 2, yy1 - (S / 2 + lift * S)) / (loop_frac * 824 / 2)
    poolm = np.exp(-(rad ** 2) / 0.55) * pool
    ground_s = ground.reshape(S, SS, S, SS, 3).mean((1, 3))
    lin = ground_s ** 2.2
    lin = lin + (ember ** 2.2)[None, None] * (halo[..., None] * 0.35 + poolm[..., None] * 0.18)
    col = lin ** (1 / 2.2)
    col = col * (1 - small[..., None]) + ember[None, None] * small[..., None]
    cov_s = cov.reshape(S, SS, S, SS).mean((1, 3))
    # rim: a hair of light along the top edge, as a glass edge catches it
    inner = np.clip((1 - superellipse_mask(S, (100, 100, 824, 824))) / (5 / 412) + 0.5, 0, 1)
    inner2 = np.clip((1 - superellipse_mask(S, (101.5, 101.5, 821, 821))) / (5 / 410) + 0.5, 0, 1)
    rim = np.clip(inner - inner2, 0, 1) * np.clip((0.55 - yy1 / S) / 0.45, 0, 1) * 0.10
    col = np.clip(col + rim[..., None], 0, 1)
    # shadow under the body
    sh = ndimage.gaussian_filter(np.roll(cov_s, 12, axis=0), 22) * 0.5
    a = np.clip(cov_s + sh * (1 - cov_s), 0, 1)
    rgb = np.where(cov_s[..., None] > 0, col, 0)
    out = np.dstack([rgb * cov_s[..., None] / np.maximum(a, 1e-6)[..., None], a])
    return Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), 'RGBA')

if __name__ == '__main__':
    im = render()
    im.save(sys.argv[2])

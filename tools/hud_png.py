#!/usr/bin/env python3
# hud_png.py hud_N.rgba [out.png] - a saved HUD texture (h57f, Documents/hud_<n>.rgba: width, height, RGBA8 sRGB
# premultiplied) as a PNG: left the HUD over black (what the panel adds), right its alpha (white = covering): a pale
# full-screen layer shows as a grey right half.
import struct, sys
from PIL import Image
d = open(sys.argv[1], 'rb').read(); w, h = struct.unpack_from('<II', d, 0); px = d[8:8 + w * h * 4]
rgb = Image.frombytes('RGBA', (w, h), px)
a = rgb.getchannel('A')
out = Image.new('RGB', (w * 2, h)); out.paste(rgb.convert('RGB'), (0, 0)); out.paste(Image.merge('RGB', (a, a, a)), (w, 0))
out.save(sys.argv[2] if len(sys.argv) > 2 else sys.argv[1].replace('.rgba', '.png'))
hist = a.histogram(); n = w * h
print('%dx%d: alpha > 0.02 on %.1f %%, > 0.5 on %.1f %%, mean alpha %.3f' % (w, h, 100 * sum(hist[6:]) / n, 100 * sum(hist[128:]) / n, sum(i * c for i, c in enumerate(hist)) / n / 255))

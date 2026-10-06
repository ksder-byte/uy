#!/usr/bin/env python3
"""Иконки сайта из квадратного логотипа (лучше от 256×256 px) → landing/lp/.

    python3 scripts/make-icons.py logo.png      # нужен Pillow: pip install pillow
    bash scripts/build-installer.sh              # затем пересобрать install.sh

Набор под требования поисковиков:
  favicon.ico          16, 32, 48 px — браузеры и /favicon.ico
  favicon-192.png      Google: квадрат, размер кратен 48 px
  favicon-120.png      Яндекс: 120×120
  favicon-32.png       вкладка браузера
  apple-touch-icon.png 180×180 без прозрачности — иконка на экране iPhone
"""
import os
import sys

from PIL import Image

if len(sys.argv) != 2:
    sys.exit(__doc__)
src = Image.open(sys.argv[1]).convert('RGBA')
if src.width != src.height:
    sys.exit('Логотип должен быть квадратным, сейчас %dx%d.' % src.size)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'landing', 'lp')


def scaled(size):
    return src.resize((size, size), Image.LANCZOS)


src.save(os.path.join(out, 'favicon.ico'), sizes=[(16, 16), (32, 32), (48, 48)])
for size in (32, 120, 192):
    # Палитра с прозрачностью: в 2–3 раза легче, для иконки разницы не видно.
    scaled(size).quantize(colors=128, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).save(
        os.path.join(out, 'favicon-%d.png' % size), optimize=True)
touch = Image.new('RGB', (180, 180), (0, 0, 0))
touch.paste(scaled(180), mask=scaled(180))
touch.quantize(colors=96, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(
    os.path.join(out, 'apple-touch-icon.png'), optimize=True)
for name in ('favicon.ico', 'favicon-32.png', 'favicon-120.png', 'favicon-192.png', 'apple-touch-icon.png'):
    print('%-22s %6d байт' % (name, os.path.getsize(os.path.join(out, name))))

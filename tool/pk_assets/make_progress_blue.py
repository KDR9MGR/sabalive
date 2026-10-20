"""Makes the blue twin of the red progress bar: `assets/pk/pk_progress_red.svga` -> `pk_progress_blue.svga`.

The red art sits at hue ~1 degree (pictures) and ~348 degrees (the bar's rounded-rectangle fill); the blue sword art
(`pk_mic_blue.svga`) is at ~203 degrees, so the pictures are turned by 202 degrees and the fill is set to 203.

    python3 tool/pk_assets/make_progress_blue.py        (needs Pillow and numpy)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import svga  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PK = os.path.normpath(os.path.join(HERE, '..', '..', 'assets', 'pk'))
RED_HUE = 0.8
BLUE_HUE = 203.0

movie = svga.read(os.path.join(PK, 'pk_progress_red.svga'))
blue = svga.retint(movie, BLUE_HUE - RED_HUE, BLUE_HUE)
svga.write(os.path.join(PK, 'pk_progress_blue.svga'), blue)
print('wrote', os.path.join(PK, 'pk_progress_blue.svga'))

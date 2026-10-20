"""Reads, rewrites and hue-shifts SVGA 2.x files (zlib + protobuf), with no protobuf library.

Needs Pillow and numpy only for `shift_hue_png`. Used by `make_progress_blue.py`; see README.md.
"""
import colorsys
import io
import struct
import zlib


def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _read_varint(b, i):
    r = 0
    s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        if not c & 0x80:
            return r, i
        s += 7


def fields(b):
    """Yield (field number, wire type, value) of one protobuf message: an int, or raw bytes."""
    i = 0
    while i < len(b):
        k, i = _read_varint(b, i)
        f, w = k >> 3, k & 7
        if w == 0:
            v, i = _read_varint(b, i)
        elif w == 1:
            v = b[i:i + 8]
            i += 8
        elif w == 2:
            n, i = _read_varint(b, i)
            v = b[i:i + n]
            i += n
        elif w == 5:
            v = b[i:i + 4]
            i += 4
        else:
            raise ValueError('unsupported wire type %d' % w)
        yield f, w, v


def encode(f, w, v):
    key = _varint((f << 3) | w)
    if w == 0:
        return key + _varint(v)
    if w == 2:
        return key + _varint(len(v)) + v
    return key + v  # fixed32 / fixed64: already raw bytes


def rewrite(message, handlers):
    """Copy [message], replacing the bytes of any length-delimited field listed in [handlers] by handler(bytes)."""
    out = bytearray()
    for f, w, v in fields(message):
        if w == 2 and f in handlers:
            v = handlers[f](v)
        out += encode(f, w, v)
    return bytes(out)


def read(path):
    return zlib.decompress(open(path, 'rb').read())


def write(path, message):
    open(path, 'wb').write(zlib.compress(message, 9))


def shift_hue_png(png_bytes, degrees):
    """The same picture with every colour turned [degrees] around the colour wheel (alpha untouched)."""
    import numpy as np
    from PIL import Image

    im = Image.open(io.BytesIO(png_bytes)).convert('RGBA')
    alpha = im.getchannel('A')
    hsv = np.asarray(im.convert('RGB').convert('HSV')).copy()
    hsv[..., 0] = (hsv[..., 0].astype(int) + round(degrees * 255 / 360)) % 256
    out = Image.fromarray(hsv, 'HSV').convert('RGB').convert('RGBA')
    out.putalpha(alpha)
    buf = io.BytesIO()
    out.save(buf, 'PNG', optimize=True)
    return buf.getvalue()


def _recolor_rgba(rgba, hue_to):
    """An RGBA message (four float32 fields) with its hue moved to [hue_to] degrees (saturation and brightness kept)."""
    vals = {1: 0.0, 2: 0.0, 3: 0.0, 4: 1.0}
    for f, _, v in fields(rgba):
        vals[f] = struct.unpack('<f', v)[0]
    h, s, v = colorsys.rgb_to_hsv(vals[1], vals[2], vals[3])
    r, g, b = colorsys.hsv_to_rgb(hue_to / 360.0, s, v)
    return b''.join(encode(i, 5, struct.pack('<f', x)) for i, x in ((1, r), (2, g), (3, b), (4, vals[4])))


def retint(message, image_hue_shift, shape_hue_to):
    """The whole movie with its pictures shifted by [image_hue_shift] degrees and the fill / stroke of its vector shapes set to the
    hue [shape_hue_to]."""
    def style(b):
        return rewrite(b, {1: lambda c: _recolor_rgba(c, shape_hue_to), 2: lambda c: _recolor_rgba(c, shape_hue_to)})

    def shape(b):
        return rewrite(b, {10: style})

    def frame(b):
        return rewrite(b, {5: shape})

    def sprite(b):
        return rewrite(b, {2: frame})

    def image_entry(b):  # a map entry: 1 = key, 2 = the picture
        return rewrite(b, {2: lambda png: shift_hue_png(png, image_hue_shift)})

    return rewrite(message, {3: image_entry, 4: sprite})

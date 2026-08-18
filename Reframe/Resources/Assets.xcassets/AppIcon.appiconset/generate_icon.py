"""
Generates AppIcon-1024.png. Kept next to the asset so the icon is reproducible rather than a
one-off export nobody can edit.

    python generate_icon.py

Concept — *Reframe*: a faint reference frame behind, tilted; a solid frame in front carrying the
edit — a play mark over a segmented timeline strip with a playhead, in the amber ramp. Warm charcoal ground so it reads at 60 px
and sits well next to Apple's own dark-first apps. Drawn at 4× and downsampled for clean edges.
"""
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math

S = 1024
SS = 4
W = S * SS


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_background():
    top = (34, 26, 24)       # warm charcoal
    mid = (96, 62, 30)       # smoky amber-brown
    bottom = (16, 12, 12)    # near black
    img = Image.new("RGB", (W, W), top)
    px = img.load()
    for y in range(W):
        t = y / (W - 1)
        c = lerp(top, mid, t / 0.55) if t < 0.55 else lerp(mid, bottom, (t - 0.55) / 0.45)
        for x in range(W):
            px[x, y] = c
    # Warm highlight, upper-left — light falling on the frame.
    glow = Image.new("L", (W, W), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W * 0.25, -W * 0.35, W * 0.75, W * 0.65], fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.16))
    warm = Image.new("RGB", (W, W), (245, 184, 77))
    img = Image.composite(Image.blend(img, warm, 0.42), img, glow.point(lambda v: int(v * 0.6)))
    return img


def rounded_frame_mask(box, radius, thickness):
    """Ring mask: a rounded rect stroke."""
    m = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(box, radius=radius, fill=255)
    inner = [box[0] + thickness, box[1] + thickness, box[2] - thickness, box[3] - thickness]
    d.rounded_rectangle(inner, radius=max(0, radius - thickness), fill=0)
    return m


def rotate_mask(m, angle, center):
    return m.rotate(angle, resample=Image.BICUBIC, center=center)


def main():
    img = gradient_background().convert("RGBA")

    cx, cy = W * 0.5, W * 0.5

    # --- Ghost frame (the reference): thin, tilted, translucent, behind-left. ---
    ghost_size = W * 0.50
    gbox = [cx - ghost_size / 2 - W * 0.055, cy - ghost_size / 2 - W * 0.055,
            cx + ghost_size / 2 - W * 0.055, cy + ghost_size / 2 - W * 0.055]
    ghost = rounded_frame_mask(gbox, radius=W * 0.075, thickness=W * 0.022)
    ghost = rotate_mask(ghost, 9, center=(cx - W * 0.055, cy - W * 0.055))
    ghost_layer = Image.new("RGBA", (W, W), (255, 240, 220, 0))
    ghost_layer.putalpha(ghost.point(lambda v: int(v * 0.42)))
    img = Image.alpha_composite(img, ghost_layer)

    # --- Solid frame (yours): thick, upright, front-right, with a soft shadow. ---
    size = W * 0.50
    box = [cx - size / 2 + W * 0.045, cy - size / 2 + W * 0.045,
           cx + size / 2 + W * 0.045, cy + size / 2 + W * 0.045]
    thickness = W * 0.052
    frame = rounded_frame_mask(box, radius=W * 0.085, thickness=thickness)

    shadow = Image.new("RGBA", (W, W), (12, 8, 6, 0))
    shadow.putalpha(frame.filter(ImageFilter.GaussianBlur(W * 0.02)).point(lambda v: int(v * 0.55)))
    shadow = ImageChops.offset(shadow, 0, int(W * 0.018))
    img = Image.alpha_composite(img, shadow)

    frame_layer = Image.new("RGBA", (W, W), (255, 248, 238, 0))
    frame_layer.putalpha(frame)
    img = Image.alpha_composite(img, frame_layer)

    # --- The edit inside: a play mark over a segmented timeline strip. ---
    inner_left = box[0] + thickness
    inner_right = box[2] - thickness
    inner_top = box[1] + thickness
    inner_bottom = box[3] - thickness
    inner_w = inner_right - inner_left
    inner_h = inner_bottom - inner_top
    icx = (inner_left + inner_right) / 2

    accent_top = (255, 208, 112)
    accent_bottom = (222, 140, 38)

    def gradient_layer(mask, top, bottom, y0, y1):
        layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        px = layer.load()
        bbox = mask.getbbox()
        if not bbox:
            return layer
        for yy in range(bbox[1], bbox[3]):
            t = min(1, max(0, (yy - y0) / max(1, (y1 - y0))))
            c = lerp(top, bottom, t)
            for xx in range(bbox[0], bbox[2]):
                px[xx, yy] = (*c, 255)
        layer.putalpha(mask)
        return layer

    # Play triangle: rounded corners via blur-threshold, sized to sit in the upper 60%.
    tri_h = inner_h * 0.42
    tri_w = tri_h * 0.92
    tcy = inner_top + inner_h * 0.40
    tri = Image.new("L", (W, W), 0)
    td = ImageDraw.Draw(tri)
    pts = [(icx - tri_w * 0.42, tcy - tri_h / 2), (icx - tri_w * 0.42, tcy + tri_h / 2), (icx + tri_w * 0.58, tcy)]
    td.polygon(pts, fill=255)
    r = W * 0.012
    tri = tri.filter(ImageFilter.GaussianBlur(r)).point(lambda v: 255 if v > 128 else 0)
    tri = tri.filter(ImageFilter.GaussianBlur(SS * 0.6))
    img = Image.alpha_composite(img, gradient_layer(tri, accent_top, accent_bottom, tcy - tri_h / 2, tcy + tri_h / 2))

    # Timeline strip: five clip segments of different lengths, one gap wide, under the play mark.
    strip_y = inner_top + inner_h * 0.74
    strip_h = inner_h * 0.115
    strip_w = inner_w * 0.68
    lengths = [0.16, 0.30, 0.12, 0.24, 0.18]
    gap = strip_w * 0.035
    total = sum(lengths)
    usable = strip_w - gap * (len(lengths) - 1)
    strip = Image.new("L", (W, W), 0)
    sd = ImageDraw.Draw(strip)
    x = icx - strip_w / 2
    for i, l in enumerate(lengths):
        seg_w = usable * l / total
        sd.rounded_rectangle([x, strip_y - strip_h / 2, x + seg_w, strip_y + strip_h / 2], radius=strip_h * 0.35, fill=255)
        x += seg_w + gap
    strip = strip.filter(ImageFilter.GaussianBlur(SS * 0.6))
    strip_layer = Image.new("RGBA", (W, W), (255, 248, 238, 0))
    strip_layer.putalpha(strip.point(lambda v: int(v * 0.92)))
    img = Image.alpha_composite(img, strip_layer)

    # Playhead: a thin accent tick through the strip, a third of the way in.
    ph_x = icx - strip_w / 2 + strip_w * 0.36
    ph = Image.new("L", (W, W), 0)
    ImageDraw.Draw(ph).rounded_rectangle(
        [ph_x - W * 0.008, strip_y - strip_h * 0.95, ph_x + W * 0.008, strip_y + strip_h * 0.95],
        radius=W * 0.008, fill=255
    )
    ph = ph.filter(ImageFilter.GaussianBlur(SS * 0.6))
    img = Image.alpha_composite(img, gradient_layer(ph, accent_top, accent_bottom, strip_y - strip_h, strip_y + strip_h))

    out = img.convert("RGB").resize((S, S), Image.LANCZOS)
    out.save("AppIcon-1024.png", "PNG", optimize=True)
    print("wrote AppIcon-1024.png")


if __name__ == "__main__":
    main()

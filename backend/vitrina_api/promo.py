"""Short promo video for a listing: the seller's real photos turning on the showcase backdrop, with music.

Made for sharing to Instagram, TikTok or WhatsApp statuses: vertical 720x1280, 8 seconds, H.264 + AAC.
Only the seller's photos are shown; nothing about the shoe is drawn or generated. The music is synthesised
here from plain sine waves and noise, so there is no third-party recording and nothing to license.

ffmpeg is needed for encoding. Without it, promo videos are off and the rest of the API is unaffected.
"""
from __future__ import annotations

import io
import math
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS, SECONDS = 720, 1280, 30, 8
FONT = Path(__file__).parent / "assets" / "Inter.ttf"  # Inter, SIL Open Font License (assets/OFL.txt)
INK, ACCENT, STUDIO = (14, 14, 16), (255, 90, 54), (243, 242, 239)
SPIN_TURN_SECONDS = 3.0  # one full turn of the 360° frames
END_CARD_AT = 6.6

CTA = {"kk": "Жан-жағынан VITRINA-да қараңыз", "ru": "Смотрите со всех сторон в VITRINA"}


def format_tenge(tiyn: int) -> str:
    """32 900 ₸, the way the app writes prices."""
    whole, part = divmod(tiyn, 100)
    text = f"{whole:,}".replace(",", " ")
    return f"{text},{part:02d} ₸" if part else f"{text} ₸"


def available() -> bool:
    return shutil.which("ffmpeg") is not None


def font(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(str(FONT), size)
    f.set_variation_by_name(weight)
    return f


def backdrop(style: str) -> Image.Image:
    """The same three showcase styles the app draws behind the 360° view."""
    if style == "premium":
        inner, outer = (58, 58, 64), (17, 17, 20)
        y, x = [c.reshape(-1) for c in _grid()]
        d = ((x - W / 2) ** 2 + (y - H * 0.45) ** 2) ** 0.5 / (0.9 * max(W, H) * 0.75)
        return _mix(inner, outer, d)
    if style == "dynamic":
        y, x = [c.reshape(-1) for c in _grid()]
        return _mix((255, 227, 211), (217, 230, 255), (x / W + y / H) / 2)
    return Image.new("RGB", (W, H), STUDIO)


def _grid():
    import numpy as np
    return np.mgrid[0:H, 0:W].astype("float32")


def _mix(a, b, t) -> Image.Image:
    import numpy as np
    t = np.clip(t, 0, 1)[:, None]
    rgb = np.array(a, "float32") * (1 - t) + np.array(b, "float32") * t
    return Image.fromarray(rgb.reshape(H, W, 3).astype("uint8"), "RGB")


def _faded(layer: Image.Image, alpha: float) -> Image.Image:
    if alpha >= 1:
        return layer
    out = layer.copy()
    out.putalpha(layer.getchannel("A").point(lambda v: int(v * max(0.0, alpha))))
    return out


def _ease(t: float) -> float:
    t = min(1.0, max(0.0, t))
    return 1 - (1 - t) ** 3


def _text_layer(lines: list[tuple[str, ImageFont.FreeTypeFont, tuple]], width: int, gap: int = 8) -> Image.Image:
    heights = [f.getbbox(t)[3] - f.getbbox(t)[1] + gap for t, f, _ in lines]
    layer = Image.new("RGBA", (width, sum(heights) + 8), (0, 0, 0, 0))
    draw, y = ImageDraw.Draw(layer), 0
    for (text, f, colour), h in zip(lines, heights):
        draw.text((width // 2, y - f.getbbox(text)[1]), text, font=f, fill=colour, anchor="ma")
        y += h
    return layer


def _wrap(text: str, f: ImageFont.FreeTypeFont, width: int, max_lines: int = 2) -> list[str]:
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if f.getlength(trial) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = lines[-1].rstrip(" ,.") + "…"
    return lines


def _price_pill(price: str) -> Image.Image:
    f = font(46, "Bold")
    w = int(f.getlength(price)) + 64
    pill = Image.new("RGBA", (w, 84), (0, 0, 0, 0))
    d = ImageDraw.Draw(pill)
    d.rounded_rectangle((0, 0, w - 1, 83), radius=42, fill=ACCENT + (255,))
    d.text((w // 2, 42), price, font=f, fill=(255, 255, 255), anchor="mm")
    return pill


def _prepare_photo(img: Image.Image, box: int) -> Image.Image:
    """Fit into a square box. A cut-out keeps its transparency; a plain photo gets rounded corners."""
    img = img.convert("RGBA")
    cutout = img.getchannel("A").getextrema()[0] < 250
    if cutout:
        img = img.crop(img.getchannel("A").point(lambda v: 255 if v > 24 else 0).getbbox() or (0, 0, *img.size))
    img.thumbnail((box, box), Image.Resampling.LANCZOS)
    if not cutout:
        mask = Image.new("L", img.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=36, fill=255)
        img.putalpha(mask)
    return img


def _shadow(width: int) -> Image.Image:
    sh = Image.new("RGBA", (width + 120, 120), (0, 0, 0, 0))
    ImageDraw.Draw(sh).ellipse((60, 40, width + 60, 80), fill=(0, 0, 0, 70))
    return sh.filter(ImageFilter.GaussianBlur(18))


def render_frames(photos: list[Image.Image], *, title: str, price: str, style: str = "clean", lang: str = "kk",
                  spin: bool = True):
    """Yields RGB frames. spin=True treats photos as a 360° sequence; otherwise they cross-fade."""
    if not photos:
        raise ValueError("no photos")
    dark = style == "premium"
    fg = (255, 255, 255) if dark else INK
    sub = (200, 200, 205) if dark else (90, 90, 96)
    bg = backdrop(style)
    box = 600
    shots = [_prepare_photo(p, box) for p in photos]
    shadow = _shadow(int(box * 0.8))
    brand = _text_layer([("V I T R I N A", font(30, "Bold"), fg)], W)
    title_layer = _text_layer([(t, font(50, "Bold"), fg) for t in _wrap(title, font(50, "Bold"), W - 96)], W)
    pill = _price_pill(price)
    cta = _text_layer([(CTA.get(lang, CTA["kk"]), font(30, "Medium"), sub)], W)
    end_brand = _text_layer([("VITRINA", font(96, "Black"), (255, 255, 255))], W)
    end_cta = _text_layer([(CTA.get(lang, CTA["kk"]), font(32, "Medium"), (220, 220, 225))], W)
    end_price = _price_pill(price)

    for i in range(FPS * SECONDS):
        t = i / FPS
        frame = bg.copy().convert("RGBA")
        frame.alpha_composite(brand, (0, 70))
        # The product: a gentle push-in and float; spin frames advance in order, photos cross-fade.
        scale = 1.0 + 0.06 * _ease(t / END_CARD_AT)
        lift = int(10 * math.sin(t * 2.2))
        cx, cy = W // 2, 600 + lift
        if spin:
            shot = shots[int(t / SPIN_TURN_SECONDS * len(shots)) % len(shots)]
        else:
            per = END_CARD_AT / len(shots)
            k = min(int(t / per), len(shots) - 1)
            nxt = shots[min(k + 1, len(shots) - 1)]
            blend = _ease((t - k * per - (per - 0.4)) / 0.4) if k + 1 < len(shots) else 0
            shot = shots[k] if blend <= 0 else Image.blend(shots[k].resize(nxt.size), nxt, blend)
        s = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.Resampling.BILINEAR)
        frame.alpha_composite(shadow, (cx - shadow.width // 2, cy + s.height // 2 - 60 - lift))
        frame.alpha_composite(s, (cx - s.width // 2, cy - s.height // 2))
        # Text slides in after the product is on screen.
        a = _ease((t - 0.4) / 0.6)
        frame.alpha_composite(_faded(title_layer, a), (0, 930 + int(30 * (1 - a))))
        b = _ease((t - 0.9) / 0.5)
        frame.alpha_composite(_faded(pill, b), ((W - pill.width) // 2, 930 + title_layer.height + 16))
        frame.alpha_composite(_faded(cta, _ease((t - 1.4) / 0.6)), (0, H - 90))
        # End card: brand, price and the call to action on ink.
        e = _ease((t - END_CARD_AT) / 0.5)
        if e > 0:
            card = Image.new("RGBA", (W, H), INK + (int(255 * e),))
            frame.alpha_composite(card)
            frame.alpha_composite(_faded(end_brand, e), (0, 470))
            frame.alpha_composite(_faded(end_price, e), ((W - end_price.width) // 2, 620))
            frame.alpha_composite(_faded(end_cta, e), (0, 740))
        yield frame.convert("RGB")


def music(seconds: float = SECONDS, rate: int = 44100) -> bytes:
    """A short upbeat loop at 120 bpm: Am-F-C-G pad, bass, kick and hi-hat. Returns 16-bit stereo WAV."""
    import numpy as np

    n = int(seconds * rate)
    t = np.arange(n) / rate
    beat = 0.5
    out = np.zeros(n, "float32")

    def hz(midi):
        return 440.0 * 2 ** ((midi - 69) / 12)

    chords = [(57, 60, 64), (53, 57, 60), (48, 52, 55), (55, 59, 62)]  # Am F C G
    for bar, chord in enumerate(chords * 2):
        start = bar * 4 * beat
        if start >= seconds:
            break
        seg = (t >= start) & (t < start + 4 * beat)
        local = t[seg] - start
        env = np.minimum(local / 0.25, 1) * np.exp(-local * 0.35)
        pad = sum(np.sin(2 * np.pi * hz(m + 12) * local) + 0.3 * np.sin(2 * np.pi * hz(m + 12) * 2.003 * local)
                  for m in chord)
        out[seg] += 0.06 * pad * env
        for k in (0, 2):  # bass on beats 1 and 3
            bs = (t >= start + k * beat) & (t < start + (k + 2) * beat)
            bl = t[bs] - start - k * beat
            out[bs] += 0.22 * np.sin(2 * np.pi * hz(chord[0] - 12) * bl) * np.exp(-bl * 3)
    rng = np.random.default_rng(7)
    for k in range(int(seconds / beat)):
        s = int(k * beat * rate)
        kl = np.arange(min(int(0.3 * rate), n - s)) / rate
        sweep = 2 * np.pi * (45 * kl + (120 - 45) / 18 * (1 - np.exp(-18 * kl)))
        out[s:s + kl.size] += 0.55 * np.sin(sweep) * np.exp(-kl * 9)
        h = int((k + 0.5) * beat * rate)
        hl = min(int(0.05 * rate), n - h)
        if hl > 0:
            noise = np.diff(rng.standard_normal(hl + 1)).astype("float32")
            out[h:h + hl] += 0.05 * noise * np.exp(-np.arange(hl) / rate * 80)
    fade = np.minimum(1, np.minimum(t / 0.2, (seconds - t) / 1.2))
    out *= np.clip(fade, 0, 1)
    out /= max(1e-6, float(np.abs(out).max())) / 0.85
    pcm = (out * 32767).astype("<i2")
    stereo = np.repeat(pcm[:, None], 2, axis=1)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(stereo.tobytes())
    return buf.getvalue()


def render_video(photos: list[Image.Image], *, title: str, price: str, style: str = "clean", lang: str = "kk",
                 spin: bool = True) -> bytes:
    """MP4 bytes. Raises RuntimeError when ffmpeg is missing or fails."""
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg not found")
    with tempfile.TemporaryDirectory() as tmp:
        audio, out = Path(tmp) / "music.wav", Path(tmp) / "promo.mp4"
        audio.write_bytes(music())
        proc = subprocess.Popen(
            [ffmpeg, "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
             "-r", str(FPS), "-i", "-", "-i", str(audio), "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
             "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-shortest", "-movflags", "+faststart",
             str(out)],
            stdin=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for frame in render_frames(photos, title=title, price=price, style=style, lang=lang, spin=spin):
                proc.stdin.write(frame.tobytes())
        finally:
            proc.stdin.close()
            err = proc.stderr.read()
            proc.stderr.close()
            proc.wait()
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {err.decode(errors='replace')[-500:]}")
        return out.read_bytes()

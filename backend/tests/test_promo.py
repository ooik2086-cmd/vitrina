import io
import unittest
import wave

from PIL import Image

from vitrina_api import promo


def shoe(colour, alpha=True):
    img = Image.new("RGBA" if alpha else "RGB", (500, 400), (0, 0, 0, 0) if alpha else (240, 240, 240))
    img.paste(Image.new("RGB", (300, 150), colour), (100, 150))
    return img


class PromoTests(unittest.TestCase):
    def test_price_text_matches_the_app(self):
        self.assertEqual(promo.format_tenge(3_290_000), "32 900 ₸")
        self.assertEqual(promo.format_tenge(100_000_000), "1 000 000 ₸")
        self.assertEqual(promo.format_tenge(123), "1,23 ₸")

    def test_frames_keep_the_photo_colours_and_end_on_the_brand_card(self):
        red = (200, 30, 30)
        frames = list(promo.render_frames([shoe(red)] * 8, title="Кроссовка", price="10 000 ₸", style="clean"))
        self.assertEqual(len(frames), promo.FPS * promo.SECONDS)
        self.assertEqual(frames[0].size, (promo.W, promo.H))
        # The shoe's pixels are pasted, never recoloured: the centre of an early frame is the photo's red.
        r, g, b = frames[10].getpixel((promo.W // 2, 600))
        self.assertTrue(abs(r - red[0]) < 12 and abs(g - red[1]) < 12 and abs(b - red[2]) < 12, (r, g, b))
        self.assertEqual(frames[-1].getpixel((10, 10)), promo.INK)

    def test_music_is_eight_seconds_of_stereo_without_clipping(self):
        with wave.open(io.BytesIO(promo.music())) as w:
            self.assertEqual((w.getnchannels(), w.getframerate()), (2, 44100))
            self.assertAlmostEqual(w.getnframes() / w.getframerate(), promo.SECONDS, places=2)
            import numpy as np
            pcm = np.frombuffer(w.readframes(w.getnframes()), "<i2")
            self.assertLess(np.abs(pcm).max(), 32767)
            self.assertGreater(np.abs(pcm).max(), 20000)

    @unittest.skipUnless(promo.available(), "ffmpeg not installed")
    def test_video_from_plain_photos(self):
        data = promo.render_video([shoe((30, 30, 200), alpha=False), shoe((30, 200, 30), alpha=False)],
                                  title="Етік", price="25 000 ₸", style="premium", lang="ru", spin=False)
        self.assertEqual(data[4:8], b"ftyp")
        self.assertGreater(len(data), 20_000)


if __name__ == "__main__":
    unittest.main()

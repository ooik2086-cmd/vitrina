// Opens a shared listing page in a real browser and reports what its 360° turn did, for test_share_browser.py.
// The page and its photos are served from memory: the page with the headers the server sent (its Content-Security-
// Policy included), each photo as a small PNG of its own colour, so which photo is on screen can be told apart.
//
//     node share_page_browser.cjs case.json   ->   one JSON line of observations on stdout
//
// case.json: {url, html, headers, images: {url: base64 png}, fail: [url]}. Needs the playwright package (NODE_PATH)
// and a Chromium it can launch.
const fs = require('fs');
const { chromium } = require('playwright');

(async () => {
  const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch();
  const out = {};
  try {
    for (const calm of [false, true]) {
      const page = await browser.newPage({ viewport: { width: 412, height: 860 }, reducedMotion: calm ? 'reduce' : 'no-preference' });
      const errors = [], asked = [];
      page.on('pageerror', e => errors.push(e.message));
      // A blocked script or style (Content-Security-Policy) shows only here; a photo that fails to load is expected.
      page.on('console', m => { if (m.type() === 'error' && !m.text().startsWith('Failed to load resource')) errors.push(m.text()); });
      await page.route('**/*', route => {
        const url = route.request().url();
        if (url === c.url) return route.fulfill({ status: 200, headers: c.headers, body: c.html });
        asked.push(url);
        if (c.fail.includes(url) || !(url in c.images)) return route.abort();
        return route.fulfill({ status: 200, contentType: 'image/png', body: Buffer.from(c.images[url], 'base64') });
      });
      await page.goto(c.url);
      const src = () => page.$eval('#shot', i => i.getAttribute('src'));
      const now = () => page.$eval('#stage', s => +s.getAttribute('aria-valuenow'));
      const seen = { first: await src(), shown: [] };
      // The turn on arrival: 12 frames at 200 ms each, then a rest of 250 ms before the full photo.
      // A page scrolled with a finger that starts on the shoe, early in the turn, must not stop it.
      const box = await (await page.$('#stage')).boundingBox();
      let scrolled = false;
      const t0 = Date.now();
      while (Date.now() - t0 < 3500) {
        if (!scrolled && Date.now() - t0 > 500) {
          scrolled = true;
          seen.askedBeforeTouch = [...asked];
          await page.mouse.move(box.x + 200, box.y + 100);
          await page.mouse.down();
          await page.mouse.move(box.x + 205, box.y + 300, { steps: 5 });
          await page.mouse.up();
        }
        const s = await src();
        if (seen.shown[seen.shown.length - 1] !== s) seen.shown.push(s);
        await page.waitForTimeout(30);
      }
      seen.restAfterTurn = await src();
      // A sideways drag of a third of the stage, rightwards.
      const before = await now();
      await page.mouse.move(box.x + 100, box.y + box.height / 2);
      await page.mouse.down();
      await page.mouse.move(box.x + 100 + box.width / 3, box.y + box.height / 2, { steps: 10 });
      seen.drag = { before, during: await now(), srcDuring: await src() };
      await page.mouse.up();
      await page.waitForTimeout(500);
      seen.drag.rest = await src();
      seen.drag.after = await now();
      // A vertical move that starts on the shoe leaves the turn alone.
      const still = await now();
      await page.mouse.move(box.x + 200, box.y + 100);
      await page.mouse.down();
      await page.mouse.move(box.x + 203, box.y + 300, { steps: 10 });
      await page.mouse.up();
      seen.vertical = { before: still, after: await now() };
      // The keys a screen reader user or a keyboard uses.
      await page.focus('#stage');
      const k = await now();
      await page.keyboard.press('ArrowLeft');
      const left = await now();
      await page.keyboard.press('ArrowRight');
      await page.keyboard.press('ArrowRight');
      seen.keys = { before: k, left, right: await now() };
      seen.errors = errors;
      out[calm ? 'calm' : 'auto'] = seen;
      await page.close();
    }
  } finally {
    await browser.close();
  }
  process.stdout.write(JSON.stringify(out) + '\n');
})().catch(e => { console.error(e); process.exit(1); });

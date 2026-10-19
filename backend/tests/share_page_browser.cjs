// Opens a shared listing page in a real browser and reports what its 360° turn did, for test_share_browser.py.
// The page and its photos are served from memory: the page with the headers the server sent (its Content-Security-
// Policy included), each photo as a small PNG of its own colour.
//
//     node share_page_browser.cjs case.json   ->   one JSON line of observations per mode on stdout
//
// case.json: {url, html, headers, images: {url: base64 png}, fail: [url], modes: [...]}. Modes:
//   auto      a desktop browser: the turn on arrival, a mouse drag, the arrow keys
//   calm      the same asking for less motion
//   touch     a phone (less motion, so nothing turns on its own): finger swipes, sent as real touches
//   saveData  a phone with data saving on;  2g  a phone on a 2g connection
// Needs the playwright package (NODE_PATH) and a Chromium it can launch.
const fs = require('fs');
const { chromium } = require('playwright');

// Every picture the page puts on the stage, in order, recorded in the page itself so none is missed between looks.
const RECORD = () => {
  window.__shown = [];
  const src = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
  Object.defineProperty(HTMLImageElement.prototype, 'src', {
    get() { return src.get.call(this); },
    set(v) { if (this.id === 'shot') window.__shown.push(v); src.set.call(this, v); },
  });
};

async function open(browser, c, mode) {
  const phone = mode !== 'auto' && mode !== 'calm';
  const context = await browser.newContext({
    viewport: { width: 412, height: phone ? 640 : 860 }, isMobile: phone, hasTouch: phone,
    reducedMotion: mode === 'calm' || mode === 'touch' ? 'reduce' : 'no-preference',
  });
  const page = await context.newPage();
  await page.addInitScript(RECORD);
  if (mode === 'saveData' || mode === '2g') {
    const connection = mode === 'saveData' ? { saveData: true, effectiveType: '4g' } : { saveData: false, effectiveType: '2g' };
    await page.addInitScript(conn => Object.defineProperty(navigator, 'connection', { get: () => conn }), connection);
  }
  const seen = { errors: [] }, asked = [];
  page.on('pageerror', e => seen.errors.push(e.message));
  // A blocked script or style (Content-Security-Policy) shows only here; a photo that fails to load is expected.
  page.on('console', m => { if (m.type() === 'error' && !m.text().startsWith('Failed to load resource')) seen.errors.push(m.text()); });
  await page.route('**/*', route => {
    const url = route.request().url();
    if (url === c.url) return route.fulfill({ status: 200, headers: c.headers, body: c.html });
    asked.push(url);
    if (c.fail.includes(url) || !(url in c.images)) return route.abort();
    return route.fulfill({ status: 200, contentType: 'image/png', body: Buffer.from(c.images[url], 'base64') });
  });
  await page.goto(c.url);
  return { context, page, seen, asked };
}

async function run(browser, c, mode) {
  const { context, page, seen, asked } = await open(browser, c, mode);
  const src = () => page.$eval('#shot', i => i.getAttribute('src'));
  const now = () => page.$eval('#stage', s => +s.getAttribute('aria-valuenow'));
  const shown = () => page.evaluate(() => window.__shown.slice());
  const box = await (await page.$('#stage')).boundingBox();
  seen.first = await src();
  seen.stage = { width: box.width, height: box.height };
  seen.hint = await page.$eval('.hint', h => h.textContent);
  if (mode === 'touch') {
    // Real finger touches: the browser decides from the stage's touch-action whether a swipe scrolls or turns.
    const cdp = await context.newCDPSession(page);
    const swipe = async (x0, y0, x1, y1) => {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x0, y: y0 }] });
      for (let i = 1; i <= 10; i++) {
        const p = { x: x0 + (x1 - x0) * i / 10, y: y0 + (y1 - y0) * i / 10 };
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [p] });
      }
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await page.waitForTimeout(400);
    };
    const mid = box.y + box.height / 2;
    const k = await now();
    await swipe(box.x + 200, mid + 100, box.x + 202, mid - 150); // up the page, starting on the shoe
    seen.scroll = { scrolled: await page.evaluate(() => window.scrollY), before: k, after: await now() };
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(200);
    const k2 = await now();
    await swipe(box.x + 100, mid, box.x + 100 + box.width / 3, mid); // then sideways: turns, after the scroll
    seen.swipe = { before: k2, after: await now() };
    seen.shown = await shown();
    await context.close();
    return seen;
  }
  // Early in the turn, a press on the shoe that moves 7 px sideways and 200 px down must not stop it: a sideways
  // drag takes the turn over only past 8 px.
  await page.waitForTimeout(500);
  seen.askedBeforeTouch = [...asked];
  await page.mouse.move(box.x + 200, box.y + 100);
  await page.mouse.down();
  await page.mouse.move(box.x + 207, box.y + 300, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(4000); // the rest of the turn (12 frames at 200 ms, 250 ms to the full photo), with room
  seen.shown = await shown();
  seen.restAfterTurn = await src();
  seen.restLoaded = await page.$eval('#shot', i => i.complete && i.naturalWidth > 0);
  // A sideways drag of a third of the stage, rightwards.
  const before = await now();
  await page.mouse.move(box.x + 100, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + 100 + box.width / 3, box.y + box.height / 2, { steps: 10 });
  seen.drag = { before, during: await now(), srcDuring: await src() };
  await page.mouse.up();
  await page.waitForTimeout(500);
  seen.drag.rest = await src();
  // The keys a screen reader user or a keyboard uses.
  await page.focus('#stage');
  const k = await now();
  await page.keyboard.press('ArrowLeft');
  const left = await now();
  await page.keyboard.press('ArrowRight');
  await page.keyboard.press('ArrowRight');
  seen.keys = { before: k, left, right: await now() };
  await context.close();
  return seen;
}

(async () => {
  const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch();
  const out = {};
  try {
    for (const mode of c.modes) out[mode] = await run(browser, c, mode);
  } finally {
    await browser.close();
  }
  process.stdout.write(JSON.stringify(out) + '\n');
})().catch(e => { console.error(e); process.exit(1); });

// node scan.js <dir with scan.html, shoe.glb, three160> <out> <variant> [size] [frames, e.g. 0,54,74] [count]
// Writes <out>/<variant>/fNNN.png: the frames of one continuous camera move (scan.html), 103 of them, or 205 (count
// 205) for the same move in half steps, as the approved page's fourth version: 4.5 degrees a frame on the turn.
const { chromium } = require('playwright');
const fs = require('fs'); const http = require('http'); const path = require('path');
const [dir, out, variant, size = '1600', only, count = '103'] = process.argv.slice(2);
if (!['103', '205'].includes(count)) throw new Error(`count is 103 or 205, not ${count}`); // the turn's easing is for these
const types = { '.js': 'text/javascript', '.html': 'text/html' };
const srv = http.createServer((q, s) => {
  const f = path.join(dir, decodeURIComponent(q.url.split('?')[0]));
  fs.readFile(f, (e, d) => {
    if (e) { s.writeHead(404); return s.end(); }
    s.writeHead(200, { 'Content-Type': types[path.extname(f)] || 'application/octet-stream' }); s.end(d);
  });
}).listen(9301, async () => {
  const b = await chromium.launch({
    executablePath: process.env.CHROMIUM || undefined,
    args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
  });
  const p = await b.newPage({ viewport: { width: +size, height: +size } });
  p.on('pageerror', e => console.log('ERR', e.message));
  await p.goto(`http://localhost:9301/scan.html?size=${size}`);
  await p.waitForFunction('window.ready === true', null, { timeout: 180000 });
  const v = (await p.evaluate('window.info')).variants.indexOf(variant);
  if (v < 0) throw new Error(`no variant ${variant}`);
  const vd = path.join(out, variant); fs.mkdirSync(vd, { recursive: true });
  await p.evaluate(([v]) => window.frame(v, 0), [v]); // the first render comes out before the page has settled: not kept
  const frames = only ? only.split(',').map(Number) : [...Array(+count).keys()];
  // Where frame i is on the 103-frame move. The fourth version's turn is eased as that page's frames are: slower past
  // the sides, quicker past the toe and the heel (fitted to its scan's outlines).
  const at = i => {
    if (+count === 103 || i >= 80) return i * 102 / (+count - 1);
    const t = i / 80;
    return 40 * (t - 0.74 * Math.sin(2 * Math.PI * t) / (2 * Math.PI));
  };
  for (const i of frames) {
    const url = await p.evaluate(([v, i]) => window.frame(v, i), [v, at(i)]);
    fs.writeFileSync(path.join(vd, `f${String(i).padStart(3, '0')}.png`), Buffer.from(url.split(',')[1], 'base64'));
  }
  await b.close(); srv.close();
});

// node scan.js <dir with scan.html, shoe.glb, three160> <out> <variant> [size] [frames, e.g. 0,54,74]
// Writes <out>/<variant>/fNNN.png: the 103 frames of one continuous camera move (scan.html).
const { chromium } = require('playwright');
const fs = require('fs'); const http = require('http'); const path = require('path');
const [dir, out, variant, size = '1600', only] = process.argv.slice(2);
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
  const frames = only ? only.split(',').map(Number) : [...Array(103).keys()];
  for (const i of frames) {
    const url = await p.evaluate(([v, i]) => window.frame(v, i), [v, i]);
    fs.writeFileSync(path.join(vd, `f${String(i).padStart(3, '0')}.png`), Buffer.from(url.split(',')[1], 'base64'));
  }
  await b.close(); srv.close();
});

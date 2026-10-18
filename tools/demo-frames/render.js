const { chromium } = require('playwright');
const fs = require('fs'); const http = require('http'); const path = require('path');
const dir = process.argv[2], out = process.argv[3];
const srv = http.createServer((q, s) => { const f = path.join(dir, decodeURIComponent(q.url.split('?')[0]));
  fs.readFile(f, (e, d) => { if (e) { s.writeHead(404); return s.end(); }
    s.writeHead(200, { 'Content-Type': f.endsWith('.js') ? 'text/javascript' : f.endsWith('.html') ? 'text/html' : 'application/octet-stream' }); s.end(d); }); }).listen(9300, async () => {
  const b = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const p = await b.newPage({ viewport: { width: 1200, height: 1200 } });
  p.on('pageerror', e => console.log('ERR', e.message)); p.on('console', m => console.log(m.text()));
  await p.goto('http://localhost:9300/render.html');
  await p.waitForFunction('window.ready === true', null, { timeout: 120000 });
  const info = await p.evaluate('window.info'); console.log(JSON.stringify(info));
  const n = +(process.argv[4] || 36);
  for (let v = 0; v < info.variants.length; v++) {
    const vd = path.join(out, info.variants[v].toLowerCase()); fs.mkdirSync(vd, { recursive: true });
    for (let i = 0; i < n; i++) {
      const url = await p.evaluate(([v, i, n]) => window.frame(v, i, n), [v, i, n]);
      fs.writeFileSync(path.join(vd, `f${String(i).padStart(2, '0')}.jpg`), Buffer.from(url.split(',')[1], 'base64'));
    }
    for (const kind of ['top', 'sole', 'detail']) {
      const url = await p.evaluate(([v, k]) => window.view(v, k), [v, kind]);
      fs.writeFileSync(path.join(vd, `${kind}.jpg`), Buffer.from(url.split(',')[1], 'base64'));
    }
  }
  await b.close(); srv.close();
});

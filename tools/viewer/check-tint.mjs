// Checks the built stage's colours in a real browser: a tint paints the coloured parts, another tint repaints them,
// none shows the colour as made, and the white sole stays white throughout. Run after build.sh:
//   node check-tint.mjs        (set PLAYWRIGHT to playwright's index.mjs if it is not installed here)
import http from 'http';
import fs from 'fs';
import path from 'path';

const { chromium } = await import(process.env.PLAYWRIGHT ?? 'playwright');
const here = path.dirname(new URL(import.meta.url).pathname);
const assets = path.join(here, '../../app/assets/viewer'), models = path.join(here, '../../app/demo/media/models');
const srv = http.createServer((q, r) => {
  const u = decodeURIComponent(q.url.split('?')[0]);
  const p = u.endsWith('.glb') ? path.join(models, path.basename(u)) : path.join(assets, path.basename(u));
  fs.readFile(p, (e, d) => {
    if (e) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { 'content-type': p.endsWith('.js') ? 'text/javascript' : p.endsWith('.html') ? 'text/html' : 'model/gltf-binary' });
    r.end(d);
  });
}).listen(0);
const port = srv.address().port;
const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const pg = await b.newPage({ viewport: { width: 360, height: 560 } });
await pg.addInitScript(() => { window.__m = []; window.Vitrina = { postMessage: m => window.__m.push(JSON.parse(m).type) }; });
await pg.goto(`http://localhost:${port}/index.html`);
await pg.waitForFunction(() => window.__m.includes('page'), null, { timeout: 20000 });
await pg.evaluate(() => vitrina.load({ url: '/shoe-1024.glb', variant: 'beach', tint: [0, 0.62, 0.66] }));
await pg.waitForFunction(() => window.__m.includes('ready'), null, { timeout: 60000 });
// The upper's side, and the sole under it, with the shoe side on as it opens.
const look = async () => {
  await pg.waitForTimeout(1500);
  const png = await pg.screenshot();
  return pg.evaluate(async src => {
    const im = new Image(); im.src = 'data:image/png;base64,' + src; await im.decode();
    const c = document.createElement('canvas'); c.width = im.width; c.height = im.height;
    const g = c.getContext('2d'); g.drawImage(im, 0, 0);
    return [[100, 300], [200, 362]].map(([x, y]) => [...g.getImageData(x, y, 1, 1).data.slice(0, 3)]);
  }, png.toString('base64'));
};
const fails = [];
const want = (name, ok, px) => { if (!ok) fails.push(`${name}: ${JSON.stringify(px)}`); console.log(name, JSON.stringify(px)); };
const red = await look();
want('red', red[0][0] > red[0][1] + 80 && red[0][0] > red[0][2] + 80, red);
await pg.evaluate(() => vitrina.setVariant('beach', [145, 0.38, 0.58]));
const green = await look();
want('green', green[0][1] > green[0][0] + 40 && green[0][1] > green[0][2] + 20, green);
await pg.evaluate(() => vitrina.setVariant('beach', null));
const pink = await look();
want('pink as made', pink[0][0] > pink[0][2] && Math.abs(pink[0][0] - pink[0][2]) < 60, pink);
for (const [n, px] of [['red', red], ['green', green], ['pink', pink]]) {
  want(`${n} sole stays white`, px[1].every(v => v > 200), px);
}
await b.close();
srv.close();
if (fails.length) { console.error('FAILED', fails); process.exit(1); }
console.log('ok');

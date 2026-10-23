// Renders the approved demo's shoe in its 12 colours (6 photos and a turning video's frames each) for app/demo, with
// the app viewer's own light, camera and tint. Run: build the page (see build.py), then
//   node render.mjs OUT_DIR
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const here = path.dirname(new URL(import.meta.url).pathname), models = path.join(here, '../../app/demo/media/models');
const [out, only = '', frames = '144'] = process.argv.slice(2);
const COLOURS = [['көк', 'midnight', null], ['қара', 'street', null], ['қызғылт', 'beach', null],
  ['қызыл', 'beach', [0, .62, .66]], ['бордо', 'beach', [345, .55, .42]], ['жасыл', 'beach', [145, .38, .58]],
  ['хаки', 'beach', [62, .22, .62]], ['сары', 'beach', [47, .78, .98]], ['қызғылт сары', 'beach', [26, .8, .82]],
  ['күлгін', 'beach', [268, .38, .62]], ['көгілдір', 'beach', [200, .55, .98]], ['сұр', 'beach', [0, 0, .78]]];
const POSES = [[0.2, 0, 1], [0.3, -0.7, 1], [0.3, Math.PI - 0.7, 1], [Math.PI / 2 - 0.25, 0, 1], [-Math.PI / 2 - 0.15, 0, 1], [0.15, 0.35, 1.9]];
const srv = http.createServer((q, r) => { const u = decodeURIComponent(q.url.split('?')[0]);
  const p = u.endsWith('.glb') ? path.join(models, path.basename(u)) : path.join(here, u);
  fs.readFile(p, (e, d) => { if (e) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { 'content-type': p.endsWith('.js') ? 'text/javascript' : p.endsWith('.html') ? 'text/html' : 'model/gltf-binary' }); r.end(d); }); }).listen(8794);
const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const pg = await b.newPage({ viewport: { width: 400, height: 400 } });
pg.on('pageerror', e => console.log('ERR', e.message));
await pg.goto('http://localhost:8794/index.html');
await pg.waitForFunction(() => window.ready === true, null, { timeout: 120000 });
const save = (f, u) => fs.writeFileSync(f, Buffer.from(u.split(',')[1], 'base64'));
for (const [i, [name, v, t]] of COLOURS.entries()) {
  if (only && !only.split(',').includes(String(i))) continue;
  const d = path.join(out, String(i)); fs.mkdirSync(path.join(d, 'v'), { recursive: true });
  const t0 = Date.now();
  await pg.evaluate(([v, t]) => window.dress(v, t), [v, t]);
  for (const [k, [x, y, z]] of POSES.entries()) save(path.join(d, `p${k}.png`), await pg.evaluate(a => window.shot(...a), [x, y, z, 1600, 1600, null]));
  save(path.join(d, 'thumb.jpg'), await pg.evaluate(() => window.shot(0.25, 0.25, 2.05 / 2.3, 168, 168, 0xF3F2EF, 'image/jpeg')));
  const n = +frames;
  for (let f = 0; f < n; f++) save(path.join(d, 'v', `${String(f).padStart(4, '0')}.jpg`),
    await pg.evaluate(a => window.shot(...a), [0.2, f / n * 2 * Math.PI, 1, 720, 960, 0xF3F2EF, 'image/jpeg']));
  console.log(i, name, (Date.now() - t0) / 1000 + 's');
}
await b.close(); srv.close();

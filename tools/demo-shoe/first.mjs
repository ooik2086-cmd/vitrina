// Renders each demo colour's first 3D picture with the app's own viewer (app/assets/viewer), exactly as the listing
// page's stage opens it: shown the moment the page opens, while the 3D itself loads behind it. Square, cut out (the
// app draws the scene and halo), one per colour of render.mjs's COLOURS, by its place there (build.py reads them so).
// Run: node first.mjs OUT_DIR [SIDE]
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const here = path.dirname(new URL(import.meta.url).pathname), app = path.join(here, '../../app');
const [out, side = '1080'] = process.argv.slice(2);
const COLOURS = [['көк', 'midnight', null], ['қара', 'street', null], ['қызғылт', 'beach', null],
  ['қызыл', 'beach', [0, .62, .66]], ['бордо', 'beach', [345, .55, .42]], ['жасыл', 'beach', [145, .38, .58]],
  ['хаки', 'beach', [62, .22, .62]], ['сары', 'beach', [47, .78, .98]], ['қызғылт сары', 'beach', [26, .8, .82]],
  ['күлгін', 'beach', [268, .38, .62]], ['көгілдір', 'beach', [200, .55, .98]], ['сұр', 'beach', [0, 0, .78]]];
const srv = http.createServer((q, r) => {
  const u = decodeURIComponent(q.url.split('?')[0]);
  const p = u.endsWith('.glb') ? path.join(app, 'demo/media/models', path.basename(u)) : path.join(app, 'assets/viewer', path.basename(u));
  fs.readFile(p, (e, d) => { if (e) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { 'content-type': p.endsWith('.js') ? 'text/javascript' : p.endsWith('.html') ? 'text/html' : 'model/gltf-binary' }); r.end(d); });
}).listen(8795);
const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const pg = await b.newPage({ viewport: { width: +side, height: +side }, deviceScaleFactor: 1 });
pg.on('pageerror', e => console.log('ERR', e.message));
await pg.addInitScript(() => { window.msgs = []; window.Vitrina = { postMessage: m => window.msgs.push(JSON.parse(m)) }; });
await pg.goto('http://localhost:8795/index.html');
await pg.addStyleTag({ content: 'html,body,#stage,#stage.dark{background:transparent!important}.halo{display:none}' });
fs.mkdirSync(out, { recursive: true });
for (const [i, [name, variant, tint]] of COLOURS.entries()) {
  const n = i + 1;
  await pg.evaluate(a => { window.msgs = []; window.vitrina.load(a); }, { url: '/m/shoe-1024.glb', variant, tint, load: n });
  await pg.waitForFunction(n => window.msgs.some(x => x.load === n && (x.type === 'ready' || x.type === 'error')), n, { timeout: 120000 });
  await pg.waitForTimeout(300);
  await pg.locator('#c').screenshot({ path: path.join(out, `${i}.png`), omitBackground: true });
  console.log(i, name);
}
await b.close(); srv.close();

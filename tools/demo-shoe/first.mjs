// Renders each demo colour's first 3D picture with the app's own viewer (app/assets/viewer), exactly as the listing
// page's stage opens it: shown the moment the page opens, while the 3D itself loads behind it. Square, cut out (the
// app draws the scene and halo). Run: node first.mjs OUT_DIR [SIDE]
import { chromium } from 'playwright';
import http from 'http'; import fs from 'fs'; import path from 'path';
const here = path.dirname(new URL(import.meta.url).pathname), app = path.join(here, '../../app');
const [out, side = '1080'] = process.argv.slice(2);
const api = JSON.parse(fs.readFileSync(path.join(app, 'demo/api.json')));
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
let n = 0;
for (const [k, l] of Object.entries(api)) {
  if (!/^GET \/listings\/\d+$/.test(k) || !l.model) continue;
  const id = k.split('/').pop(), m = l.model;
  n++;
  await pg.evaluate(a => { window.msgs = []; window.vitrina.load(a); }, { url: '/m/' + path.basename(m.url), variant: m.variant ?? null, tint: m.tint ?? null, load: n });
  await pg.waitForFunction(n => window.msgs.some(x => x.load === n && (x.type === 'ready' || x.type === 'error')), n, { timeout: 120000 });
  await pg.waitForTimeout(300);
  await pg.locator('#c').screenshot({ path: path.join(out, `${id}.png`), omitBackground: true });
  console.log(id, m.variant, m.tint ?? '');
}
await b.close(); srv.close();

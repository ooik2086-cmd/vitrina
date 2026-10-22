// The listing page's 3D stage, as the demo Aza approved (https://claude.ai/artifact/2qtcxXja97mba4JdeGMAVX): the shoe
// turns 360° every way under the finger, glides on when let go, zooms 1×–3× by pinch or double tap, always drawn at the
// screen's full pixels (Aza: no blur while it turns). The app's ModelStage shows this page in a WebView and talks to it
// through window.vitrina (in) and the Vitrina channel (out: page, ready, error, lost). Built into app/assets/viewer by
// build.sh.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';

const post = (type, extra = {}) => {
  try { window.Vitrina.postMessage(JSON.stringify({ type, ...extra })); } catch (e) { /* not in the app */ }
};
const st = document.getElementById('stage'), c = document.getElementById('c');
let reduce = false, paused = false;

let renderer;
try {
  renderer = new THREE.WebGLRenderer({ canvas: c, antialias: true, alpha: true });
} catch (e) {
  // No WebGL on this phone: said at once, so the photos show without waiting out the stage's patience.
  post('lost', { message: 'no webgl' });
  throw e;
}
renderer.setClearColor(0x000000, 0); // the scene colour and its halo show through
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.outputColorSpace = THREE.SRGBColorSpace;
const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(30, 1, 0.01, 100);
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(renderer), 0.04).texture;
const key = new THREE.DirectionalLight(0xffffff, 1.2);
key.position.set(2, 4, 3);
camera.add(key);
scene.add(camera);
const pivot = new THREE.Group();
scene.add(pivot);
const X = new THREE.Vector3(1, 0, 0), Y = new THREE.Vector3(0, 1, 0), q = new THREE.Quaternion();
const aniso = renderer.capabilities.getMaxAnisotropy();
let dirty = true, vx = 0, vy = 0, zoom = 1, zoomT = 1, r = 1;
let parser = null, meshes = [], model = null, variant = null;

const dpr = () => Math.min(window.devicePixelRatio || 1, 3); // full sharpness while moving too
function frame() {
  const w = st.clientWidth, h = st.clientHeight;
  if (!w || !h) return;
  renderer.setPixelRatio(dpr());
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.position.set(0, 0, 2.05 * r / Math.min(1, camera.aspect) / zoom);
  camera.updateProjectionMatrix();
  dirty = true;
  kick();
}

// Frames are drawn only while something moves or changed, so a shoe at rest costs nothing.
let looping = false;
function kick() {
  if (looping || paused) return;
  looping = true;
  requestAnimationFrame(tick);
}
function tick() {
  looping = false;
  if (paused) return;
  let busy = false;
  if (!pts.size && !reduce && Math.abs(vx) + Math.abs(vy) > 1e-4) {
    turn(vx, vy);
    vx *= 0.955;
    vy *= 0.955;
    busy = true;
  } else if (!pts.size) {
    vx = vy = 0;
  }
  if (Math.abs(zoomT - zoom) > 1e-3) {
    zoom += (zoomT - zoom) * (reduce ? 1 : 0.22);
    if (Math.abs(zoomT - zoom) <= 1e-3) zoom = zoomT;
    frame();
    busy = true;
  }
  if (dirty && model) {
    renderer.render(scene, camera);
    dirty = false;
  }
  if (busy || pts.size) kick();
}

function turn(dx, dy) {
  q.setFromAxisAngle(Y, dx);
  pivot.quaternion.premultiply(q);
  q.setFromAxisAngle(X, dy);
  pivot.quaternion.premultiply(q);
  dirty = true;
}

// ---- the model: a light copy first, the sharp one swapped in when it has come ----
const loader = new GLTFLoader();
const meshesOf = gltf => { const list = []; gltf.scene.traverse(o => { if (o.isMesh) list.push(o); }); return list; };

// Puts a loaded copy on the stage in place of the one shown, already in its colour (never a frame in the default one).
function use(gltf, list) {
  if (model) {
    pivot.remove(model);
    model.traverse(o => {
      if (!o.isMesh) return;
      o.geometry.dispose();
      for (const v of Object.values(o.material)) if (v?.isTexture) v.dispose();
      o.material.dispose();
    });
  }
  parser = gltf.parser;
  meshes = list;
  model = gltf.scene;
  const box = new THREE.Box3().setFromObject(model);
  model.position.sub(box.getCenter(new THREE.Vector3()));
  pivot.add(model);
  const size = box.getSize(new THREE.Vector3());
  r = Math.max(size.x, size.z);
}

// Dresses a copy's meshes in the colour [name] (a KHR_materials_variants variant); the default one when unknown.
// [still] says whether that colour is still wanted: a colour picked after it never gets painted over.
async function dress(p, list, name, still) {
  const names = p.json.extensions?.KHR_materials_variants?.variants?.map(v => v.name) ?? [];
  const idx = names.indexOf(name);
  for (const mesh of list) {
    const a = p.associations.get(mesh);
    if (idx >= 0 && a && a.meshes !== undefined) {
      const prim = p.json.meshes[a.meshes].primitives[a.primitives];
      const hit = (prim.extensions?.KHR_materials_variants?.mappings || []).find(x => x.variants.includes(idx));
      if (hit) {
        const material = await p.getDependency('material', hit.material);
        if (!still()) return;
        mesh.material = material;
      }
    }
    for (const v of Object.values(mesh.material)) {
      if (v?.isTexture && v.anisotropy !== aniso) { v.anisotropy = aniso; v.needsUpdate = true; }
    }
  }
}

// Another colour of the shoe shown. Picked before the shoe has come, it is the colour the shoe comes in.
async function paint(name) {
  variant = name;
  if (!parser) return;
  const p = parser, still = () => p === parser && variant === name; // a newer copy or colour takes over
  await dress(p, meshes, name, still);
  if (!still()) return;
  dirty = true;
  kick();
}

// Brings a copy in, dressed in the colour wanted by the time it is (which may change while it dresses).
async function bring(gltf, mine) {
  const list = meshesOf(gltf);
  let name;
  do {
    name = variant;
    await dress(gltf.parser, list, name, () => mine === loading);
    if (mine !== loading) return false;
  } while (name !== variant);
  use(gltf, list);
  return true;
}

let loading = 0;
// [load] tells which load of the app's this is: ready and error carry it back, so a late answer for a model no longer
// wanted is not taken for the one now coming.
async function load({ url, hq = null, variant: name = null, dark = false, reduceMotion = false, view = null, load: n = 0 }) {
  const mine = ++loading;
  reduce = reduceMotion;
  variant = name;
  setBackground(dark);
  try {
    const gltf = await loader.loadAsync(url);
    if (mine !== loading || !(await bring(gltf, mine))) return;
    if (view && view.length === 5) {
      pivot.quaternion.set(view[0], view[1], view[2], view[3]).normalize();
      zoom = zoomT = Math.min(3, Math.max(1, view[4]));
    } else {
      pivot.quaternion.setFromAxisAngle(X, 0.2);
    }
    frame();
    renderer.render(scene, camera);
    dirty = false;
    post('ready', { load: n });
  } catch (e) {
    if (mine === loading) post('error', { message: String(e?.message || e), load: n });
    return;
  }
  if (!hq) return;
  try {
    const sharp = await loader.loadAsync(hq);
    // Swapped in where the shoe is turned now, in the colour it shows now.
    if (mine !== loading || !(await bring(sharp, mine))) return;
    frame();
  } catch (e) { /* the light copy stays: it is the same shoe */ }
}

function setBackground(dark) {
  st.classList.toggle('dark', !!dark);
}

// ---- gestures: drag turns, two fingers or a double tap zoom ----
const pts = new Map();
let last = null, pinch = 0, tap = 0, moved = 0;
const dist = () => { const [a, b] = [...pts.values()]; return Math.hypot(a[0] - b[0], a[1] - b[1]); };
st.addEventListener('pointerdown', e => {
  pts.set(e.pointerId, [e.clientX, e.clientY]);
  st.setPointerCapture(e.pointerId);
  vx = vy = 0;
  moved = 0;
  last = [e.clientX, e.clientY, performance.now()];
  if (pts.size === 2) pinch = dist();
  kick();
});
st.addEventListener('pointermove', e => {
  if (!pts.has(e.pointerId)) return;
  pts.set(e.pointerId, [e.clientX, e.clientY]);
  if (pts.size === 2) {
    const d = dist(), f = d / (pinch || d);
    pinch = d;
    moved = 99;
    zoomT = Math.min(3, Math.max(1, zoomT * f));
    kick();
    return;
  }
  const now = performance.now(), dt = Math.max(8, now - last[2]), ddx = e.clientX - last[0], ddy = e.clientY - last[1];
  moved += Math.abs(ddx) + Math.abs(ddy);
  last = [e.clientX, e.clientY, now];
  const k = Math.PI / Math.min(st.clientWidth, st.clientHeight) * 2.2;
  turn(ddx * k, ddy * k);
  vx = ddx * k * 16 / dt;
  vy = ddy * k * 16 / dt;
  kick();
});
const up = e => {
  if (!pts.has(e.pointerId)) return;
  pts.delete(e.pointerId);
  if (pts.size === 1) {
    const [p] = pts.values();
    last = [p[0], p[1], performance.now()];
    vx = vy = 0;
    return;
  }
  if (pts.size) return;
  const now = performance.now();
  if (now - last[2] > 80) vx = vy = 0; // held still before letting go: no glide
  if (moved < 12) {
    if (now - tap < 320) {
      tap = 0;
      zoomT = zoomT > 1.2 ? 1 : 2.5;
      vx = vy = 0;
    } else {
      tap = now;
    }
  }
  kick();
};
st.addEventListener('pointerup', up);
st.addEventListener('pointercancel', up);
new ResizeObserver(frame).observe(st);
// The phone took the drawing back (low memory): the app shows the photos instead of an empty stage.
c.addEventListener('webglcontextlost', e => { e.preventDefault(); post('lost', { message: 'webgl context lost' }); });

window.vitrina = {
  load,
  setVariant: name => paint(name),
  setBackground,
  // While the photos show, nothing is drawn; back on the 3D, the last picture is drawn again.
  setPaused(p) { paused = !!p; if (!paused) { dirty = true; kick(); } },
  // The turn and zoom, to open another colour of this model showing the same.
  view: () => JSON.stringify([...pivot.quaternion.toArray(), zoomT]),
};
post('page');

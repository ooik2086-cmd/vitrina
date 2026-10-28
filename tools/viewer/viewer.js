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
// Where the camera has moved across, to bring the spot a double tap or two fingers chose nearer under them.
let panX = 0, panY = 0, panTX = 0, panTY = 0;
let parser = null, meshes = [], model = null, variant = null, tint = null;

const FOV = THREE.MathUtils.degToRad(30); // what the stage's narrower side sees
const dpr = () => Math.min(window.devicePixelRatio || 1, 3); // full sharpness while moving too
let drawn = [0, 0, 0];
function frame() {
  const w = st.clientWidth, h = st.clientHeight;
  if (!w || !h) return;
  // Only when the size changed: setting it clears the drawing, and a zoom or pan calls this every frame.
  const p = dpr();
  if (w !== drawn[0] || h !== drawn[1] || p !== drawn[2]) {
    drawn = [w, h, p];
    renderer.setPixelRatio(p);
    renderer.setSize(w, h, false);
  }
  camera.aspect = w / h;
  // Far enough that the shoe's whole sphere fits the narrower side, so turned any way (toe or heel to the camera,
  // which brings it nearer and larger) it is never cut off (Aza, 2026-10-23); zoomed in, it may be. The narrower side
  // always sees 30°, from the same distance: a tall stage shows more above and below, the shoe itself exactly as on a
  // square one, so the app's first picture (made square) matches it to the pixel.
  camera.fov = w < h ? THREE.MathUtils.radToDeg(2 * Math.atan(Math.tan(FOV / 2) * h / w)) : 30;
  camera.position.set(panX, panY, r / Math.sin(FOV / 2) / zoom);
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
  if (Math.abs(zoomT - zoom) > 1e-3 || Math.abs(panTX - panX) + Math.abs(panTY - panY) > 1e-4 * r) {
    const k = reduce ? 1 : 0.22;
    // Eased as 1/zoom, as the pan is, so the spot a double tap chose stays under the finger all the way in.
    zoom = 1 / (1 / zoom + (1 / zoomT - 1 / zoom) * k);
    panX += (panTX - panX) * k;
    panY += (panTY - panY) * k;
    if (Math.abs(zoomT - zoom) <= 1e-3 && Math.abs(panTX - panX) + Math.abs(panTY - panY) <= 1e-4 * r) {
      zoom = zoomT;
      panX = panTX;
      panY = panTY;
    }
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
  q2.setFromAxisAngle(X, dy);
  q.premultiply(q2);
  pivot.quaternion.premultiply(q);
  // Zoomed in on a spot, the spot turns with the shoe and the camera follows it, so it stays on the stage.
  if (panTX || panTY || panX || panY) {
    const room = r * (1 - 1 / zoomT);
    const follow = (x, y) => {
      spot.set(x, y, Math.sqrt(Math.max(0, r * r - x * x - y * y))).applyQuaternion(q);
      return [Math.min(room, Math.max(-room, spot.x)), Math.min(room, Math.max(-room, spot.y))];
    };
    [panTX, panTY] = follow(panTX, panTY);
    [panX, panY] = follow(panX, panY);
    frame();
  }
  dirty = true;
}
const q2 = new THREE.Quaternion(), spot = new THREE.Vector3();

// ---- the model: a light copy first, the sharp one swapped in when it has come ----
const loader = new GLTFLoader();
const meshesOf = gltf => { const list = []; gltf.scene.traverse(o => { if (o.isMesh) list.push(o); }); return list; };

// Puts a loaded copy on the stage in place of the one shown, already in its colour (never a frame in the default one).
function use(gltf, list) {
  const box = new THREE.Box3().setFromObject(gltf.scene);
  // A model with nothing to show is broken, not a shoe: said as an error, so the app shows the photos instead.
  if (box.isEmpty() || !(box.getSize(new THREE.Vector3()).length() > 0)) throw new Error('no shoe in the model');
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
  model.position.sub(box.getCenter(new THREE.Vector3()));
  pivot.add(model);
  r = box.getSize(new THREE.Vector3()).length() / 2; // the radius of the sphere round the shoe
}

// A colour the model was not made in, as on the approved demo: the variant's coloured parts take hue [h], saturation
// [sat] and lightness times [k]; white sole, dark laces and lining stay as they are. Worked out per pixel in the
// shader, in sRGB as the demo did on its canvas, so a tint costs no new picture: no memory and no wait to switch.
const TINT_GLSL = `
uniform vec3 vitrinaTint;
vec3 vtSrgb(vec3 c) {
  return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, vec3(lessThanEqual(c, vec3(0.0031308))));
}
vec3 vtLinear(vec3 c) {
  return mix(pow(c * 0.9478672986 + 0.0521327014, vec3(2.4)), c * 0.0773993808, vec3(lessThanEqual(c, vec3(0.04045))));
}
vec3 vtTint(vec3 linear) {
  vec3 c = vtSrgb(clamp(linear, 0.0, 1.0));
  float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), l = (mx + mn) * 0.5;
  float s0 = mx == mn ? 0.0 : (mx - mn) / (1.0 - abs(2.0 * l - 1.0));
  if (s0 < 0.07 || l < 0.14 || l > 0.94) return linear;
  float L = min(0.92, l * vitrinaTint.z), C = (1.0 - abs(2.0 * L - 1.0)) * vitrinaTint.y, hp = vitrinaTint.x / 60.0;
  float x = C * (1.0 - abs(mod(hp, 2.0) - 1.0)), m0 = L - C * 0.5;
  vec3 r = hp < 1.0 ? vec3(C, x, 0.0) : hp < 2.0 ? vec3(x, C, 0.0) : hp < 3.0 ? vec3(0.0, C, x)
         : hp < 4.0 ? vec3(0.0, x, C) : hp < 5.0 ? vec3(x, 0.0, C) : vec3(C, 0.0, x);
  return vtLinear(clamp(r + m0, 0.0, 1.0));
}
`;
const MAP_TINTED = THREE.ShaderChunk.map_fragment.replace(
  'diffuseColor *= sampledDiffuseColor;', 'sampledDiffuseColor.rgb = vtTint(sampledDiffuseColor.rgb);\n\tdiffuseColor *= sampledDiffuseColor;');
// Three numbers, hue taken round the circle, saturation 0–1 and a lightness factor 0–2; anything else is no tint.
const tintOf = t => Array.isArray(t) && t.length === 3 && t.every(Number.isFinite)
  ? [((t[0] % 360) + 360) % 360, Math.min(1, Math.max(0, t[1])), Math.min(2, Math.max(0, t[2]))] : null;
function tintedCopy(base, [h, sat, k]) {
  const m = base.clone();
  m.userData.plain = base;
  const tint = { value: new THREE.Vector3(h, sat, k) };
  m.onBeforeCompile = shader => {
    shader.uniforms.vitrinaTint = tint;
    shader.fragmentShader = TINT_GLSL + shader.fragmentShader.replace('#include <map_fragment>', MAP_TINTED);
  };
  m.customProgramCacheKey = () => 'vitrina-tint'; // one program for every tint: only the uniform differs
  return m;
}

// Dresses a copy's meshes in the colour [name] (a KHR_materials_variants variant; the default one when unknown),
// tinted by [tint] when given. [still] says whether that colour is still wanted: a colour picked after it never gets
// painted over.
async function dress(p, list, name, tint, still) {
  const names = p.json.extensions?.KHR_materials_variants?.variants?.map(v => v.name) ?? [];
  const idx = names.indexOf(name);
  for (const mesh of list) {
    const was = mesh.material.userData.plain ? mesh.material : null;
    if (was) {
      mesh.material = was.userData.plain; // a tint is never tinted again
      was.dispose(); // its own copy only: the textures are the plain material's
    }
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
    const t = tintOf(tint);
    if (t && mesh.material.map) mesh.material = tintedCopy(mesh.material, t);
    for (const v of Object.values(mesh.material)) {
      if (v?.isTexture && v.anisotropy !== aniso) { v.anisotropy = aniso; v.needsUpdate = true; }
    }
  }
}

// Another colour of the shoe shown. Picked before the shoe has come, it is the colour the shoe comes in.
async function paint(name, t = null) {
  variant = name;
  tint = t;
  if (!parser) return;
  const p = parser, still = () => p === parser && variant === name && tint === t; // a newer copy or colour takes over
  await dress(p, meshes, name, t, still);
  if (!still()) return;
  dirty = true;
  kick();
}

// Brings a copy in, dressed in the colour wanted by the time it is (which may change while it dresses).
async function bring(gltf, mine) {
  const list = meshesOf(gltf);
  let name, t;
  do {
    name = variant;
    t = tint;
    await dress(gltf.parser, list, name, t, () => mine === loading);
    if (mine !== loading) return false;
  } while (name !== variant || t !== tint);
  use(gltf, list);
  return true;
}

let loading = 0;
// [load] tells which load of the app's this is: ready and error carry it back, so a late answer for a model no longer
// wanted is not taken for the one now coming.
async function load({ url, hq = null, variant: name = null, tint: t = null, dark = false, reduceMotion = false, view = null, load: n = 0 }) {
  const mine = ++loading;
  reduce = reduceMotion;
  variant = name;
  tint = t;
  // At once, not through the colour's slow change: a page opened ahead of time starts light.
  st.style.transition = 'none';
  setBackground(dark);
  void st.offsetWidth;
  st.style.transition = '';
  try {
    const gltf = await loader.loadAsync(url);
    if (mine !== loading || !(await bring(gltf, mine))) return;
    if (view && (view.length === 5 || view.length === 7)) {
      pivot.quaternion.set(view[0], view[1], view[2], view[3]).normalize();
      zoom = zoomT = Math.min(3, Math.max(1, view[4]));
      // The spot zoomed in on, kept as a share of the shoe's size: another colour's model is the same shoe.
      const room = r * (1 - 1 / zoomT), at = i => Math.min(room, Math.max(-room, (view[i] || 0) * r));
      panX = panTX = view.length === 7 ? at(5) : 0;
      panY = panTY = view.length === 7 ? at(6) : 0;
    } else {
      // As the first picture shows it, whatever a finger did on that picture before the shoe came.
      pivot.quaternion.setFromAxisAngle(X, 0.2);
      vx = vy = 0;
      zoom = zoomT = 1;
      panX = panY = panTX = panTY = 0;
    }
    // A page opened ahead of time (the app keeps one ready) may get its model before it is on the screen: the first
    // picture is drawn, and said to be, only once the stage has its size.
    await sized();
    if (mine !== loading) return;
    frame();
    renderer.render(scene, camera);
    dirty = false;
    // Said once that picture is on the screen (two frames on), so the app's fade shows the shoe from its start.
    await shown();
    if (mine !== loading) return;
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

const shown = () => new Promise(done => {
  const t = setTimeout(done, 300); // no frames come to a page off the screen
  requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(t); done(); }));
});
const sized = () => new Promise(done => {
  if (st.clientWidth && st.clientHeight) return done();
  const o = new ResizeObserver(() => { if (st.clientWidth && st.clientHeight) { o.disconnect(); done(); } });
  o.observe(st);
});

function setBackground(dark) {
  st.classList.toggle('dark', !!dark);
}

// ---- gestures: drag turns (zoomed in, it moves the shoe), two fingers or a double tap zoom ----
// Zooms to [z], keeping the spot of the shoe under the screen point (x, y) where it is (Aza, 2026-10-25: "қай жерін
// саусақпен екі рет түртесің сол жері жақындайтын болсын"). Back at 1× the shoe is centred again. Measured on the
// plane through the shoe's middle, where the camera's turn is centred.
function zoomAt(z, x, y) {
  z = Math.min(3, Math.max(1, z));
  const w = st.clientWidth, h = st.clientHeight;
  if (!w || !h) return;
  const tanV = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)), tanH = tanV * w / h;
  const nx = x / w * 2 - 1, ny = 1 - y / h * 2, d = r / Math.sin(FOV / 2);
  const spotX = panTX + nx * d / zoomT * tanH, spotY = panTY + ny * d / zoomT * tanV;
  const room = r * (1 - 1 / z); // never so far across that the shoe leaves the stage
  panTX = Math.min(room, Math.max(-room, spotX - nx * d / z * tanH));
  panTY = Math.min(room, Math.max(-room, spotY - ny * d / z * tanV));
  zoomT = z;
}

const pts = new Map();
// A double tap as the phone counts one: two short still taps, the second down within 300 ms of the first's lift and
// within 100 px of it.
let last = null, pinch = 0, tap = null, moved = 0, downAt = 0, downXY = null;
const dist = () => { const [a, b] = [...pts.values()]; return Math.hypot(a[0] - b[0], a[1] - b[1]); };
st.addEventListener('pointerdown', e => {
  pts.set(e.pointerId, [e.clientX, e.clientY]);
  st.setPointerCapture(e.pointerId);
  vx = vy = 0;
  last = [e.clientX, e.clientY, performance.now()];
  if (pts.size === 1) {
    moved = 0;
    downAt = last[2];
    downXY = [e.clientX, e.clientY];
  }
  if (pts.size === 2) {
    pinch = dist();
    moved = 99; // two fingers are never a tap
  }
  kick();
});
st.addEventListener('pointermove', e => {
  if (!pts.has(e.pointerId)) return;
  pts.set(e.pointerId, [e.clientX, e.clientY]);
  if (pts.size === 2) {
    const d = dist(), f = d / (pinch || d);
    pinch = d;
    moved = 99;
    const [a, b] = [...pts.values()], box = st.getBoundingClientRect();
    zoomAt(zoomT * f, (a[0] + b[0]) / 2 - box.left, (a[1] + b[1]) / 2 - box.top);
    kick();
    return;
  }
  const now = performance.now(), dt = Math.max(8, now - last[2]), ddx = e.clientX - last[0], ddy = e.clientY - last[1];
  moved += Math.abs(ddx) + Math.abs(ddy);
  last = [e.clientX, e.clientY, now];
  if (zoomT > 1.05) {
    // Zoomed in, one finger moves the shoe the way it goes, as a zoomed photo does (Aza, 2026-10-28: turning here went
    // the opposite way, the camera chasing a spot on the shoe's outer sphere, in front of its real surface). Never so
    // far that the shoe leaves the stage; a double tap or two fingers bring it back to 1× to turn it again.
    vx = vy = 0;
    const h = st.clientHeight || 1, s = 2 * (r / Math.sin(FOV / 2)) / zoom * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) / h;
    const room = r * (1 - 1 / zoomT), clamp = v => Math.min(room, Math.max(-room, v));
    panX = panTX = clamp(panTX - ddx * s);
    panY = panTY = clamp(panTY + ddy * s);
    frame();
    return;
  }
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
  if (moved < 12 && now - downAt < 500) {
    if (tap && downAt - tap[0] < 300 && Math.hypot(downXY[0] - tap[1], downXY[1] - tap[2]) < 100) {
      tap = null;
      const box = st.getBoundingClientRect();
      zoomAt(zoomT > 1.2 ? 1 : 2.5, e.clientX - box.left, e.clientY - box.top);
      vx = vy = 0;
    } else {
      tap = [now, e.clientX, e.clientY];
    }
  } else {
    tap = null;
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
  setVariant: (name, t = null) => paint(name, t),
  setBackground,
  // While the photos show, nothing is drawn; back on the 3D, the last picture is drawn again.
  setPaused(p) { paused = !!p; if (!paused) { dirty = true; kick(); } },
  // The turn, zoom and the spot zoomed in on, to open another colour of this model showing the same.
  view: () => JSON.stringify([...pivot.quaternion.toArray(), zoomT, panTX / r, panTY / r]),
  // The stage drawn now, without its scene (the app draws that), as a PNG: the staff console keeps it, taken as the
  // model opens, as the model's first picture.
  picture() {
    if (!model) return null;
    frame();
    renderer.render(scene, camera);
    return c.toDataURL('image/png');
  },
};
post('page');

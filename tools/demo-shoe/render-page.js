// Renders the demo shoe in each colour with the app viewer's own light, camera and tint, for the demo listings.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
const c = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({ canvas: c, antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.outputColorSpace = THREE.SRGBColorSpace;
const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(30, 1, 0.01, 100);
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(renderer), 0.04).texture;
const key = new THREE.DirectionalLight(0xffffff, 1.2); key.position.set(2, 4, 3); camera.add(key); scene.add(camera);
const pivot = new THREE.Group(); scene.add(pivot);
const X = new THREE.Vector3(1, 0, 0), Y = new THREE.Vector3(0, 1, 0);
const qa = (x, y) => new THREE.Quaternion().setFromAxisAngle(X, x).multiply(new THREE.Quaternion().setFromAxisAngle(Y, y));
const tinted = new Map();
function recolor(tex, [h, sat, k]) {
  const key = `${tex.uuid}/${h}/${sat}/${k}`; if (tinted.has(key)) return tinted.get(key);
  const img = tex.image, cv = document.createElement('canvas'); cv.width = img.width; cv.height = img.height;
  const g = cv.getContext('2d', { willReadFrequently: true }); g.drawImage(img, 0, 0);
  const d = g.getImageData(0, 0, cv.width, cv.height), a = d.data;
  for (let i = 0; i < a.length; i += 4) {
    const r = a[i] / 255, gg = a[i + 1] / 255, b = a[i + 2] / 255, mx = Math.max(r, gg, b), mn = Math.min(r, gg, b);
    const l = (mx + mn) / 2, s0 = mx === mn ? 0 : (mx - mn) / (1 - Math.abs(2 * l - 1));
    if (s0 < 0.07 || l < 0.14 || l > 0.94) continue;
    const L = Math.min(0.92, l * k), C = (1 - Math.abs(2 * L - 1)) * sat, hp = h / 60;
    const x = C * (1 - Math.abs(hp % 2 - 1)), m0 = L - C / 2;
    const [r1, g1, b1] = hp < 1 ? [C, x, 0] : hp < 2 ? [x, C, 0] : hp < 3 ? [0, C, x] : hp < 4 ? [0, x, C] : hp < 5 ? [x, 0, C] : [C, 0, x];
    a[i] = (r1 + m0) * 255; a[i + 1] = (g1 + m0) * 255; a[i + 2] = (b1 + m0) * 255;
  }
  g.putImageData(d, 0, 0);
  const t = new THREE.CanvasTexture(cv);
  for (const f of ['flipY', 'colorSpace', 'wrapS', 'wrapT', 'channel', 'magFilter', 'minFilter']) t[f] = tex[f];
  t.offset.copy(tex.offset); t.repeat.copy(tex.repeat); t.needsUpdate = true; tinted.set(key, t); return t;
}
const gltf = await new GLTFLoader().loadAsync('/shoe-2048.glb');
const p = gltf.parser, meshes = []; gltf.scene.traverse(o => { if (o.isMesh) meshes.push(o); });
const model = gltf.scene, box = new THREE.Box3().setFromObject(model);
model.position.sub(box.getCenter(new THREE.Vector3())); pivot.add(model);
const size = box.getSize(new THREE.Vector3()), r = Math.max(size.x, size.z);
const names = p.json.extensions.KHR_materials_variants.variants.map(v => v.name);
const aniso = renderer.capabilities.getMaxAnisotropy();
window.dress = async (name, tint) => {
  const idx = names.indexOf(name);
  for (const mesh of meshes) {
    const a = p.associations.get(mesh), prim = p.json.meshes[a.meshes].primitives[a.primitives];
    const hit = (prim.extensions?.KHR_materials_variants?.mappings || []).find(x => x.variants.includes(idx));
    if (hit) mesh.material = await p.getDependency('material', hit.material);
    if (tint && mesh.material.map) { const m = mesh.material.clone(); m.map = recolor(mesh.material.map, tint); mesh.material = m; }
    for (const v of Object.values(mesh.material)) if (v?.isTexture) { v.anisotropy = aniso; v.needsUpdate = true; }
  }
};
// One picture: turned by [x] then [y], at [zoom], [w]×[h] px, on [bg] (null: see-through).
window.shot = (x, y, zoom, w, h, bg, type = 'image/png') => {
  renderer.setPixelRatio(1); renderer.setSize(w, h, false); camera.aspect = w / h;
  camera.position.set(0, 0, 2.05 * r / Math.min(1, w / h) / zoom); camera.updateProjectionMatrix();
  pivot.quaternion.copy(qa(x, y));
  renderer.setClearColor(bg ?? 0x000000, bg == null ? 0 : 1); renderer.render(scene, camera);
  return c.toDataURL(type, 0.92);
};
window.names = names; window.ready = true;

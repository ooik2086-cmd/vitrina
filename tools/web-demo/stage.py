"""Lays out the web demo (app/build/web, built with --dart-define=DEMO=true) as one folder a static site can serve:
the app without the renderers and debug files a browser does not use, plus the demo media that demo/api.json names
(the browser reads them from the site itself, demo.dart _demoFiles). Usage: python3 stage.py OUT_DIR"""
import os, re, shutil, sys

app = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'app')
out = sys.argv[1]
shutil.rmtree(out, ignore_errors=True)
shutil.copytree(os.path.join(app, 'build', 'web'), out)
for root, dirs, files in os.walk(out):
    for f in files:
        if f.endswith('.symbols') or f.startswith(('skwasm', 'wimp')) or f == 'flutter_service_worker.js':
            os.remove(os.path.join(root, f))
shutil.rmtree(os.path.join(out, 'canvaskit', 'webparagraph'), ignore_errors=True)
# Served from any folder: no fixed base, and no service worker (a page framed on another site cannot register one).
index = os.path.join(out, 'index.html')
html = re.sub(r'<base href="[^"]*">', '', open(index).read())
html = html.replace('content="A new Flutter project."', 'content="VITRINA demo"').replace('<title>vitrina</title>', '<title>VITRINA</title>')
open(index, 'w').write(html)
boot = os.path.join(out, 'flutter_bootstrap.js')
js = open(boot).read()
open(boot, 'w').write(js[:js.rindex('_flutter.loader.load(')] + '_flutter.loader.load({});\n')
# The media the demo's listings show, under short names (m/w0.webp, m/j0.jpg…) so the site has short addresses; the app's copy
# of demo/api.json names them so. The 3D model and first pictures are inside the app already.
api_path = os.path.join(out, 'assets', 'demo', 'api.json')
api = open(api_path).read()
names = {}
for rel in sorted(set(re.findall(r'demo/media/[^"\\]+', api))):
    if rel.startswith('demo/media/models/shoe-1024'):
        continue
    ext = rel.rsplit('.', 1)[-1]
    short = names[rel] = 'm/%s%d.%s' % (ext[0], sum(1 for n in names.values() if n.endswith('.' + ext)), ext)
    os.makedirs(os.path.join(out, 'm'), exist_ok=True)
    shutil.copy(os.path.join(app, rel), os.path.join(out, short))
api = re.sub(r'demo/media/[^"\\]+', lambda m: names.get(m.group(0), m.group(0)), api)
open(api_path, 'w').write(api)
os.remove(os.path.join(out, '.last_build_id'))
# A browser reads AssetManifest.bin.json; the .bin copy is for phones.
os.remove(os.path.join(out, 'assets', 'AssetManifest.bin'))
# A site that serves only standard web file types takes no binary 3D model: each is kept as base64 text beside its
# address, and the stage's frame reads it from there (assets/viewer/bridge.js).
import base64
for root, dirs, files in os.walk(out):
    for f in files:
        if f.endswith('.glb'):
            src = os.path.join(root, f)
            with open(src, 'rb') as b, open(src + '.txt', 'w') as t:
                t.write(base64.b64encode(b.read()).decode())
            os.remove(src)

"""Puts the approved demo's shoe (https://claude.ai/artifact/2qtcxXja97mba4JdeGMAVX) in place of every demo listing,
in its 12 colours, from what render.mjs made:

    cd tools/demo-shoe
    NODE_PATH=../viewer/node_modules ../viewer/node_modules/.bin/esbuild render-page.js --bundle --format=esm \\
        --outfile=render-page.bundle.js
    node render.mjs /tmp/shoe && node first.mjs /tmp/shoe/first && python3 build.py /tmp/shoe

The listings the backend's side matching was checked on are kept in app/demo/scan_sides.json first.
"""
import json, sys, subprocess, hashlib, shutil, copy, re
from pathlib import Path
from PIL import Image
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'backend'))
from vitrina_api.video import encode
R = Path(sys.argv[1]); app = ROOT / 'app'; demo = app / 'demo'
d = json.load(open(demo / 'api.json'))
BASE = 'https://raw.githubusercontent.com/ooik2086-cmd/vitrina/claude/initial-code/app/demo/media/'
MED = demo / 'media' / 'shoe'; MED.mkdir(exist_ok=True)

# The backend's side-matching test keeps the scans it was checked on.
if not (demo / 'scan_sides.json').exists():
    old = {k: {'media': d[f'GET /listings/{k}']['media'], 'angle_frames': d[f'GET /listings/{k}']['angle_frames']}
           for k in (1, 2, 3, 4)}
    (demo / 'scan_sides.json').write_text(json.dumps(old, ensure_ascii=False, separators=(',', ':')))
old_titles = sorted({v['title'] for k, v in d.items() if re.fullmatch(r'GET /listings/\d+', k)}, key=len, reverse=True)

def put(data, ext):
    n = hashlib.md5(data).hexdigest() + '.' + ext; (MED / n).write_bytes(data); return BASE + 'shoe/' + n
def webp(p, size=None):
    im = Image.open(p).convert('RGBA')
    if size: im = im.resize((size, size), Image.LANCZOS)
    import io; b = io.BytesIO(); im.save(b, 'WEBP', quality=90, method=6); return b.getvalue()

COLOURS = [(3, 'көк', 'midnight', None), (1, 'қара', 'street', None), (4, 'қызғылт', 'beach', None),
  (2, 'қызыл', 'beach', [0, .62, .66]), (6, 'бордо', 'beach', [345, .55, .42]), (7, 'жасыл', 'beach', [145, .38, .58]),
  (8, 'хаки', 'beach', [62, .22, .62]), (9, 'сары', 'beach', [47, .78, .98]), (10, 'қызғылт сары', 'beach', [26, .8, .82]),
  (11, 'күлгін', 'beach', [268, .38, .62]), (12, 'көгілдір', 'beach', [200, .55, .98]), (13, 'сұр', 'beach', [0, 0, .78])]
ANGLES = ['outer', 'front', 'back', 'top', 'sole', 'detail']
INSOLE = [('37', '24,0'), ('38', '24,5'), ('39', '25,0'), ('40', '25,7'), ('41', '26,3'), ('42', '27,0'), ('43', '27,7'), ('44', '28,3')]
seller = {'id': 1, 'shop_name': 'Qadam Store', 'city': 'Алматы', 'away_until': None, 'rating': 4.8, 'reviews': 23}
model = {k: v for k, v in d['GET /listings/1']['model'].items() if k not in ('turn', 'tint', 'first_url')}
new = {}
for i, (lid, name, variant, tint) in enumerate(COLOURS):
    src = R / str(i)
    media = []
    for k, angle in enumerate(ANGLES):
        full = put(webp(src / f'p{k}.png'), 'webp')
        small = put(webp(src / f'p{k}.png', 400), 'webp')
        media.append({'original_url': full, 'processed_url': full, 'angle': angle, 'thumb_url': small})
    raw = R / f'raw{i}.mp4'
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-framerate', '16', '-i', str(src / 'v' / '%04d.jpg'), '-c:v', 'libx264',
                    '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p', str(raw)], check=True)
    w = R / f'enc{i}'; shutil.rmtree(w, ignore_errors=True); w.mkdir()
    mp4, poster = encode(raw, w)
    video = {'state': 'ready', 'url': put(mp4, 'mp4'), 'poster_url': put(poster, 'jpg'), 'seconds': 9}
    m = {**model, 'variant': variant}
    if tint: m['tint'] = tint
    # The catalog card's turn: its cover's own small copy first, then the 23 pictures round from render.mjs.
    m['turn'] = [media[0]['thumb_url']] + [put(webp(src / 't' / f'{f:02d}.png'), 'webp') for f in range(1, 24)]
    # The 3D's own first picture (first.mjs), shown the moment the page opens while the 3D loads behind it.
    m['first_url'] = put(webp(R / 'first' / f'{lid}.png'), 'webp')
    new[lid] = {
        'id': lid, 'status': 'published', 'title': 'Жеңіл жүгіру кроссовкасы', 'category': 'sneakers', 'brand': None,
        'model_name': 'Foam Run Light', 'color': name, 'price_tiyn': 2110000, 'was_price_tiyn': None,
        'delivery_price_tiyn': 150000, 'segment': None, 'condition': 'new_with_box', 'authenticity': 'unverified',
        'defects': None,
        'description': 'Күнделікті жүруге және жеңіл жүгіруге арналған кроссовка. Үсті тыныс алатын тоқымадан, аяқ терлемейді. '
                       'Табаны жұмсақ, соққыны басады, тайғанамайды. Бауы мықты, үсті сүртсе тазарады. Салмағы бір жұбы '
                       'шамамен 520 грамм. Жаңа, қорабымен беріледі.',
        'facts': {'upper': 'textile', 'lining': 'textile', 'sole': 'eva', 'season': 'demi', 'country': 'TR'},
        'showcase_style': 'clean',
        'sizes': [{'id': 100 + i * 8 + k, 'label': l, 'insole_cm': c, 'available': l not in ('39', '43')} for k, (l, c) in enumerate(INSOLE)],
        'media': media, 'seller': seller, 'size_fit': {'answers': 4, 'small': 1, 'true': 3, 'large': 0},
        'stock_alerts': [], 'popularity': None, 'backdrop': 'light', 'cover_frame': None, 'angle_frames': None,
        'video': video, 'model': m,
    }
    print(i, name, 'done')

QS = {'items': [
    {'id': 2, 'text': 'Аяғым 26 см, қай өлшем?', 'answer': '41 өлшемі келеді, ішкі табаны 263 мм.', 'asked_at': '2026-10-14T09:12:00+00:00', 'mine': False},
    {'id': 1, 'text': 'Қорабы бар ма?', 'answer': 'Иә, қорабы мен жапсырмасы бар.', 'asked_at': '2026-10-12T08:30:00+00:00', 'mine': False}],
    'unanswered': None}
for k in [k for k in d if re.fullmatch(r'GET /listings/\d+(/similar|/questions)?', k)]: del d[k]
for lid, l in new.items():
    d[f'GET /listings/{lid}'] = l
    d[f'GET /listings/{lid}/questions'] = copy.deepcopy(QS)
# One question still waiting, on the red pair, so the seller's screens have one to show.
d['GET /listings/2/questions']['items'].insert(0, {'id': 3, 'text': 'Табаны жұмсақ па, ұзақ жүруге бола ма?', 'answer': None,
                                                   'asked_at': '2026-10-16T15:40:00+00:00', 'mine': False})
d['GET /listings'] = {'items': [new[c[0]] for c in COLOURS]}
d['GET /favorites'] = {'items': [new[3], new[2]]}
stats0 = {'views': 0, 'favorites': 0, 'chats': 0, 'orders': 0, 'sold': 0}
was = {it['id']: it.get('stats') for it in d['GET /me/listings']['items']}
d['GET /me/listings'] = {**d['GET /me/listings'], 'items': [{**new[c[0]], 'stats': was.get(c[0]) or stats0} for c in COLOURS]}
d['GET /sellers/1'] = {**d['GET /sellers/1'], 'rating': 4.8, 'reviews': 23, 'listings': 12}
covers = {lid: l['media'][0]['thumb_url'] for lid, l in new.items()}
REV = [('Гүлнар', '2026-10-12', 5, 'Фотодағыдай келді, түсі де дәл сондай. Жеңіл екен, күні бойы киіп жүрдім.', 'true', [0, 3]),
       ('Ерлан', '2026-10-03', 4, 'Сапасы жақсы. Жеткізу бір күн кешікті, бірақ сатушы алдын ала хабарлады.', 'small', [4]),
       ('Айгерім', '2026-09-28', 5, 'Табаны жұмсақ, тігісі ұқыпты. Екінші түсін де аламын.', 'true', [5, 1, 2])]
rv = d['GET /sellers/1/reviews']
rv['seller'] = {**rv['seller'], 'rating': 4.8, 'reviews': 23}
rv['items'] = [{'id': 10 - n, 'order_id': 1004 - n, 'rating': r, 'text': t, 'seller_reply': None,
                'photos': [new[3]['media'][p]['original_url'] for p in ph], 'fit': f, 'buyer_name': who,
                'created_at': f'{day}T10:00:00+00:00'} for n, (who, day, r, t, f, ph) in enumerate(REV)]

def walk(o):
    if isinstance(o, dict):
        if 'listing_id' in o and o['listing_id'] in new:
            if 'listing_title' in o: o['listing_title'] = new[o['listing_id']]['title']
            if 'listing_cover' in o: o['listing_cover'] = covers[o['listing_id']]
        if o.get('id') == 1 and o.get('shop_name') == 'Qadam Store' and 'rating' in o: o['rating'], o['reviews'] = 4.8, 23
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
s = json.dumps(d, ensure_ascii=False, separators=(',', ':'))
for t in old_titles: s = s.replace(t, 'Жеңіл жүгіру кроссовкасы')
(demo / 'api.json').write_text(s)
print('ok', len(s))

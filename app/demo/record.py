"""Records the demo API's answers into app/demo/api.json for the offline demo build (--dart-define=DEMO=true).

Run against a seeded local API:  python3 demo/record.py http://127.0.0.1:8000 BUYER_TOKEN SELLER_TOKEN
Media files the answers point at are copied into app/demo/media and their URLs rewritten to MEDIA_BASE.
"""
import json
import shutil
import sys
import urllib.parse
import urllib.request
from pathlib import Path

MEDIA_BASE = "https://raw.githubusercontent.com/ooik2086-cmd/vitrina/claude/initial-code/app/demo/media/"
HERE = Path(__file__).parent

base, buyer, seller, media_dir = sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4])
api = base + "/api/v1"
answers: dict[str, object] = {}
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get(path: str, token: str | None, query: dict | None = None):
    url = api + path + ("?" + urllib.parse.urlencode(query) if query else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"} if token else {})
    with opener.open(req) as r:
        return json.loads(r.read() or b"null")


def keep(path: str, token: str | None = None, query: dict | None = None):
    data = get(path, token, query)
    key = "GET " + path + ("?" + urllib.parse.urlencode(sorted(query.items())) if query else "")
    answers[key] = data
    return data


me = keep("/me", buyer)
listings = keep("/listings", buyer, {"limit": "100"})["items"]
answers["GET /listings"] = answers.pop("GET /listings?limit=100")
sellers = set()
for item in listings:
    lid = item["id"]
    full = keep(f"/listings/{lid}", buyer)
    sellers.add(full["seller"]["id"])
    keep(f"/listings/{lid}/similar", buyer)
    keep(f"/listings/{lid}/questions", buyer)
for sid in sellers:
    keep(f"/sellers/{sid}", buyer)
    keep(f"/sellers/{sid}/reviews", buyer)
for path in ("/favorites", "/saved-searches", "/conversations", "/notifications", "/me/following",
             "/me/notification-settings", "/me/blocks"):
    keep(path, buyer)
# A thread nobody wrote in yet is noise in a demo inbox.
answers["GET /conversations"]["items"] = [c for c in answers["GET /conversations"]["items"] if c["last_message"]]
for c in answers["GET /conversations"]["items"]:
    keep(f"/conversations/{c['id']}/messages", buyer, {"after_id": "0"})
for o in keep("/orders", buyer, {"role": "buyer"})["items"]:
    keep(f"/orders/{o['id']}", buyer)
keep("/offers", buyer, {"role": "buyer"})
# Seller tools show the demo shop's own figures, so the seller screens are not empty.
for path in ("/me/listings", "/me/earnings", "/me/promo-codes"):
    keep(path, seller)
keep("/me/analytics", seller, {"days": "30"})
keep("/offers", seller, {"role": "seller"})
for o in keep("/orders", seller, {"role": "seller"})["items"]:
    if f"GET /orders/{o['id']}" not in answers:
        keep(f"/orders/{o['id']}", seller)
for item in answers["GET /me/listings"]["items"]:
    if item["status"] != "published":
        answers[f"GET /listings/{item['id']}"] = get(f"/listings/{item['id']}", seller)

text = json.dumps(answers, ensure_ascii=False)
prefix = base + "/media/"
used = sorted({u.split('"')[0] for u in text.split(prefix)[1:]})
out = HERE / "media"
shutil.rmtree(out, ignore_errors=True)
for rel in used:
    (out / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(media_dir / rel, out / rel)
(HERE / "api.json").write_text(text.replace(prefix, MEDIA_BASE))
print(len(answers), "answers,", len(used), "media files")

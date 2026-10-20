"""A stand-in S3 endpoint for the deploy smoke test only: path-style buckets kept in a folder, PUT, GET (public, as
the photos bucket is), DELETE and ListObjectsV2 with a prefix. Only the buckets named in S3_PUBLIC answer a GET
that carries no signature, as a real provider would. Signatures are not verified; the API's signing is covered by
the unit tests (tests/test_storage.py).

It also stands in for Mobizon's send-SMS call: a message is kept (only when the key is the smoke test's) and the
last one to a number is read back at GET /_sms/<digits>, so the test signs in the way a person does."""
from __future__ import annotations

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "/data")
PUBLIC = set(os.environ.get("S3_PUBLIC", "").split(","))
SMS_KEY = "smoke-mobizon-key"


class Handler(BaseHTTPRequestHandler):
    def target(self):
        parts = urlsplit(self.path)
        bucket, _, key = unquote(parts.path).lstrip("/").partition("/")
        if not bucket or ".." in key.split("/"):
            return None, None, parse_qs(parts.query)
        return ROOT / bucket, key, parse_qs(parts.query)

    def answer(self, status, body=b"", ctype="application/xml"):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_PUT(self):
        bucket, key, _ = self.target()
        if not key:
            return self.answer(400)
        data = self.rfile.read(int(self.headers.get("content-length", 0)))
        (bucket / key).parent.mkdir(parents=True, exist_ok=True)
        (bucket / key).write_bytes(data)
        self.answer(200)

    def do_POST(self):
        parts = urlsplit(self.path)
        if parts.path != "/service/message/sendsmsmessage":
            return self.answer(404)
        form = parse_qs(self.rfile.read(int(self.headers.get("content-length", 0))).decode())
        if parse_qs(parts.query).get("apiKey") != [SMS_KEY]:
            answer = {"code": 1, "data": [], "message": "wrong key"}
        else:
            recipient = form["recipient"][0]
            if not recipient.isdigit():
                return self.answer(400)
            (ROOT / "_sms").mkdir(parents=True, exist_ok=True)
            (ROOT / "_sms" / recipient).write_text(form["text"][0])
            answer = {"code": 0, "data": {"messageId": "1"}, "message": ""}
        self.answer(200, json.dumps(answer).encode(), "application/json")

    def do_GET(self):
        bucket, key, query = self.target()
        if bucket is not None and bucket.name == "_sms" and key.isdigit():
            path = bucket / key
            return self.answer(200, path.read_bytes(), "text/plain") if path.is_file() else self.answer(404)
        if bucket is None:
            return self.answer(400)
        signed = "authorization" in self.headers or "X-Amz-Signature" in query
        if not signed and not (key and bucket.name in PUBLIC):
            return self.answer(403)
        if not key:
            prefix = query.get("prefix", [""])[0]
            keys = sorted(str(p.relative_to(bucket)) for p in bucket.rglob("*") if p.is_file()) if bucket.is_dir() else []
            body = ('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>false</IsTruncated>'
                    + "".join(f"<Contents><Key>{escape(k)}</Key><LastModified>2026-10-20T00:00:00.000Z</LastModified>"
                              "</Contents>" for k in keys if k.startswith(prefix)) + "</ListBucketResult>")
            return self.answer(200, body.encode())
        path = bucket / key
        if not path.is_file():
            return self.answer(404)
        self.answer(200, path.read_bytes(), "application/octet-stream")

    do_HEAD = do_GET

    def do_DELETE(self):
        bucket, key, _ = self.target()
        if key and (bucket / key).is_file():
            (bucket / key).unlink()
        self.answer(204)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()

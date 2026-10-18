import unittest
from datetime import datetime, timezone

import httpx

from vitrina_api.config import Settings
from vitrina_api.storage import LocalStorage, S3Storage, make_storage, sigv4_headers

KEY_ID, SECRET = "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"


class SigV4Tests(unittest.TestCase):
    def test_matches_the_aws_documentation_example(self):
        # "GET Object" example from the S3 Signature Version 4 documentation.
        h = sigv4_headers("GET", "https://examplebucket.s3.amazonaws.com/test.txt", region="us-east-1",
                          access_key=KEY_ID, secret_key=SECRET, headers={"Range": "bytes=0-9"},
                          now=datetime(2013, 5, 24, tzinfo=timezone.utc))
        self.assertEqual(h["authorization"],
                         "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                         "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                         "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")


class FakeBucket:
    """An in-memory S3 endpoint that insists on a signature, enough to round-trip the client."""

    def __init__(self):
        self.objects: dict[str, tuple[bytes, str]] = {}

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if not request.headers.get("authorization", "").startswith("AWS4-HMAC-SHA256 Credential=key/"):
            return httpx.Response(403)
        path = request.url.path
        if request.method == "GET" and path == "/vitrina" and request.url.params.get("list-type") == "2":
            return self.listing(request.url.params.get("continuation-token"))
        if request.method == "DELETE":
            self.objects.pop(path, None)
            return httpx.Response(204)
        if request.method == "PUT":
            self.objects[path] = (request.content, request.headers["content-type"])
            return httpx.Response(200)
        if path in self.objects:
            return httpx.Response(200, content=self.objects[path][0])
        return httpx.Response(404)

    def listing(self, token):
        """ListObjectsV2, one object per page so the client has to follow the continuation token."""
        keys = sorted(p.removeprefix("/vitrina/") for p in self.objects) + ["notes/readme.txt"]
        at = int(token or 0)
        more = at + 1 < len(keys)
        body = ('<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                f'<IsTruncated>{"true" if more else "false"}</IsTruncated>'
                + (f"<NextContinuationToken>{at + 1}</NextContinuationToken>" if more else "")
                + f"<Contents><Key>{keys[at]}</Key><LastModified>2026-10-01T08:00:00.000Z</LastModified></Contents>"
                "</ListBucketResult>")
        return httpx.Response(200, content=body.encode())


class S3StorageTests(unittest.TestCase):
    def setUp(self):
        self.bucket = FakeBucket()
        self.s3 = S3Storage(endpoint="https://s3.example.kz", bucket="vitrina", region="kz-1", access_key="key",
                            secret_key="secret", public_base="https://cdn.example.kz/",
                            client=httpx.Client(transport=httpx.MockTransport(self.bucket)))

    def test_put_then_read_back_through_the_public_url(self):
        url = self.s3.put(b"\xff\xd8photo", owner_id=7)
        self.assertRegex(url, r"^https://cdn\.example\.kz/7/[0-9a-f]{32}\.jpg$")
        path = "/vitrina/" + url.split("cdn.example.kz/")[1]
        self.assertEqual(self.bucket.objects[path], (b"\xff\xd8photo", "image/jpeg"))
        self.assertTrue(self.s3.owns(url))
        self.assertEqual(self.s3.read(url), b"\xff\xd8photo")
        self.assertEqual(self.s3.put(b"v", owner_id=7, ext="mp4").rsplit(".", 1)[1], "mp4")

    def test_refuses_urls_it_does_not_own_and_reports_failures(self):
        self.assertFalse(self.s3.owns("https://evil.example/7/x.jpg"))
        with self.assertRaises(ValueError):
            self.s3.read("https://evil.example/7/x.jpg")
        with self.assertRaises(ValueError):
            self.s3.read("https://cdn.example.kz/7/../../secret")
        with self.assertRaises(RuntimeError):
            self.s3.read("https://cdn.example.kz/7/" + "0" * 32 + ".jpg")


    def test_lists_every_page_of_our_files_and_deletes_one(self):
        a, b = self.s3.put(b"a", owner_id=7), self.s3.put(b"b", owner_id=8)
        found = dict(self.s3.keys())
        key_a, key_b = a.split("cdn.example.kz/")[1], b.split("cdn.example.kz/")[1]
        self.assertEqual(set(found), {key_a, key_b})  # notes/readme.txt is not ours
        self.assertEqual(found[key_a], datetime(2026, 10, 1, 8, tzinfo=timezone.utc))
        self.s3.delete(key_a)
        self.assertEqual(set(dict(self.s3.keys())), {key_b})
        with self.assertRaises(ValueError):
            self.s3.delete("7/../../secret")


class LocalListingTests(unittest.TestCase):
    def test_lists_and_deletes_only_files_in_our_key_shape(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            disk = LocalStorage(root, "http://test/media")
            url = disk.put(b"a", owner_id=3)
            os.makedirs(os.path.join(root, "3", "sub"))
            open(os.path.join(root, "3", "notes.txt"), "w").close()
            key = url.split("/media/")[1]
            self.assertEqual([k for k, _ in disk.keys()], [key])
            disk.delete(key)
            self.assertEqual(list(disk.keys()), [])
            with self.assertRaises(ValueError):
                disk.delete("../outside.jpg")


class ChoiceTests(unittest.TestCase):
    def test_bucket_setting_picks_s3_and_disk_is_the_default(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsInstance(make_storage(Settings(media_dir=tmp)), LocalStorage)
            s3 = make_storage(Settings(media_dir=tmp, s3_endpoint="https://s3.example.kz", s3_bucket="vitrina",
                                       s3_access_key="k", s3_secret_key="s", public_media_url="https://cdn.example.kz"))
            self.assertIsInstance(s3, S3Storage)

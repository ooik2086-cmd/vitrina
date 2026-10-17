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
        if request.method == "PUT":
            self.objects[path] = (request.content, request.headers["content-type"])
            return httpx.Response(200)
        if path in self.objects:
            return httpx.Response(200, content=self.objects[path][0])
        return httpx.Response(404)


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


class ChoiceTests(unittest.TestCase):
    def test_bucket_setting_picks_s3_and_disk_is_the_default(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsInstance(make_storage(Settings(media_dir=tmp)), LocalStorage)
            s3 = make_storage(Settings(media_dir=tmp, s3_endpoint="https://s3.example.kz", s3_bucket="vitrina",
                                       s3_access_key="k", s3_secret_key="s", public_media_url="https://cdn.example.kz"))
            self.assertIsInstance(s3, S3Storage)

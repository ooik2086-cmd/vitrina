import unittest
from datetime import datetime, timezone

import httpx

from vitrina_api.config import Settings
from vitrina_api.storage import LocalStorage, S3Storage, make_storage, presign, sigv4_headers

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


class PresignTests(unittest.TestCase):
    def test_matches_the_aws_documentation_example(self):
        # "Authenticating Requests: Using Query Parameters" example from the S3 SigV4 documentation.
        url = presign("https://examplebucket.s3.amazonaws.com/test.txt", region="us-east-1", access_key=KEY_ID,
                      secret_key=SECRET, expires=86400, now=datetime(2013, 5, 24, tzinfo=timezone.utc))
        self.assertTrue(url.endswith("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
        self.assertIn("X-Amz-Expires=86400", url)


class FakeBucket:
    """An in-memory S3 endpoint that insists on a signature, enough to round-trip the client."""

    def __init__(self):
        self.objects: dict[str, tuple[bytes, str]] = {}

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if not request.headers.get("authorization", "").startswith("AWS4-HMAC-SHA256 Credential=key/"):
            return httpx.Response(403)
        if request.method in ("GET", "DELETE"):  # recompute the signature over the request exactly as it arrived
            when = datetime.strptime(request.headers["x-amz-date"], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            expected = sigv4_headers(request.method, str(request.url), region="kz-1", access_key="key",
                                     secret_key="secret", now=when)["authorization"]
            if request.headers["authorization"] != expected:
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
        at = int(token.removeprefix("p/+=")) if token else 0
        more = at + 1 < len(keys)
        body = ('<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                f'<IsTruncated>{"true" if more else "false"}</IsTruncated>'
                + (f"<NextContinuationToken>p/+={at + 1}</NextContinuationToken>" if more else "")
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

    def test_a_listing_cut_short_without_a_token_stops_instead_of_looking_complete(self):
        self.s3.client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, content=(
            b"<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"))))
        with self.assertRaises(RuntimeError):
            list(self.s3.keys())


class PrivateBucketTests(unittest.TestCase):
    def test_private_files_are_stored_as_references_and_read_through_links_that_expire(self):
        from vitrina_api.storage import PRIVATE_BASE, private_link
        bucket = FakeBucket()
        s3 = S3Storage(endpoint="https://s3.example.kz", bucket="vitrina-private", region="kz-1", access_key="key",
                       secret_key="secret", public_base=PRIVATE_BASE,
                       client=httpx.Client(transport=httpx.MockTransport(bucket)))
        ref = s3.put(b"receipt", owner_id=4)
        self.assertRegex(ref, r"^private:/4/[0-9a-f]{32}\.jpg$")
        link = private_link(s3, ref, now=datetime(2026, 10, 18, tzinfo=timezone.utc), ttl=600)
        self.assertTrue(link.startswith(f"https://s3.example.kz/vitrina-private/{ref.removeprefix('private:/')}?"))
        self.assertIn("X-Amz-Expires=1500", link)  # 600 from the start of its 15-minute window
        self.assertEqual(private_link(s3, "private:/../secret"), "")  # damaged: shown as no file


class PrivateSettingsTests(unittest.TestCase):
    def test_private_files_never_sit_under_the_public_folder_or_link_to_the_cdn(self):
        import os
        import tempfile
        from vitrina_api.storage import make_private_storage
        with tempfile.TemporaryDirectory() as root:
            public = os.path.join(root, "media")
            with self.assertRaises(RuntimeError):
                make_private_storage(Settings(media_dir=public, private_media_dir=os.path.join(public, "private")))
            with self.assertRaises(RuntimeError):  # /media is the bucket: the CDN's host cannot serve private links
                make_private_storage(Settings(media_dir=public, private_media_dir=os.path.join(root, "p"),
                                              s3_bucket="vitrina", public_media_url="https://cdn.vitrina.kz"))
            files = make_private_storage(Settings(media_dir=public, private_media_dir=os.path.join(root, "p"),
                                                  s3_bucket="vitrina", public_media_url="https://cdn.vitrina.kz",
                                                  public_api_url="https://api.vitrina.kz/"))
            self.assertEqual(files.link_base, "https://api.vitrina.kz/api/v1/private-media")


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


class BackupBucket:
    """The backup bucket: objects by key, ListObjectsV2 with a prefix, two keys a page."""

    def __init__(self, key="key", public=()):
        self.objects: dict[str, bytes] = {}
        self.key, self.public = key, public  # buckets anyone may read

    def __call__(self, request: httpx.Request) -> httpx.Response:
        bucket, _, key = request.url.path.lstrip("/").partition("/")
        if not request.headers.get("authorization", "").startswith(f"AWS4-HMAC-SHA256 Credential={self.key}/"):
            if not (request.method == "GET" and bucket in self.public and key):
                return httpx.Response(403)
        key = f"{bucket}/{key}" if bucket != "vitrina-backup" else key
        if request.method == "GET" and not key:
            prefix, at = request.url.params.get("prefix", ""), int(request.url.params.get("continuation-token", 0))
            keys = sorted(k for k in self.objects if k.startswith(prefix))
            page, more = keys[at:at + 2], at + 2 < len(keys)
            body = ('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                    f'<IsTruncated>{"true" if more else "false"}</IsTruncated>'
                    + (f"<NextContinuationToken>{at + 2}</NextContinuationToken>" if more else "")
                    + "".join(f"<Contents><Key>{k}</Key></Contents>" for k in page) + "</ListBucketResult>")
            return httpx.Response(200, content=body.encode())
        if request.method == "PUT":
            self.objects[key] = request.content
            return httpx.Response(200)
        if request.method == "DELETE":
            self.objects.pop(key, None)
            return httpx.Response(204)
        return httpx.Response(200, content=self.objects[key]) if key in self.objects else httpx.Response(404)


class BackupTests(unittest.TestCase):
    """The database's copies off the server (vitrina_api.backup, run by deploy/backup.sh)."""

    def setUp(self):
        import tempfile
        from pathlib import Path
        from vitrina_api import backup
        self.backup, self.store = backup, BackupBucket()
        self.client = httpx.Client(transport=httpx.MockTransport(self.store))
        self.settings = Settings(s3_endpoint="https://s3.example.kz", s3_region="kz-1", s3_access_key="key",
                                 s3_secret_key="secret", s3_bucket="vitrina", s3_private_bucket="vitrina-private",
                                 s3_backup_bucket="vitrina-backup")
        self.s3 = backup.bucket(self.settings, self.client)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def dump(self, name, data=b"PGDMP dump"):
        (self.dir / name).write_bytes(data)
        return self.dir / name

    def test_a_copy_goes_up_with_its_checksum_and_comes_back_the_same(self):
        import hashlib
        digest = self.backup.put(self.s3, self.dump("vitrina-20261020T020000Z-0a1b2c3d.dump", b"PGDMP one"))
        self.assertEqual(digest, hashlib.sha256(b"PGDMP one").hexdigest())
        self.assertEqual(self.store.objects["db/vitrina-20261020T020000Z-0a1b2c3d.dump.sha256"], digest.encode())
        back = self.dir / "back"
        back.mkdir()
        got = self.backup.get(self.s3, "vitrina-20261020T020000Z-0a1b2c3d.dump", back)
        self.assertEqual((got.name, got.read_bytes()), ("vitrina-20261020T020000Z-0a1b2c3d.dump", b"PGDMP one"))
        self.assertEqual((back / (got.name + ".sha256")).read_text(),  # for restore.sh's sha256sum -c
                         f"{digest}  vitrina-20261020T020000Z-0a1b2c3d.dump\n")

    def test_a_copy_that_does_not_match_its_checksum_is_not_restored(self):
        self.backup.put(self.s3, self.dump("vitrina-20261020T020000Z-0a1b2c3d.dump"))
        self.store.objects["db/vitrina-20261020T020000Z-0a1b2c3d.dump"] = b"PGDMP cut sho"
        with self.assertRaises(SystemExit):
            self.backup.get(self.s3, "vitrina-20261020T020000Z-0a1b2c3d.dump", self.dir / "x.dump")
        self.assertFalse((self.dir / "x.dump").exists())

    def test_prune_keeps_the_newest_and_leaves_other_files_alone(self):
        for day in range(1, 6):  # listed two a page, so every page has to be read
            self.backup.put(self.s3, self.dump(f"vitrina-202610{day:02d}T020000Z-0a1b2c3d.dump"))
        self.store.objects["db/notes.txt"] = b"left by hand"
        self.assertEqual(len(self.backup.names(self.s3)), 5)
        gone = self.backup.prune(self.s3, keep=2)
        self.assertEqual(gone, [f"vitrina-202610{day:02d}T020000Z-0a1b2c3d.dump" for day in (1, 2, 3)])
        self.assertEqual(sorted(self.store.objects), ["db/notes.txt", "db/vitrina-20261004T020000Z-0a1b2c3d.dump",
                                                      "db/vitrina-20261004T020000Z-0a1b2c3d.dump.sha256",
                                                      "db/vitrina-20261005T020000Z-0a1b2c3d.dump",
                                                      "db/vitrina-20261005T020000Z-0a1b2c3d.dump.sha256"])
        with self.assertRaises(SystemExit):
            self.backup.prune(self.s3, keep=0)

    def test_refuses_odd_names_empty_dumps_and_a_shared_bucket(self):
        from dataclasses import replace
        for name in ("../etc.dump", "vitrina-latest.dump", "vitrina-20261020T020000Z-0a1b2c3d.dump.sha256"):
            with self.assertRaises(SystemExit):
                self.backup.put(self.s3, self.dump(name.replace("/", "_")) if "/" in name else self.dump(name))
            with self.assertRaises(SystemExit):
                self.backup.get(self.s3, name, self.dir)
        with self.assertRaises(SystemExit):
            self.backup.put(self.s3, self.dump("vitrina-20261020T020000Z-0a1b2c3d.dump", b""))
        self.assertEqual(self.store.objects, {})
        for shared in ("", "vitrina", "vitrina-private"):
            with self.assertRaises(SystemExit):
                self.backup.bucket(replace(self.settings, s3_backup_bucket=shared), self.client)

    def test_the_command_line(self):
        import contextlib
        import io
        import os
        from unittest import mock
        env = {"VITRINA_S3_ENDPOINT": "https://s3.example.kz", "VITRINA_S3_REGION": "kz-1",
               "VITRINA_S3_ACCESS_KEY": "key", "VITRINA_S3_SECRET_KEY": "secret",
               "VITRINA_S3_BACKUP_BUCKET": "vitrina-backup"}
        path = self.dump("vitrina-20261020T020000Z-0a1b2c3d.dump")
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out):
            self.backup.main(["put", str(path)], self.client)
            self.backup.main(["list"], self.client)
            path.unlink()
            self.backup.main(["get", path.name, str(self.dir)], self.client)
            self.backup.main(["prune", "--keep", "1"], self.client)
        self.assertIn("vitrina-20261020T020000Z-0a1b2c3d.dump\n", out.getvalue())
        self.assertEqual(path.read_bytes(), b"PGDMP dump")

    def test_a_backup_bucket_anyone_can_read_is_refused_loudly(self):
        self.store.public = ("vitrina-backup",)
        with self.assertRaises(SystemExit) as err:
            self.backup.put(self.s3, self.dump("vitrina-20261020T020000Z-0a1b2c3d.dump"))
        self.assertIn("without a key", str(err.exception))

    def test_the_backup_bucket_can_have_a_key_of_its_own(self):
        from dataclasses import replace
        own = BackupBucket(key="backupkey")
        s3 = self.backup.bucket(replace(self.settings, s3_backup_access_key="backupkey", s3_backup_secret_key="bs"),
                                httpx.Client(transport=httpx.MockTransport(own)))
        self.backup.put(s3, self.dump("vitrina-20261020T020000Z-0a1b2c3d.dump"))  # the photos' key would get 403
        self.assertIn("db/vitrina-20261020T020000Z-0a1b2c3d.dump", own.objects)

    def test_check_says_which_bucket_is_wrong(self):
        from dataclasses import replace
        settings = replace(self.settings, public_media_url="https://s3.example.kz/vitrina")
        self.store.public = ("vitrina",)
        self.assertEqual(self.backup.check(settings, self.client), [])
        self.assertEqual(self.store.objects, {})  # the probes are deleted
        self.store.public = ()
        self.assertEqual([p.split(":")[0] for p in self.backup.check(settings, self.client)], ["VITRINA_S3_BUCKET"])
        self.store.public = ("vitrina", "vitrina-private")
        self.assertEqual([p.split(":")[0] for p in self.backup.check(settings, self.client)],
                         ["VITRINA_S3_PRIVATE_BUCKET"])
        self.store.public = ("vitrina",)
        wrong = BackupBucket(key="other")
        problems = self.backup.check(settings, httpx.Client(transport=httpx.MockTransport(wrong)))
        self.assertEqual(len(problems), 3)
        self.assertIn("HTTP 403", problems[0])


class DiskStorageTests(unittest.TestCase):
    """VITRINA_STORAGE=disk: photos and private files on the server's own disk, copied beside the dumps."""

    def setUp(self):
        import tempfile
        from pathlib import Path
        from vitrina_api import backup
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.backup, self.dir = backup, Path(tmp.name)
        self.src, self.dst = self.dir / "media", self.dir / "copy"
        (self.src / "7").mkdir(parents=True)

    def test_the_copy_follows_the_folder(self):
        import os
        (self.src / "7" / "a.jpg").write_bytes(b"a")
        (self.src / "7" / "b.jpg").write_bytes(b"b")
        self.assertEqual(self.backup.mirror(self.src, self.dst), (2, 0))
        self.assertEqual(self.backup.mirror(self.src, self.dst), (0, 0))  # nothing new: nothing copied
        (self.src / "7" / "b.jpg").unlink()
        (self.src / "7" / "a.jpg").write_bytes(b"a2")
        os.utime(self.src / "7" / "a.jpg", (1, 2_000_000_000))
        (self.dst / "7" / "c.jpg.mirror-part").write_bytes(b"half")  # a run cut off before
        self.assertEqual(self.backup.mirror(self.src, self.dst), (1, 2))
        self.assertEqual(sorted(p.name for p in self.dst.rglob("*") if p.is_file()), ["a.jpg"])
        self.assertEqual((self.dst / "7" / "a.jpg").read_bytes(), b"a2")

    def test_an_empty_folder_does_not_wipe_the_copy(self):
        (self.src / "7" / "a.jpg").write_bytes(b"a")
        self.backup.mirror(self.src, self.dst)
        (self.src / "7" / "a.jpg").unlink()
        with self.assertRaises(SystemExit):  # e.g. the volume not mounted
            self.backup.mirror(self.src, self.dst)
        self.assertTrue((self.dst / "7" / "a.jpg").is_file())
        with self.assertRaises(SystemExit):
            self.backup.mirror(self.dir / "missing", self.dst)
        with self.assertRaises(SystemExit):  # even with nothing to protect: a wrong path is said
            self.backup.mirror(self.dir / "missing", self.dir / "new-copy")
        self.assertEqual(self.backup.mirror(self.src / "7" / "..", self.dir / "empty-copy"), (0, 0))
        self.assertTrue((self.dir / "empty-copy").is_dir())  # an empty folder still has its (empty) copy

    def test_putting_files_back_keeps_newer_ones(self):
        (self.src / "7" / "a.jpg").write_bytes(b"a")
        (self.dst / "8").mkdir(parents=True)
        (self.dst / "8" / "new.jpg").write_bytes(b"uploaded since")
        self.assertEqual(self.backup.mirror(self.src, self.dst, keep_extra=True), (1, 0))
        self.assertTrue((self.dst / "8" / "new.jpg").is_file())

    def test_check_writes_reads_and_removes_in_both_folders(self):
        settings = Settings(storage="disk", media_dir=str(self.dir / "m"), private_media_dir=str(self.dir / "p"),
                            public_media_url="https://vitrina.kz/media", public_api_url="https://vitrina.kz")
        self.assertEqual(self.backup.check(settings), [])
        self.assertEqual([p for p in self.dir.rglob("*") if p.is_file()], [])  # nothing left behind
        (self.dir / "p" / "0").rmdir()
        (self.dir / "p" / "0").write_bytes(b"")  # where the check's folder goes: it cannot write there
        self.assertIn("VITRINA_PRIVATE_MEDIA_DIR", " ".join(self.backup.check(settings)))

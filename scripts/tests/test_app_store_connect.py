import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("app_store_connect", str(Path(__file__).resolve().parents[1] / "app-store-connect"))
spec = importlib.util.spec_from_loader(loader.name, loader)
asc = importlib.util.module_from_spec(spec)
loader.exec_module(asc)


class ScreenshotProcessingTests(unittest.TestCase):
    def test_a_draft_screenshot_finishes_at_the_documented_parent_state(self):
        for state in ("ACTIVE", "PARENT_PREPARE_FOR_SUBMISSION"):
            with self.subTest(state=state):
                with patch.object(asc, "api", return_value={"attributes": {"state": state}}):
                    self.assertTrue(asc.processed_screenshots(["screenshot"]))

    def test_processing_is_pending_and_failed_processing_is_reported(self):
        with patch.object(asc, "api", return_value={"attributes": {"state": "ASSET_PROCESSING"}}):
            self.assertIsNone(asc.processed_screenshots(["screenshot"]))
        with patch.object(asc, "api", return_value={"attributes": {"state": "FAILED", "stateDetails": "Invalid image"}}):
            with self.assertRaisesRegex(SystemExit, "Invalid image"):
                asc.processed_screenshots(["screenshot"])


class BuildIdentityTests(unittest.TestCase):
    def test_pending_uploads_count_toward_the_next_global_build(self):
        with patch.object(asc, "api", side_effect=[
            [{"attributes": {"version": "10"}}],
            [{"attributes": {"cfBundleVersion": "12"}}],
        ]):
            self.assertEqual(13, asc.next_build_number("app"))

    def test_acceptance_filters_the_exact_uploaded_build(self):
        with patch.object(asc, "api", return_value=[]) as api:
            self.assertIsNone(asc.processed_build("app", "1.3.2", "11"))
            self.assertEqual("11", api.call_args.kwargs["filter[version]"])
            self.assertEqual("1.3.2", api.call_args.kwargs["filter[preReleaseVersion.version]"])

    def test_all_pages_are_read_before_selecting_a_build_number(self):
        pages = [
            {"data": [{"id": "first"}], "links": {"next": asc.API + "builds?cursor=next"}},
            {"data": [{"id": "last"}], "links": {"next": None}},
        ]
        with patch.object(asc, "token", return_value="fixture"), patch.object(asc, "send", side_effect=[json.dumps(p).encode() for p in pages]):
            self.assertEqual([{"id": "first"}, {"id": "last"}], asc.api("GET", "builds"))


class UploadCleanupTests(unittest.TestCase):
    def test_a_failed_transfer_reclaims_its_reserved_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "display").mkdir()
            (root / "display/01.png").write_bytes(b"fixture image")
            reservation = {"id": "reserved", "attributes": {"uploadOperations": [
                {"url": "https://example.com/upload", "offset": 0, "length": 13, "method": "PUT", "requestHeaders": []}
            ]}}
            with patch.object(asc, "draft_version", return_value=("version", False)), \
                 patch.object(asc, "apply_metadata"), \
                 patch.object(asc, "api", side_effect=[{"id": "library"}, reservation]), \
                 patch.object(asc, "send", side_effect=asc.RequestFailed("transfer failed")), \
                 patch.object(asc, "delete_unplaced") as cleanup:
                with self.assertRaisesRegex(asc.RequestFailed, "transfer failed"):
                    asc.app_store("app", "1.3.2", "11", root / "metadata", root, "notes")
                cleanup.assert_called_once_with(["reserved"])


class MetadataTests(unittest.TestCase):
    def test_only_text_that_differs_is_sent(self):
        self.assertEqual({"keywords": "ssh"}, asc.differing({"description": "d", "keywords": "x"}, {"description": "d", "keywords": "ssh"}))
        self.assertEqual({"subtitle": "s"}, asc.differing({"subtitle": None}, {"subtitle": "s"}))

    def test_files_map_to_store_fields_and_are_trimmed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "privacy_url.txt").write_text("https://example.com/privacy\n")
            (directory / "name.txt").write_text("App\n")
            self.assertEqual({"privacyPolicyUrl": "https://example.com/privacy", "name": "App"}, asc.read_fields(directory, asc.INFO_FIELDS))

    def test_a_released_app_info_is_never_patched(self):
        calls = []

        def api(method, path, data=None, **params):
            calls.append((method, path))
            if path.endswith("/appStoreVersionLocalizations"):
                return [{"id": "loc", "attributes": {"locale": "en-US", "description": "old"}}]
            if path.endswith("/appInfos"):
                return [{"id": "info", "attributes": {"state": "READY_FOR_DISTRIBUTION"}}]
            return None

        with tempfile.TemporaryDirectory() as temporary:
            locale = Path(temporary) / "en-US"
            locale.mkdir()
            (locale / "description.txt").write_text("new")
            (locale / "name.txt").write_text("App")
            with patch.object(asc, "api", side_effect=api):
                asc.apply_metadata("app", "version", Path(temporary), "- Fixed it.")
        self.assertEqual([("PATCH", "appStoreVersionLocalizations/loc")], [call for call in calls if call[0] == "PATCH"])
        self.assertNotIn("appInfoLocalizations", " ".join(path for _, path in calls))


class VersionAndMetadataTests(unittest.TestCase):
    def test_a_version_at_or_below_an_uploaded_one_is_refused_before_the_build(self):
        responses = [[{"attributes": {"versionString": "2.13.0", "appVersionState": "READY_FOR_DISTRIBUTION"}},
                      {"attributes": {"versionString": "2.14.0", "appVersionState": "PREPARE_FOR_SUBMISSION"}}],
                     [{"attributes": {"version": "2.13.1"}}]]
        for version, accepted in (("2.13.1", False), ("2.13.0", False), ("2.13.2", True)):
            with self.subTest(version=version), patch.object(asc, "api", side_effect=list(responses)):
                if accepted:
                    asc.check_version("app", version)
                else:
                    with self.assertRaisesRegex(SystemExit, "must exceed"):
                        asc.check_version("app", version)

    def test_an_editable_app_info_is_patched_and_whats_new_only_follows_a_release(self):
        calls = []

        def api(method, path, data=None, **params):
            calls.append((method, path, data and data["attributes"]))
            if path.endswith("/appStoreVersionLocalizations"):
                return [{"id": "loc", "attributes": {"locale": "en-US", "description": "same", "whatsNew": "old"}}]
            if path.endswith("/appInfos"):
                return [{"id": "info", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]
            if path.endswith("/appInfoLocalizations"):
                return [{"id": "infoloc", "attributes": {"locale": "en-US", "name": "Old"}}]
            return None

        with tempfile.TemporaryDirectory() as temporary:
            locale = Path(temporary) / "en-US"
            locale.mkdir()
            (locale / "description.txt").write_text("same")
            (locale / "name.txt").write_text("New")
            with patch.object(asc, "api", side_effect=api):
                asc.apply_metadata("app", "version", Path(temporary), None)
                asc.apply_metadata("app", "version", Path(temporary), "- Fixed it.")
        patches = [call for call in calls if call[0] == "PATCH"]
        self.assertEqual([("PATCH", "appInfoLocalizations/infoloc", {"name": "New"}),
                          ("PATCH", "appStoreVersionLocalizations/loc", {"whatsNew": "- Fixed it."}),
                          ("PATCH", "appInfoLocalizations/infoloc", {"name": "New"})], patches)

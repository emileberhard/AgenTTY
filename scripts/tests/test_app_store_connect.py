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


def submission(identifier, version, state):
    return {"id": identifier, "attributes": {"state": state},
            "relationships": {"appStoreVersionForReview": {"data": version and {"type": "appStoreVersions", "id": version}}}}


def item(identifier, version, state):
    return {"id": identifier, "attributes": {"state": state},
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version}}}}


LIVE = {"id": "live", "attributes": {"appVersionState": "READY_FOR_DISTRIBUTION", "versionString": "0.9.0"}}


class ReviewPolicyTests(unittest.TestCase):
    def test_a_rerun_leaves_its_own_version_in_review(self):
        with patch.object(asc, "api", return_value=[{"id": "review", "attributes": {
            "appVersionState": "WAITING_FOR_REVIEW", "versionString": "0.14.3"
        }}, LIVE]) as api:
            self.assertEqual((None, True), asc.draft_version("app", "0.14.3"))
            self.assertEqual(["GET"], [call.args[0] for call in api.call_args_list])

    def test_a_newer_tag_withdraws_only_its_versions_submission_and_keeps_manual_release(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "apps/app/appStoreVersions":
                return [{"id": "review", "attributes": {"appVersionState": "IN_REVIEW", "versionString": "0.10.0"}}, LIVE]
            if path == "reviewSubmissions":
                return [submission("event", None, "IN_REVIEW"), submission("target", "review", "IN_REVIEW")]
            if path == "appStoreVersions/review" and method == "GET":
                return {"attributes": {"appVersionState": "DEVELOPER_REJECTED"}}
            if path == "appStoreVersions/review":
                return {"attributes": {"versionString": "0.14.3", "releaseType": "MANUAL"}}

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual(("review", True), asc.draft_version("app", "0.14.3"))
        self.assertEqual([
            ("PATCH", "reviewSubmissions/target", {"type": "reviewSubmissions", "id": "target", "attributes": {"canceled": True}}),
            ("PATCH", "appStoreVersions/review", {"type": "appStoreVersions", "id": "review",
                                                  "attributes": {"releaseType": "MANUAL", "versionString": "0.14.3"}}),
        ], writes)

    def test_a_first_release_in_review_is_left_alone(self):
        with patch.object(asc, "api", return_value=[{"id": "review", "attributes": {
            "appVersionState": "IN_REVIEW", "versionString": "1.0.0"
        }}]) as api:
            self.assertEqual((None, False), asc.draft_version("app", "1.0.1"))
            self.assertEqual(["GET"], [call.args[0] for call in api.call_args_list])

    def test_a_newer_tag_deletes_its_versions_item_from_an_unsubmitted_draft(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path))
            if path == "reviewSubmissions":
                return [submission("draft", "review", "READY_FOR_REVIEW")]
            if path == "reviewSubmissions/draft/items":
                return [item("event", "other", "READY_FOR_REVIEW"), item("ours", "review", "READY_FOR_REVIEW")]
            if path == "appStoreVersions/review":
                return {"attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION"}}

        with patch.object(asc, "api", side_effect=api):
            asc.withdraw("app", "review", "0.10.0")
        self.assertEqual([("DELETE", "reviewSubmissionItems/ours")], writes)

    def test_a_rerun_waits_for_a_cancellation_already_underway(self):
        states = iter(["IN_REVIEW", "DEVELOPER_REJECTED"])
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append(path)
            if path == "reviewSubmissions":
                return [submission("target", "review", "CANCELING")]
            if path == "appStoreVersions/review":
                return {"attributes": {"appVersionState": next(states)}}

        with patch.object(asc, "api", side_effect=api), patch.object(asc.time, "sleep"):
            asc.withdraw("app", "review", "0.10.0")
        self.assertEqual([], writes)

    def test_a_rejected_version_resolves_its_own_item_in_its_own_submission(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions":
                return [submission("event", None, "UNRESOLVED_ISSUES"), submission("rejected", "version", "UNRESOLVED_ISSUES")]
            if path == "reviewSubmissions/rejected/items":
                return [item("other", "event-version", "REJECTED"), item("ours", "version", "REJECTED")]

        with patch.object(asc, "api", side_effect=api):
            asc.submit_for_review("app", "version", "0.14.3")
        self.assertEqual([
            ("PATCH", "reviewSubmissionItems/ours", {"type": "reviewSubmissionItems", "id": "ours", "attributes": {"resolved": True}}),
            ("PATCH", "reviewSubmissions/rejected", {"type": "reviewSubmissions", "id": "rejected", "attributes": {"submitted": True}}),
        ], writes)

    def test_a_new_submission_carries_the_version(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions" and method == "POST":
                return {"id": "new"}
            if method == "GET":
                return []

        with patch.object(asc, "api", side_effect=api):
            asc.submit_for_review("app", "version", "0.14.3")
        self.assertEqual(["reviewSubmissions", "reviewSubmissionItems", "reviewSubmissions/new"], [path for _, path, _ in writes])
        self.assertEqual({"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": "new"}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": "version"}}}, writes[1][2]["relationships"])
        self.assertEqual({"submitted": True}, writes[2][2]["attributes"])

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
            with self.subTest(version=version), patch.object(asc, "api", side_effect=list(responses)) as api:
                if accepted:
                    asc.check_version("app", version)
                else:
                    with self.assertRaisesRegex(SystemExit, "must exceed"):
                        asc.check_version("app", version)
                self.assertEqual(["apps/app/appStoreVersions", "preReleaseVersions"], [call.args[1] for call in api.call_args_list])
                self.assertEqual("app", api.call_args_list[1].kwargs["filter[app]"])

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

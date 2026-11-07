import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("app_store_connect", str(Path(__file__).resolve().parents[1] / "app-store-connect"))
spec = importlib.util.spec_from_loader(loader.name, loader)
asc = importlib.util.module_from_spec(spec)
loader.exec_module(asc)


def setUpModule():
    quiet = patch("sys.stderr", new_callable=io.StringIO)
    quiet.start()
    unittest.addModuleCleanup(quiet.stop)


class ScreenshotProcessingTests(unittest.TestCase):
    def test_ready_placements_need_no_further_processing(self):
        for state in ("ACTIVE", "PARENT_PREPARE_FOR_SUBMISSION", "PARENT_READY_FOR_REVIEW",
                      "PARENT_WAITING_FOR_REVIEW", "PARENT_IN_REVIEW", "PARENT_APPROVED"):
            with self.subTest(state=state), patch.object(asc, "api", return_value={"attributes": {"state": state}}), \
                 patch.object(asc.time, "sleep", side_effect=AssertionError("A ready placement must not wait")):
                asc.wait_for_screenshots(["screenshot"])

    def test_unknown_and_processing_states_wait_until_the_deadline(self):
        for state in ("ASSET_PROCESSING", "PENDING", "UPLOAD_COMPLETE", "PARENT_FUTURE_STATE"):
            with self.subTest(state=state), patch.object(asc, "api", return_value={"attributes": {"state": state}}), \
                 patch.object(asc, "DEADLINE", 1), patch.object(asc.time, "monotonic", return_value=2):
                with self.assertRaisesRegex(SystemExit, f"40 minutes.*screenshot.*{state}"):
                    asc.wait_for_screenshots(["screenshot"])

    def test_pending_placements_are_polled_until_every_screenshot_is_ready(self):
        with patch.object(asc, "api", side_effect=[
            {"attributes": {"state": "ACTIVE"}}, {"attributes": {"state": "PENDING"}},
            {"attributes": {"state": "ACTIVE"}}, {"attributes": {"state": "ACTIVE"}},
        ]), patch.object(asc, "DEADLINE", 1), patch.object(asc.time, "monotonic", return_value=0), \
             patch.object(asc.time, "sleep") as sleep:
            asc.wait_for_screenshots(["ipad", "iphone"])
            sleep.assert_called_once_with(20)

    def test_failed_processing_reports_the_apple_failure(self):
        with patch.object(asc, "api", return_value={"attributes": {"state": "FAILED", "stateDetails": "Invalid image"}}):
            with self.assertRaisesRegex(SystemExit, "Invalid image"):
                asc.wait_for_screenshots(["screenshot"])


class BuildIdentityTests(unittest.TestCase):
    def test_pending_uploads_count_toward_the_next_global_build(self):
        with patch.object(asc, "api", side_effect=[
            [{"attributes": {"version": "10"}}],
            [{"attributes": {"cfBundleVersion": "12"}}],
        ]):
            self.assertEqual(13, asc.next_build_number("app"))

    def test_a_dotted_pending_upload_sets_the_next_global_build(self):
        with patch.object(asc, "api", side_effect=[
            [{"attributes": {"version": "30"}}],
            [{"attributes": {"cfBundleVersion": "42.9.1"}}],
        ]):
            self.assertEqual(43, asc.next_build_number("app"))

    def test_unrecognized_build_versions_stop_allocation(self):
        for version in ("", "1.2.3.4", "1.beta", "１"):
            with self.subTest(version=version), patch.object(asc, "api", side_effect=[
                [{"attributes": {"version": version}}], [],
            ]):
                with self.assertRaisesRegex(SystemExit, "CFBundleVersion"):
                    asc.next_build_number("app")

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


class UploadFenceTests(unittest.TestCase):
    def test_a_first_attempt_uploads_beside_an_older_build_of_the_same_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["1"]) as existing, \
             patch.object(asc, "next_build_number", return_value=12):
            self.assertEqual((13, False), asc.reserve_build("app", "1.3.2", "13", fenced=False))
            existing.assert_not_called()

    def test_a_first_attempt_takes_a_newer_global_number_than_its_reservation(self):
        with patch.object(asc, "next_build_number", return_value=14), patch.object(asc.time, "sleep") as sleep:
            self.assertEqual((14, False), asc.reserve_build("app", "1.3.2", "13", fenced=False))
            sleep.assert_not_called()

    def test_a_dotted_build_is_reused_with_its_exact_apple_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["9", "12.2", "12.7.2"]), \
             patch.object(asc, "next_build_number") as reserve:
            self.assertEqual(("12.7.2", True), asc.reserve_build("app", "1.3.2", "12", fenced=True))
            reserve.assert_not_called()

    def test_a_fenced_rerun_waits_for_the_build_and_never_reserves_a_second_number(self):
        with patch.object(asc, "uploaded_build_numbers", side_effect=[[], [], ["12"]]), patch.object(asc, "next_build_number") as reserve, \
             patch.object(asc.time, "sleep"):
            self.assertEqual(("12", True), asc.reserve_build("app", "1.3.2", "12", fenced=True))
            reserve.assert_not_called()

    def test_a_retry_never_selects_an_older_build_of_the_same_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["1"]), \
             patch.object(asc.time, "sleep"), patch.object(asc.time, "monotonic", side_effect=[0, 901]):
            with self.assertRaisesRegex(SystemExit, "do not upload again blindly"):
                asc.reserve_build("app", "1.3.2", "12", fenced=True)

    def test_a_fenced_rerun_fails_when_no_build_appears(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=[]), patch.object(asc, "next_build_number") as reserve, \
             patch.object(asc.time, "sleep"), patch.object(asc.time, "monotonic", side_effect=[0, 1, 1000]):
            with self.assertRaisesRegex(SystemExit, "do not upload again"):
                asc.reserve_build("app", "1.3.2", "12", fenced=True)
            reserve.assert_not_called()

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

    def test_a_newer_tag_leaves_an_earlier_version_in_review_untouched(self):
        def api(method, path, data=None, **params):
            if method != "GET":
                raise AssertionError(f"{method} {path}")
            if path == "apps/app/appStoreVersions":
                return [{"id": "review", "attributes": {"appVersionState": "IN_REVIEW", "versionString": "0.10.0"}}, LIVE]

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual((None, True), asc.draft_version("app", "0.14.3"))

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

    def test_a_rerun_resumes_its_own_submission_instead_of_withdrawing_it(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path))
            if path == "apps/app/appStoreVersions":
                return [{"id": "draft", "attributes": {"appVersionState": "READY_FOR_REVIEW", "versionString": "0.14.3"}}, LIVE]
            if path == "reviewSubmissions":
                return [submission("resolved", "draft", "UNRESOLVED_ISSUES")]
            if path == "reviewSubmissions/resolved/items":
                return [item("ours", "draft", "READY_FOR_REVIEW")]

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual((None, True), asc.draft_version("app", "0.14.3"))
        self.assertEqual([("PATCH", "reviewSubmissions/resolved")], writes)

    def test_a_newer_tag_removes_its_version_from_an_unresolved_submission(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions":
                return [submission("unresolved", "review", "UNRESOLVED_ISSUES")]
            if path == "reviewSubmissions/unresolved/items":
                return [item("event", "other", "REJECTED"), item("ours", "review", "READY_FOR_REVIEW")]
            if path == "appStoreVersions/review":
                return {"attributes": {"appVersionState": "DEVELOPER_REJECTED"}}

        with patch.object(asc, "api", side_effect=api):
            asc.withdraw("app", "review", "0.10.0")
        self.assertEqual([("PATCH", "reviewSubmissionItems/ours",
                           {"type": "reviewSubmissionItems", "id": "ours", "attributes": {"removed": True}})], writes)

    def test_an_unrelated_draft_submission_is_left_alone(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions" and method == "POST":
                return {"id": "new"}
            if path == "reviewSubmissions" and params.get("filter[state]") == "READY_FOR_REVIEW":
                return [{"id": "event-draft"}]
            if path == "reviewSubmissions/event-draft/items":
                return [item("event", "other", "READY_FOR_REVIEW")]
            return []

        with patch.object(asc, "api", side_effect=api):
            asc.submit_for_review("app", "version", "0.14.3")
        self.assertEqual(["reviewSubmissions", "reviewSubmissionItems", "reviewSubmissions/new"], [path for _, path, _ in writes])

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
    def test_only_a_newer_unreleased_version_is_accepted(self):
        responses = [[{"attributes": {"versionString": "2.13.0", "appVersionState": "READY_FOR_DISTRIBUTION"}},
                      {"attributes": {"versionString": "2.14.0", "appVersionState": "PREPARE_FOR_SUBMISSION"}}],
                     [{"attributes": {"version": "2.13.1"}}]]
        for version, refusal in (("2.13.0", "already released"), ("2.12.9", "must exceed.*2.13.1"),
                                 ("2.13.1", None), ("2.13.2", None)):
            with self.subTest(version=version), patch.object(asc, "api", side_effect=list(responses)) as api:
                if refusal:
                    with self.assertRaisesRegex(SystemExit, refusal):
                        asc.check_version("app", version)
                else:
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


class TestFlightPolicyTests(unittest.TestCase):
    def test_what_to_test_never_adds_external_groups(self):
        calls = []

        def api(method, path, data=None, **params):
            calls.append((method, path))
            if path == "builds":
                return [{"id": "build", "attributes": {"processingState": "VALID"}}]
            if path == "builds/build/betaBuildLocalizations":
                return [{"id": "notes"}]

        with patch.object(asc, "api", side_effect=api):
            asc.what_to_test("app", "1.3.2", "11", "- Fixed it.")
        self.assertEqual([("PATCH", "betaBuildLocalizations/notes")], [call for call in calls if call[0] != "GET"])
        self.assertNotIn("betaGroups", " ".join(path for _, path in calls))

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("repackage", Path(__file__).with_name("repackage-binaries.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
draft_spec = importlib.util.spec_from_file_location("release_draft", Path(__file__).with_name("release_draft.py"))
draft = importlib.util.module_from_spec(draft_spec)
draft_spec.loader.exec_module(draft)


class VersionTests(unittest.TestCase):
    def test_rollover_boundaries(self):
        self.assertEqual(release.next_version([], "1.0.8"), "1.0.9")
        self.assertEqual(release.next_version([], "1.0.9"), "1.1.0")
        self.assertEqual(release.next_version([], "1.9.9"), "2.0.0")

    def test_only_successful_releases_advance_version(self):
        versions = [
            {"tag_name": "v1.0.9", "draft": False, "prerelease": False},
            {"tag_name": "v1.0.10", "draft": True, "prerelease": False},
            {"tag_name": "v2.0.0", "draft": False, "prerelease": True},
        ]
        self.assertEqual(release.next_version(versions, "1.0.0"), "1.1.0")

    def test_numeric_order_and_legacy_release_normalization(self):
        versions = [{"tag_name": value, "draft": False, "prerelease": False} for value in ["v1.0.9", "v1.0.13"]]
        self.assertEqual(release.next_version(versions, "1.0.0"), "1.1.0")

    def test_staged_candidate_is_a_floor_without_rewriting_it(self):
        self.assertEqual(release.next_version([], "1.0.11", ["1.0.13"]), "1.1.0")

    def test_local_installed_baseline_ahead_of_public_release_is_not_reused(self):
        versions = [{"tag_name": "v1.0.11", "draft": False, "prerelease": False}]
        self.assertEqual(release.next_version(versions, "1.0.12"), "1.1.0")


class StagingRootTests(unittest.TestCase):
    def df_output(self, path, mountpoint="/Volumes/External Drive"):
        return "\n".join((
            "Filesystem 512-blocks Used Available Capacity Mounted on",
            f"/dev/disk5s1 100 20 80 20% {mountpoint}",
        ))

    def metadata(self, filesystem, label):
        return __import__("plistlib").dumps({
            "FilesystemType": filesystem, "FilesystemName": label,
        }).decode("utf-8")

    def test_apfs_and_hfs_staging_roots_are_accepted(self):
        for filesystem, label in (("apfs", "APFS"), ("hfs", "Journaled HFS+")):
            with self.subTest(filesystem=filesystem), tempfile.TemporaryDirectory() as tmp:
                with mock.patch.object(release, "run", side_effect=[
                    self.df_output(tmp), self.metadata(filesystem, label),
                ]) as run:
                    self.assertEqual(release.prepare_staging_root(tmp), Path(tmp).resolve())
                self.assertEqual(run.call_args_list, [
                    mock.call("df", "-P", str(Path(tmp).resolve()), capture=True),
                    mock.call("diskutil", "info", "-plist", "/Volumes/External Drive", capture=True),
                ])

    def test_exfat_staging_root_fails_before_build_with_actionable_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(release, "run", side_effect=[
                self.df_output(tmp), self.metadata("exfat", "ExFAT"),
            ]):
                with self.assertRaisesRegex(RuntimeError, "exFAT output triggers BOMStream buffer overflow"):
                    release.prepare_staging_root(tmp)


class OwnerPreflightTests(unittest.TestCase):
    def metadata(self, *, owner="ilovespectra", admin=True):
        return {
            "full_name": release.REPO,
            "owner": {"login": owner},
            "permissions": {"admin": admin},
        }

    def test_official_owner_admin_is_allowed(self):
        self.assertEqual(release.validate_release_owner("ilovespectra", self.metadata()), "ilovespectra")

    def test_clone_or_non_owner_is_denied_even_if_it_has_admin_on_its_own_repo(self):
        fork_metadata = {
            "full_name": "clone-user/CruiseControl",
            "owner": {"login": "clone-user"},
            "permissions": {"admin": True},
        }
        with self.assertRaisesRegex(RuntimeError, "official repository"):
            release.validate_release_owner("clone-user", fork_metadata)
        with self.assertRaisesRegex(RuntimeError, "authenticate as the owner"):
            release.validate_release_owner("clone-user", self.metadata())

    def test_missing_admin_permission_is_denied(self):
        with self.assertRaisesRegex(RuntimeError, "needs admin permission"):
            release.validate_release_owner("ilovespectra", self.metadata(admin=False))

    def test_old_direct_publish_option_is_rejected(self):
        from contextlib import redirect_stderr
        from io import StringIO
        with mock.patch.object(sys, "argv", ["repackage-binaries.py", "--publish", "--unsigned"]):
            with redirect_stderr(StringIO()), self.assertRaises(SystemExit):
                release.parse_args()

    def test_owner_draft_option_and_preview_are_separate_modes(self):
        with mock.patch.object(sys, "argv", ["repackage-binaries.py", "--draft"]):
            self.assertTrue(release.parse_args().draft)
        with mock.patch.object(sys, "argv", ["repackage-binaries.py", "--preview"]):
            self.assertTrue(release.parse_args().preview)
        with mock.patch.object(sys, "argv", ["repackage-binaries.py", "--preview", "--staging-root", "/Volumes/BIGGERDRIVE/stage"]):
            self.assertTrue(release.parse_args().preview)
            self.assertEqual(str(release.parse_args().staging_root), "/Volumes/BIGGERDRIVE/stage")


class DraftSafetyTests(unittest.TestCase):
    def test_non_owner_downgrades_to_local_preview(self):
        mode, owner, error = draft.resolve_mode("draft", lambda: (_ for _ in ()).throw(RuntimeError("not owner")))
        self.assertEqual(mode, "preview")
        self.assertIsNone(owner)
        self.assertIsInstance(error, RuntimeError)

    def test_official_origin_accepts_https_and_ssh_but_rejects_fork(self):
        self.assertTrue(draft.is_official_origin("https://github.com/ilovespectra/CruiseControl.git"))
        self.assertTrue(draft.is_official_origin("git@github.com:ilovespectra/CruiseControl.git"))
        self.assertFalse(draft.is_official_origin("https://github.com/another/CruiseControl"))

    def test_local_artifacts_must_match_manifest_and_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "CruiseControl.pkg"
            package.write_bytes(b"test installer bytes")
            digest = draft.sha256_file(package)
            metadata = root / "release.json"
            metadata.write_text(__import__("json").dumps({
                "version": "1.1.0", "commit": "abc123", "package": package.name,
                "sha256": digest, "architecture": "universal", "minimumMacOS": "14.0",
                "notarized": False,
            }))
            checksums = root / "SHA256SUMS"
            checksums.write_text(f"{digest}  {package.name}\n")
            verified = draft.verify_local_artifacts(package, metadata, checksums,
                                                    "1.1.0", "abc123", False)
            self.assertEqual(verified["sha256"], digest)
            checksums.write_text("bad  CruiseControl.pkg\n")
            with self.assertRaisesRegex(RuntimeError, "SHA256SUMS"):
                draft.verify_local_artifacts(package, metadata, checksums,
                                             "1.1.0", "abc123", False)

    def test_ollama_release_notes_render_only_selected_verified_subjects(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "release-notes.md"
            with (
                mock.patch.object(draft, "installed_ollama_model", return_value="qwen2.5:3b"),
                mock.patch.object(draft.urllib.request, "urlopen", return_value=mock.MagicMock(
                    __enter__=lambda self: SimpleNamespace(read=lambda: b'{"response": "```json\\n[1,0]\\n```"}'),
                    __exit__=lambda *a: False)),
            ):
                notes = draft.generate_release_notes(
                    "1.1.0", "abc123", "v1.0.11", ["Verified change one", "Verified change two"],
                    "2 files changed", output)
            self.assertIn("- Verified change two", notes)
            self.assertIn("- Verified change one", notes)
            self.assertNotIn("2 files changed", notes)
            self.assertNotIn("invent", notes)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_draft_lookup_uses_authenticated_release_list(self):
        record = {"tag_name": "v1.1.0", "draft": True, "assets": []}
        self.assertIs(draft.find_draft_record([{"tag_name": "v1.0.11", "draft": False}, record], "v1.1.0"), record)
        with self.assertRaisesRegex(RuntimeError, "unpublished draft"):
            draft.find_draft_record([{"tag_name": "v1.1.0", "draft": False}], "v1.1.0")

    def test_github_draft_requires_unpublished_state_and_matching_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp) / "CruiseControl.pkg"
            package.write_bytes(b"verified package")
            record = {
                "tag_name": "v1.1.0", "draft": True, "published_at": None,
                "target_commitish": "abc123", "html_url": "https://github.com/ilovespectra/CruiseControl/releases/tag/v1.1.0",
                "assets": [{"name": package.name, "digest": f"sha256:{draft.sha256_file(package)}",
                            "size": package.stat().st_size}],
            }
            self.assertEqual(draft.verify_draft_record(record, "v1.1.0", "abc123", [package]), record["html_url"])
            record["draft"] = False
            with self.assertRaisesRegex(RuntimeError, "unpublished draft"):
                draft.verify_draft_record(record, "v1.1.0", "abc123", [package])


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("repackage", Path(__file__).with_name("repackage-binaries.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class VersionTests(unittest.TestCase):
    def test_first_release_updates_existing_installs(self):
        self.assertEqual(release.next_version([], "1.0.0"), "1.0.1")

    def test_only_successful_releases_advance_version(self):
        versions = [
            {"tag_name": "v1.0.9", "draft": False, "prerelease": False},
            {"tag_name": "v1.0.10", "draft": True, "prerelease": False},
            {"tag_name": "v2.0.0", "draft": False, "prerelease": True},
        ]
        self.assertEqual(release.next_version(versions, "1.0.0"), "1.0.10")

    def test_numeric_order(self):
        versions = [{"tag_name": value, "draft": False, "prerelease": False} for value in ["v1.0.9", "v1.0.10"]]
        self.assertEqual(release.next_version(versions, "1.0.0"), "1.0.11")


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

    def test_unauthorized_publish_attempt_stops_before_release_write(self):
        calls = []
        head = "deadbeef" * 5

        def fake_run(*args, capture=False, **kwargs):
            calls.append(tuple(map(str, args)))
            command = tuple(map(str, args))
            if command == ("git", "status", "--porcelain"):
                return ""
            if command[:4] == ("gh", "repo", "view", release.REPO):
                return '{"defaultBranchRef":{"name":"main"}}'
            if command == ("git", "fetch", "origin", "main"):
                return ""
            if command in (("git", "rev-parse", "origin/main"), ("git", "rev-parse", "HEAD")):
                return head
            if command == ("gh", "api", "user", "--jq", ".login"):
                return "clone-user"
            if command == ("gh", "api", f"repos/{release.REPO}"):
                return __import__("json").dumps(self.metadata())
            raise AssertionError(f"Unexpected command: {command}")

        with mock.patch.object(release, "run", side_effect=fake_run), mock.patch.object(sys, "argv", ["repackage-binaries.py", "--publish", "--unsigned"]):
            with self.assertRaisesRegex(RuntimeError, "authenticate as the owner"):
                release.main()
        self.assertNotIn(("gh", "release", "create"), calls)


if __name__ == "__main__":
    unittest.main()

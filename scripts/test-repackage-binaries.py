import importlib.util
from pathlib import Path
import unittest

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


if __name__ == "__main__":
    unittest.main()

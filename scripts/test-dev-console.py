import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

spec = importlib.util.spec_from_file_location("console", Path(__file__).with_name("dev-console.py"))
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = patch.object(console, "STATE", Path(self.temporary.name))
        self.state.start()
        console.database().close()

    def tearDown(self):
        self.state.stop()
        self.temporary.cleanup()

    def test_history_survives_reopen(self):
        with console.database() as db:
            db.execute("INSERT INTO jobs(id,mode,status,created,source_commit) VALUES('abc','preview','failed',1,'commit')")
        self.assertEqual(console.snapshot()[0]["source_commit"], "commit")
        self.assertEqual(console.snapshot()[0]["status"], "failed")

    def test_missing_worker_is_interrupted(self):
        with console.database() as db:
            db.execute("INSERT INTO jobs(id,mode,status,created,pid,source_commit) VALUES('abc','preview','running',1,99999999,'commit')")
        self.assertEqual(console.snapshot()[0]["status"], "interrupted")

    def test_dirty_checkout_rejected(self):
        with patch.object(console, "command", return_value=" M source"):
            with self.assertRaisesRegex(ValueError, "clean"):
                console.start_job("preview")

    def test_invalid_mode_rejected(self):
        with self.assertRaises(ValueError):
            console.start_job("--anything")

    def test_commit_requires_staged_files(self):
        with patch.object(console, "command", return_value=""):
            with self.assertRaisesRegex(ValueError, "No staged changes"):
                console.start_job("commit")

    def test_commit_preserves_hooks_and_adds_trailer(self):
        (console.STATE / "abc.message").write_text("Improve developer console")
        with patch.object(console, "command", side_effect=["tree", "1 file changed", "tree", "new-commit"]), patch.object(
                console.subprocess, "run") as run:
            console.commit_staged("abc")
        args = run.call_args.args[0]
        self.assertEqual(args[:2], ["git", "commit"])
        self.assertNotIn("--no-verify", args)
        self.assertNotIn("--no-gpg-sign", args)
        self.assertIn("Improve developer console", args)

    def test_changed_index_prevents_commit(self):
        (console.STATE / "abc.message").write_text("Improve developer console")
        with patch.object(console, "command", side_effect=["tree", "1 file changed", "other-tree"]), patch.object(
                console.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "changed"):
                console.commit_staged("abc")
            run.assert_not_called()

    def test_exclusive_build_lock(self):
        with (console.STATE / "build.lock").open("a") as lock:
            console.fcntl.flock(lock, console.fcntl.LOCK_EX | console.fcntl.LOCK_NB)
            with patch.object(console, "command", side_effect=["", "commit"]):
                with self.assertRaisesRegex(ValueError, "already running"):
                    console.start_job("preview")

    def test_worker_failure_is_persisted(self):
        with console.database() as db:
            db.execute("INSERT INTO jobs(id,mode,status,created,source_commit) VALUES('abc','preview','queued',1,'commit')")
        lock = (console.STATE / "build.lock").open("a")
        fd = console.os.dup(lock.fileno())
        with lock, patch.object(console, "command", return_value="commit"), patch.object(
                console.subprocess, "Popen", return_value=Mock(wait=Mock(return_value=7))):
            console.run_worker("abc", fd)
        job = console.snapshot()[0]
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["exit_code"], 7)
        self.assertIsNotNone(job["finished"])

    def test_http_origin_and_host_guards(self):
        server = console.ThreadingHTTPServer(("127.0.0.1", 0), console.Handler)
        with patch.object(console, "PORT", server.server_port):
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                root = f"http://127.0.0.1:{server.server_port}"
                with urlopen(root + "/api/status") as response:
                    self.assertIn("token", json.load(response))
                for headers in [{}, {"Origin": "https://evil.example", "X-Console-Token": console.Handler.token}]:
                    with self.assertRaises(HTTPError) as error:
                        urlopen(Request(root + "/api/build", data=b'{"mode":"draft"}', headers=headers))
                    self.assertEqual(error.exception.code, 403)
                    error.exception.close()
                with self.assertRaises(HTTPError) as error:
                    urlopen(Request(root + "/", headers={"Host": "evil.example"}))
                self.assertEqual(error.exception.code, 403)
                error.exception.close()
            finally:
                server.shutdown()
                thread.join()
                server.server_close()


if __name__ == "__main__":
    unittest.main()

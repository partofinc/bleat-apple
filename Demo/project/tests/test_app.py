import json
import time
import unittest
from pathlib import Path

PUBLIC = Path(__file__).resolve().parent.parent / "public"


class PublicTests(unittest.TestCase):
    def test_index_has_a_title(self):
        self.assertIn("<title>", (PUBLIC / "index.html").read_text())

    def test_health_is_ok(self):
        self.assertEqual(json.loads((PUBLIC / "health.json").read_text())["status"], "ok")

    def test_slow_integration(self):
        time.sleep(4)
        self.assertTrue(PUBLIC.is_dir())


if __name__ == "__main__":
    unittest.main()

import importlib.util
import os
import re
import unittest

from vitrina_api.app import create_app
from vitrina_api.config import Settings


class RouteTableTests(unittest.TestCase):
    """The API is split over several modules; these guard what the split could quietly break."""

    def test_no_pattern_path_hides_a_literal_one_after_it(self):
        app = create_app(Settings(database_url="sqlite://", auto_create_schema=True))
        routes = [(r.path, m) for r in app.routes if hasattr(r, "methods") for m in r.methods]
        for i, (path, method) in enumerate(routes):
            pattern = re.compile("^" + re.sub(r"\{[^}]+\}", "[^/]+", path) + "$")
            for later, later_method in routes[i + 1:]:
                if later_method == method and "{" in path and "{" not in later and pattern.match(later):
                    self.fail(f"{method} {path} is matched before {later}, which can never be reached")

    def test_the_backfill_script_still_imports(self):
        path = os.path.join(os.path.dirname(__file__), "..", "scripts", "cutout_backfill.py")
        spec = importlib.util.spec_from_file_location("cutout_backfill", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # importing must not fail; main() is not run
        self.assertTrue(callable(getattr(module, "main", None)))


if __name__ == "__main__":
    unittest.main()

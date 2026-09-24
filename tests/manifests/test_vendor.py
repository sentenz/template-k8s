"""Exercise promotion and download-failure behavior without network access."""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml


spec = importlib.util.spec_from_file_location(
    "vendor_helm", Path(__file__).resolve().parents[2] / "scripts/vendor-helm.py"
)
vendor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vendor)


class VendorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.old = self.root / "example-1.0.0"
        self.old.mkdir()
        (self.old / "sentinel").write_text("existing production chart")

    def download(self, command, **kwargs):
        chart = Path(command[command.index("--untardir") + 1]) / "example"
        chart.mkdir()
        (chart / "Chart.yaml").write_text(yaml.safe_dump({"name": "example", "version": "2.0.0"}))

    def test_new_version_preserves_production_version(self):
        with patch.object(vendor.subprocess, "run", side_effect=self.download):
            vendor.vendor_chart("example", "2.0.0", "https://example.invalid", self.root, ["helm"])
        self.assertTrue((self.root / "example-2.0.0/example/Chart.yaml").is_file())
        self.assertEqual((self.old / "sentinel").read_text(), "existing production chart")
        self.assertFalse(list(self.root.glob(".download-*")))

    def test_failed_download_preserves_existing_version(self):
        with patch.object(vendor.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "helm")):
            with self.assertRaises(subprocess.CalledProcessError):
                vendor.vendor_chart("example", "2.0.0", "https://example.invalid", self.root, ["helm"])
        self.assertTrue((self.old / "sentinel").is_file())
        self.assertFalse((self.root / "example-2.0.0").exists())
        self.assertFalse(list(self.root.glob(".download-*")))

    def test_existing_version_is_immutable(self):
        with patch.object(vendor.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                vendor.vendor_chart("example", "1.0.0", "https://example.invalid", self.root, ["helm"])
            run.assert_not_called()
        self.assertTrue((self.old / "sentinel").is_file())

    def test_wrong_chart_metadata_is_not_published(self):
        with patch.object(vendor.subprocess, "run", side_effect=self.download):
            with self.assertRaises(ValueError):
                vendor.vendor_chart("example", "3.0.0", "https://example.invalid", self.root, ["helm"])
        self.assertFalse((self.root / "example-3.0.0").exists())


if __name__ == "__main__":
    unittest.main()

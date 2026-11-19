"""Static branding regressions for the BHAT NETWORK app."""
from pathlib import Path
import json
import re
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "index.html"
SW = ROOT / "sw.js"
MANIFEST = ROOT / "manifest.webmanifest"
BRANDING = ROOT / "assets" / "branding"


def png_dimensions(path: Path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"not a PNG: {path}")
    return struct.unpack(">II", data[16:24])


class BrandingTests(unittest.TestCase):
    def setUp(self):
        self.index = INDEX.read_text()
        self.sw = SW.read_text()
        self.manifest = json.loads(MANIFEST.read_text())

    def test_all_branding_assets_exist_with_exact_dimensions(self):
        expected = {
            "bhat-network-32.png": (32, 32),
            "bhat-network-180.png": (180, 180),
            "bhat-network-192.png": (192, 192),
            "bhat-network-512.png": (512, 512),
            "bhat-network-1024.png": (1024, 1024),
        }
        for name, dimensions in expected.items():
            asset = BRANDING / name
            self.assertTrue(asset.is_file(), asset)
            self.assertEqual(png_dimensions(asset), dimensions)

    def test_html_uses_local_subpath_safe_branding_paths(self):
        self.assertIn('href="./assets/branding/bhat-network-32.png"', self.index)
        self.assertIn('href="./assets/branding/bhat-network-180.png"', self.index)
        self.assertIn('href="./manifest.webmanifest"', self.index)
        self.assertNotIn("res.cloudinary.com", self.index)
        self.assertIn('class="splash-logo" src="./assets/branding/bhat-network-512.png"', self.index)
        self.assertGreaterEqual(self.index.count('class="rail-logo" src="./assets/branding/bhat-network-192.png"'), 3)
        self.assertIn('class="welcome-logo" src="./assets/branding/bhat-network-512.png"', self.index)

    def test_manifest_has_size_accurate_local_icon_variants_and_subpath_scope(self):
        self.assertEqual(self.manifest["start_url"], "./")
        self.assertEqual(self.manifest["scope"], "./")
        icons = {icon["sizes"]: icon for icon in self.manifest["icons"]}
        self.assertEqual(set(icons), {"192x192", "512x512"})
        for size, icon in icons.items():
            self.assertTrue(icon["src"].startswith("./assets/branding/"))
            self.assertEqual(icon["type"], "image/png")
            self.assertIn("maskable", icon["purpose"])

    def test_service_worker_versions_and_caches_branding_only(self):
        self.assertRegex(self.sw, r"const BRAND_CACHE = ['\"]bhat-network-brand-v2['\"]")
        self.assertIn("bhat-network-brand-", self.sw)
        self.assertIn("self.skipWaiting()", self.sw)
        self.assertIn("self.clients.claim()", self.sw)
        self.assertIn("assets/branding/", self.sw)
        self.assertIn("manifest.webmanifest", self.sw)
        self.assertIn("event.request.mode === 'navigate'", self.sw)
        self.assertNotIn("receipt.js", self.sw)


if __name__ == "__main__":
    unittest.main()

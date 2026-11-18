from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")


class QRAndScrollRegressionTests(unittest.TestCase):
    def function_body(self, name, next_marker):
        start = HTML.index(name)
        end = HTML.index(next_marker, start)
        return HTML[start:end]

    def test_vehicle_and_workshop_qr_sheets_offer_share_download_and_scan(self):
        self.assertIn('data-qr-vehicle="${esc(v.passport_token)}"', HTML)
        self.assertIn('data-qr-shop="${esc(S.workshop.id)}"', HTML)
        self.assertIn('data-qr-share>Share QR</button>', HTML)
        self.assertIn('data-qr-download>Download PNG</button>', HTML)
        self.assertIn('data-qr-scan>Scan QR</button>', HTML)

    def test_qr_image_sharing_uses_file_share_and_falls_back_to_link(self):
        body = self.function_body("async function shareQRImage()", "function ensureQRScanLib()")
        self.assertIn("navigator.canShare?.({ files: [file] })", body)
        self.assertIn("files: [file]", body)
        self.assertIn("shareLink(current.url, current.title)", body)

    def test_scan_supports_camera_and_image_with_native_and_jsqr_decoders(self):
        self.assertIn("navigator.mediaDevices?.getUserMedia", HTML)
        self.assertIn("capture=\"environment\"", HTML)
        self.assertIn("new window.BarcodeDetector({ formats: ['qr_code'] })", HTML)
        self.assertIn("jsqr@1.4.0/dist/jsQR.js", HTML)
        self.assertIn("async function onQRPhotoChange(e)", HTML)

    def test_scanned_app_qr_routes_in_app_and_external_link_requires_tap(self):
        body = self.function_body("function handleScannedQR(value)", "function classifyError(err)")
        self.assertIn("url.origin === appUrl.origin", body)
        self.assertIn("location.hash = hash", body)
        self.assertIn("This QR links outside BHAT Network", body)
        self.assertIn("link.href = url.href", body)
        self.assertIn("target=\"_blank\"", HTML)

    def test_top_edge_pull_refresh_is_blocked_but_nested_scrollers_are_exempt(self):
        body = self.function_body("function preventPullToRefresh()", "function bind()")
        self.assertIn("overscroll-behavior-y:none", HTML)
        self.assertIn("{ passive: false }", body)
        self.assertIn("e.preventDefault()", body)
        self.assertIn(".sheet-panel,.filters,.ptabs,.thumbs", body)
        self.assertIn("document.body.classList.contains('no-scroll')", body)

    def test_closing_scanner_stops_camera_tracks(self):
        body = self.function_body("function stopQRScanner()", "async function startQRScanner()")
        self.assertIn("qrScanStream.getTracks().forEach(track => track.stop())", body)
        self.assertIn("video.srcObject = null", body)


if __name__ == "__main__":
    unittest.main()

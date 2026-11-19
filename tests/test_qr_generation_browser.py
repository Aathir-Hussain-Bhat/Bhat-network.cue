"""Browser regression: pip install playwright opencv-python-headless numpy; install Chromium.

Runs against a temporary local server with synthetic entities and blocks app
network requests. Downloads only the public QR library unless QRCODE_TEST_PATH
is set to a local copy. No app accounts or customer data are accessed.
Set CHROMIUM_PATH to a Chromium executable if Playwright's browser is absent.
To exercise the app's photo scanner, set JSQR_TEST_PATH to the downloaded
jsQR 1.4.0 dist/jsQR.js file (the same version used by the application).
"""
import base64
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import threading
import unittest
from urllib.request import urlopen

import cv2
import numpy as np
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
QR_URL = 'https://cdn.jsdelivr.net/npm/qrcode@1.5.1/build/qrcode.js'


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


class QRBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        qr_path = os.environ.get('QRCODE_TEST_PATH')
        if qr_path:
            cls.qr_library = Path(qr_path).read_bytes()
        else:
            with urlopen(QR_URL, timeout=15) as response:
                cls.qr_library = response.read()
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(ROOT)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f'http://127.0.0.1:{cls.server.server_port}/'
        cls.playwright = sync_playwright().start()
        executable = os.environ.get('CHROMIUM_PATH')
        options = {'headless': True, 'args': ['--no-sandbox']}
        if executable:
            options['executable_path'] = executable
        cls.browser = cls.playwright.chromium.launch(**options)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.context = self.browser.new_context(service_workers='block')
        self.page = self.context.new_page()
        self.page.route('**/*', lambda route: route.continue_() if route.request.url.startswith(self.base) else route.abort())
        self.page.route(QR_URL, lambda route: route.fulfill(status=200, content_type='text/javascript', body=self.qr_library))
        self.page.goto(self.base, wait_until='load')

    def tearDown(self):
        self.context.close()

    def test_vehicle_and_workshop_images_encode_real_links(self):
        # The app's delegated click handlers build the payload and render the
        # QR sheet. Only the triggering buttons are synthetic test fixtures.
        for kind, attribute, identifier, expected_hash in (
            ('vehicle', 'data-qr-vehicle', 'test-vehicle-token', '#/passport/test-vehicle-token'),
            ('workshop', 'data-qr-shop', '00000000-0000-4000-8000-000000000001', '#/shop/00000000-0000-4000-8000-000000000001'),
            ('receipt', 'data-qr-receipt', 'record-synthetic-0001', '#/record/record-synthetic-0001'),
        ):
            with self.subTest(kind=kind):
                self.page.evaluate('''([attribute, identifier]) => {
                    const button = document.createElement('button');
                    button.setAttribute(attribute, identifier);
                    button.setAttribute('data-qr-name', 'Synthetic test');
                    document.body.appendChild(button);
                    button.click();
                }''', [attribute, identifier])
                img = self.page.locator('#qr-frame img')
                img.wait_for(state='visible', timeout=5000)
                data_url = img.get_attribute('src')
                self.assertTrue(data_url and data_url.startswith('data:image/png;base64,'), data_url)
                image_bytes = base64.b64decode(data_url.split(',', 1)[1], validate=True)
                self.assertGreater(len(image_bytes), 1000)
                image = cv2.imdecode(np.frombuffer(image_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
                self.assertIsNotNone(image)
                decoded, points, _ = cv2.QRCodeDetector().detectAndDecode(image)
                self.assertIsNotNone(points, 'QR image must contain a recognizable code')
                self.assertEqual(decoded, self.base + expected_hash)
                self.page.locator('#sheet-qr [data-close]').click()
                self.page.locator('#sheet-qr').wait_for(state='hidden')

    def test_retry_after_temporary_library_failure(self):
        self.page.unroute(QR_URL)
        self.page.route(QR_URL, lambda route: route.abort())
        self.page.reload(wait_until='load')
        self.page.evaluate('''() => {
            const button = document.createElement('button');
            button.setAttribute('data-qr-vehicle', 'retry-test');
            document.body.appendChild(button);
            button.click();
        }''')
        retry = self.page.locator('[data-qr-retry]')
        retry.wait_for(state='visible', timeout=5000)
        self.page.unroute(QR_URL)
        self.page.route(QR_URL, lambda route: route.fulfill(status=200, content_type='text/javascript', body=self.qr_library))
        retry.click()
        self.page.locator('#qr-frame img').wait_for(state='visible', timeout=5000)

    def test_pull_down_blocked_at_top_but_nested_scroller_is_exempt(self):
        result = self.page.evaluate('''() => {
            window.scrollTo(0, 0);
            function drag(target) {
                const touch = y => new Touch({identifier: 1, target, clientX: 30, clientY: y});
                target.dispatchEvent(new TouchEvent('touchstart', {bubbles: true, cancelable: true, touches: [touch(30)]}));
                const move = new TouchEvent('touchmove', {bubbles: true, cancelable: true, touches: [touch(80)]});
                target.dispatchEvent(move);
                target.dispatchEvent(new TouchEvent('touchend', {bubbles: true, touches: []}));
                return move.defaultPrevented;
            }
            const panel = document.createElement('div');
            panel.className = 'sheet-panel';
            document.body.appendChild(panel);
            return {atTop: drag(document.body), nested: drag(panel)};
        }''')
        self.assertEqual(result, {'atTop': True, 'nested': False})

    def test_generated_image_can_be_scanned_as_a_photo(self):
        jsqr_path = os.environ.get('JSQR_TEST_PATH')
        if not jsqr_path:
            self.skipTest('Set JSQR_TEST_PATH to test the real fallback decoder offline')
        jsqr = Path(jsqr_path).read_bytes()
        self.page.route('https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
                        lambda route: route.fulfill(status=200, content_type='text/javascript', body=jsqr))
        self.page.evaluate('''() => {
            const button = document.createElement('button');
            button.setAttribute('data-qr-vehicle', 'scan-test-token');
            button.setAttribute('data-qr-name', 'Synthetic vehicle');
            document.body.appendChild(button);
            button.click();
        }''')
        image = self.page.locator('#qr-frame img')
        image.wait_for(state='visible', timeout=5000)
        png = base64.b64decode(image.get_attribute('src').split(',', 1)[1], validate=True)
        self.page.locator('[data-qr-scan]').click()
        self.page.locator('#qr-scan-file').set_input_files({'name': 'test.png', 'mimeType': 'image/png', 'buffer': png})
        self.page.wait_for_url('**/#/passport/scan-test-token', timeout=10000)
        self.assertTrue(self.page.url.endswith('#/passport/scan-test-token'))
        self.page.evaluate('''() => {
            const button = document.createElement('button');
            button.setAttribute('data-qr-receipt', 'record-synthetic-0001');
            document.body.appendChild(button);
            button.click();
        }''')
        receipt_image = self.page.locator('#qr-frame img')
        receipt_image.wait_for(state='visible', timeout=5000)
        receipt_png = base64.b64decode(receipt_image.get_attribute('src').split(',', 1)[1], validate=True)
        decoded, points, _ = cv2.QRCodeDetector().detectAndDecode(cv2.imdecode(np.frombuffer(receipt_png, dtype=np.uint8), cv2.IMREAD_COLOR))
        self.assertIsNotNone(points, 'receipt QR must contain a recognizable code')
        self.assertEqual(decoded, self.base + '#/record/record-synthetic-0001')
        self.page.locator('[data-qr-scan]').click()
        self.page.locator('#qr-scan-file').set_input_files({'name': 'receipt.png', 'mimeType': 'image/png', 'buffer': receipt_png})
        self.page.wait_for_url('**/#/signin', timeout=10000)
        self.assertEqual(self.page.evaluate("() => sessionStorage.getItem('bhat-network:receipt-return')"), '#/record/record-synthetic-0001')


if __name__ == '__main__':
    unittest.main()

"""Offline browser coverage for private service receipts.

The tests serve the checked-in static app, abort every non-local request, and
install a tiny in-page Supabase-shaped fake before the app boot script runs.
No real Supabase project, account, customer, or network download is used.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
import unittest

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
CUSTOMER_ID = "customer-synthetic-0001"
OWNER_ID = "owner-synthetic-0001"
WORKSHOP_ID = "workshop-synthetic-0001"
RECORD_ID = "record-synthetic-0001"
BOOKING_ID = "booking-synthetic-0001"
RECEIPT_ID = "receipt-synthetic-0001"

SNAPSHOT = {
    "workshop": {"id": WORKSHOP_ID, "name": "Synthetic Motors"},
    "customer": {"profile_id": CUSTOMER_ID, "name": "Asha Synthetic", "phone": "6000000000"},
    "vehicle": {"id": "vehicle-synthetic-0001", "make": "Honda", "model": "City", "year": 2021, "color": "Blue", "plate": "JK01AB1234"},
    "service": {
        "record_id": RECORD_ID,
        "booking_id": BOOKING_ID,
        "name": "Brake overhaul",
        "category": "brakes",
        "date": "2026-11-18",
        "work_performed": "Replaced front brake pads and resurfaced rotors.",
        "parts": "Brembo pads; rotor resurfacing kit",
        "mileage_km": 42300,
        "cost": 8750,
        "notes": "Road-tested and checked brake fluid.",
    },
    "message": "Thank you for choosing Synthetic Motors. Drive safely.",
}

RECORD = {
    "id": RECORD_ID,
    "booking_id": BOOKING_ID,
    "service_name": "Brake overhaul",
    "service_category": "brakes",
    "record_date": "2026-11-18",
    "created_at": "2026-11-18T10:00:00Z",
    "public_token": "synthetic-public-token",
    "workshop": {"name": "Synthetic Motors"},
    "member": {"full_name": "Tech Synthetic"},
}

BOOKING = {
    "id": BOOKING_ID,
    "status": "READY",
    "request_type": "booking",
    "workshop_id": WORKSHOP_ID,
    "vehicle_id": "vehicle-synthetic-0001",
    "customer_profile_id": CUSTOMER_ID,
    "service_name": "Brake overhaul",
    "customer": {"full_name": "Asha Synthetic"},
    "vehicle": {"make": "Honda", "model": "City", "plate": "JK01AB1234", "odometer_km": 42300},
    "service": {"name": "Brake overhaul", "category": "brakes"},
}


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass


class ReceiptUIBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(ROOT)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/"
        cls.playwright = sync_playwright().start()
        options = {"headless": True, "args": ["--no-sandbox"]}
        if os.environ.get("CHROMIUM_PATH"):
            options["executable_path"] = os.environ["CHROMIUM_PATH"]
        cls.browser = cls.playwright.chromium.launch(**options)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.context = self.browser.new_context(accept_downloads=True, service_workers="block")
        self.page = self.context.new_page()
        self.page.route("**/*", lambda route: route.continue_() if route.request.url.startswith(self.base) else route.abort())

    def tearDown(self):
        self.context.close()

    def open_app(self, role="customer", receipt="ready", authenticated=True, route=None):
        fixture = {
            "role": role,
            "receipt": receipt,
            "authenticated": authenticated,
            "snapshot": SNAPSHOT,
            "record": RECORD,
            "booking": BOOKING,
            "calls": [],
        }
        fixture_json = json.dumps(fixture)
        self.page.add_init_script(script="""
            (() => {
              const {role, receipt, authenticated, snapshot, record, booking, calls} = __FIXTURE__;
              window.__fixture = {role, receipt, authenticated, snapshot, record, booking, calls};
              window.__shareCalls = 0;
              window.__downloadCalls = 0;
              const userId = role === 'workshop_owner' ? 'owner-synthetic-0001' : 'customer-synthetic-0001';
              const user = {id: userId, user_metadata: {full_name: role === 'workshop_owner' ? 'Owner Synthetic' : 'Asha Synthetic', role}};
              let isAuthenticated = authenticated, authListener = null;
              const profile = {id: userId, role, full_name: role === 'workshop_owner' ? 'Owner Synthetic' : 'Asha Synthetic',
                               phone: '6000000000', onboarding_complete: true};
              const workshop = {id: 'workshop-synthetic-0001', name: 'Synthetic Motors', owner_profile_id: userId,
                                verified: true, address_text: '1 Test Lane', area: 'Srinagar', district: 'Srinagar',
                                city: 'Srinagar', state: 'Jammu and Kashmir', phone: '6000000001', listings: []};
              const result = data => Promise.resolve({data, error: null});
              const error = message => Promise.resolve({data: null, error: {message}});
              function builder(table) {
                let op = {table};
                const b = {
                  select: (...args) => { op.select = args; return b; },
                  eq: (...args) => { op.eq = args; return b; },
                  order: (...args) => { op.order = args; return b; },
                  limit: (...args) => { op.limit = args; return b; },
                  maybeSingle: () => run(op, 'maybeSingle'),
                  single: () => run(op, 'single'),
                  then: (resolve, reject) => run(op, 'list').then(resolve, reject),
                  insert: value => { op.insert = value; return b; },
                  update: value => { op.update = value; return b; },
                };
                return b;
              }
              function run(op, mode) {
                const eq = Object.fromEntries((op.eq || []).length ? [[op.eq[0], op.eq[1]]] : []);
                window.__fixture.calls.push({kind: 'from', table: op.table, mode, eq, select: op.select});
                if (op.table === 'profiles') return result(profile);
                if (op.table === 'service_records') return result(record);
                if (op.table === 'workshop_receipts') {
                  if (receipt === 'error') return error('synthetic receipt load failure');
                  if (receipt === 'missing') return result(null);
                  return result({id: 'receipt-synthetic-0001', service_record_id: record.id, snapshot});
                }
                if (op.table === 'vehicles') return result([]);
                if (op.table === 'service_requests') return result(role === 'workshop_owner' ? [booking] : []);
                if (op.table === 'workshops') return result(workshop);
                if (op.table === 'workshop_services' || op.table === 'listings') return result([]);
                if (op.table === 'notifications') return result([]);
                if (op.table === 'booking_updates') return result({id: 'update-synthetic'});
                return result(mode === 'list' ? [] : null);
              }
              function rpc(name, args) {
                window.__fixture.calls.push({kind: 'rpc', name, args});
                if (name === 'get_workshop_receipt_settings') return result({workshop_id: args.p_workshop, completion_message: 'Synthetic default message', is_custom: false});
                if (name === 'set_workshop_receipt_message') return result({workshop_id: args.p_workshop, completion_message: args.p_message, is_custom: true});
                if (name === 'complete_ready_booking') return result({receipt_id: 'new-receipt', booking_id: args.p_booking, snapshot});
                if (name === 'unread_count') return result([]);
                return result([]);
              }
              window.supabase = {createClient: () => ({
                auth: {
                  onAuthStateChange: cb => { authListener = cb; setTimeout(() => cb('INITIAL_SESSION', isAuthenticated ? {user} : null), 0); return {data: {subscription: {unsubscribe(){}}}}; },
                  signInWithPassword: async () => { isAuthenticated = true; window.__fixture.authenticated = true; authListener?.('SIGNED_IN', {user}); return {error: null}; },
                  signOut: async () => result(null)
                },
                from: builder,
                rpc,
              })};
              Object.defineProperty(navigator, 'share', {configurable: true, value: async () => { window.__shareCalls++; return; }});
              Object.defineProperty(navigator, 'canShare', {configurable: true, value: () => true});
            })()
        """.replace("__FIXTURE__", fixture_json))
        target = route or ("#/record/" + RECORD_ID)
        self.page.goto(self.base + target, wait_until="load")
        if authenticated:
            self.page.locator("#record-body").get_by_text("Private service receipt", exact=True).wait_for(timeout=8000) if receipt == "ready" else self.page.locator("#record-body").wait_for(timeout=8000)
        else:
            self.page.locator("#view-signin").wait_for(state="visible", timeout=8000)

    def calls(self):
        return self.page.evaluate("() => window.__fixture.calls")

    def test_customer_record_uses_private_snapshot_and_exact_receipt_actions(self):
        self.open_app()
        body = self.page.locator("#record-body")
        self.assertEqual(body.locator("[data-qr-receipt]").count(), 1)
        for exact in (SNAPSHOT["service"]["work_performed"], SNAPSHOT["service"]["parts"], "₹8,750", SNAPSHOT["service"]["notes"], SNAPSHOT["message"]):
            self.assertIn(exact, body.inner_text())
        self.assertEqual(self.page.evaluate("() => window.__shareCalls"), 0)
        with self.page.expect_download() as download_info:
            self.page.locator("[data-receipt-download]").click()
        download = download_info.value
        self.assertTrue(download.suggested_filename.startswith("bhat-service-receipt-"))
        self.assertTrue(download.suggested_filename.endswith(".pdf"))
        self.assertEqual(self.page.evaluate("() => window.__shareCalls"), 0)
        self.page.locator("[data-receipt-share]").click()
        self.page.wait_for_function("() => window.__shareCalls === 1")
        self.assertEqual(self.page.evaluate("() => window.__shareCalls"), 1)

    def test_missing_receipt_state_is_explicit(self):
        self.open_app(receipt="missing")
        panel = self.page.locator("#record-receipt-panel")
        self.assertIn("No PDF receipt for this older service", panel.inner_text())
        self.assertEqual(panel.locator("[data-receipt-download]").count(), 0)
        self.assertEqual(panel.locator("[data-qr-receipt]").count(), 0)

    def test_receipt_error_state_is_explicit_and_retryable(self):
        self.open_app(receipt="error")
        panel = self.page.locator("#record-receipt-panel")
        self.assertIn("Couldn’t load the receipt", panel.inner_text())
        self.assertEqual(panel.locator("[data-receipt-retry]").count(), 1)

    def test_owner_record_route_is_accessible(self):
        self.open_app(role="workshop_owner", receipt="missing")
        self.page.goto(self.base + "#/record/" + RECORD_ID, wait_until="load")
        self.assertTrue(self.page.url.endswith("#/record/" + RECORD_ID))
        self.page.locator("#record-body").get_by_text("Brake overhaul", exact=True).wait_for(timeout=8000)

    def test_private_receipt_deep_link_survives_sign_in(self):
        self.open_app(authenticated=False, route="#/record/" + RECORD_ID)
        self.page.wait_for_url("**/#/signin", timeout=8000)
        self.assertEqual(self.page.evaluate("() => sessionStorage.getItem('bhat-network:receipt-return')"), "#/record/" + RECORD_ID)
        self.page.locator("#si-email").fill("customer@synthetic.invalid")
        self.page.locator("#si-password").fill("synthetic-password")
        self.page.locator("#si-submit").click()
        self.page.wait_for_url("**/#/record/" + RECORD_ID, timeout=8000)
        self.page.locator("#record-body").get_by_text("Private service receipt", exact=True).wait_for(timeout=8000)
        self.assertIsNone(self.page.evaluate("() => sessionStorage.getItem('bhat-network:receipt-return')"))

    def test_malformed_receipt_return_cannot_redirect_outside_the_app(self):
        self.open_app(authenticated=False, route="#/record/%2F%2Fevil.example")
        self.page.wait_for_url("**/#/signin", timeout=8000)
        self.assertIsNone(self.page.evaluate("() => sessionStorage.getItem('bhat-network:receipt-return')"))
        self.page.locator("#si-email").fill("customer@synthetic.invalid")
        self.page.locator("#si-password").fill("synthetic-password")
        self.page.locator("#si-submit").click()
        self.page.wait_for_url("**/#/home", timeout=8000)
        self.assertNotIn("evil.example", self.page.url)

    def test_completion_uses_atomic_rpc_and_does_not_auto_send_message(self):
        self.open_app(role="workshop_owner", receipt="missing")
        self.page.goto(self.base + "#/booking/" + BOOKING_ID, wait_until="load")
        action = self.page.locator('[data-booking-action="COMPLETED"]').first
        action.wait_for(timeout=8000)
        action.click()
        self.page.locator("#sheet-record").wait_for(state="visible")
        self.page.locator("#rc-work").fill(SNAPSHOT["service"]["work_performed"])
        self.page.locator("#rc-parts").fill(SNAPSHOT["service"]["parts"])
        self.page.locator("#rc-cost").fill("8750")
        self.page.locator("#rc-notes").fill(SNAPSHOT["service"]["notes"])
        self.page.locator("#rc-submit").click()
        self.page.wait_for_function("""() => window.__fixture.calls.some(c => c.kind === 'rpc' && c.name === 'complete_ready_booking')""")
        calls = self.calls()
        complete = [c for c in calls if c.get("kind") == "rpc" and c.get("name") == "complete_ready_booking"]
        self.assertEqual(len(complete), 1)
        self.assertEqual(complete[0]["args"]["p_booking"], BOOKING_ID)
        self.assertEqual(complete[0]["args"]["p_fields"]["work_performed"], SNAPSHOT["service"]["work_performed"])
        self.assertFalse(any(c.get("kind") == "from" and c.get("table") == "messages" for c in calls))
        self.assertFalse(any(c.get("kind") == "rpc" and c.get("name") == "send_message" for c in calls))

    def test_message_settings_load_and_save_when_owner_can_configure(self):
        self.open_app(role="workshop_owner", receipt="missing")
        self.page.goto(self.base + "#/workshop", wait_until="load")
        form = self.page.locator("#form-receipt-settings")
        form.wait_for(state="visible", timeout=8000)
        field = self.page.locator("#receipt-message")
        field.fill("Synthetic saved message")
        self.page.locator("#receipt-message-save").click()
        self.page.wait_for_function("""() => window.__fixture.calls.some(c => c.kind === 'rpc' && c.name === 'set_workshop_receipt_message')""")
        saved = [c for c in self.calls() if c.get("kind") == "rpc" and c.get("name") == "set_workshop_receipt_message"]
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0]["args"]["p_message"], "Synthetic saved message")


if __name__ == "__main__":
    unittest.main()

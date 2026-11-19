"""Offline responsive/browser regressions for the current static Bhat Network app.

The app has an advertising marquee. The
owner-dashboard feature banner is also covered through ``.feat-card`` and
its adjacent marketplace surface (``#dash-market-sec``). All records below are
synthetic and served by an in-page Supabase-shaped fake; no account or project
is contacted.

Dependencies:
    python3 -m pip install playwright
    python3 -m playwright install chromium

Run from the repository root:
    python3 tests/test_ui_enhancements_browser.py
"""

from datetime import datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
import unittest

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OWNER_ID = "owner-ui-synthetic"
CUSTOMER_ID = "customer-ui-synthetic"
WORKSHOP_ID = "workshop-ui-synthetic"
CUSTOMER_2_ID = "customer-ui-synthetic-2"
TODAY = datetime.now().strftime("%Y-%m-%d")

VEHICLE = {
    "id": "vehicle-ui-synthetic",
    "make": "Honda", "model": "City", "year": 2021,
    "plate": "JK01AB1234", "nickname": "Asha's City", "odometer_km": 42000,
}
CUSTOMER = {"id": CUSTOMER_ID, "full_name": "Asha Responsive", "phone": "6000000000"}
CUSTOMER_2 = {"id": CUSTOMER_2_ID, "full_name": "Bharat Long Customer Name", "phone": "6111111111"}
WORKSHOP = {
    "id": WORKSHOP_ID, "name": "Synthetic Motors", "owner_profile_id": OWNER_ID,
    "status": "active", "verification_status": "VERIFIED", "is_verified": True,
    "area": "Srinagar", "district": "Srinagar", "phone": "6000000001",
    "photo_url": None, "listings": [],
    "working_days": [1, 2, 3, 4, 5, 6],
    "hours": [{"day_of_week": d, "is_open": True, "open_time": "09:00", "close_time": "18:00"} for d in range(7)],
}
REQUESTED = {
    "id": "booking-ui-requested", "status": "REQUESTED", "request_type": "booking",
    "workshop_id": WORKSHOP_ID, "customer_profile_id": CUSTOMER_ID,
    "customer": CUSTOMER, "vehicle": VEHICLE, "service_name": "Brake inspection",
    "service": {"name": "Brake inspection", "duration_min": 60},
    "created_at": "2026-11-18T08:00:00Z", "updated_at": "2026-11-18T08:00:00Z",
    "preferred_date": TODAY, "preferred_time": "10:00",
    "additional": [], "updates": [],
}
SCHEDULED = {
    "id": "booking-ui-scheduled", "status": "SCHEDULED", "request_type": "booking",
    "workshop_id": WORKSHOP_ID, "customer_profile_id": CUSTOMER_2_ID,
    "customer": CUSTOMER_2, "vehicle": {**VEHICLE, "id": "vehicle-ui-synthetic-2", "plate": "JK02CD5678", "make": "Maruti", "model": "Swift"},
    "service_name": "Oil service", "service": {"name": "Oil service", "duration_min": 60},
    "created_at": "2026-11-18T09:00:00Z", "updated_at": "2026-11-18T09:00:00Z",
    "scheduled_at": TODAY + "T12:00:00+05:30", "appointment_duration_min": 60,
    "additional": [], "updates": [],
}
RECORD = {
    "id": "record-ui-synthetic", "customer_profile_id": CUSTOMER_ID,
    "customer": CUSTOMER, "vehicle": VEHICLE, "vehicle_id": VEHICLE["id"],
    "service_name": "Brake overhaul", "record_date": "2026-11-01",
    "private_receipt": None,
}
LISTING = {
    "id": "listing-ui-synthetic", "title": "Genuine brake pads", "description": "Synthetic listing",
    "category": "parts", "price": 1200, "status": "ACTIVE",
    "workshop": {"id": WORKSHOP_ID, "name": WORKSHOP["name"]},
}


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


class UIEnhancementBrowserTests(unittest.TestCase):
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
        self.context = self.browser.new_context(
            viewport={"width": 375, "height": 812},
            reduced_motion="no-preference",
            service_workers="block",
        )
        self.page = self.context.new_page()
        self.page.route("**/*", lambda route: route.continue_() if route.request.url.startswith(self.base) else route.abort())

    def tearDown(self):
        self.context.close()

    def open_app(self, role="workshop_owner", route="dashboard", width=375):
        self.page.set_viewport_size({"width": width, "height": 812})
        fixture = {"role": role, "owner": OWNER_ID, "customer": CUSTOMER_ID,
                   "workshop": WORKSHOP, "bookings": [REQUESTED, SCHEDULED],
                   "records": [RECORD], "listings": [LISTING]}
        script = r"""
(() => {
  const f = __FIXTURE__;
  const userId = f.role === 'workshop_owner' ? f.owner : f.customer;
  const profile = {id: userId, role: f.role, full_name: f.role === 'workshop_owner' ? 'Owner Responsive' : f.customer === 'customer-ui-synthetic' ? 'Asha Responsive' : 'Bharat Responsive', phone: '6000000000', onboarding_complete: true};
  const ok = data => Promise.resolve({data, error: null});
  const rows = table => {
    if (table === 'profiles') return [profile];
    if (table === 'workshops') return [f.workshop];
    if (table === 'vehicles') return [{...f.bookings[0].vehicle, is_primary: true}];
    if (table === 'service_records') return f.records;
    if (table === 'marketplace_listings') return f.listings;
    if (table === 'notifications' || table === 'booking_updates') return [];
    if (table === 'service_requests') return f.role === 'customer' ? f.bookings.filter(b => b.customer_profile_id === userId) : f.bookings;
    return [];
  };
  function run(op, mode) {
    let data = rows(op.table);
    for (const [key, value] of (op.filters || [])) {
      if (key === 'eq') data = data.filter(row => row[value[0]] === value[1]);
      if (key === 'in') data = data.filter(row => value[1].includes(row[value[0]]));
      if (key === 'gte') data = data.filter(row => String(row[value[0]] || '') >= String(value[1]));
      if (key === 'lt') data = data.filter(row => String(row[value[0]] || '') < String(value[1]));
    }
    if (mode === 'maybeSingle' || mode === 'single') data = data[0] || null;
    if (op.table === 'service_requests' && op.filters.some(([key, value]) => key === 'in' && value[0] === 'status')) data = f.bookings.filter(b => b.scheduled_at);
    return ok(data);
  }
  function builder(table) {
    const op = {table, filters: []};
    const b = {
      select: () => b, eq: (...x) => { op.filters.push(['eq', x]); return b; },
      in: (...x) => { op.filters.push(['in', x]); return b; }, gte: (...x) => { op.filters.push(['gte', x]); return b; },
      lt: (...x) => { op.filters.push(['lt', x]); return b; }, neq: () => b, or: () => b,
      order: () => b, limit: () => b, range: () => b, filter: () => b,
      maybeSingle: () => run(op, 'maybeSingle'), single: () => run(op, 'single'),
      insert: value => { op.insert = value; return b; }, update: value => { op.update = value; return b; },
      then: (resolve, reject) => run(op, 'list').then(resolve, reject),
    };
    return b;
  }
  window.supabase = {createClient: () => ({
    auth: {onAuthStateChange: cb => { setTimeout(() => cb('INITIAL_SESSION', {user: {id: userId, user_metadata: {full_name: profile.full_name, role: f.role}}}), 0); return {data: {subscription: {unsubscribe(){}}}};}, signOut: async () => ok(null)},
    from: builder,
    rpc: (name, args) => { if (name === 'unread_count') return ok([]); if (name === 'public_workshop') return ok(f.workshop); return ok([]); },
    channel: () => { const channel = {on: () => channel, subscribe: () => channel}; return channel; }, removeChannel: () => {},
  })};
})();
""".replace("__FIXTURE__", json.dumps(fixture))
        self.page.add_init_script(script)
        self.page.goto(self.base + "#/" + route, wait_until="load")
        self.page.locator("#splash").wait_for(state="hidden", timeout=8000)

    def assert_no_horizontal_overflow(self):
        widths = self.page.evaluate("() => ({scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth})")
        self.assertLessEqual(widths["scroll"], widths["client"], widths)

    def test_dashboard_feature_banner_and_marketplace_are_responsive_with_reduced_motion(self):
        self.page.emulate_media(reduced_motion="reduce")
        self.open_app("workshop_owner", "dashboard", 375)
        self.page.locator("#dash-workshop .feat-card").wait_for(timeout=8000)
        self.assertIn("Synthetic Motors", self.page.locator("#dash-workshop").inner_text())
        self.assertEqual(self.page.locator("#dash-market-sec").count(), 1)
        self.page.locator("#dash-market-sec #dm-listings .prod-card").first.wait_for(timeout=8000)
        self.assert_no_horizontal_overflow()
        motion = self.page.evaluate("""() => {
          const nodes = [...document.querySelectorAll('*')];
          return nodes.filter(n => getComputedStyle(n).animationName !== 'none')
            .map(n => getComputedStyle(n).animationDuration).filter(Boolean);
        }""")
        self.assertTrue(all(float(d.removesuffix("s")) <= 0.01 for d in motion), motion[:10])
        self.assertTrue(self.page.locator("#dash-workshop a[href='#/owner-bookings']").is_visible())

    def test_advertising_marquee_pause_and_reduced_motion_scroll_surface(self):
        self.open_app("workshop_owner", "dashboard", 375)
        marquee = self.page.locator(".network-marquee")
        marquee.wait_for(timeout=8000)
        self.assertIn("Advertising", self.page.locator("#network-preview-title").inner_text())
        self.assertEqual(marquee.locator(".network-marquee-group").count(), 2)
        self.assertEqual(marquee.locator(".network-marquee-group[aria-hidden='true']").count(), 1)
        self.assertGreater(self.page.evaluate("el => el.scrollWidth", marquee.element_handle()),
                           self.page.evaluate("el => el.clientWidth", marquee.element_handle()))
        pause = self.page.locator("[data-network-pause]")
        self.assertEqual(pause.get_attribute("aria-pressed"), "false")
        pause.scroll_into_view_if_needed()
        self.page.emulate_media(reduced_motion="no-preference")
        track = marquee.locator(".network-marquee-track").first
        before = track.evaluate("el => getComputedStyle(el).transform")
        self.page.wait_for_timeout(120)
        after = track.evaluate("el => getComputedStyle(el).transform")
        self.assertNotEqual(before, after)
        pause.click()
        self.assertEqual(pause.get_attribute("aria-pressed"), "true")
        self.assertEqual(pause.inner_text(), "Play")
        self.assertTrue(marquee.evaluate("el => el.classList.contains('is-paused')"))
        self.assertEqual(track.evaluate("el => getComputedStyle(el).animationPlayState"), "paused")
        pause.click()
        self.assertEqual(pause.get_attribute("aria-pressed"), "false")
        self.assertEqual(pause.inner_text(), "Pause")
        self.assertEqual(track.evaluate("el => getComputedStyle(el).animationPlayState"), "running")
        self.assert_no_horizontal_overflow()

    def test_customer_cards_keep_data_and_navigation_on_narrow_view(self):
        self.open_app("workshop_owner", "owner-customers", 375)
        cards = self.page.locator("#cust-body .cust-card")
        cards.first.wait_for(timeout=8000)
        self.assertGreaterEqual(cards.count(), 2)
        asha = cards.filter(has_text="Asha Responsive")
        self.assertEqual(asha.count(), 1)
        self.assertIn("1 vehicle", asha.inner_text())
        href = asha.get_attribute("href")
        self.assertEqual(href, "#/wcustomer/" + CUSTOMER_ID)
        asha.click()
        self.page.locator("#wcustomer-body .profile-card").wait_for(timeout=5000)
        self.assertIn("Asha Responsive", self.page.locator("#wcustomer-body").inner_text())
        self.assert_no_horizontal_overflow()

    def test_workshop_day_appointments_have_ordered_navigation_and_date_controls(self):
        self.open_app("workshop_owner", "owner-bookings", 375)
        date = self.page.locator("#wb-day-date")
        today = self.page.evaluate("""() => { const d = new Date(); return [d.getFullYear(), String(d.getMonth()+1).padStart(2,'0'), String(d.getDate()).padStart(2,'0')].join('-'); }""")
        date.fill(today)
        date.dispatch_event("change")
        self.page.locator("#wb-day-list .wb-day-item").first.wait_for(timeout=8000)
        self.assertEqual(self.page.locator("#wb-day-count").inner_text(), "1 appointment")
        item = self.page.locator("#wb-day-list .wb-day-item").first
        self.assertIn("Bharat Long Customer Name", item.inner_text())
        self.assertEqual(item.get_attribute("href"), "#/booking/" + SCHEDULED["id"])
        old = date.input_value()
        self.page.locator("[data-wb-day-shift='1']").click()
        self.assertNotEqual(date.input_value(), old)
        self.page.locator("[data-wb-day-today]").click()
        self.assertEqual(date.input_value(), old)
        for width in (320, 768):
            self.page.set_viewport_size({"width": width, "height": 812})
            self.page.wait_for_timeout(100)
            client = self.page.evaluate("() => document.documentElement.clientWidth")
            for selector in ("#wb-day-date", "[data-wb-day-shift='-1']", "[data-wb-day-shift='1']", "[data-wb-day-today]"):
                box = self.page.locator(selector).bounding_box()
                self.assertIsNotNone(box)
                self.assertGreaterEqual(box["x"], 0)
                self.assertLessEqual(box["x"] + box["width"], client)
            chip = self.page.locator("#wb-day-list .wb-day-item .chip").first.bounding_box()
            self.assertIsNotNone(chip)
            self.assertGreaterEqual(chip["x"], 0)
            self.assertLessEqual(chip["x"] + chip["width"], client)
        self.assert_no_horizontal_overflow()

    def test_booking_cards_preserve_actions_history_and_filtering(self):
        self.open_app("workshop_owner", "owner-bookings", 375)
        cards = self.page.locator("#wb-list .svc2")
        cards.first.wait_for(timeout=8000)
        self.assertEqual(cards.count(), 2)
        first = cards.filter(has_text="Asha Responsive")
        self.assertEqual(first.count(), 1)
        self.assertEqual(first.locator("a[href='#/booking/booking-ui-requested']").count(), 1)
        self.assertGreaterEqual(first.locator("a[href='#/wcustomer/" + CUSTOMER_ID + "']").count(), 1)
        first.locator("[data-whist='booking-ui-requested']").click()
        self.assertIn("Bookings at your workshop (1)", first.inner_text())
        self.assertEqual(first.locator(".svc2-hrow").count(), 1)
        self.page.locator("#wb-filters [data-bfilter='requests']").click()
        self.assertEqual(self.page.locator("#wb-list .svc2").count(), 1)
        self.assertIn("Asha Responsive", self.page.locator("#wb-list").inner_text())
        self.page.locator("#wb-search").fill("Bharat")
        self.page.wait_for_timeout(500)
        self.assertIn("No bookings match your search", self.page.locator("#wb-list").inner_text())
        self.assert_no_horizontal_overflow()


if __name__ == "__main__":
    unittest.main()

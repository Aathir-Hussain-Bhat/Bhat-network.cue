"""Offline browser regressions for customer service reviews.

All user, booking, receipt-eligibility, and review data is synthetic. The app is
served locally and all non-local requests are blocked; the Supabase client is a
small in-page mock, so tests never write to the real project.
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
CUSTOMER_ID = "customer-review-synthetic-0001"
BOOKING_ID = "booking-review-synthetic-0001"
WORKSHOP_ID = "workshop-review-synthetic-0001"

BOOKING = {
    "id": BOOKING_ID,
    "status": "COMPLETED",
    "request_type": "booking",
    "customer_profile_id": CUSTOMER_ID,
    "workshop_id": WORKSHOP_ID,
    "vehicle_id": "vehicle-review-synthetic-0001",
    "service_name": "Synthetic brake service",
    "created_at": "2026-11-18T10:00:00Z",
    "updated_at": "2026-11-19T10:00:00Z",
    "workshop": {"id": WORKSHOP_ID, "name": "Synthetic Motors", "area": "Srinagar", "district": "Srinagar"},
    "vehicle": {"id": "vehicle-review-synthetic-0001", "make": "Honda", "model": "City", "plate": "JK01AB1234"},
    "service": {"name": "Synthetic brake service", "category": "brakes"},
    "updates": [],
    "history": [],
    "additional": [],
}


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


class ServiceReviewBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(
            ("127.0.0.1", 0),
            partial(QuietHandler, directory=str(ROOT)),
        )
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
        self.context = self.browser.new_context(service_workers="block")
        self.page = self.context.new_page()
        self.page.route(
            "**/*",
            lambda route: route.continue_()
            if route.request.url.startswith(self.base)
            else route.abort(),
        )

    def tearDown(self):
        self.context.close()

    def open_app(self, eligibility="eligible", submission="success"):
        fixture = {
            "eligibility": eligibility,
            "submission": submission,
            "booking": BOOKING,
            "calls": [],
        }
        self.page.add_init_script(
            """
            (() => {
              const f = __FIXTURE__;
              const CUSTOMER_ID = "customer-review-synthetic-0001";
              const user = {id: CUSTOMER_ID, user_metadata: {full_name: "Synthetic Customer"}};
              const profile = {
                id: CUSTOMER_ID, role: "customer", full_name: "Synthetic Customer",
                phone: "6000000000", onboarding_complete: true
              };
              const ok = data => Promise.resolve({data, error: null});
              const filtersFor = op => op.filters || [];
              function run(op, mode) {
                f.calls.push({kind: "from", table: op.table, mode, filters: filtersFor(op)});
                if (op.table === "profiles") return ok(profile);
                if (op.table === "service_requests") {
                  const idFilter = filtersFor(op).find(([kind, args]) => kind === "eq" && args[0] === "id");
                  const rows = idFilter
                    ? (idFilter[1][1] === f.booking.id ? [f.booking] : [])
                    : [f.booking];
                  return ok(mode === "maybeSingle" || mode === "single" ? (rows[0] || null) : rows);
                }
                return ok(mode === "list" ? [] : null);
              }
              function builder(table) {
                const op = {table, filters: []};
                const b = {
                  select: () => b,
                  eq: (...args) => { op.filters.push(["eq", args]); return b; },
                  neq: (...args) => { op.filters.push(["neq", args]); return b; },
                  in: (...args) => { op.filters.push(["in", args]); return b; },
                  gte: (...args) => { op.filters.push(["gte", args]); return b; },
                  lt: (...args) => { op.filters.push(["lt", args]); return b; },
                  order: () => b,
                  limit: () => b,
                  maybeSingle: () => run(op, "maybeSingle"),
                  single: () => run(op, "single"),
                  then: (resolve, reject) => run(op, "list").then(resolve, reject),
                };
                return b;
              }
              function rpc(name, args) {
                f.calls.push({kind: "rpc", name, args});
                if (name === "get_service_review_for_booking") {
                  return ok({eligible: f.eligibility === "eligible", review: null});
                }
                if (name === "submit_service_review") {
                  if (f.submission === "error") {
                    return Promise.resolve({data: null, error: {message: "Synthetic review write failure", code: "P0001"}});
                  }
                  return ok({rating: args.p_rating, comment: args.p_comment, created_at: "2026-11-19T12:00:00Z"});
                }
                if (name === "unread_count") return ok(0);
                if (name === "public_workshop_reviews") return ok({review_count: 0, average_rating: null, reviews: []});
                return ok(null);
              }
              window.__reviewFixture = f;
              window.supabase = {createClient: () => ({
                auth: {
                  onAuthStateChange: cb => {
                    setTimeout(() => cb("INITIAL_SESSION", {user}), 0);
                    return {data: {subscription: {unsubscribe(){}}}};
                  },
                  signOut: async () => ok(null)
                },
                from: builder,
                rpc,
                channel: () => { const c = {on: () => c, subscribe: () => c}; return c; },
                removeChannel: () => {}
              })};
            })();
            """.replace("__FIXTURE__", json.dumps(fixture))
        )
        self.page.goto(self.base + "#/cbooking/" + BOOKING_ID, wait_until="load")
        self.page.locator("#splash").wait_for(state="hidden", timeout=8000)
        self.page.locator("#cbooking-body").wait_for(timeout=8000)
        if eligibility == "eligible":
            self.page.locator("#form-service-review").wait_for(timeout=8000)
        else:
            self.page.get_by_text("A review is available after the workshop completes this service with its private service receipt.").wait_for(timeout=8000)

    def calls(self):
        return self.page.evaluate("() => window.__reviewFixture.calls")

    def test_eligible_customer_submits_review_through_scoped_rpc(self):
        self.open_app()
        form = self.page.locator("#form-service-review")
        form.locator('[name="rating"]').select_option("5")
        form.locator('[name="comment"]').fill("Synthetic review for browser test")
        form.locator('button[type="submit"]').click()

        self.page.locator(".toast.t-success").wait_for(timeout=8000)
        self.assertIn("Verified service review submitted", self.page.locator(".toast.t-success").inner_text())
        self.page.get_by_text("Your verified service review", exact=True).wait_for(timeout=8000)
        calls = self.calls()
        submissions = [call for call in calls if call.get("name") == "submit_service_review"]
        self.assertEqual(len(submissions), 1, calls)
        self.assertEqual(submissions[0]["args"], {
            "p_booking": BOOKING_ID,
            "p_rating": 5,
            "p_comment": "Synthetic review for browser test",
        })
        self.assertFalse(any(call.get("table") in {"service_reviews", "workshop_receipts"} for call in calls), calls)

    def test_review_write_error_is_visible_and_keeps_form_for_retry(self):
        self.open_app(submission="error")
        form = self.page.locator("#form-service-review")
        form.locator('[name="rating"]').select_option("4")
        form.locator('button[type="submit"]').click()

        error_toast = self.page.locator(".toast.t-error")
        error_toast.wait_for(timeout=8000)
        self.assertIn("Something went wrong", error_toast.inner_text())
        self.assertTrue(form.is_visible())
        self.assertFalse(any(call.get("table") in {"service_reviews", "workshop_receipts"} for call in self.calls()))

    def test_customer_without_receipt_eligibility_is_not_offered_a_review_form(self):
        self.open_app(eligibility="no_receipt")
        self.assertEqual(self.page.locator("#form-service-review").count(), 0)
        self.assertFalse(any(call.get("name") == "submit_service_review" for call in self.calls()))


if __name__ == "__main__":
    unittest.main()

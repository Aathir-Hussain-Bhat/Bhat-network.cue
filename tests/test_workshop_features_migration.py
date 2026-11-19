from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "supabase/migrations/20261119210500_workshop_verification_reviews_earnings.sql"
SQL = MIGRATION_PATH.read_text(encoding="utf-8").lower()
HTML = (ROOT / "index.html").read_text(encoding="utf-8").lower()


def segment(start, stop=None):
    start = start.lower()
    begin = SQL.index(start)
    end = len(SQL) if stop is None else SQL.index(stop.lower(), begin)
    return SQL[begin:end]


class WorkshopFeaturesMigrationTests(unittest.TestCase):
    def test_is_a_new_additive_migration(self):
        self.assertTrue(MIGRATION_PATH.is_file())
        self.assertIn("create table public.workshop_verification_applications", SQL)
        self.assertIn("create table public.service_reviews", SQL)
        self.assertIn("create table public.workshop_money_entries", SQL)
        self.assertNotIn("drop table", SQL)
        self.assertNotIn("truncate", SQL)
        self.assertNotIn("alter table public.workshop_receipts", SQL)
        self.assertNotIn("delete from public.workshops", SQL)

    def test_verification_applications_are_private_and_owner_submitted(self):
        table = segment(
            "create table public.workshop_verification_applications",
            "create or replace function public.protect_workshop_verification()",
        )
        self.assertIn("enable row level security", table)
        self.assertIn("revoke all on table public.workshop_verification_applications from public, anon, authenticated", table)
        self.assertIn("grant select on table public.workshop_verification_applications to authenticated", table)
        self.assertIn("using (applicant_profile_id = auth.uid() or public.is_admin())", table)
        self.assertNotIn("grant insert", table)

        submit = segment(
            "create or replace function public.submit_workshop_verification_application(",
            "-- reviews can only be created",
        )
        self.assertIn("security definer", submit)
        self.assertIn("set search_path = ''", submit)
        self.assertIn("v_workshop.owner_profile_id <> auth.uid()", submit)
        self.assertIn("v_workshop.verification_status in ('verified', 'suspended')", submit)
        self.assertIn("insert into public.workshop_verification_applications", submit)
        self.assertIn("old.verification_status = 'rejected'", segment(
            "create or replace function public.protect_workshop_verification()",
            "revoke all on function public.protect_workshop_verification()",
        ))
        self.assertIn("new.verification_status = 'pending'", segment(
            "create or replace function public.protect_workshop_verification()",
            "revoke all on function public.protect_workshop_verification()",
        ))
        self.assertIn("grant execute on function public.submit_workshop_verification_application(uuid,text) to authenticated", SQL)
        self.assertNotIn("create or replace function public.admin_set_workshop_verification", SQL)

    def test_application_submission_is_audited_and_notifies_admins(self):
        self.assertIn("create trigger workshop_verification_applications_audit", SQL)
        self.assertIn("insert into public.audit_log", segment(
            "create or replace function public.audit_workshop_verification_application()",
            "revoke all on function public.audit_workshop_verification_application()",
        ))
        self.assertIn("create trigger workshop_verification_applications_notify_admins", SQL)
        notify = segment(
            "create or replace function public.notify_admins_workshop_verification_application()",
            "revoke all on function public.notify_admins_workshop_verification_application()",
        )
        self.assertIn("where p.role = 'admin'", notify)
        self.assertIn("v_status <> 'rejected'", notify)

    def test_reviews_require_one_completed_receipt_backed_booking(self):
        table = segment(
            "create table public.service_reviews",
            "create or replace function public.get_service_review_for_booking(",
        )
        self.assertIn("booking_id uuid not null unique", table)
        self.assertIn("service_record_id uuid not null unique", table)
        self.assertIn("enable row level security", table)
        self.assertIn("revoke all on table public.service_reviews from public, anon, authenticated", table)

        submit = segment(
            "create or replace function public.submit_service_review(",
            "revoke all on function public.submit_service_review",
        )
        self.assertIn("v_request.status <> 'completed'", submit)
        self.assertIn("v_request.request_type <> 'booking'", submit)
        self.assertIn("v_request.customer_profile_id <> auth.uid()", submit)
        self.assertIn("join public.workshop_receipts wr", submit)
        self.assertIn("wr.service_record_id = r.id", submit)
        self.assertIn("wr.booking_id = v_request.id", submit)
        self.assertIn("wr.workshop_id = v_request.workshop_id", submit)
        self.assertIn("wr.customer_profile_id = v_request.customer_profile_id", submit)
        self.assertIn("raise exception 'a verified completion receipt is required before reviewing'", submit)
        self.assertIn("grant execute on function public.submit_service_review(uuid,integer,text) to authenticated", SQL)

    def test_public_reviews_are_non_identifying_and_do_not_expose_receipts(self):
        public = segment(
            "create or replace function public.public_workshop_reviews(",
            "revoke all on function public.public_workshop_reviews",
        )
        self.assertIn("security definer", public)
        self.assertIn("'rating'", public)
        self.assertIn("'comment'", public)
        self.assertIn("'service_name'", public)
        self.assertIn("q.status = 'completed'", public)
        self.assertIn("limit 20", public)
        for private_field in ("customer_profile_id", "phone", "address_text", "snapshot", "receipt_id"):
            self.assertNotIn(private_field, public)
        self.assertIn("grant execute on function public.public_workshop_reviews(uuid) to anon, authenticated", SQL)
        self.assertIn("your comment is public", HTML)
        self.assertIn("verified service", HTML)

    def test_money_tracking_is_workshop_scoped_and_append_only(self):
        table = segment(
            "create table public.workshop_money_entries",
            "create or replace function public.protect_workshop_money_entry_immutability()",
        )
        self.assertIn("entry_type in ('income', 'expense')", table)
        self.assertIn("amount numeric(12,2) not null check (amount > 0)", table)
        self.assertIn("enable row level security", table)
        self.assertIn("revoke all on table public.workshop_money_entries from public, anon, authenticated", table)
        self.assertIn("before update or delete on public.workshop_money_entries", SQL)

        add = segment(
            "create or replace function public.add_workshop_money_entry(",
            "revoke all on function public.add_workshop_money_entry",
        )
        self.assertIn("p_workshop is null or not public.is_workshop_member(p_workshop, array['owner','manager'])", add)
        self.assertIn("p_type is null or p_type not in ('income', 'expense')", add)
        self.assertIn("created_by_profile_id, entry_type", add)

        summary = segment(
            "create or replace function public.workshop_earnings_summary(",
            "revoke all on function public.workshop_earnings_summary",
        )
        self.assertIn("p_workshop is null or not public.is_workshop_member", summary)
        self.assertIn("from public.workshop_receipts wr", summary)
        self.assertIn("q.status = 'completed'", summary)
        self.assertIn("wr.snapshot #>> '{service,cost}'", summary)
        self.assertIn("from public.workshop_money_entries e", summary)
        self.assertIn("'workshop_entered_income'", summary)
        self.assertIn("'workshop_entered_expenses'", summary)
        for untrusted_source in ("workshop_services", "price_min", "price_max", "marketplace_listings", "additional_work_requests"):
            self.assertNotIn(untrusted_source, summary)
        self.assertIn("grant execute on function public.workshop_earnings_summary(uuid) to authenticated", SQL)

    def test_workshop_ui_is_owner_routed_and_financial_labels_are_explicit(self):
        self.assertIn("'earnings':        { view: 'view-earnings',      shell: 'owner',    auth: true }", HTML)
        self.assertIn('href="#/earnings" data-route="earnings"', HTML)
        earnings_ui = HTML[HTML.index("function screenearnings()") : HTML.index("async function onsubmitmoneyentry(")]
        self.assertIn("s.profile?.role !== 'workshop_owner'", earnings_ui)
        for label in (
            "workshop-entered income", "workshop-entered expenses", "completed service amounts",
            "not a payment or bank balance", "not independently verified or processed",
            "amount recorded on a receipt does not confirm payment was collected",
        ):
            self.assertIn(label, HTML)
        self.assertIn("service estimates and listing prices are not counted as income", HTML)
        self.assertIn("workshop_money_entries", SQL)

    def test_workshop_verification_form_and_admin_review_screen_are_added(self):
        self.assertIn('id="form-verification-application"', HTML)
        self.assertIn("submit_workshop_verification_application", HTML)
        self.assertIn("application is awaiting administrator review", HTML)
        self.assertIn("latest owner application", HTML)
        self.assertIn("from('workshop_verification_applications')", HTML)
        self.assertIn("application_note", HTML)

    def test_existing_receipt_and_public_qr_rpcs_are_untouched(self):
        for name in ("public_passport", "public_service_record", "public_workshop", "complete_ready_booking", "get_private_receipt"):
            self.assertNotRegex(SQL, rf"(?m)^[ \t]*create\s+(or\s+replace\s+)?function\s+public\.{name}\s*\(")
            self.assertNotRegex(SQL, rf"(?m)^[ \t]*grant\s+execute\s+on\s+function\s+public\.{name}\s*\(")
        self.assertNotIn("receipt_qr", SQL)
        self.assertNotIn("workshop_receipts", (ROOT / "admin-data.js").read_text(encoding="utf-8").lower())


if __name__ == "__main__":
    unittest.main()

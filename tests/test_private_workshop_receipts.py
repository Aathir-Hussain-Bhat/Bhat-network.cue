from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "supabase/migrations/20261119010000_private_workshop_receipts.sql").read_text(encoding="utf-8")
INITIAL = (ROOT / "supabase/migrations/20261118100000_initial_schema.sql").read_text(encoding="utf-8")
SQL = MIGRATION.lower()
INITIAL_SQL = INITIAL.lower()


class PrivateWorkshopReceiptMigrationTests(unittest.TestCase):
    def function_body(self, signature_fragment, next_fragment=None):
        start = SQL.index(signature_fragment.lower())
        if next_fragment is None:
            return SQL[start:]
        return SQL[start:SQL.index(next_fragment.lower(), start)]

    def test_new_schema_is_snapshot_based_and_contains_no_public_receipt_token(self):
        self.assertIn("create table public.workshop_receipts", SQL)
        self.assertIn("snapshot jsonb not null", SQL)
        self.assertIn("booking_id uuid not null unique", SQL)
        self.assertIn("service_record_id uuid not null unique", SQL)
        self.assertIn("constraint workshop_receipts_snapshot_object", SQL)
        self.assertNotIn("public_token", self.function_body("create table public.workshop_receipts", "create index workshop_receipts_customer_idx"))
        self.assertIn("create trigger workshop_receipts_immutable", SQL)
        self.assertIn("before update or delete on public.workshop_receipts", SQL)

    def test_completion_rpc_locks_ready_booking_and_commits_all_three_writes(self):
        body = self.function_body("create or replace function public.complete_ready_booking", "create or replace function public.get_private_receipt")
        self.assertIn("returns jsonb", body)
        self.assertIn("for update", body)
        self.assertIn("v_booking.status <> 'ready'", body)
        self.assertIn("only ready bookings can be completed", body)
        self.assertIn("insert into public.service_records", body)
        self.assertIn("insert into public.workshop_receipts", body)
        self.assertIn("update public.service_requests", body)
        self.assertIn("set status = 'completed'", body)
        self.assertLess(body.index("insert into public.service_records"), body.index("insert into public.workshop_receipts"))
        self.assertLess(body.index("insert into public.workshop_receipts"), body.index("update public.service_requests"))
        self.assertIn("exception\n  when unique_violation", body)

    def test_service_record_gets_only_public_safe_base_fields(self):
        body = self.function_body("create or replace function public.complete_ready_booking", "create or replace function public.get_private_receipt")
        record_insert = body[body.index("insert into public.service_records"):body.index("v_snapshot :=", body.index("insert into public.service_records"))]
        self.assertIn("service_name, service_category, record_date", record_insert)
        for sensitive_column in ("work_performed", "parts_text", "mileage_km", "cost", "notes"):
            self.assertNotIn(sensitive_column, record_insert)
        self.assertIn("keep sensitive completion details out of service_records", body)

    def test_sensitive_values_are_written_only_to_private_snapshot(self):
        body = self.function_body("create or replace function public.complete_ready_booking", "create or replace function public.get_private_receipt")
        snapshot = body[body.index("v_snapshot :="):body.index("insert into public.workshop_receipts", body.index("v_snapshot :="))]
        for field in ("'work_performed', v_work_performed", "'parts', v_parts_text", "'mileage_km', v_mileage", "'cost', v_cost", "'notes', v_notes", "'message', v_message"):
            self.assertIn(field, snapshot)
        self.assertNotIn("v_record.work_performed", snapshot)
        self.assertNotIn("v_record.parts_text", snapshot)
        self.assertNotIn("v_record.mileage_km", snapshot)
        self.assertNotIn("v_record.cost", snapshot)
        self.assertNotIn("v_record.notes", snapshot)

    def test_category_fallback_handles_no_selected_service(self):
        body = self.function_body("create or replace function public.complete_ready_booking", "create or replace function public.get_private_receipt")
        category_start = body.index("v_service_category :=")
        category_block = body[category_start:body.index("v_work_performed :=", category_start)]
        self.assertIn("nullif(btrim(p_fields ->> 'service_category'), '')", category_block)
        self.assertIn("from public.workshop_services s where s.id = v_booking.service_id", category_block)
        self.assertIn("'general'", category_block)

    def test_completion_validates_lengths_and_participant_ownership(self):
        body = self.function_body("create or replace function public.complete_ready_booking", "create or replace function public.get_private_receipt")
        self.assertIn("v_vehicle.owner_profile_id <> v_booking.customer_profile_id", body)
        self.assertIn("s.workshop_id = v_booking.workshop_id", body)
        for phrase in (
            "service name must be at most 200 characters",
            "service category must be at most 100 characters",
            "work performed must be at most 4000 characters",
            "parts text must be at most 4000 characters",
            "notes must be at most 4000 characters",
            "mileage cannot be negative",
            "cost cannot be negative",
        ):
            self.assertIn(phrase, body)

    def test_only_owner_or_manager_can_configure_private_message(self):
        for name in ("set_workshop_receipt_message", "get_workshop_receipt_settings"):
            body = self.function_body(f"create or replace function public.{name}", "create or replace function public." + ("get_workshop_receipt_settings" if name == "set_workshop_receipt_message" else "complete_ready_booking"))
            self.assertIn("is_workshop_member(p_workshop, array['owner','manager'])", body)
            self.assertIn("authentication required", body)
        self.assertIn("workshop_receipt_settings", SQL)
        self.assertIn("completion_message text", SQL)

    def test_receipt_access_has_no_admin_bypass_and_anon_has_no_grant(self):
        policy = self.function_body("create policy workshop_receipts_read_private", "revoke all on function public.default_workshop_receipt_message")
        self.assertIn("customer_profile_id = auth.uid()", policy)
        self.assertIn("is_workshop_member(workshop_id, array['owner','manager','staff','technician'])", policy)
        self.assertNotIn("is_admin()", policy)
        grants = self.function_body("revoke all on table public.workshop_receipt_settings")
        self.assertIn("from public, anon, authenticated", grants)
        self.assertIn("grant select on public.workshop_receipts to authenticated", grants)
        self.assertIn("revoke all on function public.get_private_receipt(uuid) from public, anon, authenticated", SQL)
        self.assertIn("grant execute on function public.get_private_receipt(uuid) to authenticated", SQL)

    def test_existing_public_passport_and_record_rpcs_are_not_replaced_or_changed(self):
        # Their original definitions, including their existing QR visibility, remain
        # solely in the initial migration. This migration must not redefine or grant them.
        for name in ("public_passport", "public_service_record"):
            self.assertNotRegex(SQL, rf"create\s+(or\s+replace\s+)?function\s+public\.{name}")
            self.assertNotRegex(SQL, rf"revoke\s+all\s+on\s+function\s+public\.{name}")
            self.assertNotRegex(SQL, rf"grant\s+execute\s+on\s+function\s+public\.{name}")
            self.assertRegex(INITIAL_SQL, rf"create\s+function\s+public\.{name}")
        self.assertIn("'mileage_km', sr.mileage_km", INITIAL_SQL)
        self.assertIn("'work_performed', sr.work_performed", INITIAL_SQL)
        self.assertIn("'public_token', sr.public_token", INITIAL_SQL)

    def test_existing_migrations_and_frontend_are_untouched(self):
        tracked = {p.name for p in (ROOT / "supabase/migrations").glob("*.sql")}
        self.assertIn("20261118100000_initial_schema.sql", tracked)
        self.assertEqual(MIGRATION.count("create or replace function public.complete_ready_booking"), 1)
        self.assertTrue((ROOT / "supabase/migrations/20261119010000_private_workshop_receipts.sql").is_file())


if __name__ == "__main__":
    unittest.main()

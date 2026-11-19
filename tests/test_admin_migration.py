from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MIGRATION_PATH = ROOT / "supabase/migrations/20261119061148_admin_crud_and_workshop_verification_notifications.sql"
SQL = MIGRATION_PATH.read_text(encoding="utf-8").lower()


class AdminMigrationTests(unittest.TestCase):
    def policy_body(self, name):
        start = SQL.index(f"create policy {name}")
        end = SQL.find(";", start)
        return SQL[start:end]

    def function_body(self, signature, next_marker=None):
        start = SQL.index(signature.lower())
        end = len(SQL) if next_marker is None else SQL.index(next_marker.lower(), start)
        return SQL[start:end]

    def test_migration_is_new_separate_file(self):
        self.assertTrue(MIGRATION_PATH.is_file())
        self.assertEqual(MIGRATION_PATH.name, "20261119061148_admin_crud_and_workshop_verification_notifications.sql")

    def test_admin_crud_is_authenticated_only_and_does_not_expand_anon_access(self):
        tables = (
            "profiles", "customers", "workshops", "workshop_members",
            "workshop_services", "workshop_hours", "vehicles", "service_requests",
            "booking_updates", "booking_status_history", "booking_intake",
            "additional_work_requests", "service_records", "marketplace_listings",
        )
        for table in tables:
            body = self.policy_body(f"{table}_admin_all")
            self.assertIn("for all to authenticated", body)
            self.assertIn("using (public.is_admin())", body)
            self.assertIn("with check (public.is_admin())", body)
            self.assertNotIn("to anon", body)
        self.assertNotIn("grant", " ".join(self.policy_body(f"{t}_admin_all") for t in tables))
        self.assertIn("do not add an admin bypass to notifications", SQL)
        self.assertIn("do not add an admin bypass to audit_log", SQL)
        self.assertIn("do not add an admin bypass to audit_log or private workshop receipts", SQL)

    def test_metrics_is_admin_only_fixed_search_path_and_expected_keys(self):
        body = self.function_body("create or replace function public.admin_metrics()")
        self.assertIn("returns jsonb", body)
        self.assertIn("stable", body)
        self.assertIn("security definer", body)
        self.assertIn("set search_path = ''", body)
        self.assertIn("if not public.is_admin()", body)
        for key in (
            "'users'", "'customers'", "'workshops'", "'pending_verifications'",
            "'suspended'", "'bookings'", "'quick_requests'", "'completed_services'",
            "'active_listings'",
        ):
            self.assertIn(key, body)
        self.assertIn("revoke all on function public.admin_metrics() from public, anon, authenticated", SQL)
        self.assertIn("grant execute on function public.admin_metrics() to authenticated", SQL)

    def test_role_changes_are_trigger_audited_and_no_email_auto_promotion_exists(self):
        body = self.function_body("create or replace function public.audit_profile_role_change()")
        self.assertIn("if new.role is distinct from old.role", body)
        self.assertIn("insert into public.audit_log", body)
        self.assertIn("'profile_role_changed'", body)
        self.assertIn("create trigger profiles_audit_role_change", SQL)
        self.assertNotRegex(SQL, r"email_confirmed_at.*role\s*=\s*'admin'")
        self.assertNotIn("lower(u.email)", SQL)
        self.assertNotIn("raw_user_meta_data ->> 'role' = 'admin'", SQL)

    def test_verification_is_admin_managed_audited_and_notifiable(self):
        self.assertIn("create trigger workshops_notify_admins_on_application", SQL)
        self.assertIn("create trigger workshops_notify_admins_on_verification_status", SQL)
        self.assertIn("create trigger workshops_guard_verification_on_insert", SQL)
        insert_guard = self.function_body("create or replace function public.guard_workshop_verification_on_insert()", "create or replace function public.audit_profile_role_change()")
        self.assertIn("not public.is_admin()", insert_guard)
        self.assertIn("new.verification_status is distinct from 'pending'", insert_guard)
        self.assertIn("new.is_verified is distinct from false", insert_guard)
        body = self.function_body("create or replace function public.notify_admins_workshop_verification()")
        self.assertIn("from public.profiles p", body)
        self.assertIn("where p.role = 'admin'", body)
        self.assertIn("new.verification_status is distinct from old.verification_status", body)
        self.assertIn("'workshop_verification_application'", body)
        self.assertIn("'workshop_verification_status'", body)
        self.assertIn("jsonb_build_object('workshop_id', new.id", body)
        audit = self.function_body("create or replace function public.audit_workshop_verification_change()")
        self.assertIn("insert into public.audit_log", audit)
        self.assertIn("'workshop_verification_changed'", audit)
        self.assertIn("revoke all on function public.notify_admins_workshop_verification() from public, anon, authenticated", SQL)

    def test_existing_public_qr_contracts_are_not_redefined_or_granted(self):
        for name in ("public_passport", "public_service_record", "public_workshop"):
            self.assertNotRegex(SQL, rf"create\s+(or\s+replace\s+)?function\s+public\.{name}")
            self.assertNotRegex(SQL, rf"grant\s+execute\s+on\s+function\s+public\.{name}")
            self.assertNotRegex(SQL, rf"revoke\s+all\s+on\s+function\s+public\.{name}")

    def test_admin_verification_rpc_keeps_authenticated_grant_and_single_trigger_audit_path(self):
        body = self.function_body(
            "create or replace function public.admin_set_workshop_verification(",
            "create or replace function public.admin_metrics()",
        )
        self.assertIn("if not public.is_admin()", body)
        self.assertIn("p_status not in ('pending','verified','rejected','suspended')", body)
        self.assertIn("update public.workshops", body)
        self.assertNotIn("insert into public.audit_log", body)
        self.assertIn("grant execute on function public.admin_set_workshop_verification(uuid,text,text) to authenticated", SQL)


if __name__ == "__main__":
    unittest.main()

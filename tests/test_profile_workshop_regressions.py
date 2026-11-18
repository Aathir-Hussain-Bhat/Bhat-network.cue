from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")
MIGRATION = (ROOT / "supabase/migrations/20261118140500_add_workshop_location_and_vehicle_color.sql").read_text(encoding="utf-8").lower()


class MarkupParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = {}
        self.elements = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.setdefault(attrs["id"], []).append(tag)
        self.elements.append((tag, attrs))


class ProfileAndWorkshopRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dom = MarkupParser()
        cls.dom.feed(HTML)

    def assertHtmlContains(self, fragment, message):
        self.assertTrue(fragment in HTML, message)

    def test_profile_display_and_editor_have_distinct_unique_ids(self):
        self.assertEqual(self.dom.ids.get("pf-display-name"), ["h2"])
        self.assertEqual(self.dom.ids.get("pf-name"), ["input"])
        self.assertEqual(self.dom.ids.get("pf-phone"), ["input"])
        self.assertHtmlContains("$('#pf-display-name').textContent", "Profile display should target its own heading ID.")
        self.assertHtmlContains("val('pf-name')", "Profile save should read the editable name input.")
        self.assertHtmlContains("district: district || null, area: area || null", "Profile save should include location fields.")

    def test_onboarding_back_buttons_are_delegated_to_step_navigation(self):
        back_roles = [attrs.get("data-back") for tag, attrs in self.dom.elements
                      if tag == "button" and "data-back" in attrs]
        self.assertIn("c", back_roles)
        self.assertIn("o", back_roles)
        pattern = re.compile(r"closest\('\[data-back\]'\).*?showStep\(role,\s*step\s*-\s*1\)", re.S)
        self.assertIsNotNone(pattern.search(HTML), "Back buttons must decrement the current onboarding step.")

    def test_migration_adds_every_field_written_by_the_current_forms(self):
        for table, column in (
            ("workshops", "city"),
            ("workshops", "state"),
            ("workshops", "postal_code"),
            ("vehicles", "color"),
        ):
            pattern = rf"alter table public\.{table}[\s\S]*?add column if not exists {column} text"
            self.assertRegex(MIGRATION, pattern, f"Migration should add {table}.{column}.")
        for fragment in ("city: city || null", "state: state || null", "postal_code: postal || null", "color: color || null, year:"):
            self.assertHtmlContains(fragment, f"Frontend must persist the migrated field: {fragment}")
        self.assertHtmlContains("district,area,city,state,postal_code,address_text", "Public workshop details must select the new location columns.")
        self.assertHtmlContains("w.city, w.district, w.state, w.postal_code", "Public workshop addresses must render the new location columns.")

    def test_live_supabase_configuration_and_sign_in_fix_remain_intact(self):
        self.assertHtmlContains("https://hmbpikrgbgtgdmciwmpz.supabase.co", "Keep the configured Supabase project unchanged.")
        self.assertHtmlContains("sb_publishable_LbdWJxql3krR-1e7S9M6rw_385QpWxz", "Keep the configured publishable key unchanged.")
        result = subprocess.run(
            ["git", "-C", str(ROOT), "merge-base", "--is-ancestor", "02a3ba6", "HEAD"],
            check=False,
        )
        self.assertEqual(result.returncode, 0, "The live sign-in fix commit 02a3ba6 must remain in history.")


if __name__ == "__main__":
    unittest.main()

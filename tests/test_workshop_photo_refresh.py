from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")


class WorkshopPhotoRefreshTests(unittest.TestCase):
    def function_body(self, name, next_marker):
        start = HTML.index(name)
        end = HTML.index(next_marker, start)
        return HTML[start:end]

    def test_photo_save_updates_cached_list_and_detail_views(self):
        body = self.function_body("async function saveWorkshopImage()", "async function removeWorkshopImage()")
        self.assertIn("S.workshops.map(w => w.id === workshopId", body)
        self.assertIn("S.shopDetail?.id === workshopId", body)
        self.assertIn("photo_url: photoUrl", body)

    def test_photo_removal_updates_cached_list_and_detail_views(self):
        body = self.function_body("async function removeWorkshopImage()", "async function onSubmitWorkshop(e)")
        self.assertIn("S.workshops.map(w => w.id === workshopId", body)
        self.assertIn("S.shopDetail?.id === workshopId", body)
        self.assertIn("photo_url: null", body)

    def test_returning_to_workshop_list_or_detail_refetches_cached_data(self):
        body = self.function_body("function applyRoute()", "let searchTimer = null;")
        self.assertIn("if (name === 'nearby' && S.workshops !== null) loadWorkshops(true);", body)
        self.assertIn("if (name === 'shop' && param) loadShopDetail(param);", body)
        self.assertIn("lastRouteKey = routeKey;", body)

    def test_detail_fetches_are_deduplicated_for_signed_in_and_public_views(self):
        body = self.function_body("async function loadShopDetail(id)", "function openBookingSheet(id)")
        self.assertIn("if (S.shopDetailLoading?.id === id) return;", body)
        self.assertIn("if (S.shopDetailLoading !== request", body)
        self.assertIn("await DB.workshops.get(id)", body)
        self.assertIn("await DB.publicApi.workshop(id)", body)
        self.assertIn("S.shopDetailLoading = null", body)


if __name__ == "__main__":
    unittest.main()

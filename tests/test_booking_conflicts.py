from pathlib import Path
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")
MIGRATION = (ROOT / "supabase/migrations/20261118182841_conflict_safe_appointments.sql").read_text(encoding="utf-8").lower()


class BookingConflictTests(unittest.TestCase):
    def function_body(self, name, next_marker):
        start = HTML.index(name)
        end = HTML.index(next_marker, start)
        return HTML[start:end]

    def test_overlap_helper_handles_intersection_and_touching_slots(self):
        start = HTML.index("function appointmentDurationMinutes(b, forScheduling = false)")
        end = HTML.index("function daysSummary(arr)", start)
        helpers = HTML[start:end]
        script = helpers + """
const result = {
  falsePositiveNewService: appointmentIntervalsOverlap('2026-11-20T09:00:00Z', appointmentDurationMinutes({ appointment_duration_min: 60, scheduled_at: null, service: { duration_min: 30 } }, true), '2026-11-20T09:30:00Z', 30),
  actualConflictNewService: appointmentIntervalsOverlap('2026-11-20T09:00:00Z', appointmentDurationMinutes({ appointment_duration_min: 60, scheduled_at: null, service: { duration_min: 45 } }, true), '2026-11-20T09:30:00Z', 30),
  overlap: appointmentIntervalsOverlap('2026-11-20T09:00:00Z', 60, '2026-11-20T09:30:00Z', 30),
  touching: appointmentIntervalsOverlap('2026-11-20T09:00:00Z', 60, '2026-11-20T10:00:00Z', 30),
  separate: appointmentIntervalsOverlap('2026-11-20T09:00:00Z', 30, '2026-11-20T10:00:00Z', 30),
  defaultDuration: appointmentDurationMinutes({}),
  serviceDuration: appointmentDurationMinutes({ appointment_duration_min: 60, scheduled_at: null, service: { duration_min: 45 } }, true),
  scheduledSnapshot: appointmentDurationMinutes({ appointment_duration_min: 60, scheduled_at: '2026-11-20T09:00:00Z', service: { duration_min: 30 } }),
  rescheduledServiceDuration: appointmentDurationMinutes({ appointment_duration_min: 30, scheduled_at: '2026-11-20T09:00:00Z', service: { duration_min: 45 } }, true)
};
process.stdout.write(JSON.stringify(result));
"""
        result = subprocess.run(["node", "-e", script], check=True, capture_output=True, text=True)
        self.assertEqual(
            result.stdout,
            '{"falsePositiveNewService":false,"actualConflictNewService":true,"overlap":true,"touching":false,"separate":false,"defaultDuration":60,"serviceDuration":45,"scheduledSnapshot":60,"rescheduledServiceDuration":45}',
        )

    def test_day_view_has_accessible_date_controls_and_agenda_container(self):
        for fragment in (
            'id="wb-day-date" type="date"',
            'data-wb-day-shift="-1"',
            'data-wb-day-shift="1"',
            'data-wb-day-today',
            'id="wb-day-list"',
            'aria-label="Appointments for the selected day"',
        ):
            self.assertIn(fragment, HTML)
        self.assertIn("async function loadWorkshopDayAppointments", HTML)
        self.assertIn("function renderWorkshopDay()", HTML)
        self.assertIn(".order('scheduled_at', { ascending: true })", HTML)

    def test_schedule_checks_same_workshop_active_slots_before_transition(self):
        body = self.function_body("async function onSubmitSchedule(e)", "\nfunction ")
        self.assertIn("DB.bookings.forWorkshopWindow(w.id", body)
        self.assertIn("appointmentIntervalsOverlap", body)
        self.assertIn("Choose another time", body)
        self.assertLess(body.index("appointmentIntervalsOverlap"), body.index("doTransition(b, 'SCHEDULED'"))
        self.assertIn("service_requests_no_overlapping_appointments", HTML)

    def test_unscheduled_duration_uses_selected_service_before_preliminary_check(self):
        start = HTML.index("function appointmentDurationMinutes(b, forScheduling = false)")
        end = HTML.index("function appointmentIntervalsOverlap", start)
        helper = HTML[start:end]
        self.assertIn("const snapshot = Number(b?.appointment_duration_min);", helper)
        self.assertIn("const service = Number(b?.service?.duration_min);", helper)
        self.assertIn("function appointmentDurationMinutes(b, forScheduling = false)", helper)
        self.assertIn("const minutes = forScheduling ? service : snapshot;", helper)
        self.assertIn("appointmentDurationMinutes(b, true)", HTML[HTML.index("async function onSubmitSchedule(e)"):])

    def test_window_query_is_limited_to_active_bookings_in_the_workshop(self):
        body = self.function_body("forWorkshopWindow: (wid, fromIso, toIso)", "get: id => sb.from('service_requests')")
        for fragment in (
            ".eq('workshop_id', wid)",
            ".eq('request_type', 'booking')",
            ".in('status', ['SCHEDULED','VEHICLE_RECEIVED','IN_SERVICE','READY'])",
            ".gte('scheduled_at', fromIso)",
            ".lt('scheduled_at', toIso)",
            ".limit(250)",
        ):
            self.assertIn(fragment, body)

    def test_database_migration_snapshots_duration_and_rejects_overlaps(self):
        self.assertIn("add column if not exists appointment_duration_min integer not null default 60", MIGRATION)
        self.assertIn("coalesce(s.duration_min, 60)", MIGRATION)
        self.assertIn("create trigger service_requests_set_appointment_duration", MIGRATION)
        self.assertIn("exclude using gist", MIGRATION)
        self.assertIn("service_requests_no_overlapping_appointments", MIGRATION)
        self.assertIn("with &&", MIGRATION)
        self.assertIn("'[)'", MIGRATION)
        self.assertIn("status not in ('completed','cancelled','rejected','resolved')", MIGRATION)

    def test_conflict_constraint_errors_are_explained(self):
        self.assertIn("c === '23p01'", HTML.lower())
        self.assertIn("This time overlaps another appointment. Choose a different time.", HTML)


if __name__ == "__main__":
    unittest.main()

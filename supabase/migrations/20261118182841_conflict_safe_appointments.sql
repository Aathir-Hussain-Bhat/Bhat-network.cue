-- Keep scheduled service appointments from overlapping at the same workshop.
-- The duration is snapshotted from the selected service when the appointment is scheduled;
-- general requests without a duration use a one-hour slot.

create extension if not exists btree_gist;

alter table public.service_requests
  add column if not exists appointment_duration_min integer not null default 60
  check (appointment_duration_min between 5 and 1440);

update public.service_requests as r
set appointment_duration_min = coalesce(s.duration_min, 60)
from public.workshop_services as s
where s.id = r.service_id
  and s.workshop_id = r.workshop_id
  and r.request_type = 'booking'
  and r.scheduled_at is not null;

comment on column public.service_requests.appointment_duration_min is
  'Duration captured for a scheduled booking in minutes; defaults to 60 for general service requests.';

create or replace function public.set_booking_appointment_duration()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.request_type = 'booking' and new.scheduled_at is not null then
    select coalesce(s.duration_min, 60)
      into new.appointment_duration_min
    from public.workshop_services as s
    where s.id = new.service_id
      and s.workshop_id = new.workshop_id;

    if not found then
      new.appointment_duration_min := 60;
    end if;
  end if;
  return new;
end;
$$;

create trigger service_requests_set_appointment_duration
  before insert or update of scheduled_at, service_id, workshop_id
  on public.service_requests
  for each row execute function public.set_booking_appointment_duration();

alter table public.service_requests
  add constraint service_requests_no_overlapping_appointments
  exclude using gist (
    workshop_id with =,
    (tsrange(
      scheduled_at at time zone 'UTC',
      (scheduled_at at time zone 'UTC') + appointment_duration_min * interval '1 minute',
      '[)'
    )) with &&
  )
  where (
    request_type = 'booking'
    and scheduled_at is not null
    and status not in ('COMPLETED','CANCELLED','REJECTED','RESOLVED')
  );

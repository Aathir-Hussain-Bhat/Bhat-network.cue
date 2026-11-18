-- Private workshop receipts.
-- This migration deliberately does not alter existing customer, vehicle, workshop,
-- service-record, or public-record contracts. Existing direct completion paths remain
-- compatible; new callers should use complete_ready_booking for atomic completion.

create table public.workshop_receipt_settings (
  workshop_id uuid primary key references public.workshops(id) on delete cascade,
  completion_message text,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint workshop_receipt_settings_message_length
    check (completion_message is null or length(btrim(completion_message)) between 1 and 1000)
);

create table public.workshop_receipts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.service_requests(id) on delete restrict,
  service_record_id uuid not null unique references public.service_records(id) on delete restrict,
  workshop_id uuid not null references public.workshops(id) on delete restrict,
  customer_profile_id uuid not null references public.profiles(id) on delete restrict,
  snapshot jsonb not null,
  created_at timestamptz not null default now(),
  constraint workshop_receipts_snapshot_object check (jsonb_typeof(snapshot) = 'object')
);

create index workshop_receipts_customer_idx
  on public.workshop_receipts(customer_profile_id, created_at desc);
create index workshop_receipts_workshop_idx
  on public.workshop_receipts(workshop_id, created_at desc);

create or replace function public.default_workshop_receipt_message(p_workshop uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select format('Thank you for choosing %s. We appreciate your trust in our workshop.', w.name)
  from public.workshops w
  where w.id = p_workshop;
$$;

create or replace function public.protect_workshop_receipt_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Private receipts are immutable' using errcode = '42501';
end;
$$;

create trigger workshop_receipts_immutable
  before update or delete on public.workshop_receipts
  for each row execute function public.protect_workshop_receipt_immutability();

create or replace function public.set_workshop_receipt_message(
  p_workshop uuid,
  p_message text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_message text := nullif(btrim(p_message), '');
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not public.is_workshop_member(p_workshop, array['owner','manager']) then
    raise exception 'Only a workshop owner or manager can configure receipt messages' using errcode = '42501';
  end if;
  if v_message is not null and length(v_message) > 1000 then
    raise exception 'Receipt message must be at most 1000 characters' using errcode = '22023';
  end if;
  select w.name into v_name from public.workshops w where w.id = p_workshop;
  if v_name is null then
    raise exception 'Workshop not found' using errcode = 'P0002';
  end if;

  insert into public.workshop_receipt_settings(workshop_id, completion_message, updated_by)
  values (p_workshop, v_message, auth.uid())
  on conflict (workshop_id) do update
    set completion_message = excluded.completion_message,
        updated_by = excluded.updated_by,
        updated_at = now();

  return jsonb_build_object(
    'workshop_id', p_workshop,
    'completion_message', coalesce(v_message, format('Thank you for choosing %s. We appreciate your trust in our workshop.', v_name)),
    'is_custom', v_message is not null
  );
end;
$$;

create or replace function public.get_workshop_receipt_settings(p_workshop uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_message text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not public.is_workshop_member(p_workshop, array['owner','manager']) then
    raise exception 'Only a workshop owner or manager can view receipt settings' using errcode = '42501';
  end if;
  select w.name into v_name from public.workshops w where w.id = p_workshop;
  if v_name is null then
    raise exception 'Workshop not found' using errcode = 'P0002';
  end if;
  select s.completion_message into v_message
  from public.workshop_receipt_settings s
  where s.workshop_id = p_workshop;
  return jsonb_build_object(
    'workshop_id', p_workshop,
    'completion_message', coalesce(v_message, format('Thank you for choosing %s. We appreciate your trust in our workshop.', v_name)),
    'is_custom', v_message is not null
  );
end;
$$;

create or replace function public.complete_ready_booking(
  p_booking uuid,
  p_fields jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.service_requests%rowtype;
  v_workshop public.workshops%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_customer public.profiles%rowtype;
  v_customer_address text;
  v_service_name text;
  v_service_category text;
  v_work_performed text;
  v_parts_text text;
  v_notes text;
  v_message text;
  v_record public.service_records%rowtype;
  v_receipt public.workshop_receipts%rowtype;
  v_record_date date;
  v_mileage integer;
  v_cost numeric(12,2);
  v_snapshot jsonb;
  v_allowed constant text[] := array['service_name','service_category','work_performed','parts_text','mileage_km','cost','record_date','notes'];
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'Completion fields must be a JSON object' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_fields) as k(key) where key <> all(v_allowed)) then
    raise exception 'Unsupported completion fields' using errcode = '22023';
  end if;

  select * into v_booking
  from public.service_requests
  where id = p_booking
  for update;
  if not found then
    raise exception 'Service booking not found' using errcode = 'P0002';
  end if;
  if v_booking.request_type <> 'booking' or v_booking.status <> 'READY' then
    raise exception 'Only READY bookings can be completed with a receipt' using errcode = '22023';
  end if;
  if not public.is_workshop_member(v_booking.workshop_id, array['owner','manager','staff','technician']) then
    raise exception 'Workshop access required' using errcode = '42501';
  end if;

  select * into v_workshop from public.workshops where id = v_booking.workshop_id;
  select * into v_vehicle from public.vehicles where id = v_booking.vehicle_id;
  select * into v_customer from public.profiles where id = v_booking.customer_profile_id;
  select c.address_text into v_customer_address from public.customers c where c.profile_id = v_booking.customer_profile_id;
  if v_vehicle.id is null or v_customer.id is null or v_workshop.id is null then
    raise exception 'Booking participant records are incomplete' using errcode = '23503';
  end if;
  if v_vehicle.owner_profile_id <> v_booking.customer_profile_id then
    raise exception 'Booking vehicle does not belong to the customer' using errcode = '23503';
  end if;
  if v_booking.service_id is not null and not exists (
    select 1 from public.workshop_services s
    where s.id = v_booking.service_id and s.workshop_id = v_booking.workshop_id
  ) then
    raise exception 'Selected service does not belong to the booking workshop' using errcode = '23503';
  end if;

  v_service_name := coalesce(
    nullif(btrim(p_fields ->> 'service_name'), ''),
    nullif(btrim(v_booking.service_name), ''),
    'Vehicle service'
  );
  v_service_category := coalesce(
    nullif(btrim(p_fields ->> 'service_category'), ''),
    (select nullif(btrim(s.category), '') from public.workshop_services s where s.id = v_booking.service_id),
    'general'
  );
  v_work_performed := nullif(btrim(p_fields ->> 'work_performed'), '');
  v_parts_text := nullif(btrim(p_fields ->> 'parts_text'), '');
  v_notes := nullif(btrim(p_fields ->> 'notes'), '');
  if v_service_name is null then raise exception 'Service name is required' using errcode = '22023'; end if;
  if length(v_service_name) > 200 then raise exception 'Service name must be at most 200 characters' using errcode = '22023'; end if;
  if length(v_service_category) > 100 then raise exception 'Service category must be at most 100 characters' using errcode = '22023'; end if;
  if v_work_performed is not null and length(v_work_performed) > 4000 then raise exception 'Work performed must be at most 4000 characters' using errcode = '22023'; end if;
  if v_parts_text is not null and length(v_parts_text) > 4000 then raise exception 'Parts text must be at most 4000 characters' using errcode = '22023'; end if;
  if v_notes is not null and length(v_notes) > 4000 then raise exception 'Notes must be at most 4000 characters' using errcode = '22023'; end if;

  v_record_date := coalesce(nullif(btrim(p_fields ->> 'record_date'),'')::date, current_date);
  v_mileage := case when p_fields ? 'mileage_km' and nullif(btrim(p_fields ->> 'mileage_km'),'') is not null then (btrim(p_fields ->> 'mileage_km'))::integer else null end;
  v_cost := case when p_fields ? 'cost' and nullif(btrim(p_fields ->> 'cost'),'') is not null then (btrim(p_fields ->> 'cost'))::numeric(12,2) else null end;
  if v_mileage is not null and v_mileage < 0 then raise exception 'Mileage cannot be negative' using errcode = '22023'; end if;
  if v_cost is not null and v_cost < 0 then raise exception 'Cost cannot be negative' using errcode = '22023'; end if;
  select coalesce(s.completion_message, public.default_workshop_receipt_message(v_booking.workshop_id))
    into v_message
  from public.workshop_receipt_settings s
  where s.workshop_id = v_booking.workshop_id;
  v_message := coalesce(v_message, public.default_workshop_receipt_message(v_booking.workshop_id));

  -- Keep sensitive completion details out of service_records: existing public RPCs
  -- expose those columns for every current and future record.
  insert into public.service_records(
    workshop_id, booking_id, vehicle_id, customer_profile_id, member_profile_id,
    service_name, service_category, record_date
  ) values (
    v_booking.workshop_id, v_booking.id, v_booking.vehicle_id, v_booking.customer_profile_id, auth.uid(),
    v_service_name, v_service_category, v_record_date
  ) returning * into v_record;

  v_snapshot := jsonb_build_object(
    'workshop', jsonb_build_object(
      'id', v_workshop.id, 'name', v_workshop.name, 'address_text', v_workshop.address_text,
      'area', v_workshop.area, 'district', v_workshop.district, 'city', v_workshop.city,
      'state', v_workshop.state, 'postal_code', v_workshop.postal_code, 'phone', v_workshop.phone
    ),
    'customer', jsonb_build_object(
      'profile_id', v_customer.id, 'name', v_customer.full_name, 'phone', v_customer.phone,
      'address_text', v_customer_address
    ),
    'vehicle', jsonb_build_object(
      'id', v_vehicle.id, 'make', v_vehicle.make, 'model', v_vehicle.model, 'year', v_vehicle.year,
      'vehicle_type', v_vehicle.vehicle_type, 'color', v_vehicle.color, 'plate', v_vehicle.plate
    ),
    'service', jsonb_build_object(
      'record_id', v_record.id, 'booking_id', v_booking.id, 'name', v_service_name,
      'category', v_service_category, 'date', v_record_date,
      'work_performed', v_work_performed, 'parts', v_parts_text,
      'mileage_km', v_mileage, 'cost', v_cost, 'notes', v_notes
    ),
    'message', v_message
  );

  insert into public.workshop_receipts(
    booking_id, service_record_id, workshop_id, customer_profile_id, snapshot
  ) values (
    v_booking.id, v_record.id, v_booking.workshop_id, v_booking.customer_profile_id, v_snapshot
  ) returning * into v_receipt;

  update public.service_requests
  set status = 'COMPLETED', updated_at = now()
  where id = v_booking.id;

  return jsonb_build_object('receipt_id', v_receipt.id, 'booking_id', v_booking.id, 'snapshot', v_snapshot);
exception
  when unique_violation then
    raise exception 'This booking already has a service record or receipt' using errcode = '23505';
end;
$$;

create or replace function public.get_private_receipt(p_receipt uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select r.snapshot
  from public.workshop_receipts r
  where r.id = p_receipt;
$$;

revoke all on table public.workshop_receipt_settings, public.workshop_receipts from public, anon, authenticated;
grant select on public.workshop_receipts to authenticated;

alter table public.workshop_receipt_settings enable row level security;
alter table public.workshop_receipts enable row level security;

create policy workshop_receipts_read_private on public.workshop_receipts
  for select to authenticated using (
    customer_profile_id = auth.uid()
    or public.is_workshop_member(workshop_id, array['owner','manager','staff','technician'])
  );

revoke all on function public.default_workshop_receipt_message(uuid) from public, anon, authenticated;
revoke all on function public.protect_workshop_receipt_immutability() from public, anon, authenticated;
revoke all on function public.set_workshop_receipt_message(uuid,text) from public, anon, authenticated;
revoke all on function public.get_workshop_receipt_settings(uuid) from public, anon, authenticated;
revoke all on function public.complete_ready_booking(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.get_private_receipt(uuid) from public, anon, authenticated;
grant execute on function public.set_workshop_receipt_message(uuid,text) to authenticated;
grant execute on function public.get_workshop_receipt_settings(uuid) to authenticated;
grant execute on function public.complete_ready_booking(uuid,jsonb) to authenticated;
grant execute on function public.get_private_receipt(uuid) to authenticated;

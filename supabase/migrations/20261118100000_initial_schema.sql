-- Bhat Network initial backend schema
-- Fresh project only: no legacy data is imported.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'customer' check (role in ('customer','workshop_owner','admin')),
  full_name text not null default '',
  phone text,
  district text,
  area text,
  avatar_url text,
  onboarding_complete boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customers (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  address_text text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workshops (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null unique references public.profiles(id) on delete restrict,
  name text not null check (length(btrim(name)) >= 2),
  phone text,
  district text not null,
  area text,
  address_text text,
  description text,
  status text not null default 'active' check (status in ('active','inactive','suspended')),
  is_verified boolean not null default false,
  verification_status text not null default 'PENDING' check (verification_status in ('PENDING','VERIFIED','REJECTED','SUSPENDED')),
  verification_reason text,
  photo_url text,
  open_time time,
  close_time time,
  working_days text[] not null default '{}',
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workshops_verified_flag_check check (is_verified = (verification_status = 'VERIFIED'))
);

create table public.workshop_members (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  member_role text not null default 'staff' check (member_role in ('owner','manager','staff','technician')),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workshop_id, profile_id)
);

create table public.workshop_services (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  name text not null check (length(btrim(name)) >= 2),
  category text not null,
  description text,
  duration_min integer check (duration_min between 5 and 1440),
  price_min numeric(12,2) check (price_min >= 0),
  price_max numeric(12,2) check (price_max >= 0),
  price_note text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workshop_services_price_range_check check (price_min is null or price_max is null or price_min <= price_max)
);

create table public.workshop_hours (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 1 and 7),
  is_open boolean not null default true,
  open_time time not null default '09:00',
  close_time time not null default '18:00',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workshop_id, day_of_week),
  check (close_time > open_time)
);

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid not null references public.profiles(id) on delete cascade,
  plate text not null,
  make text not null,
  model text not null,
  year integer check (year between 1950 and 2100),
  vehicle_type text,
  fuel_type text,
  nickname text,
  odometer_km integer check (odometer_km is null or odometer_km >= 0),
  is_primary boolean not null default false,
  passport_token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.service_requests (
  id uuid primary key default gen_random_uuid(),
  customer_profile_id uuid not null constraint service_requests_customer_profile_id_fkey references public.profiles(id) on delete restrict,
  workshop_id uuid references public.workshops(id) on delete set null,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  service_id uuid references public.workshop_services(id) on delete set null,
  request_type text not null check (request_type in ('booking','quick_service')),
  issue_type text,
  service_name text,
  preferred_date date,
  preferred_time time,
  scheduled_at timestamptz,
  estimated_ready_at timestamptz,
  note text check (note is null or length(note) <= 2000),
  location_text text,
  location_lat double precision check (location_lat between -90 and 90),
  location_lng double precision check (location_lng between -180 and 180),
  status text not null default 'REQUESTED' check (status in ('REQUESTED','ACCEPTED','SCHEDULED','VEHICLE_RECEIVED','IN_SERVICE','READY','COMPLETED','REJECTED','CANCELLED','DISPATCHED','IN_PROGRESS','RESOLVED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (request_type <> 'booking' or workshop_id is not null),
  check (request_type <> 'booking' or vehicle_id is not null)
);

create table public.booking_updates (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.service_requests(id) on delete cascade,
  workshop_id uuid references public.workshops(id) on delete set null,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  author_profile_id uuid not null references public.profiles(id) on delete restrict,
  title text not null,
  message text,
  created_at timestamptz not null default now()
);

create table public.booking_status_history (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.service_requests(id) on delete cascade,
  old_status text,
  new_status text not null,
  note text,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);

create table public.booking_intake (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.service_requests(id) on delete cascade,
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  received_at timestamptz not null default now(),
  mileage_km integer check (mileage_km is null or mileage_km >= 0),
  concern text,
  notes text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table public.additional_work_requests (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.service_requests(id) on delete cascade,
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  title text not null,
  reason text,
  estimated_cost numeric(12,2) check (estimated_cost is null or estimated_cost >= 0),
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','DECLINED')),
  created_by uuid not null references public.profiles(id) on delete restrict,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.service_records (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete restrict,
  booking_id uuid references public.service_requests(id) on delete set null,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  customer_profile_id uuid not null constraint service_records_customer_profile_id_fkey references public.profiles(id) on delete restrict,
  member_profile_id uuid not null constraint service_records_member_profile_id_fkey references public.profiles(id) on delete restrict,
  service_name text not null,
  service_category text not null,
  work_performed text,
  parts_text text,
  mileage_km integer check (mileage_km is null or mileage_km >= 0),
  cost numeric(12,2) check (cost is null or cost >= 0),
  record_date date not null default current_date,
  notes text,
  public_token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  message text,
  body text,
  notification_type text not null default 'general',
  entity_type text,
  entity_id uuid,
  data jsonb not null default '{}'::jsonb,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.marketplace_listings (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  title text not null check (length(btrim(title)) >= 2),
  description text,
  category text not null,
  price numeric(12,2) check (price is null or price >= 0),
  is_available boolean not null default true,
  status text not null default 'DRAFT' check (status in ('ACTIVE','DRAFT','REJECTED','SUSPENDED','REMOVED')),
  photo_urls text[] not null default '{}',
  compat_make text,
  compat_model text,
  compat_year_from integer check (compat_year_from is null or compat_year_from between 1950 and 2100),
  compat_year_to integer check (compat_year_to is null or compat_year_to between 1950 and 2100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (compat_year_from is null or compat_year_to is null or compat_year_from <= compat_year_to)
);

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor uuid constraint audit_log_actor_fkey references public.profiles(id) on delete set null,
  action text not null,
  target_type text not null,
  target_id uuid,
  reason text,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create unique index vehicles_one_primary_per_owner_idx on public.vehicles(owner_profile_id) where is_primary;
create unique index service_records_one_per_booking_idx on public.service_records(booking_id) where booking_id is not null;
create index vehicles_owner_created_idx on public.vehicles(owner_profile_id, created_at desc);
create index workshops_browse_idx on public.workshops(status, verification_status, created_at desc);
create index workshop_services_workshop_idx on public.workshop_services(workshop_id, is_active, category);
create index workshop_hours_workshop_idx on public.workshop_hours(workshop_id, day_of_week);
create index workshop_members_profile_idx on public.workshop_members(profile_id, status);
create index service_requests_customer_idx on public.service_requests(customer_profile_id, created_at desc);
create index service_requests_workshop_idx on public.service_requests(workshop_id, created_at desc);
create index service_requests_vehicle_idx on public.service_requests(vehicle_id, created_at desc);
create index booking_updates_booking_idx on public.booking_updates(booking_id, created_at desc);
create index booking_history_booking_idx on public.booking_status_history(booking_id, changed_at desc);
create index additional_work_booking_idx on public.additional_work_requests(booking_id, created_at desc);
create index service_records_vehicle_idx on public.service_records(vehicle_id, record_date desc);
create index service_records_workshop_idx on public.service_records(workshop_id, created_at desc);
create index notifications_profile_idx on public.notifications(profile_id, read, created_at desc);
create index marketplace_listings_browse_idx on public.marketplace_listings(status, category, created_at desc);
create index marketplace_listings_workshop_idx on public.marketplace_listings(workshop_id, created_at desc);

create function public.is_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;

create function public.is_workshop_member(p_workshop uuid, p_roles text[] default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.workshops w
    where w.id = p_workshop
      and ((w.owner_profile_id = auth.uid() and (p_roles is null or 'owner' = any(p_roles)))
        or exists (
          select 1 from public.workshop_members wm
          where wm.workshop_id = p_workshop and wm.profile_id = auth.uid() and wm.status = 'active'
            and (p_roles is null or wm.member_role = any(p_roles))
        ))
  );
$$;

create function public.can_view_service_request(p_request uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_admin() or exists (
    select 1 from public.service_requests r
    where r.id = p_request and (
      r.customer_profile_id = auth.uid()
      or public.is_workshop_member(r.workshop_id, array['owner','manager','staff','technician'])
    )
  );
$$;

create function public.can_view_vehicle(p_vehicle uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_admin() or exists (
    select 1 from public.vehicles v where v.id = p_vehicle and v.owner_profile_id = auth.uid()
  ) or exists (
    select 1 from public.service_requests r where r.vehicle_id = p_vehicle and public.is_workshop_member(r.workshop_id)
  ) or exists (
    select 1 from public.service_records sr where sr.vehicle_id = p_vehicle
      and (sr.customer_profile_id = auth.uid() or public.is_workshop_member(sr.workshop_id))
  );
$$;

create function public.can_view_profile(p_profile uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_admin() or p_profile = auth.uid()
    or exists (
      select 1 from public.service_requests r
      where (r.customer_profile_id = p_profile and public.is_workshop_member(r.workshop_id))
         or (r.customer_profile_id = auth.uid() and (
             exists (select 1 from public.workshops w where w.id = r.workshop_id and w.owner_profile_id = p_profile)
             or exists (select 1 from public.workshop_members wm where wm.workshop_id = r.workshop_id and wm.profile_id = p_profile and wm.status = 'active')
         ))
    )
    or exists (
      select 1 from public.service_records sr
      where (sr.customer_profile_id = p_profile and public.is_workshop_member(sr.workshop_id))
         or (sr.customer_profile_id = auth.uid() and sr.member_profile_id = p_profile)
    );
$$;

create function public.touch_updated_at()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
begin
  v_role := case when new.raw_user_meta_data ->> 'role' = 'workshop_owner' then 'workshop_owner' else 'customer' end;
  insert into public.profiles(id, role, full_name, phone)
  values (new.id, v_role, coalesce(new.raw_user_meta_data ->> 'full_name',''), nullif(new.raw_user_meta_data ->> 'phone',''))
  on conflict (id) do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_auth_user();

create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();
create trigger customers_touch_updated_at before update on public.customers for each row execute function public.touch_updated_at();
create trigger workshops_touch_updated_at before update on public.workshops for each row execute function public.touch_updated_at();
create trigger workshop_members_touch_updated_at before update on public.workshop_members for each row execute function public.touch_updated_at();
create trigger workshop_services_touch_updated_at before update on public.workshop_services for each row execute function public.touch_updated_at();
create trigger workshop_hours_touch_updated_at before update on public.workshop_hours for each row execute function public.touch_updated_at();
create trigger vehicles_touch_updated_at before update on public.vehicles for each row execute function public.touch_updated_at();
create trigger marketplace_listings_touch_updated_at before update on public.marketplace_listings for each row execute function public.touch_updated_at();

create function public.protect_profile_role()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only an administrator can change profile roles' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger profiles_protect_role before update on public.profiles
  for each row execute function public.protect_profile_role();

create function public.add_workshop_owner_member()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.workshop_members(workshop_id, profile_id, member_role)
  values (new.id, new.owner_profile_id, 'owner') on conflict (workshop_id, profile_id) do nothing;
  return new;
end;
$$;
create trigger workshops_add_owner_member after insert on public.workshops
  for each row execute function public.add_workshop_owner_member();

create function public.protect_workshop_verification()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and (new.is_verified is distinct from old.is_verified or new.verification_status is distinct from old.verification_status or new.verification_reason is distinct from old.verification_reason) then
    raise exception 'Workshop verification is administrator-managed' using errcode = '42501';
  end if;
  if new.verification_status is distinct from old.verification_status then
    new.is_verified := (new.verification_status = 'VERIFIED');
  end if;
  return new;
end;
$$;
create trigger workshops_protect_verification before update on public.workshops
  for each row execute function public.protect_workshop_verification();

create function public.set_primary_vehicle()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.is_primary then
    update public.vehicles set is_primary = false
    where owner_profile_id = new.owner_profile_id and id <> new.id and is_primary;
  end if;
  return new;
end;
$$;
create trigger vehicles_set_primary before insert or update of is_primary on public.vehicles
  for each row execute function public.set_primary_vehicle();

create function public.protect_listing_status()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and auth.uid() is not null and not public.is_admin()
     and not public.is_workshop_member(old.workshop_id, array['owner','manager']) then
    raise exception 'Only workshop managers or administrators can change listing status' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and auth.uid() is not null and not public.is_admin()
     and new.status not in ('ACTIVE','DRAFT') then
    raise exception 'Workshop members may publish or draft their own listings only' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger marketplace_listings_protect_status before update on public.marketplace_listings
  for each row execute function public.protect_listing_status();

create function public.protect_request_update()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  if auth.uid() is null or public.is_admin() then return new; end if;

  if new.customer_profile_id is distinct from old.customer_profile_id
     or new.workshop_id is distinct from old.workshop_id
     or new.request_type is distinct from old.request_type
     or new.created_at is distinct from old.created_at then
    raise exception 'Request ownership and type are immutable' using errcode = '42501';
  end if;

  if old.customer_profile_id = auth.uid() then
    if new.status is distinct from old.status and (new.status <> 'CANCELLED' or old.status in ('COMPLETED','REJECTED','CANCELLED','RESOLVED')) then
      raise exception 'Customers may only cancel an open request' using errcode = '42501';
    end if;
    if (to_jsonb(new) - array['vehicle_id','service_id','service_name','preferred_date','preferred_time','note','status','updated_at'])
       is distinct from
       (to_jsonb(old) - array['vehicle_id','service_id','service_name','preferred_date','preferred_time','note','status','updated_at']) then
      raise exception 'Customers cannot change workshop-managed request fields' using errcode = '42501';
    end if;
    if new.status is distinct from old.status and new.status <> 'CANCELLED' then
      raise exception 'Invalid customer status change' using errcode = '42501';
    end if;
    if new.status is not distinct from old.status and old.status <> 'REQUESTED'
       and (new.vehicle_id is distinct from old.vehicle_id or new.service_id is distinct from old.service_id
         or new.service_name is distinct from old.service_name or new.preferred_date is distinct from old.preferred_date
         or new.preferred_time is distinct from old.preferred_time or new.note is distinct from old.note) then
      raise exception 'Only requested bookings may be edited' using errcode = '42501';
    end if;
  elsif public.is_workshop_member(old.workshop_id, array['owner','manager','staff','technician']) then
    if (to_jsonb(new) - array['status','scheduled_at','estimated_ready_at','updated_at'])
       is distinct from
       (to_jsonb(old) - array['status','scheduled_at','estimated_ready_at','updated_at']) then
      raise exception 'Workshop members cannot change customer or request ownership fields' using errcode = '42501';
    end if;
    if new.status is distinct from old.status then
      if old.status in ('COMPLETED','REJECTED','CANCELLED','RESOLVED') then
        raise exception 'Closed requests cannot be changed' using errcode = '42501';
      end if;
      if new.status not in ('ACCEPTED','SCHEDULED','VEHICLE_RECEIVED','IN_SERVICE','READY','COMPLETED','REJECTED','CANCELLED','DISPATCHED','IN_PROGRESS','RESOLVED') then
        raise exception 'Invalid service request status' using errcode = '22023';
      end if;
      if new.status = 'CANCELLED' then return new; end if;
      if new.status = 'REJECTED' and old.status = 'REQUESTED' then return new; end if;
      if old.request_type = 'booking' and not (
        (old.status = 'REQUESTED' and new.status = 'ACCEPTED') or
        (old.status = 'ACCEPTED' and new.status = 'SCHEDULED') or
        (old.status = 'SCHEDULED' and new.status = 'VEHICLE_RECEIVED') or
        (old.status = 'VEHICLE_RECEIVED' and new.status = 'IN_SERVICE') or
        (old.status = 'IN_SERVICE' and new.status = 'READY') or
        (old.status = 'READY' and new.status = 'COMPLETED')) then
        raise exception 'Invalid booking status transition' using errcode = '22023';
      end if;
      if old.request_type = 'quick_service' and not (
        (old.status = 'REQUESTED' and new.status = 'ACCEPTED') or
        (old.status = 'ACCEPTED' and new.status = 'DISPATCHED') or
        (old.status = 'DISPATCHED' and new.status = 'IN_PROGRESS') or
        (old.status = 'IN_PROGRESS' and new.status = 'RESOLVED')) then
        raise exception 'Invalid quick-service status transition' using errcode = '22023';
      end if;
    end if;
  else
    raise exception 'Not authorized to update this request' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger service_requests_guard before update on public.service_requests
  for each row execute function public.protect_request_update();

create function public.log_request_event()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_owner uuid;
  v_target uuid;
  v_title text;
begin
  if tg_op = 'INSERT' then
    insert into public.booking_status_history(booking_id, old_status, new_status, note, changed_by)
    values (new.id, null, new.status, 'Request created', auth.uid());
    if new.workshop_id is not null then
      select owner_profile_id into v_owner from public.workshops where id = new.workshop_id;
      if v_owner is not null and v_owner <> new.customer_profile_id then
        insert into public.notifications(profile_id, title, message, notification_type, entity_type, entity_id)
        values (v_owner, 'New service request', coalesce(new.service_name,new.issue_type,'A customer sent a request'), 'service_request', 'service_request', new.id);
      end if;
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.booking_status_history(booking_id, old_status, new_status, changed_by)
    values (new.id, old.status, new.status, auth.uid());
    v_title := case new.status
      when 'ACCEPTED' then 'Request accepted' when 'SCHEDULED' then 'Appointment scheduled'
      when 'VEHICLE_RECEIVED' then 'Vehicle received' when 'IN_SERVICE' then 'Service started'
      when 'READY' then 'Vehicle ready' when 'COMPLETED' then 'Service completed'
      when 'REJECTED' then 'Request declined' when 'CANCELLED' then 'Request cancelled'
      when 'DISPATCHED' then 'Help dispatched' when 'IN_PROGRESS' then 'Service in progress'
      when 'RESOLVED' then 'Request resolved' else 'Request updated' end;
    if auth.uid() = new.customer_profile_id then
      if new.workshop_id is not null then
        select owner_profile_id into v_target from public.workshops where id = new.workshop_id;
      end if;
    else
      v_target := new.customer_profile_id;
    end if;
    if v_target is not null then
      insert into public.notifications(profile_id, title, message, notification_type, entity_type, entity_id)
      values (v_target, v_title, coalesce(new.service_name,new.issue_type,'Service request') || ' · ' || new.status, 'service_request', 'service_request', new.id);
    end if;
  end if;
  return new;
end;
$$;
create trigger service_requests_log after insert or update of status on public.service_requests
  for each row execute function public.log_request_event();

create function public.protect_additional_work_response()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  if auth.uid() is null or public.is_admin() then return new; end if;
  if new.booking_id is distinct from old.booking_id or new.workshop_id is distinct from old.workshop_id
     or new.vehicle_id is distinct from old.vehicle_id or new.title is distinct from old.title
     or new.reason is distinct from old.reason or new.estimated_cost is distinct from old.estimated_cost
     or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'Additional work details are immutable after submission' using errcode = '42501';
  end if;
  if old.status <> 'PENDING' or old.created_by = auth.uid() then
    raise exception 'Only the customer may respond to a pending additional-work request' using errcode = '42501';
  end if;
  if not exists (select 1 from public.service_requests r where r.id = old.booking_id and r.customer_profile_id = auth.uid()) then
    raise exception 'Not authorized to respond to this request' using errcode = '42501';
  end if;
  if new.status not in ('APPROVED','DECLINED') then
    raise exception 'Response must be APPROVED or DECLINED' using errcode = '22023';
  end if;
  new.responded_at := now();
  return new;
end;
$$;
create trigger additional_work_response_guard before update on public.additional_work_requests
  for each row execute function public.protect_additional_work_response();

create function public.protect_notification_update()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_admin() and (
    new.profile_id is distinct from old.profile_id or new.title is distinct from old.title
    or new.message is distinct from old.message or new.body is distinct from old.body
    or new.notification_type is distinct from old.notification_type or new.entity_type is distinct from old.entity_type
    or new.entity_id is distinct from old.entity_id or new.data is distinct from old.data
    or new.created_at is distinct from old.created_at
  ) then
    raise exception 'Only notification read state can be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger notifications_guard before update on public.notifications
  for each row execute function public.protect_notification_update();

create function public.notify_additional_work()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_customer uuid;
begin
  if tg_op = 'INSERT' then
    select customer_profile_id into v_customer from public.service_requests where id = new.booking_id;
    if v_customer is not null then
      insert into public.notifications(profile_id,title,message,notification_type,entity_type,entity_id)
      values (v_customer,'Approval needed',new.title,'additional_work','additional_work',new.id);
    end if;
  elsif new.status is distinct from old.status then
    insert into public.notifications(profile_id,title,message,notification_type,entity_type,entity_id)
    select w.owner_profile_id,'Additional work response',new.status,'additional_work','additional_work',new.id
    from public.workshops w where w.id = new.workshop_id;
  end if;
  return new;
end;
$$;
create trigger additional_work_notify after insert or update of status on public.additional_work_requests
  for each row execute function public.notify_additional_work();

create function public.transition_service_request(
  p_request uuid,
  p_status text,
  p_changes jsonb default '{}'::jsonb,
  p_note text default null
)
returns public.service_requests
language plpgsql security definer
set search_path = ''
as $$
declare
  v_request public.service_requests%rowtype;
  v_result public.service_requests%rowtype;
  v_is_customer boolean;
  v_is_member boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' then raise exception 'Changes must be a JSON object' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_object_keys(p_changes) as k(key) where key not in ('scheduled_at','estimated_ready_at')) then
    raise exception 'Unsupported request fields in transition' using errcode = '22023';
  end if;
  select * into v_request from public.service_requests where id = p_request for update;
  if not found then raise exception 'Service request not found' using errcode = 'P0002'; end if;
  v_is_customer := v_request.customer_profile_id = auth.uid();
  v_is_member := public.is_workshop_member(v_request.workshop_id, array['owner','manager','staff','technician']);
  if not public.is_admin() and not v_is_customer and not v_is_member then raise exception 'Not authorized' using errcode = '42501'; end if;
  if v_is_customer and p_status <> 'CANCELLED' then raise exception 'Customers may only cancel a request' using errcode = '42501'; end if;
  if not v_is_customer and not public.is_admin() and not v_is_member then raise exception 'Workshop access required' using errcode = '42501'; end if;
  if p_status not in ('ACCEPTED','SCHEDULED','VEHICLE_RECEIVED','IN_SERVICE','READY','COMPLETED','REJECTED','CANCELLED','DISPATCHED','IN_PROGRESS','RESOLVED') then
    raise exception 'Invalid request status' using errcode = '22023';
  end if;
  update public.service_requests set
    status = p_status,
    scheduled_at = case when p_changes ? 'scheduled_at' then nullif(p_changes ->> 'scheduled_at','')::timestamptz else scheduled_at end,
    estimated_ready_at = case when p_changes ? 'estimated_ready_at' then nullif(p_changes ->> 'estimated_ready_at','')::timestamptz else estimated_ready_at end,
    updated_at = now()
  where id = p_request returning * into v_result;
  return v_result;
end;
$$;

create function public.admin_set_workshop_verification(p_workshop uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_old jsonb; v_new jsonb;
begin
  if not public.is_admin() then raise exception 'Administrator access required' using errcode = '42501'; end if;
  if p_status not in ('PENDING','VERIFIED','REJECTED','SUSPENDED') then raise exception 'Invalid verification status' using errcode = '22023'; end if;
  select to_jsonb(w) into v_old from public.workshops w where w.id = p_workshop for update;
  if v_old is null then raise exception 'Workshop not found' using errcode = 'P0002'; end if;
  update public.workshops set verification_status = p_status, is_verified = (p_status = 'VERIFIED'), verification_reason = nullif(btrim(p_reason),'')
  where id = p_workshop returning to_jsonb(workshops) into v_new;
  insert into public.audit_log(actor,action,target_type,target_id,reason,old_data,new_data)
  values (auth.uid(),'workshop_verification_changed','workshop',p_workshop,nullif(btrim(p_reason),''),v_old,v_new);
  return jsonb_build_object('id',p_workshop,'verification_status',p_status);
end;
$$;

create function public.admin_set_listing_status(p_listing uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_old jsonb; v_new jsonb;
begin
  if not public.is_admin() then raise exception 'Administrator access required' using errcode = '42501'; end if;
  if p_status not in ('ACTIVE','DRAFT','REJECTED','SUSPENDED','REMOVED') then raise exception 'Invalid listing status' using errcode = '22023'; end if;
  select to_jsonb(l) into v_old from public.marketplace_listings l where l.id = p_listing for update;
  if v_old is null then raise exception 'Listing not found' using errcode = 'P0002'; end if;
  update public.marketplace_listings set status = p_status, updated_at = now() where id = p_listing returning to_jsonb(marketplace_listings) into v_new;
  insert into public.audit_log(actor,action,target_type,target_id,reason,old_data,new_data)
  values (auth.uid(),'marketplace_listing_status_changed','marketplace_listing',p_listing,nullif(btrim(p_reason),''),v_old,v_new);
  return jsonb_build_object('id',p_listing,'status',p_status);
end;
$$;

create function public.admin_set_member_role(p_member uuid, p_role text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_old jsonb; v_new jsonb;
begin
  if not public.is_admin() then raise exception 'Administrator access required' using errcode = '42501'; end if;
  if p_role not in ('owner','manager','staff','technician') then raise exception 'Invalid member role' using errcode = '22023'; end if;
  select to_jsonb(m) into v_old from public.workshop_members m where m.id = p_member for update;
  if v_old is null then raise exception 'Workshop member not found' using errcode = 'P0002'; end if;
  update public.workshop_members set member_role = p_role, updated_at = now() where id = p_member returning to_jsonb(workshop_members) into v_new;
  insert into public.audit_log(actor,action,target_type,target_id,reason,old_data,new_data)
  values (auth.uid(),'workshop_member_role_changed','workshop_member',p_member,nullif(btrim(p_reason),''),v_old,v_new);
  return jsonb_build_object('id',p_member,'member_role',p_role);
end;
$$;

create function public.public_passport(p_token text)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'make', v.make, 'model', v.model, 'year', v.year, 'vehicle_type', v.vehicle_type,
    'service_count', count(sr.id),
    'records', coalesce(jsonb_agg(jsonb_build_object(
      'id', sr.id, 'service_name', sr.service_name, 'service_category', sr.service_category,
      'record_date', sr.record_date, 'mileage_km', sr.mileage_km, 'cost', sr.cost,
      'work_performed', sr.work_performed, 'parts_text', sr.parts_text,
      'workshop_name', w.name, 'workshop', jsonb_build_object('name',w.name,'area',w.area,'district',w.district)
    ) order by sr.record_date desc, sr.created_at desc) filter (where sr.id is not null), '[]'::jsonb)
  )
  from public.vehicles v
  left join public.service_records sr on sr.vehicle_id = v.id
  left join public.workshops w on w.id = sr.workshop_id
  where v.passport_token = p_token
  group by v.id;
$$;

create function public.public_service_record(p_token text)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id', sr.id, 'service_name', sr.service_name, 'service_category', sr.service_category,
    'work_performed', sr.work_performed, 'parts_text', sr.parts_text, 'mileage_km', sr.mileage_km,
    'cost', sr.cost, 'record_date', sr.record_date, 'notes', sr.notes, 'public_token', sr.public_token,
    'workshop', jsonb_build_object('id',w.id,'name',w.name,'area',w.area,'district',w.district),
    'member', jsonb_build_object('full_name',p.full_name)
  )
  from public.service_records sr
  join public.workshops w on w.id = sr.workshop_id
  left join public.profiles p on p.id = sr.member_profile_id
  where sr.public_token = p_token;
$$;

create function public.public_workshop(p_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id',w.id,'name',w.name,'description',w.description,'phone',w.phone,
    'district',w.district,'area',w.area,'address_text',w.address_text,'status',w.status,
    'is_verified',w.is_verified,'verification_status',w.verification_status,
    'photo_url',w.photo_url,'open_time',w.open_time,'close_time',w.close_time,
    'working_days',w.working_days,'latitude',w.latitude,'longitude',w.longitude,
    'created_at',w.created_at,
    'services',coalesce((select jsonb_agg(to_jsonb(s) - 'workshop_id' order by s.name) from public.workshop_services s where s.workshop_id=w.id and s.is_active),'[]'::jsonb),
    'hours',coalesce((select jsonb_agg(to_jsonb(h) - 'workshop_id' order by h.day_of_week) from public.workshop_hours h where h.workshop_id=w.id),'[]'::jsonb)
  )
  from public.workshops w
  where w.id = p_id and w.status='active' and w.verification_status <> 'SUSPENDED';
$$;

revoke all on function public.is_admin() from public, anon, authenticated;
revoke all on function public.is_workshop_member(uuid,text[]) from public, anon, authenticated;
revoke all on function public.can_view_service_request(uuid) from public, anon, authenticated;
revoke all on function public.can_view_vehicle(uuid) from public, anon, authenticated;
revoke all on function public.can_view_profile(uuid) from public, anon, authenticated;
revoke all on function public.touch_updated_at() from public, anon, authenticated;
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.protect_profile_role() from public, anon, authenticated;
revoke all on function public.add_workshop_owner_member() from public, anon, authenticated;
revoke all on function public.protect_workshop_verification() from public, anon, authenticated;
revoke all on function public.set_primary_vehicle() from public, anon, authenticated;
revoke all on function public.protect_listing_status() from public, anon, authenticated;
revoke all on function public.protect_request_update() from public, anon, authenticated;
revoke all on function public.log_request_event() from public, anon, authenticated;
revoke all on function public.protect_additional_work_response() from public, anon, authenticated;
revoke all on function public.protect_notification_update() from public, anon, authenticated;
revoke all on function public.notify_additional_work() from public, anon, authenticated;
revoke all on function public.transition_service_request(uuid,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.admin_set_workshop_verification(uuid,text,text) from public, anon, authenticated;
revoke all on function public.admin_set_listing_status(uuid,text,text) from public, anon, authenticated;
revoke all on function public.admin_set_member_role(uuid,text,text) from public, anon, authenticated;
revoke all on function public.public_passport(text) from public, anon, authenticated;
revoke all on function public.public_service_record(text) from public, anon, authenticated;
revoke all on function public.public_workshop(uuid) from public, anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.is_workshop_member(uuid,text[]) to anon, authenticated;
grant execute on function public.can_view_service_request(uuid) to authenticated;
grant execute on function public.can_view_vehicle(uuid) to authenticated;
grant execute on function public.can_view_profile(uuid) to authenticated;
grant execute on function public.transition_service_request(uuid,text,jsonb,text) to authenticated;
grant execute on function public.admin_set_workshop_verification(uuid,text,text) to authenticated;
grant execute on function public.admin_set_listing_status(uuid,text,text) to authenticated;
grant execute on function public.admin_set_member_role(uuid,text,text) to authenticated;
grant execute on function public.public_passport(text) to anon, authenticated;
grant execute on function public.public_service_record(text) to anon, authenticated;
grant execute on function public.public_workshop(uuid) to anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on public.workshops, public.workshop_services, public.workshop_hours, public.marketplace_listings to anon;

alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.workshops enable row level security;
alter table public.workshop_members enable row level security;
alter table public.workshop_services enable row level security;
alter table public.workshop_hours enable row level security;
alter table public.vehicles enable row level security;
alter table public.service_requests enable row level security;
alter table public.booking_updates enable row level security;
alter table public.booking_status_history enable row level security;
alter table public.booking_intake enable row level security;
alter table public.additional_work_requests enable row level security;
alter table public.service_records enable row level security;
alter table public.notifications enable row level security;
alter table public.marketplace_listings enable row level security;
alter table public.audit_log enable row level security;

create policy profiles_read_related on public.profiles for select to authenticated using (public.can_view_profile(id));
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id = auth.uid() and role in ('customer','workshop_owner'));
create policy profiles_update_self_or_admin on public.profiles for update to authenticated using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());

create policy customers_read_self_or_admin on public.customers for select to authenticated using (profile_id = auth.uid() or public.is_admin());
create policy customers_insert_self on public.customers for insert to authenticated with check (profile_id = auth.uid());
create policy customers_update_self on public.customers for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy workshops_public_or_member_read on public.workshops for select to anon, authenticated using (
  (status = 'active' and verification_status <> 'SUSPENDED') or owner_profile_id = auth.uid()
  or public.is_workshop_member(id) or public.is_admin()
);
create policy workshops_owner_insert on public.workshops for insert to authenticated with check (
  owner_profile_id = auth.uid() and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'workshop_owner')
);
create policy workshops_owner_update on public.workshops for update to authenticated using (owner_profile_id = auth.uid() or public.is_admin()) with check (owner_profile_id = auth.uid() or public.is_admin());

create policy workshop_members_read_related on public.workshop_members for select to authenticated using (
  profile_id = auth.uid() or public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin()
);
create policy workshop_members_owner_manage on public.workshop_members for all to authenticated using (
  public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin()
) with check (public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin());

create policy workshop_services_public_or_member_read on public.workshop_services for select to anon, authenticated using (
  exists (select 1 from public.workshops w where w.id=workshop_id and w.status='active' and w.verification_status <> 'SUSPENDED')
  or public.is_workshop_member(workshop_id) or public.is_admin()
);
create policy workshop_services_owner_manage on public.workshop_services for all to authenticated using (
  public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin()
) with check (public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin());

create policy workshop_hours_public_or_member_read on public.workshop_hours for select to anon, authenticated using (
  exists (select 1 from public.workshops w where w.id=workshop_id and w.status='active' and w.verification_status <> 'SUSPENDED')
  or public.is_workshop_member(workshop_id) or public.is_admin()
);
create policy workshop_hours_owner_manage on public.workshop_hours for all to authenticated using (
  public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin()
) with check (public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin());

create policy vehicles_owner_or_service_read on public.vehicles for select to authenticated using (owner_profile_id=auth.uid() or public.can_view_vehicle(id));
create policy vehicles_insert_owner on public.vehicles for insert to authenticated with check (owner_profile_id=auth.uid());
create policy vehicles_update_owner on public.vehicles for update to authenticated using (owner_profile_id=auth.uid() or public.is_admin()) with check (owner_profile_id=auth.uid() or public.is_admin());
create policy vehicles_delete_owner on public.vehicles for delete to authenticated using (owner_profile_id=auth.uid() or public.is_admin());

create policy service_requests_read_participants on public.service_requests for select to authenticated using (
  customer_profile_id=auth.uid() or public.is_workshop_member(workshop_id) or public.is_admin()
);
create policy service_requests_create_customer on public.service_requests for insert to authenticated with check (
  customer_profile_id=auth.uid()
  and (vehicle_id is null or exists (select 1 from public.vehicles v where v.id=vehicle_id and v.owner_profile_id=auth.uid()))
  and (workshop_id is null or exists (select 1 from public.workshops w where w.id=workshop_id and w.status='active' and w.verification_status <> 'SUSPENDED'))
);
create policy service_requests_update_participants on public.service_requests for update to authenticated using (
  customer_profile_id=auth.uid() or public.is_workshop_member(workshop_id) or public.is_admin()
) with check (customer_profile_id=auth.uid() or public.is_workshop_member(workshop_id) or public.is_admin());

create policy booking_status_history_read_participants on public.booking_status_history for select to authenticated using (public.can_view_service_request(booking_id));
create policy booking_updates_read_participants on public.booking_updates for select to authenticated using (public.can_view_service_request(booking_id));
create policy booking_updates_insert_participant on public.booking_updates for insert to authenticated with check (
  author_profile_id=auth.uid() and exists (
    select 1 from public.service_requests r where r.id=booking_id and r.workshop_id is not distinct from workshop_id
      and (r.customer_profile_id=auth.uid() or public.is_workshop_member(r.workshop_id))
  )
);

create policy booking_intake_read_participants on public.booking_intake for select to authenticated using (public.can_view_service_request(booking_id));
create policy booking_intake_insert_workshop on public.booking_intake for insert to authenticated with check (
  created_by=auth.uid() and public.is_workshop_member(workshop_id,array['owner','manager','staff','technician'])
  and exists (select 1 from public.service_requests r where r.id=booking_id and r.workshop_id=booking_intake.workshop_id and r.vehicle_id is not distinct from booking_intake.vehicle_id)
);

create policy additional_work_read_participants on public.additional_work_requests for select to authenticated using (public.can_view_service_request(booking_id));
create policy additional_work_insert_workshop on public.additional_work_requests for insert to authenticated with check (
  created_by=auth.uid() and public.is_workshop_member(workshop_id,array['owner','manager','staff','technician'])
  and exists (select 1 from public.service_requests r where r.id=booking_id and r.workshop_id=additional_work_requests.workshop_id and r.vehicle_id is not distinct from additional_work_requests.vehicle_id)
);
create policy additional_work_customer_respond on public.additional_work_requests for update to authenticated using (
  exists (select 1 from public.service_requests r where r.id=booking_id and r.customer_profile_id=auth.uid())
) with check (exists (select 1 from public.service_requests r where r.id=booking_id and r.customer_profile_id=auth.uid()));

create policy service_records_read_participants on public.service_records for select to authenticated using (
  customer_profile_id=auth.uid() or public.is_workshop_member(workshop_id) or public.is_admin()
);
create policy service_records_insert_workshop on public.service_records for insert to authenticated with check (
  member_profile_id=auth.uid() and public.is_workshop_member(workshop_id,array['owner','manager','staff','technician'])
  and exists (select 1 from public.vehicles v where v.id=vehicle_id and v.owner_profile_id=customer_profile_id)
  and (booking_id is null or exists (
    select 1 from public.service_requests r where r.id=booking_id and r.workshop_id=service_records.workshop_id
      and r.vehicle_id=service_records.vehicle_id and r.customer_profile_id=service_records.customer_profile_id
  ))
);

create policy notifications_read_self on public.notifications for select to authenticated using (profile_id=auth.uid());
create policy notifications_update_self on public.notifications for update to authenticated using (profile_id=auth.uid()) with check (profile_id=auth.uid());

create policy marketplace_listings_public_or_member_read on public.marketplace_listings for select to anon, authenticated using (
  (status='ACTIVE' and exists (select 1 from public.workshops w where w.id=workshop_id and w.status='active' and w.verification_status <> 'SUSPENDED'))
  or public.is_workshop_member(workshop_id) or public.is_admin()
);
create policy marketplace_listings_owner_insert on public.marketplace_listings for insert to authenticated with check (
  public.is_workshop_member(workshop_id,array['owner','manager']) and status in ('ACTIVE','DRAFT')
);
create policy marketplace_listings_owner_update on public.marketplace_listings for update to authenticated using (
  public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin()
) with check (public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin());
create policy marketplace_listings_owner_delete on public.marketplace_listings for delete to authenticated using (
  public.is_workshop_member(workshop_id,array['owner','manager']) or public.is_admin()
);

create policy audit_log_admin_read on public.audit_log for select to authenticated using (public.is_admin());

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values
  ('profile-photos','profile-photos',true,5242880,array['image/jpeg','image/png','image/webp']),
  ('workshop-photos','workshop-photos',true,8388608,array['image/jpeg','image/png','image/webp']),
  ('marketplace-photos','marketplace-photos',true,8388608,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=excluded.public, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

create policy bhat_public_photo_read on storage.objects for select to anon, authenticated using (bucket_id in ('profile-photos','workshop-photos','marketplace-photos'));
create policy bhat_photo_insert_own_folder on storage.objects for insert to authenticated with check (
  bucket_id in ('profile-photos','workshop-photos','marketplace-photos') and (storage.foldername(name))[1]=auth.uid()::text
);
create policy bhat_photo_update_own_folder on storage.objects for update to authenticated using (
  bucket_id in ('profile-photos','workshop-photos','marketplace-photos') and (storage.foldername(name))[1]=auth.uid()::text
) with check (
  bucket_id in ('profile-photos','workshop-photos','marketplace-photos') and (storage.foldername(name))[1]=auth.uid()::text
);
create policy bhat_photo_delete_own_folder on storage.objects for delete to authenticated using (
  bucket_id in ('profile-photos','workshop-photos','marketplace-photos') and (storage.foldername(name))[1]=auth.uid()::text
);

do $$
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='service_requests') then
    alter publication supabase_realtime add table public.service_requests;
  end if;
end;
$$;

-- Helpful explicit indexes and policies are intentionally scoped to the Bhat Network tables/buckets only.

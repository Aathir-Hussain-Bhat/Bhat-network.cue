-- Workshop verification applications, completed-service reviews, and private money tracking.
-- This migration is additive. It preserves admin_set_workshop_verification,
-- existing audit/notification flows, private receipt RLS, and all public QR RPCs.

-- Applications are kept separately from workshops so applicant notes are never
-- exposed by public workshop reads or the generic admin data editor.
create table public.workshop_verification_applications (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete restrict,
  applicant_profile_id uuid not null references public.profiles(id) on delete restrict,
  application_note text,
  submitted_at timestamptz not null default transaction_timestamp(),
  constraint workshop_verification_application_note_length
    check (application_note is null or length(btrim(application_note)) between 1 and 1000)
);

create index workshop_verification_applications_latest_idx
  on public.workshop_verification_applications(workshop_id, submitted_at desc);

alter table public.workshop_verification_applications enable row level security;
revoke all on table public.workshop_verification_applications from public, anon, authenticated;
grant select on table public.workshop_verification_applications to authenticated;

create policy workshop_verification_applications_read_owner_or_admin
  on public.workshop_verification_applications
  for select to authenticated
  using (applicant_profile_id = auth.uid() or public.is_admin());

create or replace function public.protect_workshop_verification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and (new.is_verified is distinct from old.is_verified
          or new.verification_status is distinct from old.verification_status
          or new.verification_reason is distinct from old.verification_reason) then
    -- A rejected workshop may return to PENDING only within the same transaction
    -- that records its owner's application through the security-definer RPC below.
    if not (
      old.owner_profile_id = auth.uid()
      and old.verification_status = 'REJECTED'
      and new.verification_status = 'PENDING'
      and new.is_verified is false
      and new.verification_reason is null
      and exists (
        select 1
        from public.workshop_verification_applications a
        where a.workshop_id = old.id
          and a.applicant_profile_id = auth.uid()
          and a.submitted_at = transaction_timestamp()
      )
    ) then
      raise exception 'Workshop verification is administrator-managed' using errcode = '42501';
    end if;
  end if;
  if new.verification_status is distinct from old.verification_status then
    new.is_verified := (new.verification_status = 'VERIFIED');
  end if;
  return new;
end;
$$;

revoke all on function public.protect_workshop_verification() from public, anon, authenticated;

create or replace function public.audit_workshop_verification_application()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_log(actor, action, target_type, target_id, reason, old_data, new_data)
  values (
    new.applicant_profile_id,
    'workshop_verification_application_submitted',
    'workshop',
    new.workshop_id,
    'Workshop verification application submitted',
    null,
    jsonb_build_object('application_id', new.id, 'submitted_at', new.submitted_at)
  );
  return new;
end;
$$;
revoke all on function public.audit_workshop_verification_application() from public, anon, authenticated;
create trigger workshop_verification_applications_audit
  after insert on public.workshop_verification_applications
  for each row execute function public.audit_workshop_verification_application();

create or replace function public.notify_admins_workshop_verification_application()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_status text;
begin
  select w.name, w.verification_status into v_name, v_status
  from public.workshops w where w.id = new.workshop_id;
  insert into public.notifications(
    profile_id, title, message, body, notification_type, entity_type, entity_id, data
  )
  select p.id,
         'New workshop verification application',
         format('%s submitted verification details.', coalesce(v_name, 'A workshop')),
         format('%s submitted verification details.', coalesce(v_name, 'A workshop')),
         'workshop_verification_application',
         'workshop',
         new.workshop_id,
         jsonb_build_object('workshop_id', new.workshop_id, 'application_id', new.id)
  from public.profiles p
  where p.role = 'admin' and v_status <> 'REJECTED';
  return new;
end;
$$;
revoke all on function public.notify_admins_workshop_verification_application() from public, anon, authenticated;
create trigger workshop_verification_applications_notify_admins
  after insert on public.workshop_verification_applications
  for each row execute function public.notify_admins_workshop_verification_application();

create or replace function public.submit_workshop_verification_application(
  p_workshop uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workshop public.workshops%rowtype;
  v_application public.workshop_verification_applications%rowtype;
  v_note text := nullif(btrim(p_note), '');
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if v_note is not null and length(v_note) > 1000 then
    raise exception 'Application note must be at most 1000 characters' using errcode = '22023';
  end if;

  select * into v_workshop
  from public.workshops
  where id = p_workshop
  for update;
  if not found then
    raise exception 'Workshop not found' using errcode = 'P0002';
  end if;
  if v_workshop.owner_profile_id <> auth.uid() then
    raise exception 'Only the workshop owner can submit a verification application' using errcode = '42501';
  end if;
  if v_workshop.verification_status in ('VERIFIED', 'SUSPENDED') then
    raise exception 'This workshop cannot submit an application in its current status' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.workshop_verification_applications a
    where a.workshop_id = p_workshop
      and a.applicant_profile_id = auth.uid()
      and a.submitted_at > transaction_timestamp() - interval '1 minute'
  ) then
    raise exception 'Please wait a minute before sending another application update' using errcode = '22023';
  end if;

  insert into public.workshop_verification_applications(
    workshop_id, applicant_profile_id, application_note
  ) values (p_workshop, auth.uid(), v_note)
  returning * into v_application;

  if v_workshop.verification_status = 'REJECTED' then
    update public.workshops
    set verification_status = 'PENDING', is_verified = false, verification_reason = null
    where id = p_workshop;
    v_workshop.verification_status := 'PENDING';
  end if;

  return jsonb_build_object(
    'id', v_application.id,
    'application_note', v_application.application_note,
    'submitted_at', v_application.submitted_at,
    'verification_status', v_workshop.verification_status
  );
end;
$$;
revoke all on function public.submit_workshop_verification_application(uuid,text) from public, anon, authenticated;
grant execute on function public.submit_workshop_verification_application(uuid,text) to authenticated;

-- Reviews can only be created for a completed booking with its immutable private
-- receipt. The table itself is not exposed; customers use scoped RPCs and public
-- workshop profiles receive an explicit non-identifying projection.
create table public.service_reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.service_requests(id) on delete restrict,
  service_record_id uuid not null unique references public.service_records(id) on delete restrict,
  workshop_id uuid not null references public.workshops(id) on delete restrict,
  customer_profile_id uuid not null references public.profiles(id) on delete restrict,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  constraint service_review_comment_length
    check (comment is null or length(btrim(comment)) <= 1500)
);

create index service_reviews_workshop_latest_idx
  on public.service_reviews(workshop_id, created_at desc);
alter table public.service_reviews enable row level security;
revoke all on table public.service_reviews from public, anon, authenticated;

create or replace function public.get_service_review_for_booking(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request public.service_requests%rowtype;
  v_record uuid;
  v_review jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select * into v_request from public.service_requests where id = p_booking;
  if not found or v_request.customer_profile_id <> auth.uid() then
    return jsonb_build_object('eligible', false, 'review', null);
  end if;
  if v_request.request_type <> 'booking' or v_request.status <> 'COMPLETED' then
    return jsonb_build_object('eligible', false, 'review', null);
  end if;

  select r.id into v_record
  from public.service_records r
  join public.workshop_receipts wr
    on wr.service_record_id = r.id
   and wr.booking_id = v_request.id
   and wr.workshop_id = v_request.workshop_id
   and wr.customer_profile_id = v_request.customer_profile_id
  where r.booking_id = v_request.id
    and r.workshop_id = v_request.workshop_id
    and r.customer_profile_id = v_request.customer_profile_id
  limit 1;
  if v_record is null then
    return jsonb_build_object('eligible', false, 'review', null);
  end if;

  select jsonb_build_object('rating', sr.rating, 'comment', sr.comment, 'created_at', sr.created_at)
    into v_review
  from public.service_reviews sr
  where sr.booking_id = v_request.id
    and sr.service_record_id = v_record
    and sr.customer_profile_id = auth.uid();

  return jsonb_build_object('eligible', true, 'review', v_review);
end;
$$;
revoke all on function public.get_service_review_for_booking(uuid) from public, anon, authenticated;
grant execute on function public.get_service_review_for_booking(uuid) to authenticated;

create or replace function public.submit_service_review(
  p_booking uuid,
  p_rating integer,
  p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.service_requests%rowtype;
  v_record uuid;
  v_comment text := nullif(btrim(p_comment), '');
  v_review public.service_reviews%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'Choose a rating from 1 to 5' using errcode = '22023';
  end if;
  if v_comment is not null and length(v_comment) > 1500 then
    raise exception 'Review must be at most 1500 characters' using errcode = '22023';
  end if;

  select * into v_request
  from public.service_requests
  where id = p_booking
  for update;
  if not found or v_request.customer_profile_id <> auth.uid() then
    raise exception 'Completed service not found for this customer' using errcode = '42501';
  end if;
  if v_request.request_type <> 'booking' or v_request.status <> 'COMPLETED' then
    raise exception 'Reviews are available only for completed services' using errcode = '22023';
  end if;

  select r.id into v_record
  from public.service_records r
  join public.workshop_receipts wr
    on wr.service_record_id = r.id
   and wr.booking_id = v_request.id
   and wr.workshop_id = v_request.workshop_id
   and wr.customer_profile_id = v_request.customer_profile_id
  where r.booking_id = v_request.id
    and r.workshop_id = v_request.workshop_id
    and r.customer_profile_id = v_request.customer_profile_id
  limit 1;
  if v_record is null then
    raise exception 'A verified completion receipt is required before reviewing' using errcode = '22023';
  end if;

  insert into public.service_reviews(
    booking_id, service_record_id, workshop_id, customer_profile_id, rating, comment
  ) values (
    v_request.id, v_record, v_request.workshop_id, auth.uid(), p_rating::smallint, v_comment
  ) returning * into v_review;

  return jsonb_build_object(
    'rating', v_review.rating,
    'comment', v_review.comment,
    'created_at', v_review.created_at
  );
end;
$$;
revoke all on function public.submit_service_review(uuid,integer,text) from public, anon, authenticated;
grant execute on function public.submit_service_review(uuid,integer,text) to authenticated;

create or replace function public.public_workshop_reviews(p_workshop uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'review_count', (select count(*) from public.service_reviews r where r.workshop_id = p_workshop),
    'average_rating', (select round(avg(r.rating)::numeric, 1) from public.service_reviews r where r.workshop_id = p_workshop),
    'reviews', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'rating', recent.rating,
          'comment', recent.comment,
          'created_at', recent.created_at,
          'service_name', recent.service_name
        ) order by recent.created_at desc
      )
      from (
        select r.rating, r.comment, r.created_at, sr.service_name
        from public.service_reviews r
        join public.service_records sr on sr.id = r.service_record_id
        join public.service_requests q on q.id = r.booking_id
        where r.workshop_id = p_workshop
          and sr.booking_id = r.booking_id
          and q.status = 'COMPLETED'
        order by r.created_at desc
        limit 20
      ) recent
    ), '[]'::jsonb)
  );
$$;
revoke all on function public.public_workshop_reviews(uuid) from public, anon, authenticated;
grant execute on function public.public_workshop_reviews(uuid) to anon, authenticated;

-- Manually entered items are append-only and separate from service receipt amounts.
-- The UI labels them as workshop-entered and never treats estimates or listing
-- prices as earned or paid money.
create table public.workshop_money_entries (
  id uuid primary key default gen_random_uuid(),
  workshop_id uuid not null references public.workshops(id) on delete restrict,
  created_by_profile_id uuid not null references public.profiles(id) on delete restrict,
  entry_type text not null check (entry_type in ('income', 'expense')),
  category text not null,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  entry_date date not null default current_date,
  created_at timestamptz not null default now(),
  constraint workshop_money_entry_category_length
    check (length(btrim(category)) between 1 and 60),
  constraint workshop_money_entry_description_length
    check (length(btrim(description)) between 1 and 300)
);

create index workshop_money_entries_latest_idx
  on public.workshop_money_entries(workshop_id, entry_date desc, created_at desc);
alter table public.workshop_money_entries enable row level security;
revoke all on table public.workshop_money_entries from public, anon, authenticated;

create or replace function public.protect_workshop_money_entry_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Workshop money entries are append-only; add a correcting entry instead' using errcode = '42501';
end;
$$;
revoke all on function public.protect_workshop_money_entry_immutability() from public, anon, authenticated;
create trigger workshop_money_entries_immutable
  before update or delete on public.workshop_money_entries
  for each row execute function public.protect_workshop_money_entry_immutability();

create or replace function public.add_workshop_money_entry(
  p_workshop uuid,
  p_type text,
  p_category text,
  p_description text,
  p_amount numeric,
  p_entry_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text := nullif(btrim(p_category), '');
  v_description text := nullif(btrim(p_description), '');
  v_entry public.workshop_money_entries%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_workshop is null or not public.is_workshop_member(p_workshop, array['owner','manager']) then
    raise exception 'Only a workshop owner or manager can add money entries' using errcode = '42501';
  end if;
  if p_type is null or p_type not in ('income', 'expense') then
    raise exception 'Choose income or expense' using errcode = '22023';
  end if;
  if v_category is null or length(v_category) > 60 then
    raise exception 'Category must be between 1 and 60 characters' using errcode = '22023';
  end if;
  if v_description is null or length(v_description) > 300 then
    raise exception 'Description must be between 1 and 300 characters' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 9999999999.99 then
    raise exception 'Amount must be greater than zero and within the supported range' using errcode = '22023';
  end if;

  insert into public.workshop_money_entries(
    workshop_id, created_by_profile_id, entry_type, category, description, amount, entry_date
  ) values (
    p_workshop, auth.uid(), p_type, v_category, v_description, p_amount, coalesce(p_entry_date, current_date)
  ) returning * into v_entry;

  return jsonb_build_object(
    'id', v_entry.id,
    'entry_type', v_entry.entry_type,
    'category', v_entry.category,
    'description', v_entry.description,
    'amount', v_entry.amount,
    'entry_date', v_entry.entry_date,
    'created_at', v_entry.created_at
  );
end;
$$;
revoke all on function public.add_workshop_money_entry(uuid,text,text,text,numeric,date) from public, anon, authenticated;
grant execute on function public.add_workshop_money_entry(uuid,text,text,text,numeric,date) to authenticated;

create or replace function public.workshop_earnings_summary(p_workshop uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_service_amount numeric(14,2) := 0;
  v_completed_services integer := 0;
  v_service_amount_count integer := 0;
  v_service_amount_missing_count integer := 0;
  v_manual_income numeric(14,2) := 0;
  v_manual_expenses numeric(14,2) := 0;
  v_manual_entry_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_workshop is null or not public.is_workshop_member(p_workshop, array['owner','manager','staff','technician']) then
    raise exception 'Workshop access required' using errcode = '42501';
  end if;

  select
    coalesce(sum(nullif(wr.snapshot #>> '{service,cost}', '')::numeric), 0)::numeric(14,2),
    count(*)::integer,
    count(*) filter (where nullif(wr.snapshot #>> '{service,cost}', '') is not null)::integer,
    count(*) filter (where nullif(wr.snapshot #>> '{service,cost}', '') is null)::integer
  into v_service_amount, v_completed_services, v_service_amount_count, v_service_amount_missing_count
  from public.workshop_receipts wr
  join public.service_requests q on q.id = wr.booking_id and q.status = 'COMPLETED'
  join public.service_records r on r.id = wr.service_record_id and r.booking_id = q.id
  where wr.workshop_id = p_workshop;

  select
    coalesce(sum(e.amount) filter (where e.entry_type = 'income'), 0)::numeric(14,2),
    coalesce(sum(e.amount) filter (where e.entry_type = 'expense'), 0)::numeric(14,2),
    count(*)::integer
  into v_manual_income, v_manual_expenses, v_manual_entry_count
  from public.workshop_money_entries e
  where e.workshop_id = p_workshop;

  return jsonb_build_object(
    'currency_code', 'INR',
    'summary', jsonb_build_object(
      'completed_services', v_completed_services,
      'service_amount_total', v_service_amount,
      'service_amount_count', v_service_amount_count,
      'service_amount_missing_count', v_service_amount_missing_count,
      'workshop_entered_income', v_manual_income,
      'workshop_entered_expenses', v_manual_expenses,
      'workshop_entered_net', v_manual_income - v_manual_expenses,
      'recorded_difference', v_service_amount + v_manual_income - v_manual_expenses,
      'manual_entry_count', v_manual_entry_count
    ),
    'services', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'record_id', recent.id,
          'service_name', recent.service_name,
          'record_date', recent.record_date,
          'amount', recent.amount
        ) order by recent.record_date desc, recent.id
      )
      from (
        select
          r.id,
          r.service_name,
          coalesce(nullif(wr.snapshot #>> '{service,date}', '')::date, r.record_date) as record_date,
          nullif(wr.snapshot #>> '{service,cost}', '')::numeric(12,2) as amount
        from public.workshop_receipts wr
        join public.service_requests q on q.id = wr.booking_id and q.status = 'COMPLETED'
        join public.service_records r on r.id = wr.service_record_id and r.booking_id = q.id
        where wr.workshop_id = p_workshop
        order by coalesce(nullif(wr.snapshot #>> '{service,date}', '')::date, r.record_date) desc, r.id
        limit 100
      ) recent
    ), '[]'::jsonb),
    'manual_entries', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'entry_type', recent.entry_type,
          'category', recent.category,
          'description', recent.description,
          'amount', recent.amount,
          'entry_date', recent.entry_date,
          'created_at', recent.created_at
        ) order by recent.entry_date desc, recent.created_at desc
      )
      from (
        select e.entry_type, e.category, e.description, e.amount, e.entry_date, e.created_at
        from public.workshop_money_entries e
        where e.workshop_id = p_workshop
        order by e.entry_date desc, e.created_at desc
        limit 100
      ) recent
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.workshop_earnings_summary(uuid) from public, anon, authenticated;
grant execute on function public.workshop_earnings_summary(uuid) to authenticated;

-- Admin CRUD, audited role/verification changes, and workshop verification notifications.
--
-- The existing app models a verification application as a public.workshops row;
-- this migration therefore does not introduce a parallel application table.
-- No anonymous grants or public QR/passport RPCs are changed.
--
-- Bootstrap remains an operational step: use bootstrap-admin.sql only after
-- confirming the target auth identity's email. This migration does not grant a
-- callable role-escalation path to authenticated users.

-- Existing authenticated table grants are broad, but RLS did not consistently
-- provide an admin path for every app-owned table. Keep the path authenticated
-- only and leave audit/private receipt tables intentionally excluded.
create policy profiles_admin_all on public.profiles
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy customers_admin_all on public.customers
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy workshops_admin_all on public.workshops
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy workshop_members_admin_all on public.workshop_members
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy workshop_services_admin_all on public.workshop_services
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy workshop_hours_admin_all on public.workshop_hours
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy vehicles_admin_all on public.vehicles
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy service_requests_admin_all on public.service_requests
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy booking_updates_admin_all on public.booking_updates
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy booking_status_history_admin_all on public.booking_status_history
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy booking_intake_admin_all on public.booking_intake
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy additional_work_requests_admin_all on public.additional_work_requests
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy service_records_admin_all on public.service_records
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy marketplace_listings_admin_all on public.marketplace_listings
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Do not add an admin bypass to notifications: an administrator may read only
-- notifications addressed to that administrator, just like any other user.
-- Do not add an admin bypass to audit_log or private workshop receipts.

-- The existing update guard does not cover INSERT. Owners must not be able to
-- create a workshop with a pre-approved badge or an administrator's reason.
create or replace function public.guard_workshop_verification_on_insert()
returns trigger language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and (new.verification_status is distinct from 'PENDING'
          or new.is_verified is distinct from false
          or new.verification_reason is not null) then
    raise exception 'Workshop verification is administrator-managed' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_workshop_verification_on_insert() from public, anon, authenticated;
create trigger workshops_guard_verification_on_insert
before insert on public.workshops
for each row execute function public.guard_workshop_verification_on_insert();

create or replace function public.audit_profile_role_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.role is distinct from old.role then
    insert into public.audit_log(actor, action, target_type, target_id, reason, old_data, new_data)
    values (
      auth.uid(),
      'profile_role_changed',
      'profile',
      new.id,
      'Role changed by an administrator',
      jsonb_build_object('role', old.role),
      jsonb_build_object('role', new.role)
    );
  end if;
  return new;
end;
$$;

revoke all on function public.audit_profile_role_change() from public, anon, authenticated;

create trigger profiles_audit_role_change
after update of role on public.profiles
for each row execute function public.audit_profile_role_change();

create or replace function public.audit_workshop_verification_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.verification_status is distinct from old.verification_status
     or new.is_verified is distinct from old.is_verified
     or new.verification_reason is distinct from old.verification_reason then
    insert into public.audit_log(actor, action, target_type, target_id, reason, old_data, new_data)
    values (
      auth.uid(),
      'workshop_verification_changed',
      'workshop',
      new.id,
      nullif(btrim(new.verification_reason), ''),
      jsonb_build_object(
        'verification_status', old.verification_status,
        'is_verified', old.is_verified,
        'verification_reason', old.verification_reason
      ),
      jsonb_build_object(
        'verification_status', new.verification_status,
        'is_verified', new.is_verified,
        'verification_reason', new.verification_reason
      )
    );
  end if;
  return new;
end;
$$;

revoke all on function public.audit_workshop_verification_change() from public, anon, authenticated;

create trigger workshops_audit_verification_change
after update of verification_status, is_verified, verification_reason on public.workshops
for each row execute function public.audit_workshop_verification_change();

create or replace function public.notify_admins_workshop_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text;
  v_message text;
  v_type text;
begin
  if tg_op = 'INSERT' then
    v_title := 'New workshop verification application';
    v_message := format('%s is awaiting verification.', new.name);
    v_type := 'workshop_verification_application';
  elsif new.verification_status is distinct from old.verification_status then
    v_title := 'Workshop verification status updated';
    v_message := format('%s is now %s.', new.name, new.verification_status);
    v_type := 'workshop_verification_status';
  else
    return new;
  end if;

  -- The trigger derives recipients from the protected role column. Callers
  -- cannot choose a recipient, inject notification rows, or expose workshop
  -- data to non-admin profiles through this path.
  insert into public.notifications(
    profile_id, title, message, body, notification_type, entity_type, entity_id, data
  )
  select p.id, v_title, v_message, v_message, v_type, 'workshop', new.id,
         jsonb_build_object('workshop_id', new.id, 'verification_status', new.verification_status)
  from public.profiles p
  where p.role = 'admin';

  return new;
end;
$$;

revoke all on function public.notify_admins_workshop_verification() from public, anon, authenticated;

create trigger workshops_notify_admins_on_application
after insert on public.workshops
for each row execute function public.notify_admins_workshop_verification();

create trigger workshops_notify_admins_on_verification_status
after update of verification_status on public.workshops
for each row execute function public.notify_admins_workshop_verification();

-- Existing admin_set_workshop_verification already performs its own audit
-- insert. Replace it so the verification audit is emitted exactly once by the
-- trigger above, including direct admin CRUD updates through RLS.
create or replace function public.admin_set_workshop_verification(
  p_workshop uuid,
  p_status text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new jsonb;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if not public.is_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_status not in ('PENDING','VERIFIED','REJECTED','SUSPENDED') then
    raise exception 'Invalid verification status' using errcode = '22023';
  end if;
  if not exists (select 1 from public.workshops where id = p_workshop) then
    raise exception 'Workshop not found' using errcode = 'P0002';
  end if;

  update public.workshops
  set verification_status = p_status,
      is_verified = (p_status = 'VERIFIED'),
      verification_reason = v_reason
  where id = p_workshop
  returning jsonb_build_object(
    'id', id,
    'verification_status', verification_status,
    'is_verified', is_verified
  ) into v_new;

  return v_new;
end;
$$;

revoke all on function public.admin_set_workshop_verification(uuid,text,text) from public, anon, authenticated;
grant execute on function public.admin_set_workshop_verification(uuid,text,text) to authenticated;


-- The existing admin dashboard calls this aggregate RPC. It returns no rows or
-- profile/email data and cannot be used by a non-admin to probe table contents.
create or replace function public.admin_metrics()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'users', (select count(*) from public.profiles),
    'customers', (select count(*) from public.customers),
    'workshops', (select count(*) from public.workshops),
    'pending_verifications', (select count(*) from public.workshops where verification_status = 'PENDING'),
    'suspended', (select count(*) from public.workshops where verification_status = 'SUSPENDED'),
    'bookings', (select count(*) from public.service_requests where request_type = 'booking'),
    'quick_requests', (select count(*) from public.service_requests where request_type = 'quick_service'),
    'completed_services', (select count(*) from public.service_requests where status = 'COMPLETED'),
    'active_listings', (select count(*) from public.marketplace_listings where status = 'ACTIVE')
  );
end;
$$;

revoke all on function public.admin_metrics() from public, anon, authenticated;
grant execute on function public.admin_metrics() to authenticated;

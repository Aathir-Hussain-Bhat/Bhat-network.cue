-- Run once only after the owner's account has been created and email-confirmed.
-- Replace the placeholder email before running. Expected result: UPDATE 1.
update public.profiles as p
set role = 'admin', onboarding_complete = true, updated_at = now()
from auth.users as u
where p.id = u.id
  and lower(u.email) = lower('REPLACE_WITH_CONFIRMED_OWNER_EMAIL')
  and u.email_confirmed_at is not null;

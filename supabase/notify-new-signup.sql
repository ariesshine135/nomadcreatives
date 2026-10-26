-- Email a notification for every new row in public.beta_signups.
--
-- How it works: an AFTER INSERT trigger calls the Resend email API through
-- pg_net. pg_net is asynchronous, so a slow or failed email never blocks or
-- breaks the signup itself.
--
-- One-time setup:
--   1. Create a free account at https://resend.com and make an API key.
--   2. In Supabase: Database > Extensions > enable "pg_net" (if not already on).
--   3. Fill in the two values in STEP 1 below, then paste this whole file into
--      Supabase > SQL Editor and click Run.
--   4. Test it by signing up on the site with any email.
--
-- Note: until you verify your own domain in Resend, the sender must be
-- onboarding@resend.dev, and Resend only delivers to the email address you
-- signed up to Resend with. Use that address as the recipient.

create extension if not exists pg_net;

-- STEP 1: store the API key and recipient as secrets (kept out of this repo).
-- Run once. To change a value later, delete it under Settings > Vault first.
select vault.create_secret('re_REPLACE_WITH_YOUR_RESEND_API_KEY', 'resend_api_key');
select vault.create_secret('you@example.com', 'signup_notify_to');

-- STEP 2: the function that sends the email.
create or replace function public.notify_new_beta_signup()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  api_key   text;
  recipient text;
begin
  select decrypted_secret into api_key
    from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  select decrypted_secret into recipient
    from vault.decrypted_secrets where name = 'signup_notify_to' limit 1;

  if api_key is null or recipient is null then
    raise warning 'beta signup email skipped: Vault secrets not set';
    return new;
  end if;

  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || api_key,
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object(
      'from',    'FeedBecky Beta <onboarding@resend.dev>',
      'to',      jsonb_build_array(recipient),
      'subject', 'New beta signup: ' || new.email,
      'text',    'Someone just joined the FeedBecky beta waitlist.' || chr(10) || chr(10)
                 || 'Email: ' || new.email || chr(10)
                 || 'Signed up: ' || to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI') || ' UTC'
    )
  );
  return new;
exception when others then
  -- Never let a notification problem reject a signup.
  raise warning 'beta signup email failed: %', sqlerrm;
  return new;
end;
$$;

-- STEP 3: run the function after each new signup.
drop trigger if exists on_beta_signup_notify on public.beta_signups;
create trigger on_beta_signup_notify
  after insert on public.beta_signups
  for each row execute function public.notify_new_beta_signup();

-- Troubleshooting: recent email API responses (status 200 = sent).
-- select id, status_code, content, created from net._http_response order by created desc limit 5;

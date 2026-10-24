-- =====================================================
-- SPOIAD update: editable payment account, editable course prices,
-- certificate signature and public certificate verification.
-- Safe to run more than once. Run the whole file in
-- Supabase > SQL Editor > New query > paste > Run
-- =====================================================

-- 1. Settings table (payment account, prices, certificate signature)
create table if not exists public.settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;

drop policy if exists "settings_read" on public.settings;
-- Everyone may read the prices (they are shown on public pages).
-- Only logged-in users may read the payment account and certificate settings.
create policy "settings_read" on public.settings
  for select to anon, authenticated
  using (key = 'prices' or auth.uid() is not null);

revoke insert, update, delete on public.settings from anon, authenticated;

-- 2. Default values (never overwrites what you have already saved)
insert into public.settings (key, value) values
  ('payment', '{"bank":"Kuda Bank","number":"2013463188","name":"","note":"Use your reference as the transfer narration, then send your proof of payment on WhatsApp."}'::jsonb),
  ('certificate', '{"signatory":"","title":"Programme Director"}'::jsonb),
  ('prices', '{"word":5000,"excel":6000,"powerpoint":5000,"web":12000,"design":8000,"video":10000,"marketing":9000,"dataentry":4500,"computer":3000,"data":12000,"backend":15000,"frontend":10000,"corel":8000,"ai":12000,"va":9000,"uiux":10000}'::jsonb)
on conflict (key) do nothing;

-- 3. Admin-only function that saves a setting
create or replace function public.set_setting(p_key text, p_value jsonb)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Not allowed'; end if;
  if p_key not in ('payment','certificate','prices') then raise exception 'Unknown setting'; end if;
  insert into public.settings (key, value, updated_at) values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end;
$$;
revoke all on function public.set_setting(text, jsonb) from public, anon;
grant execute on function public.set_setting(text, jsonb) to authenticated;

-- 4. Each registration remembers the price it was shown.
--    The price is set by the server, so students cannot change it.
alter table public.enrollments add column if not exists amount integer;

create or replace function public.enrollment_set_amount()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  select nullif(value ->> new.course_id, '')::integer into new.amount
  from public.settings where key = 'prices';
  return new;
end;
$$;

drop trigger if exists enrollment_amount on public.enrollments;
create trigger enrollment_amount
  before insert on public.enrollments
  for each row execute function public.enrollment_set_amount();

-- 5. Public certificate verification (anyone with the ID can check it)
create or replace function public.verify_certificate(p_cert text)
returns table (student_name text, course_id text, completed_at timestamptz)
language sql security definer stable
set search_path = public
as $$
  select p.name, e.course_id, e.completed_at
  from public.enrollments e
  join public.profiles p on p.id = e.user_id
  where e.cert_id = upper(trim(p_cert)) and e.status = 'active'
  limit 1;
$$;
revoke all on function public.verify_certificate(text) from public;
grant execute on function public.verify_certificate(text) to anon, authenticated;

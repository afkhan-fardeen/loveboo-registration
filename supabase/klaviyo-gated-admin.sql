-- Run once in the Supabase SQL Editor BEFORE deploying the matching code.

-- 1. Only registrations confirmed by Klaviyo are shown in admin.
alter table public.registrations
  add column if not exists klaviyo_synced boolean not null default false;

-- Rows that already exist were collected before this flag; keep them visible.
update public.registrations set klaviyo_synced = true where klaviyo_synced = false;

-- 2. Let the logged-in admin edit prizes (name, quantity, image).
drop policy if exists "admin update prizes" on public.prizes;
create policy "admin update prizes" on public.prizes
  for update to authenticated using (true) with check (true);

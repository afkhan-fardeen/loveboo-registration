-- Run once in the Supabase SQL Editor. Safe to run before OR after deploying
-- the matching code (the page falls back gracefully if this isn't applied).

-- 1. Idempotent registrations: the page sends a client-generated id with every
--    registration, so a retry after a lost response can't create a duplicate.
alter table public.registrations add column if not exists client_id uuid;
create unique index if not exists registrations_client_id_key on public.registrations (client_id);

-- 2. Fast admin listing for thousands of rows.
create index if not exists registrations_created_at_idx on public.registrations (created_at desc);

-- 3. Server-side spin: weighted pick + stock claim in one atomic step, so odds
--    can't be tampered with from the browser. Weights = remaining stock;
--    unlimited prizes weigh as much as the largest limited stock; "Try Again"
--    always has a 25% share. Returns {"kind":"try_again"} or
--    {"kind":"prize","id":...,"name":...,"image_url":...}.
create or replace function public.spin_wheel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  try_again_share constant numeric := 0.25;
  unlimited_w numeric;
  total numeric;
  roll numeric;
  acc numeric := 0;
  p record;
  picked prizes.id%type;
  won record;
begin
  select greatest(1, coalesce(max(quantity - given_count), 0)) into unlimited_w
    from prizes where active and quantity is not null and given_count < quantity;

  select coalesce(sum(case when quantity is null then unlimited_w else quantity - given_count end), 0)
    into total
    from prizes where active and (quantity is null or given_count < quantity);

  if total <= 0 then
    return jsonb_build_object('kind', 'try_again');
  end if;

  roll := random() * (total / (1 - try_again_share));
  if roll >= total then
    return jsonb_build_object('kind', 'try_again');
  end if;

  for p in
    select id, quantity, given_count from prizes
    where active and (quantity is null or given_count < quantity)
    order by sort_order, id
  loop
    acc := acc + case when p.quantity is null then unlimited_w else p.quantity - p.given_count end;
    if roll < acc then picked := p.id; exit; end if;
  end loop;

  -- Atomic claim: only succeeds while stock remains (guards concurrent spins).
  update prizes set given_count = given_count + 1
   where id = picked and (quantity is null or given_count < quantity)
  returning id, name, image_url into won;

  if not found then
    return jsonb_build_object('kind', 'try_again');
  end if;

  return jsonb_build_object('kind', 'prize', 'id', won.id, 'name', won.name, 'image_url', won.image_url);
end;
$$;

revoke all on function public.spin_wheel() from public;
grant execute on function public.spin_wheel() to anon, authenticated;

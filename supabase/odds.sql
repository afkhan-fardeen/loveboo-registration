-- Explicit odds for the wheel: a "chance" weight per prize, and an adjustable Try Again share.
-- Run once in the Supabase SQL Editor of the registration project (after daily-limit.sql). Safe to run again.
--
-- How it works
--   * prizes.weight: the prize's relative chance. Empty (null) = weight by remaining stock, as before.
--   * wheel_settings.try_again_pct: the share of every spin that lands on "Try Again" (a first Try Again
--     gives a free re-spin, so guests end up with nothing far less often than this number).
--   * A prize's chance of winning a spin = weight / (sum of the weights of the prizes that can be won right
--     now) x (100% - Try Again share). Sold-out prizes and prizes at their daily cap drop out automatically.

alter table public.prizes add column if not exists weight numeric
  check (weight is null or weight >= 0);

create table if not exists public.wheel_settings (
  id int primary key default 1 check (id = 1),
  try_again_pct numeric not null default 25 check (try_again_pct >= 0 and try_again_pct <= 90)
);
insert into public.wheel_settings (id, try_again_pct) values (1, 25) on conflict (id) do nothing;
alter table public.wheel_settings enable row level security;
drop policy if exists "admin manages wheel settings" on public.wheel_settings;
create policy "admin manages wheel settings" on public.wheel_settings
  for all to authenticated using (true) with check (true);

-- The wheel on the page loads this view; it now also carries the weight.
create or replace view public.prizes_available as
select p.id, p.name, p.image_url, p.quantity, p.given_count, p.daily_limit, p.sort_order, p.weight
from public.prizes p
where p.active
  and (p.quantity is null or p.given_count < p.quantity)
  and (p.daily_limit is null
       or coalesce((select d.given from public.prize_daily d
                    where d.prize_id = p.id and d.day = (now() at time zone 'Asia/Dubai')::date), 0) < p.daily_limit);
grant select on public.prizes_available to anon, authenticated;

create or replace function public.spin_wheel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ta numeric := coalesce((select try_again_pct from wheel_settings where id = 1), 25) / 100;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  unlimited_w numeric;
  total numeric;
  roll numeric;
  acc numeric := 0;
  p record;
  picked prizes.id%type;
  won record;
  claimed int;
begin
  select greatest(1, coalesce(max(quantity - given_count), 0)) into unlimited_w
    from prizes_available where quantity is not null;

  -- weight if set, otherwise remaining stock (unlimited prizes weigh as much as the largest stock)
  select coalesce(sum(coalesce(weight, case when quantity is null then unlimited_w else quantity - given_count end)), 0)
    into total from prizes_available;

  if total <= 0 then
    return jsonb_build_object('kind', 'try_again');
  end if;

  roll := random() * (total / (1 - v_ta));
  if roll >= total then
    return jsonb_build_object('kind', 'try_again');
  end if;

  for p in select id, quantity, given_count, weight from prizes_available order by sort_order, id
  loop
    acc := acc + coalesce(p.weight, case when p.quantity is null then unlimited_w else p.quantity - p.given_count end);
    if roll < acc then picked := p.id; exit; end if;
  end loop;

  update prizes set given_count = given_count + 1
   where id = picked and (quantity is null or given_count < quantity)
  returning id, name, image_url, daily_limit into won;

  if not found then
    return jsonb_build_object('kind', 'try_again');
  end if;

  if won.daily_limit is not null then
    insert into prize_daily (prize_id, day, given) values (won.id, v_today, 1)
      on conflict (prize_id, day) do update set given = prize_daily.given + 1
      where prize_daily.given < won.daily_limit;
    get diagnostics claimed = row_count;
    if claimed = 0 then
      update prizes set given_count = given_count - 1 where id = won.id;
      return jsonb_build_object('kind', 'try_again');
    end if;
  end if;

  return jsonb_build_object('kind', 'prize', 'id', won.id, 'name', won.name, 'image_url', won.image_url);
end;
$$;

revoke all on function public.spin_wheel() from public;
grant execute on function public.spin_wheel() to anon, authenticated;

-- Starting odds: the two 50ml sets are pushed hard, the special gifts stay rare, Try Again 10%.
-- Per guest (including the free re-spin) that is about: 3 x 50ml 46%, 6 x 50ml 46%, Mama Set 3.5%,
-- Detangle Set 2%, Mystery Gift 0.5%, nothing 1%. Change any of these later in the admin.
update public.wheel_settings set try_again_pct = 10 where id = 1;
update public.prizes set weight = 46  where name = '3 × 50ml Products';
update public.prizes set weight = 46  where name = '6 × 50ml Products';
update public.prizes set weight = 3.5 where name = 'Mama Set';
update public.prizes set weight = 2   where name = 'Detangle Set';
update public.prizes set weight = 0.5 where name = 'Mystery Gift';

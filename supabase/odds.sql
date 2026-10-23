-- Wheel odds you control: a "chance" weight per prize (one for parents, one for non-parents), an adjustable
-- Try Again share, and daily caps. Run once in the Supabase SQL Editor of the registration project, after
-- daily-limit.sql. Safe to run again.
--
-- The rules
--   * STOCK IS ONLY FOR YOUR OWN TRACKING. prizes.quantity and given_count are counted and shown in the admin,
--     but they never take a gift off the wheel and never change anyone's odds.
--   * A gift's chance = its weight / the sum of the weights of the gifts on the wheel. Parents use
--     prizes.weight; guests who answered "No" to "Are you a parent?" use prizes.weight_non_parent
--     (falling back to weight when that is empty). Empty weights count as 1.
--   * Only two things take a gift off the wheel: switching it off ("Hidden" in the admin) and its daily cap.
--   * wheel_settings.try_again_pct: the share of a first spin that lands on "Try Again". That gives a free
--     re-spin, and the re-spin is guaranteed to be a gift (p_final = true never returns Try Again).

alter table public.prizes add column if not exists weight numeric check (weight is null or weight >= 0);
alter table public.prizes add column if not exists weight_non_parent numeric check (weight_non_parent is null or weight_non_parent >= 0);

create table if not exists public.wheel_settings (
  id int primary key default 1 check (id = 1),
  try_again_pct numeric not null default 25 check (try_again_pct >= 0 and try_again_pct <= 90)
);
insert into public.wheel_settings (id, try_again_pct) values (1, 25) on conflict (id) do nothing;
alter table public.wheel_settings enable row level security;
drop policy if exists "admin manages wheel settings" on public.wheel_settings;
create policy "admin manages wheel settings" on public.wheel_settings
  for all to authenticated using (true) with check (true);
drop policy if exists "anyone reads wheel settings" on public.wheel_settings;
create policy "anyone reads wheel settings" on public.wheel_settings
  for select to anon, authenticated using (true);

-- The gifts on the wheel right now: switched on and under today's daily cap. Stock is NOT considered.
create or replace view public.prizes_available as
select p.id, p.name, p.image_url, p.quantity, p.given_count, p.daily_limit, p.sort_order, p.weight, p.weight_non_parent
from public.prizes p
where p.active
  and (p.daily_limit is null
       or coalesce((select d.given from public.prize_daily d
                    where d.prize_id = p.id and d.day = (now() at time zone 'Asia/Dubai')::date), 0) < p.daily_limit);
grant select on public.prizes_available to anon, authenticated;

-- spin_wheel(p_final, p_parent):
--   p_final  = the guest's last spin (their second, after a Try Again): never Try Again.
--   p_parent = false for guests who answered "No" to "Are you a parent?".
drop function if exists public.spin_wheel();
drop function if exists public.spin_wheel(boolean);
create or replace function public.spin_wheel(p_final boolean default false, p_parent boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ta numeric := case when p_final then 0 else coalesce((select try_again_pct from wheel_settings where id = 1), 25) / 100 end;
  v_today date := (now() at time zone 'Asia/Dubai')::date;
  total numeric;
  roll numeric;
  acc numeric;
  p record;
  picked prizes.id%type;
  won record;
  claimed int;
  attempt int;
begin
  for attempt in 1..3 loop
    select coalesce(sum(case when p_parent then coalesce(weight, 1) else coalesce(weight_non_parent, weight, 1) end), 0)
      into total from prizes_available;

    if total <= 0 then
      return jsonb_build_object('kind', 'try_again');   -- no gift is switched on
    end if;

    roll := random() * (total / (1 - v_ta));
    if roll >= total then
      return jsonb_build_object('kind', 'try_again');
    end if;

    acc := 0; picked := null;
    for p in select id, weight, weight_non_parent from prizes_available order by sort_order, id
    loop
      acc := acc + case when p_parent then coalesce(p.weight, 1) else coalesce(p.weight_non_parent, p.weight, 1) end;
      if roll < acc then picked := p.id; exit; end if;
    end loop;

    -- Count it (row lock also serialises concurrent spins for the same gift). Stock is not a limit.
    update prizes set given_count = given_count + 1
     where id = picked
    returning id, name, image_url, daily_limit into won;

    if found then
      if won.daily_limit is null then
        return jsonb_build_object('kind', 'prize', 'id', won.id, 'name', won.name, 'image_url', won.image_url);
      end if;
      -- Atomic claim of today's allowance; hand the count back if the day is already full.
      insert into prize_daily (prize_id, day, given) values (won.id, v_today, 1)
        on conflict (prize_id, day) do update set given = prize_daily.given + 1
        where prize_daily.given < won.daily_limit;
      get diagnostics claimed = row_count;
      if claimed > 0 then
        return jsonb_build_object('kind', 'prize', 'id', won.id, 'name', won.name, 'image_url', won.image_url);
      end if;
      update prizes set given_count = given_count - 1 where id = won.id;
    end if;
    -- the day's allowance filled up while we picked: look again
  end loop;

  return jsonb_build_object('kind', 'try_again');
end;
$$;

revoke all on function public.spin_wheel(boolean, boolean) from public;
grant execute on function public.spin_wheel(boolean, boolean) to anon, authenticated;

-- Starting odds (chance per guest; everyone ends up with a gift):
--                       parents   not a parent
--   3 x 50ml Products     64%        78%
--   6 x 50ml Products     30%         5%
--   Detangle Set           2%        15%
--   Mama Set              3.5%        1.5%
--   Mystery Gift          0.5%        0.5%
-- Daily caps: Mama Set 4 a day, Mystery Gift 2 a day. Try Again 20% (free re-spin, always a gift).
-- All of it is editable in the admin (Try Again box, and Edit on each prize).
update public.wheel_settings set try_again_pct = 20 where id = 1;
update public.prizes set weight = 64,  weight_non_parent = 78  where name = '3 × 50ml Products';
update public.prizes set weight = 30,  weight_non_parent = 5   where name = '6 × 50ml Products';
update public.prizes set weight = 2,   weight_non_parent = 15  where name = 'Detangle Set';
update public.prizes set weight = 3.5, weight_non_parent = 1.5 where name = 'Mama Set';
update public.prizes set weight = 0.5, weight_non_parent = 0.5 where name = 'Mystery Gift';
update public.prizes set daily_limit = 4 where name = 'Mama Set';
update public.prizes set daily_limit = 2 where name = 'Mystery Gift';

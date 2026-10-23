-- Daily cap per prize (for example Mystery Gift: at most 3 a day).
-- Run once in the Supabase SQL Editor of the registration project. Safe to run again.
-- "A day" is a Dubai calendar day (Asia/Dubai).
-- Needs reliability.sql to have been run first (it created spin_wheel()).

-- 1. The cap itself. Empty (null) = no daily cap. Editable per prize in the admin ("Max per day").
alter table public.prizes add column if not exists daily_limit int
  check (daily_limit is null or daily_limit >= 0);

-- 2. How many of each prize were given on each day. Only spin_wheel() writes to it.
create table if not exists public.prize_daily (
  prize_id uuid not null references public.prizes (id) on delete cascade,
  day      date not null,
  given    int  not null default 0,
  primary key (prize_id, day)
);
alter table public.prize_daily enable row level security;  -- no policies: guests can't read or write it

-- 3. The prizes that can still be won right now (active, in stock, under today's cap).
--    The wheel on the page loads this, so a prize that hit its daily cap leaves the wheel until tomorrow.
create or replace view public.prizes_available as
select p.id, p.name, p.image_url, p.quantity, p.given_count, p.daily_limit, p.sort_order
from public.prizes p
where p.active
  and (p.quantity is null or p.given_count < p.quantity)
  and (p.daily_limit is null
       or coalesce((select d.given from public.prize_daily d
                    where d.prize_id = p.id and d.day = (now() at time zone 'Asia/Dubai')::date), 0) < p.daily_limit);
grant select on public.prizes_available to anon, authenticated;

-- 4. spin_wheel(): same odds as before (weights = remaining stock, Try Again always 25%),
--    but a prize at its daily cap is never picked, and the cap is enforced atomically.
create or replace function public.spin_wheel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  try_again_share constant numeric := 0.25;
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

  select coalesce(sum(case when quantity is null then unlimited_w else quantity - given_count end), 0)
    into total from prizes_available;

  if total <= 0 then
    return jsonb_build_object('kind', 'try_again');
  end if;

  roll := random() * (total / (1 - try_again_share));
  if roll >= total then
    return jsonb_build_object('kind', 'try_again');
  end if;

  for p in select id, quantity, given_count from prizes_available order by sort_order, id
  loop
    acc := acc + case when p.quantity is null then unlimited_w else p.quantity - p.given_count end;
    if roll < acc then picked := p.id; exit; end if;
  end loop;

  -- Atomic claim of stock (the row lock also serialises concurrent spins for the same prize).
  update prizes set given_count = given_count + 1
   where id = picked and (quantity is null or given_count < quantity)
  returning id, name, image_url, daily_limit into won;

  if not found then
    return jsonb_build_object('kind', 'try_again');
  end if;

  -- Atomic claim of today's allowance; hand the unit back if the day is already full.
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

-- 5. The limit you asked for: Mystery Gift, at most 2 a day (it still has its total stock as well).
update public.prizes set daily_limit = 2 where name = 'Mystery Gift';

-- Pral – udvidelse 3
--   * Runder følger Superligaens spillerunder (round_key fra Sportmonks) i stedet for kalenderugen
--   * Udsatte og aflyste kampe: kald annulleres, og indsatsen gives tilbage
--   * Næste mål afgøres først, når målet har stået i 2 minutter (VAR)
--   * Live-kald lagt op til 40 sekunder før et mål eller rødt kort annulleres
-- Kør efter 20261116000000_pral_v2.sql. Kan køres flere gange.

-- ============================================================
-- Nye kolonner og status 'void' (annulleret)
-- ============================================================
alter table public.matches add column if not exists round_key text;              -- fx 'R339123' (Sportmonks round_id)
alter table public.matches add column if not exists round_name text;             -- fx 'Runde 17'
alter table public.matches add column if not exists ng_pending jsonb not null default '[]'; -- mål, der venter på at blive bekræftet
create index if not exists matches_round_idx on public.matches (round_key);

alter table public.matches drop constraint if exists matches_status_check;
alter table public.matches add constraint matches_status_check check (status in ('scheduled', 'live', 'finished', 'void'));
alter table public.picks drop constraint if exists picks_status_check;
alter table public.picks add constraint picks_status_check check (status in ('pending', 'won', 'lost', 'void'));
alter table public.pick_legs drop constraint if exists pick_legs_status_check;
alter table public.pick_legs add constraint pick_legs_status_check check (status in ('pending', 'won', 'lost', 'void'));

-- ============================================================
-- Runder
-- ============================================================
-- En kamps runde: Superligaens runde, ellers ugen for kampstart (bruges af demo-kampe)
create or replace function public.match_round(m public.matches)
returns text language sql stable as $$
  select coalesce(m.round_key, to_char(coalesce(m.starts_at, now()) at time zone 'Europe/Copenhagen', 'IYYY-"W"IW'))
$$;

-- Den aktuelle runde = runden for den første kamp, der ikke er slut (eller den sidst spillede)
create or replace function public.current_round()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select public.match_round(m) from public.matches m
      where m.status in ('scheduled', 'live') and m.starts_at >= now() - interval '4 hours'
      order by m.starts_at limit 1),
    (select public.match_round(m) from public.matches m where m.status = 'finished' order by m.starts_at desc limit 1),
    to_char(now() at time zone 'Europe/Copenhagen', 'IYYY-"W"IW'))
$$;

create or replace function public.round_label(k text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select round_name from public.matches where round_key = k and round_name is not null limit 1),
    case when k ~ '^\d{4}-W\d{2}$' then 'Uge ' || ltrim(substr(k, 7), '0') else k end)
$$;

-- Aktuel og forrige runde med navne (appen bruger den til kåringer)
create or replace function public.rounds_info()
returns table (current_round text, current_name text, previous_round text, previous_name text)
language sql stable security definer set search_path = '' as $$
  with cur as (select public.current_round() as r),
  prev as (
    select public.match_round(m) as r from public.matches m, cur
     where m.status = 'finished' and public.match_round(m) <> cur.r and m.starts_at < now()
     order by m.starts_at desc limit 1)
  select cur.r, public.round_label(cur.r), prev.r, public.round_label(prev.r) from cur left join prev on true
$$;

-- ============================================================
-- Budget pr. runde (annullerede kald tæller ikke)
-- ============================================================
create or replace function public.check_budget(uid uuid, p_stake int, p_round text)
returns void language plpgsql security definer set search_path = '' as $$
declare spent int;
begin
  if uid is null then raise exception 'Du skal være logget ind'; end if;
  if p_stake < public.pral_setting('min_stake') or p_stake > public.pral_setting('max_stake') then
    raise exception 'Indsatsen skal være mellem % og % PP', public.pral_setting('min_stake'), public.pral_setting('max_stake');
  end if;
  perform 1 from public.profiles where id = uid for update;
  select coalesce(sum(stake), 0) into spent from public.picks where user_id = uid and round = p_round and status <> 'void';
  if spent + p_stake > public.pral_setting('round_budget') then
    raise exception 'Du har kun % PP tilbage i %', public.pral_setting('round_budget') - spent, lower(public.round_label(p_round));
  end if;
end $$;

-- Låsen kender nu også aflyste kampe
create or replace function public.lock_reason(m public.matches)
returns text language sql stable as $$
  select case
    when m.status = 'void' then 'Kampen er udsat eller aflyst'
    when m.status = 'finished' then 'Kampen er slut'
    when m.status = 'live' and m.minute >= public.pral_setting('live_close') then 'Live-kald er lukket'
    when m.status = 'live' and m.updated_at < now() - make_interval(secs => public.pral_setting('stale_secs')) then 'Afventer data'
    when m.lock_until is not null and m.lock_until > now() then 'Odds opdateres'
    when m.status = 'scheduled' and m.starts_at is not null and m.starts_at <= now() then 'Kampen er gået i gang'
    else null
  end
$$;

-- ============================================================
-- Afgiv kald: runden er kampens runde
-- ============================================================
create or replace function public.place_pick(p_match bigint, p_outcome int, p_stake int, p_comment text default null)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); m public.matches; why text; r public.picks; rnd text;
begin
  if p_outcome not in (0, 1, 2) then raise exception 'Ugyldigt udfald'; end if;
  select * into m from public.matches where id = p_match for share;
  if not found then raise exception 'Kampen findes ikke'; end if;
  why := public.lock_reason(m);
  if why is not null then raise exception '%', why; end if;
  rnd := public.match_round(m);
  perform public.check_budget(uid, p_stake, rnd);
  insert into public.picks (user_id, kind, match_id, outcome, stake, odds, minute, live, round, comment)
  values (uid, 'single', m.id, p_outcome, p_stake, m.odds[p_outcome + 1], m.minute, m.status = 'live', rnd, nullif(trim(p_comment), ''))
  returning * into r;
  return r;
end $$;

create or replace function public.place_combo(p_legs jsonb, p_stake int, p_comment text default null)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); leg jsonb; m public.matches; total numeric := 1; n int; r public.picks; o int; rnd text;
begin
  n := jsonb_array_length(p_legs);
  if n < 2 or n > 5 then raise exception 'Et kombikald skal have 2–5 kampe'; end if;
  if (select count(distinct (x ->> 'match')) from jsonb_array_elements(p_legs) x) <> n then
    raise exception 'Hver kamp må kun være med én gang';
  end if;
  for leg in select * from jsonb_array_elements(p_legs) loop
    o := (leg ->> 'outcome')::int;
    if o not in (0, 1, 2) then raise exception 'Ugyldigt udfald'; end if;
    select * into m from public.matches where id = (leg ->> 'match')::bigint for share;
    if not found then raise exception 'Kampen findes ikke'; end if;
    if not public.prematch_open(m) then raise exception '% – % er gået i gang. Kombikald kan kun bruge kampe, der ikke er startet', m.home, m.away; end if;
    if rnd is null then rnd := public.match_round(m);
    elsif rnd <> public.match_round(m) then raise exception 'Alle kampe i et kombikald skal være i samme runde'; end if;
    total := total * m.odds[o + 1];
  end loop;
  perform public.check_budget(uid, p_stake, rnd);
  insert into public.picks (user_id, kind, stake, odds, round, comment)
  values (uid, 'combo', p_stake, public.cap_odds(total), rnd, nullif(trim(p_comment), ''))
  returning * into r;
  insert into public.pick_legs (pick_id, match_id, outcome, odds)
  select r.id, (x ->> 'match')::bigint, (x ->> 'outcome')::smallint, m2.odds[(x ->> 'outcome')::int + 1]
  from jsonb_array_elements(p_legs) x join public.matches m2 on m2.id = (x ->> 'match')::bigint;
  return r;
end $$;

create or replace function public.place_next_goal(p_match bigint, p_side int, p_stake int)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); m public.matches; why text; r public.picks; rnd text;
begin
  if p_side not in (0, 1, 2) then raise exception 'Ugyldigt valg'; end if;
  select * into m from public.matches where id = p_match for share;
  if not found then raise exception 'Kampen findes ikke'; end if;
  if m.status <> 'live' or m.ng_odds is null then raise exception 'Næste mål kan kun kaldes under kampen'; end if;
  why := public.lock_reason(m);
  if why is not null then raise exception '%', why; end if;
  rnd := public.match_round(m);
  perform public.check_budget(uid, p_stake, rnd);
  insert into public.picks (user_id, kind, match_id, outcome, stake, odds, minute, live, round)
  values (uid, 'next_goal', m.id, p_side, p_stake, m.ng_odds[p_side + 1], m.minute, true, rnd)
  returning * into r;
  return r;
end $$;

create or replace function public.react_pick(p_target bigint, p_kind text, p_stake int)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t public.picks; o numeric; r public.picks;
begin
  if p_kind not in ('follow', 'fade') then raise exception 'Ugyldig handling'; end if;
  select * into t from public.picks where id = p_target;
  if not found or t.kind not in ('single', 'combo') then raise exception 'Kaldet findes ikke'; end if;
  if t.user_id = uid then raise exception 'Du kan ikke følge eller modspille dit eget kald'; end if;
  if not public.share_club(uid, t.user_id) then raise exception 'I er ikke i samme klub'; end if;
  if t.status <> 'pending' then raise exception 'Kaldet er allerede afgjort'; end if;
  if exists (select 1 from public.picks where user_id = uid and target_pick = t.id) then
    raise exception 'Du har allerede reageret på dette kald';
  end if;
  o := public.current_pick_odds(t);
  if o is null then raise exception 'Kampen er gået i gang, så kaldet kan ikke længere følges eller modspilles'; end if;
  if p_kind = 'fade' then o := public.cap_odds(1 / (1 - 1 / o)); end if;
  perform public.check_budget(uid, p_stake, t.round);
  insert into public.picks (user_id, kind, target_pick, stake, odds, round)
  values (uid, p_kind, t.id, p_stake, o, t.round)
  returning * into r;
  return r;
end $$;

drop function if exists public.check_budget(uuid, int);

-- ============================================================
-- Afregning
-- ============================================================
-- Kombikald afgøres ud fra benene. Annullerede ben udgår, og oddsene regnes om uden dem.
create or replace function public.settle_combos()
returns int language plpgsql security definer set search_path = '' as $$
declare n int := 0; k int;
begin
  -- Odds uden annullerede ben
  update public.picks p
     set odds = public.cap_odds(coalesce((select exp(sum(ln(l.odds))) from public.pick_legs l where l.pick_id = p.id and l.status <> 'void'), 1))
   where p.kind = 'combo' and p.status = 'pending'
     and exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status = 'void');
  -- Alle ben annulleret: indsatsen tilbage
  update public.picks p set status = 'void', payout = p.stake, settled_at = now()
   where p.kind = 'combo' and p.status = 'pending'
     and not exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status <> 'void');
  get diagnostics k = row_count; n := n + k;
  update public.picks p set status = 'lost', payout = 0, settled_at = now()
   where p.kind = 'combo' and p.status = 'pending'
     and exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status = 'lost');
  get diagnostics k = row_count; n := n + k;
  update public.picks p set status = 'won', payout = round(p.stake * p.odds)::int, settled_at = now()
   where p.kind = 'combo' and p.status = 'pending'
     and not exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status in ('pending', 'lost'))
     and exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status = 'won');
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

-- Følg og modspil: annulleret mål eller et ben, der udgår, gør reaktionen ugyldig (indsats tilbage)
create or replace function public.settle_reactions()
returns int language plpgsql security definer set search_path = '' as $$
declare n int; k int;
begin
  update public.picks f set status = 'void', payout = f.stake, settled_at = now()
    from public.picks t
   where f.target_pick = t.id and f.status = 'pending'
     and (t.status = 'void' or exists (select 1 from public.pick_legs l where l.pick_id = t.id and l.status = 'void'));
  get diagnostics n = row_count;
  update public.picks f
     set status = case when (f.kind = 'follow') = (t.status = 'won') then 'won' else 'lost' end,
         payout = case when (f.kind = 'follow') = (t.status = 'won') then round(f.stake * f.odds)::int else 0 end,
         settled_at = now()
    from public.picks t
   where f.target_pick = t.id and f.status = 'pending' and t.status in ('won', 'lost');
  get diagnostics k = row_count;
  return n + k;
end $$;

-- Næste mål. p_before: kun kald lagt før målet (kald lagt efter venter på det næste mål)
drop function if exists public.settle_next_goal(bigint, int);
create or replace function public.settle_next_goal(p_match bigint, p_side int, p_before timestamptz default null)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.picks
     set status = case when outcome = p_side then 'won' else 'lost' end,
         payout = case when outcome = p_side then round(stake * odds)::int else 0 end,
         settled_at = now()
   where match_id = p_match and kind = 'next_goal' and status = 'pending'
     and (p_before is null or created_at < p_before);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.settle_match(p_match bigint)
returns int language plpgsql security definer set search_path = '' as $$
declare m public.matches; res int; n int := 0; k int;
begin
  select * into m from public.matches where id = p_match for update;
  if not found or m.status <> 'finished' or m.settled then return 0; end if;
  res := case when m.gh > m.ga then 0 when m.gh = m.ga then 1 else 2 end;
  update public.picks
     set status = case when outcome = res then 'won' else 'lost' end,
         payout = case when outcome = res then round(stake * odds)::int else 0 end,
         settled_at = now()
   where match_id = p_match and kind = 'single' and status = 'pending';
  get diagnostics k = row_count; n := n + k;
  n := n + public.settle_next_goal(p_match, 1);
  update public.pick_legs set status = case when outcome = res then 'won' else 'lost' end
   where match_id = p_match and status = 'pending';
  n := n + public.settle_combos();
  n := n + public.settle_reactions();
  update public.matches set settled = true where id = p_match;
  return n;
end $$;

-- Udsat eller aflyst kamp: alle kald på kampen annulleres, og indsatsen gives tilbage
create or replace function public.settle_void_match(p_match bigint)
returns int language plpgsql security definer set search_path = '' as $$
declare n int := 0; k int;
begin
  update public.matches set status = 'void', settled = true, lock_until = null where id = p_match;
  update public.picks set status = 'void', payout = stake, settled_at = now()
   where match_id = p_match and kind in ('single', 'next_goal') and status = 'pending';
  get diagnostics k = row_count; n := n + k;
  update public.pick_legs set status = 'void' where match_id = p_match and status = 'pending';
  n := n + public.settle_combos();
  n := n + public.settle_reactions();
  return n;
end $$;

-- Live-kald lagt kort før et mål eller rødt kort annulleres (folk kan se kampen hurtigere end vores data)
create or replace function public.void_recent_live(p_match bigint, p_seconds int default 40)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.picks set status = 'void', payout = stake, settled_at = now()
   where match_id = p_match and live and status = 'pending' and kind in ('single', 'next_goal')
     and created_at > now() - make_interval(secs => p_seconds);
  get diagnostics n = row_count;
  return n;
end $$;

-- ============================================================
-- Min runde (nu med rundens navn; annullerede kald tæller ikke som indsat)
-- ============================================================
drop function if exists public.my_round();
create or replace function public.my_round()
returns table (round text, round_name text, budget int, spent int, left_pp int, won int, bonus int, result int, picks int)
language sql stable security definer set search_path = '' as $$
  with r as (select public.current_round() as k),
  p as (select pk.* from public.picks pk, r where pk.user_id = auth.uid() and pk.round = r.k)
  select r.k, public.round_label(r.k),
    public.pral_setting('round_budget')::int,
    coalesce((select sum(stake) from p where status <> 'void'), 0)::int,
    (public.pral_setting('round_budget') - coalesce((select sum(stake) from p where status <> 'void'), 0))::int,
    coalesce((select sum(payout) from p where status = 'won'), 0)::int,
    (case when exists (select 1 from p) then public.pral_setting('bonus') else 0 end)::int,
    (coalesce((select sum(payout - stake) from p where status <> 'pending'), 0)
      + case when exists (select 1 from p) then public.pral_setting('bonus') else 0 end)::int,
    (select count(*) from p)::int
  from r
$$;

-- ============================================================
-- Badges: stime og kåringer tæller i runder, ikke kalenderuger
-- ============================================================
create or replace function public.my_badges()
returns table (id text, got boolean)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid(); cur text := public.current_round();
begin
  return query
  with mine as (select * from public.picks where user_id = me),
  rounds_ord as (
    select x.r, row_number() over (order by x.s) as rn
    from (select public.match_round(m) as r, min(m.starts_at) as s from public.matches m group by 1) x
  ),
  islands as (
    select ro.rn - row_number() over (order by ro.rn) as g
    from rounds_ord ro join (select distinct round from mine) mr on mr.round = ro.r
  ),
  mates as (
    select distinct y.user_id from public.club_members x join public.club_members y using (club_id) where x.user_id = me
  ),
  slips as (
    select p.* from public.picks p where p.kind in ('single', 'combo') and p.user_id in (select user_id from mates union select me)
  )
  select v.id, v.got from (values
    ('welcome',  exists (select 1 from public.club_members where user_id = me)),
    ('first',    exists (select 1 from mine)),
    ('home',     exists (select 1 from mine where status = 'won')),
    ('combo',    exists (select 1 from mine p where p.kind = 'combo' and p.status = 'won'
                         and (select count(*) from public.pick_legs l where l.pick_id = p.id and l.status = 'won') >= 3)),
    ('long',     exists (select 1 from mine where status = 'won' and odds >= 5)),
    ('live',     exists (select 1 from mine where live and status <> 'void')),
    ('late',     exists (select 1 from mine where live and status = 'won' and minute >= 75)),
    ('fader',    exists (select 1 from mine where kind = 'fade' and status = 'won')),
    ('streak',   coalesce((select max(c) >= 5 from (select count(*) c from islands group by g) s), false)),
    ('profet',   exists (select 1 from mine p where p.kind in ('single', 'combo') and p.status = 'won' and p.round <> cur
                          and not exists (select 1 from slips o where o.round = p.round and o.status = 'won' and o.odds > p.odds))),
    ('broler',   exists (select 1 from mine p where p.kind in ('single', 'combo') and p.status = 'lost' and p.round <> cur
                          and not exists (select 1 from slips o where o.round = p.round and o.status = 'lost' and o.odds < p.odds)))
  ) as v(id, got);
end $$;

-- ============================================================
-- Adgang
-- ============================================================
revoke execute on function public.check_budget(uuid, int, text)               from public, anon, authenticated;
revoke execute on function public.settle_combos()                             from public, anon, authenticated;
revoke execute on function public.settle_reactions()                          from public, anon, authenticated;
revoke execute on function public.settle_next_goal(bigint, int, timestamptz)  from public, anon, authenticated;
revoke execute on function public.settle_match(bigint)                        from public, anon, authenticated;
revoke execute on function public.settle_void_match(bigint)                   from public, anon, authenticated;
revoke execute on function public.void_recent_live(bigint, int)               from public, anon, authenticated;
revoke execute on function public.my_round()                                  from public, anon;
revoke execute on function public.rounds_info()                               from public, anon;
grant execute on function public.my_round()                                   to authenticated;
grant execute on function public.rounds_info()                                to authenticated;
grant execute on function public.settle_next_goal(bigint, int, timestamptz)   to service_role;
grant execute on function public.settle_match(bigint)                         to service_role;
grant execute on function public.settle_void_match(bigint)                    to service_role;
grant execute on function public.void_recent_live(bigint, int)                to service_role;

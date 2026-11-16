-- Pral – udvidelse 2: kombikald, næste mål, følg og modspil, klubbens kald, kåringer, rivaler og badges
-- Kør efter 20261115000000_pral.sql. Kan køres flere gange.

-- ============================================================
-- Kampe: odds på næste mål og chancen gennem kampen
-- ============================================================
alter table public.matches add column if not exists ng_odds numeric[];                 -- [hjemme scorer, intet mål, ude scorer]
alter table public.matches add column if not exists history jsonb not null default '[]'; -- [[minut, p1, pX, p2], ...]

-- ============================================================
-- Kald: flere slags
--   single    ét udfald i én kamp (før eller under kampen)
--   combo     2–5 kampe, odds ganges sammen (benene ligger i pick_legs)
--   next_goal hvem scorer næste mål: 0 = hjemme, 1 = intet mål, 2 = ude
--   follow    kopi af en vens kald
--   fade      modspil af en vens kald
-- ============================================================
alter table public.picks add column if not exists kind text not null default 'single';
alter table public.picks add column if not exists target_pick bigint references public.picks on delete cascade;
alter table public.picks add column if not exists comment text;
alter table public.picks add column if not exists settled_at timestamptz;
alter table public.picks alter column match_id drop not null;
alter table public.picks alter column outcome drop not null;

alter table public.picks drop constraint if exists picks_kind_chk;
alter table public.picks add constraint picks_kind_chk check (kind in ('single', 'combo', 'next_goal', 'follow', 'fade'));
alter table public.picks drop constraint if exists picks_shape_chk;
alter table public.picks add constraint picks_shape_chk check (
  (kind in ('single', 'next_goal') and match_id is not null and outcome is not null and target_pick is null) or
  (kind = 'combo' and match_id is null and outcome is null and target_pick is null) or
  (kind in ('follow', 'fade') and match_id is null and outcome is null and target_pick is not null));
alter table public.picks drop constraint if exists picks_comment_chk;
alter table public.picks add constraint picks_comment_chk check (comment is null or char_length(comment) <= 80);

create unique index if not exists picks_one_reaction_idx on public.picks (user_id, target_pick) where target_pick is not null;
create index if not exists picks_target_idx on public.picks (target_pick) where target_pick is not null;
create index if not exists picks_round_idx on public.picks (round);

create table if not exists public.pick_legs (
  pick_id  bigint not null references public.picks on delete cascade,
  match_id bigint not null references public.matches,
  outcome  smallint not null check (outcome between 0 and 2),
  odds     numeric(6, 2) not null,
  status   text not null default 'pending' check (status in ('pending', 'won', 'lost')),
  primary key (pick_id, match_id)
);
create index if not exists pick_legs_pending_idx on public.pick_legs (match_id) where status = 'pending';

alter table public.pick_legs enable row level security;
drop policy if exists "se egne ben" on public.pick_legs;
create policy "se egne ben" on public.pick_legs for select to authenticated
  using (exists (select 1 from public.picks p where p.id = pick_id and p.user_id = auth.uid()));

-- ============================================================
-- Hjælpere
-- ============================================================
-- Er kampen åben for kald før kampen (ikke startet og ikke låst)?
create or replace function public.prematch_open(m public.matches)
returns boolean language sql stable as $$
  select m.status = 'scheduled' and public.lock_reason(m) is null
$$;

-- Tjek budgettet og lås brugeren, så to kald på samme tid ikke bruger samme PP
create or replace function public.check_budget(uid uuid, p_stake int)
returns void language plpgsql security definer set search_path = '' as $$
declare spent int;
begin
  if uid is null then raise exception 'Du skal være logget ind'; end if;
  if p_stake < public.pral_setting('min_stake') or p_stake > public.pral_setting('max_stake') then
    raise exception 'Indsatsen skal være mellem % og % PP', public.pral_setting('min_stake'), public.pral_setting('max_stake');
  end if;
  perform 1 from public.profiles where id = uid for update;
  select coalesce(sum(stake), 0) into spent from public.picks where user_id = uid and round = public.current_round();
  if spent + p_stake > public.pral_setting('round_budget') then
    raise exception 'Du har kun % PP tilbage i denne runde', public.pral_setting('round_budget') - spent;
  end if;
end $$;

create or replace function public.cap_odds(o numeric)
returns numeric language sql immutable as $$ select round(least(50, greatest(1.01, o)), 2) $$;

-- Deler to brugere en klub?
create or replace function public.share_club(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.club_members x join public.club_members y using (club_id) where x.user_id = a and y.user_id = b)
$$;

-- ============================================================
-- Afgiv kald
-- ============================================================
drop function if exists public.place_pick(bigint, int, int);
create or replace function public.place_pick(p_match bigint, p_outcome int, p_stake int, p_comment text default null)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); m public.matches; why text; r public.picks;
begin
  if p_outcome not in (0, 1, 2) then raise exception 'Ugyldigt udfald'; end if;
  select * into m from public.matches where id = p_match for share;
  if not found then raise exception 'Kampen findes ikke'; end if;
  why := public.lock_reason(m);
  if why is not null then raise exception '%', why; end if;
  perform public.check_budget(uid, p_stake);
  insert into public.picks (user_id, kind, match_id, outcome, stake, odds, minute, live, round, comment)
  values (uid, 'single', m.id, p_outcome, p_stake, m.odds[p_outcome + 1], m.minute, m.status = 'live', public.current_round(), nullif(trim(p_comment), ''))
  returning * into r;
  return r;
end $$;

-- p_legs = [{"match": 123, "outcome": 0}, ...]
create or replace function public.place_combo(p_legs jsonb, p_stake int, p_comment text default null)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); leg jsonb; m public.matches; total numeric := 1; n int; r public.picks; o int;
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
    total := total * m.odds[o + 1];
  end loop;
  perform public.check_budget(uid, p_stake);
  insert into public.picks (user_id, kind, stake, odds, round, comment)
  values (uid, 'combo', p_stake, public.cap_odds(total), public.current_round(), nullif(trim(p_comment), ''))
  returning * into r;
  insert into public.pick_legs (pick_id, match_id, outcome, odds)
  select r.id, (x ->> 'match')::bigint, (x ->> 'outcome')::smallint, m2.odds[(x ->> 'outcome')::int + 1]
  from jsonb_array_elements(p_legs) x join public.matches m2 on m2.id = (x ->> 'match')::bigint;
  return r;
end $$;

-- Næste mål: 0 = hjemmeholdet scorer, 1 = intet mål mere, 2 = udeholdet scorer
create or replace function public.place_next_goal(p_match bigint, p_side int, p_stake int)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); m public.matches; why text; r public.picks;
begin
  if p_side not in (0, 1, 2) then raise exception 'Ugyldigt valg'; end if;
  select * into m from public.matches where id = p_match for share;
  if not found then raise exception 'Kampen findes ikke'; end if;
  if m.status <> 'live' or m.ng_odds is null then raise exception 'Næste mål kan kun kaldes under kampen'; end if;
  why := public.lock_reason(m);
  if why is not null then raise exception '%', why; end if;
  perform public.check_budget(uid, p_stake);
  insert into public.picks (user_id, kind, match_id, outcome, stake, odds, minute, live, round)
  values (uid, 'next_goal', m.id, p_side, p_stake, m.ng_odds[p_side + 1], m.minute, true, public.current_round())
  returning * into r;
  return r;
end $$;

-- De aktuelle odds på et kald (enkelt eller kombi), hvis alle kampe stadig er åbne. Ellers null.
create or replace function public.current_pick_odds(t public.picks)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare m public.matches; total numeric := 1; l record;
begin
  if t.kind = 'single' then
    select * into m from public.matches where id = t.match_id;
    if not public.prematch_open(m) then return null; end if;
    return m.odds[t.outcome + 1];
  elsif t.kind = 'combo' then
    for l in select * from public.pick_legs where pick_id = t.id loop
      select * into m from public.matches where id = l.match_id;
      if not public.prematch_open(m) then return null; end if;
      total := total * m.odds[l.outcome + 1];
    end loop;
    return public.cap_odds(total);
  end if;
  return null;
end $$;

-- Følg eller modspil en vens kald. Odds = de aktuelle odds, når man trykker.
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
  perform public.check_budget(uid, p_stake);
  insert into public.picks (user_id, kind, target_pick, stake, odds, round)
  values (uid, p_kind, t.id, p_stake, o, public.current_round())
  returning * into r;
  return r;
end $$;

-- ============================================================
-- Afregning (kun Edge Functions)
-- ============================================================
create or replace function public.settle_reactions()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.picks f
     set status = case when (f.kind = 'follow') = (t.status = 'won') then 'won' else 'lost' end,
         payout = case when (f.kind = 'follow') = (t.status = 'won') then round(f.stake * f.odds)::int else 0 end,
         settled_at = now()
    from public.picks t
   where f.target_pick = t.id and f.status = 'pending' and t.status <> 'pending';
  get diagnostics n = row_count;
  return n;
end $$;

-- Næste mål afgøres: p_side = 0 (hjemme scorede), 2 (ude scorede) eller 1 (slutfløjt uden flere mål)
create or replace function public.settle_next_goal(p_match bigint, p_side int)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.picks
     set status = case when outcome = p_side then 'won' else 'lost' end,
         payout = case when outcome = p_side then round(stake * odds)::int else 0 end,
         settled_at = now()
   where match_id = p_match and kind = 'next_goal' and status = 'pending';
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

  update public.picks p set status = 'lost', payout = 0, settled_at = now()
   where p.kind = 'combo' and p.status = 'pending'
     and exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status = 'lost');
  get diagnostics k = row_count; n := n + k;
  update public.picks p set status = 'won', payout = round(p.stake * p.odds)::int, settled_at = now()
   where p.kind = 'combo' and p.status = 'pending'
     and not exists (select 1 from public.pick_legs l where l.pick_id = p.id and l.status <> 'won');
  get diagnostics k = row_count; n := n + k;

  n := n + public.settle_reactions();
  update public.matches set settled = true where id = p_match;
  return n;
end $$;

-- ============================================================
-- Klubbens kald i en runde (alle slags, med ben og reaktioner)
-- ============================================================
create or replace function public.club_picks(p_club uuid, p_round text default null)
returns table (
  id bigint, user_id uuid, name text, kind text, match_id bigint, outcome smallint, target_pick bigint,
  stake int, odds numeric, minute int, live boolean, status text, payout int, comment text, created_at timestamptz,
  legs jsonb, followers int, faders int, my_reaction text
) language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_member(p_club) then raise exception 'Du er ikke med i klubben'; end if;
  return query
  select p.id, p.user_id, pr.name, p.kind, p.match_id, p.outcome, p.target_pick,
         p.stake, p.odds, p.minute, p.live, p.status, p.payout, p.comment, p.created_at,
         coalesce((select jsonb_agg(jsonb_build_object('match', l.match_id, 'outcome', l.outcome, 'odds', l.odds, 'status', l.status) order by l.match_id)
                   from public.pick_legs l where l.pick_id = p.id), '[]'::jsonb),
         (select count(*)::int from public.picks f where f.target_pick = p.id and f.kind = 'follow'),
         (select count(*)::int from public.picks f where f.target_pick = p.id and f.kind = 'fade'),
         (select f.kind from public.picks f where f.target_pick = p.id and f.user_id = auth.uid())
  from public.picks p
  join public.club_members cm on cm.user_id = p.user_id and cm.club_id = p_club
  join public.profiles pr on pr.id = p.user_id
  where p.round = coalesce(p_round, public.current_round())
  order by p.created_at desc;
end $$;

-- ============================================================
-- Rangliste (nu også for en bestemt runde)
-- ============================================================
drop function if exists public.club_leaderboard(uuid, text);
create or replace function public.club_leaderboard(p_club uuid, p_scope text default 'week', p_round text default null)
returns table (user_id uuid, name text, result int, hits int, picks int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_member(p_club) then raise exception 'Du er ikke med i klubben'; end if;
  return query
  with per_round as (
    select p.user_id, p.round,
           sum(case when p.status = 'pending' then 0 else p.payout - p.stake end) + public.pral_setting('bonus') as res,
           count(*) filter (where p.status = 'won') as hits,
           count(*) as n
    from public.picks p
    join public.club_members cm on cm.user_id = p.user_id and cm.club_id = p_club
    where p_scope = 'season' or p.round = coalesce(p_round, public.current_round())
    group by p.user_id, p.round
  )
  select cm.user_id, pr.name, coalesce(sum(r.res), 0)::int, coalesce(sum(r.hits), 0)::int, coalesce(sum(r.n), 0)::int
  from public.club_members cm
  join public.profiles pr on pr.id = cm.user_id
  left join per_round r on r.user_id = cm.user_id
  where cm.club_id = p_club
  group by cm.user_id, pr.name
  order by 3 desc, 4 desc, 2;
end $$;

-- ============================================================
-- Kåringer for en runde: profet, brøler og konge
-- ============================================================
create or replace function public.club_awards(p_club uuid, p_round text)
returns table (award text, user_id uuid, name text, odds numeric, payout int, result int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_member(p_club) then raise exception 'Du er ikke med i klubben'; end if;
  return query
  with cp as (
    select p.*, pr.name from public.picks p
    join public.club_members cm on cm.user_id = p.user_id and cm.club_id = p_club
    join public.profiles pr on pr.id = p.user_id
    where p.round = p_round and p.kind in ('single', 'combo')
  )
  (select 'profet'::text, cp.user_id, cp.name, cp.odds, cp.payout, null::int from cp where cp.status = 'won' order by cp.odds desc, cp.payout desc limit 1)
  union all
  (select 'broler'::text, cp.user_id, cp.name, cp.odds, cp.payout, null::int from cp where cp.status = 'lost' order by cp.odds asc limit 1)
  union all
  (select 'konge'::text, lb.user_id, lb.name, null::numeric, null::int, lb.result
     from public.club_leaderboard(p_club, 'week', p_round) lb where lb.picks > 0 order by lb.result desc, lb.hits desc limit 1);
end $$;

-- ============================================================
-- Rivaler: vundne og tabte modspil mod hver klubkammerat
-- ============================================================
create or replace function public.my_rivals(p_club uuid)
returns table (user_id uuid, name text, wins int, losses int)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if not public.is_member(p_club) then raise exception 'Du er ikke med i klubben'; end if;
  return query
  with duels as (
    -- jeg modspillede dem
    select t.user_id as other, (f.status = 'won') as i_won
      from public.picks f join public.picks t on t.id = f.target_pick
     where f.user_id = me and f.kind = 'fade' and f.status <> 'pending'
    union all
    -- de modspillede mig
    select f.user_id, (f.status = 'lost')
      from public.picks f join public.picks t on t.id = f.target_pick
     where t.user_id = me and f.kind = 'fade' and f.status <> 'pending'
  )
  select cm.user_id, pr.name,
         count(*) filter (where d.i_won)::int,
         count(*) filter (where d.i_won = false)::int
  from public.club_members cm
  join public.profiles pr on pr.id = cm.user_id
  left join duels d on d.other = cm.user_id
  where cm.club_id = p_club and cm.user_id <> me
  group by cm.user_id, pr.name
  order by pr.name;
end $$;

-- ============================================================
-- Badges, regnet ud fra dine data
-- ============================================================
create or replace function public.my_badges()
returns table (id text, got boolean)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  return query
  with mine as (select * from public.picks where user_id = me),
  weeks as (
    select distinct to_date(round || '-1', 'IYYY-"W"IW-ID') as d from mine
  ),
  islands as (
    select d - (row_number() over (order by d))::int * 7 as g from weeks
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
                         and (select count(*) from public.pick_legs l where l.pick_id = p.id) >= 3)),
    ('long',     exists (select 1 from mine where status = 'won' and odds >= 5)),
    ('live',     exists (select 1 from mine where live)),
    ('late',     exists (select 1 from mine where live and status = 'won' and minute >= 75)),
    ('fader',    exists (select 1 from mine where kind = 'fade' and status = 'won')),
    ('streak',   coalesce((select max(c) >= 5 from (select count(*) c from islands group by g) s), false)),
    ('profet',   exists (select 1 from mine p where p.kind in ('single', 'combo') and p.status = 'won'
                          and p.round < public.current_round()
                          and not exists (select 1 from slips o where o.round = p.round and o.status = 'won' and o.odds > p.odds))),
    ('broler',   exists (select 1 from mine p where p.kind in ('single', 'combo') and p.status = 'lost'
                          and p.round < public.current_round()
                          and not exists (select 1 from slips o where o.round = p.round and o.status = 'lost' and o.odds < p.odds)))
  ) as v(id, got);
end $$;

-- ============================================================
-- Adgang til de nye funktioner
-- ============================================================
revoke execute on function public.place_pick(bigint, int, int, text)        from public, anon;
revoke execute on function public.place_combo(jsonb, int, text)              from public, anon;
revoke execute on function public.place_next_goal(bigint, int, int)          from public, anon;
revoke execute on function public.react_pick(bigint, text, int)              from public, anon;
revoke execute on function public.club_picks(uuid, text)                     from public, anon;
revoke execute on function public.club_leaderboard(uuid, text, text)         from public, anon;
revoke execute on function public.club_awards(uuid, text)                    from public, anon;
revoke execute on function public.my_rivals(uuid)                            from public, anon;
revoke execute on function public.my_badges()                                from public, anon;
revoke execute on function public.check_budget(uuid, int)                    from public, anon, authenticated;
revoke execute on function public.current_pick_odds(public.picks)            from public, anon, authenticated;
revoke execute on function public.share_club(uuid, uuid)                     from public, anon, authenticated;
revoke execute on function public.settle_reactions()                         from public, anon, authenticated;
revoke execute on function public.settle_next_goal(bigint, int)              from public, anon, authenticated;
revoke execute on function public.settle_match(bigint)                       from public, anon, authenticated;
grant execute on function public.place_pick(bigint, int, int, text)          to authenticated;
grant execute on function public.place_combo(jsonb, int, text)               to authenticated;
grant execute on function public.place_next_goal(bigint, int, int)           to authenticated;
grant execute on function public.react_pick(bigint, text, int)               to authenticated;
grant execute on function public.club_picks(uuid, text)                      to authenticated;
grant execute on function public.club_leaderboard(uuid, text, text)          to authenticated;
grant execute on function public.club_awards(uuid, text)                     to authenticated;
grant execute on function public.my_rivals(uuid)                             to authenticated;
grant execute on function public.my_badges()                                 to authenticated;
grant execute on function public.settle_next_goal(bigint, int)               to service_role;
grant execute on function public.settle_match(bigint)                        to service_role;

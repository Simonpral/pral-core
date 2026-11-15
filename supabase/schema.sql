-- =====================================================================
-- Pral – database til index.html
-- Kør hele filen én gang i Supabase: SQL Editor → New query → indsæt → Run.
-- =====================================================================

-- ---------- Runder: én runde pr. uge (fx '2026-W46'), dansk tid ----------
create or replace function public.pral_round(ts timestamptz default now())
returns text language sql stable as $$
  select to_char(ts at time zone 'Europe/Copenhagen', 'IYYY-"W"IW')
$$;

-- ---------- Profiler ----------
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text check (char_length(name) <= 40),
  adult_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);

-- Opret automatisk en profil, når en ny bruger logger ind første gang
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, adult_confirmed_at)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)), 40),
    case when new.raw_user_meta_data->>'adult_confirmed_at' ~ '^\d{4}-\d{2}-\d{2}T'
         then (new.raw_user_meta_data->>'adult_confirmed_at')::timestamptz end
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Kampe (udfyldes af jer, ikke af brugerne) ----------
create table public.matches (
  id bigint generated always as identity primary key,
  home text not null,
  away text not null,
  starts_at timestamptz,
  status text not null default 'scheduled' check (status in ('scheduled', 'live', 'finished')),
  minute int not null default 0,
  gh int not null default 0,                     -- mål hjemme
  ga int not null default 0,                     -- mål ude
  odds numeric(6,2)[] not null check (array_length(odds, 1) = 3),   -- {1, X, 2}
  prev_odds numeric(6,2)[],
  chance numeric(4,3)[],                         -- fx {0.45, 0.30, 0.25}
  feed jsonb not null default '[]',              -- fx [{"minute": 12, "text": "Mål!"}]
  lock_until timestamptz,                        -- lås kald, mens odds opdateres
  updated_at timestamptz not null default now()
);

create or replace function public.matches_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.odds is distinct from old.odds then new.prev_odds := old.odds; end if;
  return new;
end $$;

create trigger matches_touch before update on public.matches
  for each row execute function public.matches_touch();

-- ---------- Kald (bets) ----------
create table public.picks (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  match_id bigint not null references public.matches on delete cascade,
  round text not null,
  outcome smallint not null check (outcome between 0 and 2),   -- 0 = 1, 1 = X, 2 = 2
  stake int not null check (stake between 10 and 300),
  odds numeric(6,2) not null,
  live boolean not null default false,
  minute int not null default 0,
  status text not null default 'pending' check (status in ('pending', 'won', 'lost')),
  payout int not null default 0,
  created_at timestamptz not null default now()
);
create index picks_user_round on public.picks (user_id, round);
create index picks_match on public.picks (match_id);

-- Afregn kald automatisk, når en kamp sættes til 'finished'
create or replace function public.settle_picks()
returns trigger language plpgsql security definer set search_path = public as $$
declare res int;
begin
  if new.status = 'finished' and old.status is distinct from 'finished' then
    res := case when new.gh > new.ga then 0 when new.gh = new.ga then 1 else 2 end;
    update public.picks
       set status = case when outcome = res then 'won' else 'lost' end,
           payout = case when outcome = res then round(stake * odds)::int else 0 end
     where match_id = new.id and status = 'pending';
  end if;
  return new;
end $$;

create trigger settle_picks after update on public.matches
  for each row execute function public.settle_picks();

-- ---------- Klubber ----------
create table public.clubs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 40),
  code text not null unique,
  owner_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now()
);

create table public.club_members (
  club_id uuid not null references public.clubs on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (club_id, user_id)
);

create or replace function public.is_club_member(p_club uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.club_members where club_id = p_club and user_id = auth.uid())
$$;

-- =====================================================================
-- Sikkerhed (Row Level Security)
-- =====================================================================
alter table public.profiles     enable row level security;
alter table public.matches      enable row level security;
alter table public.picks        enable row level security;
alter table public.clubs        enable row level security;
alter table public.club_members enable row level security;

create policy "Se egen profil"     on public.profiles for select to authenticated using (id = auth.uid());
create policy "Ret egen profil"    on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "Alle kan se kampe"  on public.matches  for select to anon, authenticated using (true);
create policy "Se egne kald"       on public.picks    for select to authenticated using (user_id = auth.uid());
create policy "Se egne klubber"    on public.clubs    for select to authenticated using (public.is_club_member(id));
create policy "Se klubmedlemmer"   on public.club_members for select to authenticated using (public.is_club_member(club_id));

-- Brugere må kun rette deres navn. Alt andet sker gennem funktionerne nedenfor.
revoke insert, update, delete on public.profiles, public.matches, public.picks, public.clubs, public.club_members from anon, authenticated;
grant update (name) on public.profiles to authenticated;

-- =====================================================================
-- Funktioner, som appen kalder (sb.rpc)
-- =====================================================================

-- Min runde: indsat, gevinst, bonus, resultat og PP tilbage
create or replace function public.my_round()
returns table (round text, spent int, won int, bonus int, result int, left_pp int)
language sql stable security definer set search_path = public as $$
  with r as (select public.pral_round() as rd),
  s as (
    select coalesce(sum(p.stake), 0)::int as spent,
           coalesce(sum(p.payout), 0)::int as won,
           count(*) as n
      from public.picks p, r
     where p.user_id = auth.uid() and p.round = r.rd
  )
  select r.rd, s.spent, s.won,
         case when s.n > 0 then 50 else 0 end,
         s.won - s.spent + case when s.n > 0 then 50 else 0 end,
         1000 - s.spent
    from r, s
$$;

-- Afgiv et kald. Samme låseregler som i appen, men håndhævet i databasen.
create or replace function public.place_pick(p_match bigint, p_outcome int, p_stake int)
returns setof public.picks
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  m public.matches;
  r text := public.pral_round();
  used int;
begin
  if uid is null then raise exception 'Du skal være logget ind'; end if;
  if p_outcome is null or p_outcome not in (0, 1, 2) then raise exception 'Ugyldigt udfald'; end if;
  if p_stake is null or p_stake < 10 or p_stake > 300 then raise exception 'Indsatsen skal være mellem 10 og 300 PP'; end if;

  -- Lås brugerens profil, så to samtidige kald ikke kan overskride budgettet
  insert into public.profiles (id) values (uid) on conflict (id) do nothing;
  perform 1 from public.profiles where id = uid for update;

  select * into m from public.matches where id = p_match;
  if not found then raise exception 'Kampen findes ikke'; end if;
  if m.status = 'finished' then raise exception 'Kampen er slut'; end if;
  if m.status = 'live' and m.minute >= 85 then raise exception 'Live-kald er lukket'; end if;
  if m.status = 'live' and now() - m.updated_at > interval '90 seconds' then raise exception 'Afventer data'; end if;
  if m.lock_until is not null and m.lock_until > now() then raise exception 'Odds opdateres'; end if;
  if m.status = 'scheduled' and m.starts_at is not null and m.starts_at <= now() then raise exception 'Kampen er gået i gang'; end if;

  select coalesce(sum(stake), 0) into used from public.picks where user_id = uid and round = r;
  if used + p_stake > 1000 then raise exception 'Du har ikke PP nok tilbage i denne runde'; end if;

  return query
    insert into public.picks (user_id, match_id, round, outcome, stake, odds, live, minute)
    values (uid, m.id, r, p_outcome, p_stake, m.odds[p_outcome + 1], m.status = 'live', m.minute)
    returning *;
end $$;

-- Lav en klub med en tilfældig kode på 6 tegn
create or replace function public.create_club(p_name text)
returns setof public.clubs
language plpgsql security definer set search_path = public as $$
declare c public.clubs; v_code text;
begin
  if auth.uid() is null then raise exception 'Du skal være logget ind'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Giv klubben et navn på mindst 2 tegn'; end if;
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.clubs where code = v_code);
  end loop;
  insert into public.clubs (name, code, owner_id) values (left(trim(p_name), 40), v_code, auth.uid()) returning * into c;
  insert into public.club_members (club_id, user_id) values (c.id, auth.uid());
  return next c;
end $$;

-- Meld dig ind i en klub med koden
create or replace function public.join_club(p_code text)
returns setof public.clubs
language plpgsql security definer set search_path = public as $$
declare c public.clubs;
begin
  if auth.uid() is null then raise exception 'Du skal være logget ind'; end if;
  select * into c from public.clubs where code = upper(trim(coalesce(p_code, '')));
  if not found then raise exception 'Klubkoden findes ikke'; end if;
  insert into public.club_members (club_id, user_id) values (c.id, auth.uid()) on conflict do nothing;
  return next c;
end $$;

-- Rangliste for en klub: 'week' = denne runde, 'season' = alle runder
create or replace function public.club_leaderboard(p_club uuid, p_scope text default 'week')
returns table (user_id uuid, name text, picks int, hits int, result int)
language sql stable security definer set search_path = public as $$
  select cm.user_id,
         coalesce(pr.name, 'Spiller'),
         count(k.id)::int,
         (count(k.id) filter (where k.status = 'won'))::int,
         (coalesce(sum(k.payout), 0) - coalesce(sum(k.stake), 0) + 50 * count(distinct k.round))::int
    from public.club_members cm
    left join public.profiles pr on pr.id = cm.user_id
    left join public.picks k on k.user_id = cm.user_id
                            and (p_scope = 'season' or k.round = public.pral_round())
   where cm.club_id = p_club
     and public.is_club_member(p_club)
   group by cm.user_id, pr.name
   order by 5 desc, 4 desc, 2
$$;

-- Kun loggede-ind brugere må kalde funktionerne
revoke execute on function public.my_round(), public.place_pick(bigint, int, int), public.create_club(text),
  public.join_club(text), public.club_leaderboard(uuid, text) from public, anon;
grant execute on function public.my_round(), public.place_pick(bigint, int, int), public.create_club(text),
  public.join_club(text), public.club_leaderboard(uuid, text) to authenticated;

-- =====================================================================
-- Live-opdateringer (Realtime) for kampe og kald
-- =====================================================================
alter publication supabase_realtime add table public.matches, public.picks;

-- =====================================================================
-- Testkampe (valgfrit – slet dem, når I har rigtige kampe)
-- =====================================================================
insert into public.matches (home, away, starts_at, odds, chance) values
  ('FC København', 'Brøndby IF', now() + interval '2 days', '{2.10, 3.40, 3.30}', '{0.45, 0.28, 0.27}'),
  ('FC Midtjylland', 'AGF',      now() + interval '3 days', '{1.85, 3.60, 4.10}', '{0.52, 0.26, 0.22}');

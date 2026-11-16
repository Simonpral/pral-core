-- Pral – database til Supabase
-- Kør hele filen én gang i Supabase → SQL Editor (eller med `supabase db push`).
--
-- Grundregler, som databasen selv håndhæver:
--   * Appen kan kun LÆSE kampe og odds. Kun Edge Functions (med secret key) kan skrive dem.
--   * Kald kan kun afgives gennem funktionen place_pick, som selv slår oddsene op.
--     Appen sender kun kamp, udfald og indsats – aldrig odds.
--   * 1.000 PP pr. runde, 10–300 PP pr. kald, live-kald lukker i 85. minut,
--     låst 20 sekunder efter mål og røde kort, låst hvis data er mere end 90 sekunder gamle.
--   * Rundens resultat = gevinster − indsatser + 50 PP i deltagerbonus (hvis mindst ét kald).

-- ============================================================
-- Indstillinger (ét sted, så de er lette at ændre)
-- ============================================================
create or replace function public.pral_setting(key text)
returns numeric language sql immutable as $$
  select case key
    when 'round_budget' then 1000
    when 'min_stake'    then 10
    when 'max_stake'    then 300
    when 'bonus'        then 50
    when 'live_close'   then 85   -- minut, hvor live-kald lukker
    when 'stale_secs'   then 90   -- data ældre end dette = låst
  end
$$;

-- Runden = ISO-uge i dansk tid, fx '2026-W47'. Kan senere skiftes til Superligaens spillerunder.
create or replace function public.current_round()
returns text language sql stable as $$
  select to_char(now() at time zone 'Europe/Copenhagen', 'IYYY-"W"IW')
$$;

-- ============================================================
-- Tabeller
-- ============================================================
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  name       text not null default 'Ny spiller' check (char_length(name) between 1 and 30),
  created_at timestamptz not null default now()
);

-- Holdenes styrke (skrives af funktionen nightly)
create table if not exists public.teams (
  id           bigint primary key,      -- Sportmonks' hold-id
  name         text,
  attack_home  numeric not null default 1,
  defence_home numeric not null default 1,
  attack_away  numeric not null default 1,
  defence_away numeric not null default 1,
  games        int not null default 0,
  updated_at   timestamptz not null default now()
);

create table if not exists public.league_stats (
  league_id  bigint primary key,
  avg_home   numeric not null,
  avg_away   numeric not null,
  matches    int not null,
  updated_at timestamptz not null default now()
);

-- Kampe og odds (skrives af funktionerne live-odds og nightly)
create table if not exists public.matches (
  id          bigint primary key,       -- Sportmonks' fixture-id
  league_id   bigint,
  starts_at   timestamptz,
  status      text not null default 'scheduled' check (status in ('scheduled', 'live', 'finished')),
  home        text not null,
  away        text not null,
  home_id     bigint,
  away_id     bigint,
  minute      int not null default 0,
  gh          int not null default 0,
  ga          int not null default 0,
  reds_home   int not null default 0,
  reds_away   int not null default 0,
  lh          numeric not null default 1.5,   -- forventede mål hjemme på 90 min
  la          numeric not null default 1.2,   -- forventede mål ude på 90 min
  odds        numeric[] not null,             -- [1, X, 2]
  prev_odds   numeric[],
  chance      numeric[],                      -- [1, X, 2] som 0–1
  lock_until  timestamptz,
  feed        jsonb not null default '[]',
  settled     boolean not null default false,
  updated_at  timestamptz not null default now(),
  check (array_length(odds, 1) = 3)
);
create index if not exists matches_status_idx on public.matches (status, starts_at);

create table if not exists public.picks (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles on delete cascade,
  match_id   bigint not null references public.matches,
  outcome    smallint not null check (outcome between 0 and 2),   -- 0 = 1, 1 = X, 2 = 2
  stake      int not null check (stake > 0),
  odds       numeric(6, 2) not null,
  minute     int,
  live       boolean not null default false,
  round      text not null,
  status     text not null default 'pending' check (status in ('pending', 'won', 'lost')),
  payout     int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists picks_user_round_idx on public.picks (user_id, round);
create index if not exists picks_pending_idx on public.picks (match_id) where status = 'pending';

create table if not exists public.clubs (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 2 and 40),
  code       text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  owner      uuid references public.profiles on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.club_members (
  club_id   uuid not null references public.clubs on delete cascade,
  user_id   uuid not null references public.profiles on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (club_id, user_id)
);
create index if not exists club_members_user_idx on public.club_members (user_id);

-- ============================================================
-- Ny bruger → profil
-- ============================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, name)
  values (new.id, left(coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1), 'Ny spiller'), 30))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- Låsen: hvorfor kan man ikke afgive kald lige nu? (null = åben)
-- ============================================================
create or replace function public.lock_reason(m public.matches)
returns text language sql stable as $$
  select case
    when m.status = 'finished' then 'Kampen er slut'
    when m.status = 'live' and m.minute >= public.pral_setting('live_close') then 'Live-kald er lukket'
    when m.status = 'live' and m.updated_at < now() - make_interval(secs => public.pral_setting('stale_secs')) then 'Afventer data'
    when m.lock_until is not null and m.lock_until > now() then 'Odds opdateres'
    when m.status = 'scheduled' and m.starts_at is not null and m.starts_at <= now() then 'Kampen er gået i gang'
    else null
  end
$$;

-- ============================================================
-- Afgiv et kald. Serveren slår oddsene op – appen sender dem aldrig.
-- ============================================================
create or replace function public.place_pick(p_match bigint, p_outcome int, p_stake int)
returns public.picks language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := auth.uid();
  m      public.matches;
  why    text;
  rnd    text := public.current_round();
  spent  int;
  result public.picks;
begin
  if uid is null then raise exception 'Du skal være logget ind'; end if;
  if p_outcome not in (0, 1, 2) then raise exception 'Ugyldigt udfald'; end if;
  if p_stake < public.pral_setting('min_stake') or p_stake > public.pral_setting('max_stake') then
    raise exception 'Indsatsen skal være mellem % og % PP', public.pral_setting('min_stake'), public.pral_setting('max_stake');
  end if;

  -- Lås kampens række, så oddsene ikke skifter midt i kaldet
  select * into m from public.matches where id = p_match for share;
  if not found then raise exception 'Kampen findes ikke'; end if;
  why := public.lock_reason(m);
  if why is not null then raise exception '%', why; end if;

  -- Lås brugerens profil, så to kald på samme tid ikke kan bruge det samme budget
  perform 1 from public.profiles where id = uid for update;
  select coalesce(sum(stake), 0) into spent from public.picks where user_id = uid and round = rnd;
  if spent + p_stake > public.pral_setting('round_budget') then
    raise exception 'Du har kun % PP tilbage i denne runde', public.pral_setting('round_budget') - spent;
  end if;

  insert into public.picks (user_id, match_id, outcome, stake, odds, minute, live, round)
  values (uid, m.id, p_outcome, p_stake, m.odds[p_outcome + 1], m.minute, m.status = 'live', rnd)
  returning * into result;
  return result;
end $$;

-- ============================================================
-- Min runde: budget og resultat
-- ============================================================
create or replace function public.my_round()
returns table (round text, budget int, spent int, left_pp int, won int, bonus int, result int, picks int)
language sql stable security definer set search_path = '' as $$
  with p as (
    select * from public.picks where user_id = auth.uid() and round = public.current_round()
  )
  select
    public.current_round(),
    public.pral_setting('round_budget')::int,
    coalesce(sum(stake), 0)::int,
    (public.pral_setting('round_budget') - coalesce(sum(stake), 0))::int,
    coalesce(sum(payout) filter (where status = 'won'), 0)::int,
    (case when count(*) > 0 then public.pral_setting('bonus') else 0 end)::int,
    (coalesce(sum(payout - stake) filter (where status <> 'pending'), 0)
      + case when count(*) > 0 then public.pral_setting('bonus') else 0 end)::int,
    count(*)::int
  from p
$$;

-- ============================================================
-- Klubber
-- ============================================================
create or replace function public.is_member(p_club uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.club_members where club_id = p_club and user_id = auth.uid())
$$;

create or replace function public.create_club(p_name text)
returns public.clubs language plpgsql security definer set search_path = '' as $$
declare c public.clubs;
begin
  if auth.uid() is null then raise exception 'Du skal være logget ind'; end if;
  insert into public.clubs (name, owner) values (trim(p_name), auth.uid()) returning * into c;
  insert into public.club_members (club_id, user_id) values (c.id, auth.uid());
  return c;
end $$;

create or replace function public.join_club(p_code text)
returns public.clubs language plpgsql security definer set search_path = '' as $$
declare c public.clubs;
begin
  if auth.uid() is null then raise exception 'Du skal være logget ind'; end if;
  select * into c from public.clubs where code = upper(trim(p_code));
  if not found then raise exception 'Der findes ingen klub med koden %', upper(trim(p_code)); end if;
  insert into public.club_members (club_id, user_id) values (c.id, auth.uid()) on conflict do nothing;
  return c;
end $$;

-- Rangliste for en klub. p_scope = 'week' (denne runde) eller 'season' (alle runder).
-- Ved pointlighed vinder den med flest kald, der ramte plet.
create or replace function public.club_leaderboard(p_club uuid, p_scope text default 'week')
returns table (user_id uuid, name text, result int, hits int, picks int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_member(p_club) then raise exception 'Du er ikke med i klubben'; end if;
  return query
  with per_round as (
    select p.user_id, p.round,
           sum(case when p.status = 'pending' then 0 else p.payout - p.stake end)
             + public.pral_setting('bonus') as res,
           count(*) filter (where p.status = 'won') as hits,
           count(*) as n
    from public.picks p
    join public.club_members cm on cm.user_id = p.user_id and cm.club_id = p_club
    where p_scope = 'season' or p.round = public.current_round()
    group by p.user_id, p.round
  )
  select cm.user_id, pr.name,
         coalesce(sum(r.res), 0)::int,
         coalesce(sum(r.hits), 0)::int,
         coalesce(sum(r.n), 0)::int
  from public.club_members cm
  join public.profiles pr on pr.id = cm.user_id
  left join per_round r on r.user_id = cm.user_id
  where cm.club_id = p_club
  group by cm.user_id, pr.name
  order by 3 desc, 4 desc, 2;
end $$;

-- ============================================================
-- Afregning ved slutfløjt (kun Edge Functions må kalde den)
-- ============================================================
create or replace function public.settle_match(p_match bigint)
returns int language plpgsql security definer set search_path = '' as $$
declare m public.matches; res int; n int;
begin
  select * into m from public.matches where id = p_match for update;
  if not found or m.status <> 'finished' or m.settled then return 0; end if;
  res := case when m.gh > m.ga then 0 when m.gh = m.ga then 1 else 2 end;
  update public.picks
     set status = case when outcome = res then 'won' else 'lost' end,
         payout = case when outcome = res then round(stake * odds)::int else 0 end
   where match_id = p_match and status = 'pending';
  get diagnostics n = row_count;
  update public.matches set settled = true where id = p_match;
  return n;
end $$;

-- ============================================================
-- Adgang (Row Level Security)
-- ============================================================
alter table public.profiles     enable row level security;
alter table public.teams        enable row level security;
alter table public.league_stats enable row level security;
alter table public.matches      enable row level security;
alter table public.picks        enable row level security;
alter table public.clubs        enable row level security;
alter table public.club_members enable row level security;

-- Alle må se kampe, odds og holdstyrke. Ingen policy til at skrive = kun Edge Functions kan.
drop policy if exists "alle ser kampe" on public.matches;
create policy "alle ser kampe" on public.matches for select to anon, authenticated using (true);
drop policy if exists "alle ser hold" on public.teams;
create policy "alle ser hold" on public.teams for select to anon, authenticated using (true);
drop policy if exists "alle ser ligasnit" on public.league_stats;
create policy "alle ser ligasnit" on public.league_stats for select to anon, authenticated using (true);

-- Profiler: indloggede ser navne, man retter kun sit eget.
drop policy if exists "se navne" on public.profiles;
create policy "se navne" on public.profiles for select to authenticated using (true);
drop policy if exists "ret eget navn" on public.profiles;
create policy "ret eget navn" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Kald: man ser kun sine egne. Oprettes kun via place_pick.
drop policy if exists "se egne kald" on public.picks;
create policy "se egne kald" on public.picks for select to authenticated using (user_id = auth.uid());

-- Klubber: man ser de klubber, man er med i, og deres medlemmer.
drop policy if exists "se egne klubber" on public.clubs;
create policy "se egne klubber" on public.clubs for select to authenticated using (public.is_member(id));
drop policy if exists "se klubkammerater" on public.club_members;
create policy "se klubkammerater" on public.club_members for select to authenticated using (public.is_member(club_id));
drop policy if exists "forlad klub" on public.club_members;
create policy "forlad klub" on public.club_members for delete to authenticated using (user_id = auth.uid());

-- Kun navnet på profilen kan rettes
revoke update on public.profiles from anon, authenticated;
grant update (name) on public.profiles to authenticated;

-- Funktioner: kun de rigtige roller må kalde dem
revoke execute on function public.place_pick(bigint, int, int)   from public, anon;
revoke execute on function public.my_round()                     from public, anon;
revoke execute on function public.create_club(text)              from public, anon;
revoke execute on function public.join_club(text)                from public, anon;
revoke execute on function public.club_leaderboard(uuid, text)   from public, anon;
revoke execute on function public.settle_match(bigint)           from public, anon, authenticated;
revoke execute on function public.handle_new_user()              from public, anon, authenticated;
grant execute on function public.place_pick(bigint, int, int)    to authenticated;
grant execute on function public.my_round()                      to authenticated;
grant execute on function public.create_club(text)               to authenticated;
grant execute on function public.join_club(text)                 to authenticated;
grant execute on function public.club_leaderboard(uuid, text)    to authenticated;

-- ============================================================
-- Realtime: appen får besked med det samme, når odds eller kald ændrer sig
-- ============================================================
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'matches') then
      alter publication supabase_realtime add table public.matches;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'picks') then
      alter publication supabase_realtime add table public.picks;
    end if;
  end if;
end $$;

-- =====================================================================
-- Pral – database til index.html og login.html
-- Kør hele filen én gang: Supabase → SQL Editor → New query → indsæt → Run
-- =====================================================================

-- ---------- Profiler ----------
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text,
  pp int not null default 1000,
  streak int not null default 0,
  badges text[] not null default '{welcome}',
  created_at timestamptz not null default now()
);

-- Opret automatisk en profil, når en bruger opretter sig
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
                                split_part(new.email, '@', 1)), 40))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Klubber ----------
create table public.clubs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  invite_code text not null unique,
  created_by uuid not null default auth.uid() references public.profiles on delete cascade,
  created_at timestamptz not null default now()
);

create table public.club_members (
  club_id uuid not null references public.clubs on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (club_id, user_id)
);

-- ---------- Kald og reaktioner (følg / modspil) ----------
create table public.calls (
  id bigint generated always as identity primary key,
  club_id uuid not null references public.clubs on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  round int not null,
  picks jsonb not null default '[]',
  stake int not null check (stake > 0),
  odds numeric(10,2) not null,
  comment text not null default '' check (char_length(comment) <= 280),
  status text not null default 'pending' check (status in ('pending', 'won', 'lost')),
  created_at timestamptz not null default now()
);
create index calls_club_round on public.calls (club_id, round);

create table public.call_reactions (
  call_id bigint not null references public.calls on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  action text not null check (action in ('follow', 'fade')),
  created_at timestamptz not null default now(),
  primary key (call_id, user_id)
);

-- ---------- Hjælpefunktioner til sikkerheden ----------
create or replace function public.is_club_member(p_club uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.club_members where club_id = p_club and user_id = auth.uid())
$$;

create or replace function public.shares_club(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.club_members a
    join public.club_members b on b.club_id = a.club_id
    where a.user_id = auth.uid() and b.user_id = p_user)
$$;

create or replace function public.call_club(p_call bigint)
returns uuid language sql stable security definer set search_path = public as $$
  select club_id from public.calls where id = p_call
$$;

-- =====================================================================
-- Sikkerhed (Row Level Security)
-- =====================================================================
alter table public.profiles       enable row level security;
alter table public.clubs          enable row level security;
alter table public.club_members   enable row level security;
alter table public.calls          enable row level security;
alter table public.call_reactions enable row level security;

-- Profiler: se dig selv og dem i dine klubber. Ret kun din egen.
create policy "profiles_select" on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_club(id));
create policy "profiles_insert" on public.profiles for insert to authenticated
  with check (id = auth.uid());
create policy "profiles_update" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Klubber: alle loggede ind kan slå en klub op (nødvendigt for at joine med kode)
create policy "clubs_select" on public.clubs for select to authenticated using (true);
create policy "clubs_insert" on public.clubs for insert to authenticated
  with check (created_by = auth.uid());

-- Medlemskaber: se medlemmer i dine klubber. Meld kun dig selv ind og ud.
create policy "members_select" on public.club_members for select to authenticated
  using (user_id = auth.uid() or public.is_club_member(club_id));
create policy "members_insert" on public.club_members for insert to authenticated
  with check (user_id = auth.uid());
create policy "members_update" on public.club_members for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "members_delete" on public.club_members for delete to authenticated
  using (user_id = auth.uid());

-- Kald: se klubbens kald. Afgiv kun egne kald i klubber, du er med i.
create policy "calls_select" on public.calls for select to authenticated
  using (public.is_club_member(club_id));
create policy "calls_insert" on public.calls for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending' and public.is_club_member(club_id));

-- Reaktioner: se klubbens reaktioner. Følg / modspil kun som dig selv.
create policy "reactions_select" on public.call_reactions for select to authenticated
  using (public.is_club_member(public.call_club(call_id)));
create policy "reactions_insert" on public.call_reactions for insert to authenticated
  with check (user_id = auth.uid() and public.is_club_member(public.call_club(call_id)));
create policy "reactions_update" on public.call_reactions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "reactions_delete" on public.call_reactions for delete to authenticated
  using (user_id = auth.uid());

-- Ingen adgang uden login
revoke all on public.profiles, public.clubs, public.club_members, public.calls, public.call_reactions from anon;

-- =====================================================================
-- Live-opdateringer (Realtime) for kald og reaktioner
-- =====================================================================
alter publication supabase_realtime add table public.calls, public.call_reactions;

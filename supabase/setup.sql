-- =============================================================================
-- Breet Run leaderboard: Supabase setup (supabase/setup.sql)
-- Run this once in your Supabase project: Dashboard > SQL Editor > New query >
-- paste everything > Run. It is safe to run again later (it updates in place).
--
-- How it works
--   * Each player claims a username once. Names are unique, ignoring case, so
--     "Hopper" and "hopper" count as the same name.
--   * When a name is claimed, the game makes a secret token and keeps it on the
--     player's device. Only a hash of it is stored here. Scores can only be saved
--     for a username together with its token, so nobody can post as someone else.
--   * The browser never touches the tables directly. Row level security is on
--     with no policies, and the game only calls the functions below.
-- =============================================================================


-- 1. Tables -------------------------------------------------------------------

create table if not exists public.players (
  id          uuid primary key default gen_random_uuid(),
  username    text not null,
  token_hash  text not null,
  created_at  timestamptz not null default now(),
  constraint players_username_format check (username ~ '^[A-Za-z0-9_]{3,16}$')
);

-- One name per person, case-insensitive.
create unique index if not exists players_username_unique
  on public.players (lower(username));

create table if not exists public.scores (
  player_id       uuid not null references public.players (id) on delete cascade,
  level           smallint not null check (level between 1 and 10),
  best            integer not null check (best >= 0),
  coins           integer not null check (coins >= 0),
  updated_at      timestamptz not null default now(),
  last_submit_at  timestamptz not null default now(),
  primary key (player_id, level)
);

create index if not exists scores_level_best_idx
  on public.scores (level, best desc);

-- Coins available in each level (the layouts are fixed). A run can never be worth
-- more than coins x $200, so anything above that is rejected.
-- If you change the levels in the game, update these numbers.
create table if not exists public.level_caps (
  level      smallint primary key,
  max_coins  integer not null
);

insert into public.level_caps (level, max_coins) values
  (1, 78), (2, 76), (3, 105), (4, 118), (5, 113),
  (6, 110), (7, 102), (8, 137), (9, 122), (10, 141)
on conflict (level) do update set max_coins = excluded.max_coins;


-- 2. Lock the tables down -----------------------------------------------------

alter table public.players    enable row level security;
alter table public.scores     enable row level security;
alter table public.level_caps enable row level security;

revoke all on public.players, public.scores, public.level_caps from anon, authenticated;


-- 3. Functions the game calls -------------------------------------------------

-- Shared username rules (the game checks the same rules for instant feedback).
create or replace function public.username_problem(p_username text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_username is null or p_username !~ '^[A-Za-z0-9_]{3,16}$' then 'invalid'
    when lower(p_username) like '%breet%'
      or lower(p_username) in ('admin', 'support', 'official', 'moderator', 'mod', 'staff')
      then 'reserved'
    else null
  end;
$$;

-- Live "is this name free?" check while the player types.
create or replace function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.username_problem(p_username) is null
     and not exists (
       select 1 from public.players where lower(username) = lower(p_username)
     );
$$;

-- Claim a name. The unique index makes this safe even if two people try the
-- same name at the same moment: one wins, the other gets 'taken'.
create or replace function public.claim_username(p_username text, p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_problem text := public.username_problem(p_username);
begin
  if v_problem is not null then
    return json_build_object('ok', false, 'error', v_problem);
  end if;
  if p_token is null or length(p_token) < 32 then
    return json_build_object('ok', false, 'error', 'bad_token');
  end if;

  insert into public.players (username, token_hash)
  values (p_username, encode(sha256(convert_to(p_token, 'UTF8')), 'hex'));

  return json_build_object('ok', true, 'username', p_username);
exception
  when unique_violation then
    return json_build_object('ok', false, 'error', 'taken');
end;
$$;

-- Save a finished run. Keeps each player's best per level and returns their rank.
create or replace function public.submit_score(
  p_username text,
  p_token    text,
  p_level    int,
  p_score    int,
  p_coins    int
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid;
  v_cap     int;
  v_prev    public.scores%rowtype;
  v_best    int;
  v_rank    bigint;
  v_players bigint;
begin
  select id into v_player
    from public.players
   where lower(username) = lower(p_username)
     and token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex');
  if v_player is null then
    return json_build_object('ok', false, 'error', 'unauthorized');
  end if;

  select max_coins into v_cap from public.level_caps where level = p_level;
  if v_cap is null
     or p_coins is null or p_coins < 0 or p_coins > v_cap
     or p_score is null or p_score < 0 or p_score > p_coins * 200 then
    return json_build_object('ok', false, 'error', 'rejected');
  end if;

  -- A level takes at least 45 seconds, so two saves for the same level within
  -- 15 seconds can't come from real play.
  select * into v_prev from public.scores where player_id = v_player and level = p_level;
  if v_prev.last_submit_at is not null and v_prev.last_submit_at > now() - interval '15 seconds' then
    return json_build_object('ok', false, 'error', 'too_fast');
  end if;

  insert into public.scores as s (player_id, level, best, coins)
  values (v_player, p_level, p_score, p_coins)
  on conflict (player_id, level) do update
     set best           = greatest(s.best, excluded.best),
         coins          = case when excluded.best > s.best then excluded.coins else s.coins end,
         updated_at     = case when excluded.best > s.best then now() else s.updated_at end,
         last_submit_at = now()
  returning best into v_best;

  select count(*) + 1 into v_rank    from public.scores where level = p_level and best > v_best;
  select count(*)     into v_players from public.scores where level = p_level;

  return json_build_object(
    'ok', true,
    'best', v_best,
    'improved', coalesce(v_prev.best, -1) < p_score,
    'rank', v_rank,
    'players', v_players
  );
end;
$$;

-- Top players for one level, or overall (sum of each player's level bests) when
-- p_level is null. Ties share a rank; whoever got there first is listed first.
create or replace function public.leaderboard(p_level int default null, p_limit int default 10)
returns table (rank bigint, username text, score bigint)
language sql
stable
security definer
set search_path = public
as $$
  with totals as (
    select s.player_id, sum(s.best)::bigint as score, max(s.updated_at) as reached_at
      from public.scores s
     where p_level is null or s.level = p_level
     group by s.player_id
  )
  select rank() over (order by t.score desc) as rank,
         p.username,
         t.score
    from totals t
    join public.players p on p.id = t.player_id
   order by t.score desc, t.reached_at asc
   limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;

-- Where one player stands, for showing "you" under the top 10.
create or replace function public.player_standing(p_username text, p_level int default null)
returns table (rank bigint, username text, score bigint)
language sql
stable
security definer
set search_path = public
as $$
  with totals as (
    select s.player_id, sum(s.best)::bigint as score
      from public.scores s
     where p_level is null or s.level = p_level
     group by s.player_id
  ),
  me as (
    select t.score, p.username
      from totals t
      join public.players p on p.id = t.player_id
     where lower(p.username) = lower(p_username)
  )
  select (select count(*) + 1 from totals o where o.score > me.score) as rank,
         me.username,
         me.score
    from me;
$$;


-- 4. Who can call what --------------------------------------------------------

revoke execute on function public.username_problem(text) from public, anon, authenticated;

grant execute on function
  public.username_available(text),
  public.claim_username(text, text),
  public.submit_score(text, text, int, int, int),
  public.leaderboard(int, int),
  public.player_standing(text, int)
to anon, authenticated;


-- 5. Handy admin queries (run by hand in the SQL editor when you need them) ----
--
-- Top 20 overall:
--   select * from public.leaderboard(null, 20);
--
-- Remove a player and all their scores (e.g. an offensive name):
--   delete from public.players where lower(username) = lower('their_name');

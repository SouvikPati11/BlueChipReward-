-- ==========================================================================
-- BlueChip Rewards — COMPLETE DATABASE SETUP (one-shot)
--
-- Generated from supabase/migrations/*.sql (in order). This single file lets
-- you set up the entire backend by pasting it into the Supabase SQL Editor
-- and pressing Run — no CLI or local tools required. It is idempotent and
-- safe to re-run. The migrations/ folder + Supabase Deploy workflow remain
-- the canonical path for CLI-based deploys; this file mirrors them.
-- ==========================================================================


-- ==========================================================================
-- >>> supabase/migrations/0001_schema.sql
-- ==========================================================================
-- ============================================================================
-- BlueChip Rewards — Core Schema
-- All monetary/points state lives here. The Flutter client NEVER writes to
-- these tables directly; every balance change flows through SECURITY DEFINER
-- functions (see 0003_functions.sql) that lock the wallet row and append an
-- immutable ledger entry.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type user_status       as enum ('active', 'suspended', 'banned');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app_role          as enum ('user', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ledger_type        as enum (
    'daily_reward', 'mining', 'scratch', 'ad', 'quiz', 'task',
    'referral', 'signup_bonus', 'withdrawal_hold', 'withdrawal_refund',
    'admin_adjustment'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type mining_status      as enum ('active', 'settled', 'expired');
exception when duplicate_object then null; end $$;

do $$ begin
  create type scratch_status     as enum ('available', 'scratched', 'expired');
exception when duplicate_object then null; end $$;

do $$ begin
  create type task_type          as enum ('link_visit', 'telegram', 'social', 'invite', 'custom');
exception when duplicate_object then null; end $$;

do $$ begin
  create type task_state         as enum ('pending', 'verified', 'rewarded', 'rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type withdrawal_status  as enum ('pending', 'approved', 'rejected', 'paid');
exception when duplicate_object then null; end $$;

do $$ begin
  create type notification_type  as enum ('reward', 'withdrawal', 'task', 'daily', 'announcement', 'system');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Profiles  (1:1 with auth.users)
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text,
  full_name     text,
  username      text unique,
  avatar_url    text,
  referral_code text unique not null,
  referred_by   uuid references public.profiles(id),
  status        user_status not null default 'active',
  metadata      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_profiles_referred_by on public.profiles(referred_by);

-- ---------------------------------------------------------------------------
-- Roles  (server-authoritative; never a client boolean)
-- ---------------------------------------------------------------------------
create table if not exists public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role    app_role not null,
  primary key (user_id, role)
);

-- ---------------------------------------------------------------------------
-- Wallet cache  (fast read; the ledger is the source of truth)
-- ---------------------------------------------------------------------------
create table if not exists public.wallets (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  balance            bigint not null default 0 check (balance >= 0),
  total_earned       bigint not null default 0 check (total_earned >= 0),
  total_withdrawn    bigint not null default 0 check (total_withdrawn >= 0),
  pending_withdrawal bigint not null default 0 check (pending_withdrawal >= 0),
  updated_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Immutable ledger  (append-only; the audit trail for every BCP movement)
-- ---------------------------------------------------------------------------
create table if not exists public.wallet_transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  amount        bigint not null,                    -- signed: +credit / -debit
  balance_after bigint not null,
  type          ledger_type not null,
  reference_id  uuid,
  description   text,
  metadata      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists idx_tx_user_created on public.wallet_transactions(user_id, created_at desc);
create index if not exists idx_tx_type on public.wallet_transactions(type);

-- ---------------------------------------------------------------------------
-- App settings  (admin-configurable reward values / limits / availability)
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id)
);

-- ---------------------------------------------------------------------------
-- Daily reward claims
-- ---------------------------------------------------------------------------
create table if not exists public.daily_reward_claims (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  claim_date date not null default (now() at time zone 'utc')::date,
  streak     int  not null default 1,
  amount     bigint not null,
  created_at timestamptz not null default now(),
  unique (user_id, claim_date)
);

-- ---------------------------------------------------------------------------
-- Mining sessions  (server-authoritative lazy accrual)
-- ---------------------------------------------------------------------------
create table if not exists public.mining_sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  started_at      timestamptz not null default now(),
  ends_at         timestamptz not null,
  rate_per_hour   bigint not null,
  accrued         bigint not null default 0,
  claimed         bigint not null default 0,
  status          mining_status not null default 'active',
  last_settled_at timestamptz not null default now(),
  created_at      timestamptz not null default now()
);
-- at most one active session per user
create unique index if not exists uniq_active_mining
  on public.mining_sessions(user_id) where (status = 'active');

-- ---------------------------------------------------------------------------
-- Scratch cards  (reward decided server-side at issue time, hidden until scratch)
-- ---------------------------------------------------------------------------
create table if not exists public.scratch_cards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  reward_amount bigint not null,
  status        scratch_status not null default 'available',
  source        text not null default 'daily',
  issued_date   date not null default (now() at time zone 'utc')::date,
  expires_at    timestamptz,
  scratched_at  timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists idx_scratch_user on public.scratch_cards(user_id, status);

-- ---------------------------------------------------------------------------
-- Ad reward events  (server rate-limited; optional AdMob SSV verification)
-- ---------------------------------------------------------------------------
create table if not exists public.ad_rewards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  reward_amount bigint not null,
  network       text not null default 'admob',
  verified      boolean not null default false,
  ssv_signature text,
  reward_date   date not null default (now() at time zone 'utc')::date,
  created_at    timestamptz not null default now()
);
create index if not exists idx_ad_user_date on public.ad_rewards(user_id, reward_date);

-- ---------------------------------------------------------------------------
-- Quiz
-- ---------------------------------------------------------------------------
create table if not exists public.quizzes (
  id         uuid primary key default gen_random_uuid(),
  quiz_date  date not null unique,
  title      text not null,
  reward     bigint not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.quiz_questions (
  id            uuid primary key default gen_random_uuid(),
  quiz_id       uuid not null references public.quizzes(id) on delete cascade,
  position      int not null default 0,
  question      text not null,
  options       jsonb not null,          -- ["A","B","C","D"]
  correct_index int not null             -- never sent to the client
);
create index if not exists idx_qq_quiz on public.quiz_questions(quiz_id, position);
create table if not exists public.quiz_attempts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  quiz_id       uuid not null references public.quizzes(id) on delete cascade,
  correct_count int not null,
  total_count   int not null,
  reward        bigint not null,
  created_at    timestamptz not null default now(),
  unique (user_id, quiz_id)
);

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------
create table if not exists public.tasks (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  description   text,
  type          task_type not null default 'link_visit',
  reward        bigint not null,
  action_url    text,
  instructions  text,
  config        jsonb not null default '{}'::jsonb,   -- e.g. { "telegram_chat_id": "..." }
  auto_verify   boolean not null default false,
  active        boolean not null default true,
  position      int not null default 0,
  created_at    timestamptz not null default now()
);
create table if not exists public.task_completions (
  id           uuid primary key default gen_random_uuid(),
  task_id      uuid not null references public.tasks(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  state        task_state not null default 'pending',
  proof        jsonb not null default '{}'::jsonb,
  reward       bigint,
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid references public.profiles(id),
  unique (task_id, user_id)
);
create index if not exists idx_task_comp_user on public.task_completions(user_id);
create index if not exists idx_task_comp_state on public.task_completions(state);

-- ---------------------------------------------------------------------------
-- Referrals  (one row per referred user; reward paid through the ledger)
-- ---------------------------------------------------------------------------
create table if not exists public.referrals (
  id            uuid primary key default gen_random_uuid(),
  referrer_id   uuid not null references public.profiles(id) on delete cascade,
  referred_id   uuid not null references public.profiles(id) on delete cascade,
  level         int not null default 1,
  reward_amount bigint not null default 0,
  created_at    timestamptz not null default now(),
  unique (referred_id, level)
);
create index if not exists idx_ref_referrer on public.referrals(referrer_id);

-- ---------------------------------------------------------------------------
-- Payment methods + Withdrawals  (manual review by admin)
-- ---------------------------------------------------------------------------
create table if not exists public.payment_methods (
  id         uuid primary key default gen_random_uuid(),
  key        text unique not null,       -- 'upi', 'paytm', 'bank', 'usdt' ...
  name       text not null,
  fields     jsonb not null default '[]'::jsonb, -- [{ "key":"upi_id","label":"UPI ID","type":"text" }]
  min_amount bigint not null default 0,
  active     boolean not null default true,
  position   int not null default 0
);
create table if not exists public.withdrawals (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  amount       bigint not null check (amount > 0),
  method_key   text not null,
  details      jsonb not null default '{}'::jsonb,
  status       withdrawal_status not null default 'pending',
  admin_notes  text,
  created_at   timestamptz not null default now(),
  processed_at timestamptz,
  processed_by uuid references public.profiles(id)
);
create index if not exists idx_wd_user on public.withdrawals(user_id, created_at desc);
create index if not exists idx_wd_status on public.withdrawals(status);

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.profiles(id) on delete cascade,  -- null = broadcast
  title      text not null,
  body       text,
  type       notification_type not null default 'system',
  data       jsonb not null default '{}'::jsonb,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists idx_notif_user on public.notifications(user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------
create table if not exists public.audit_logs (
  id         uuid primary key default gen_random_uuid(),
  actor_id   uuid references public.profiles(id),
  action     text not null,
  entity     text,
  entity_id  text,
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_created on public.audit_logs(created_at desc);


-- ==========================================================================
-- >>> supabase/migrations/0002_core_functions.sql
-- ==========================================================================
-- ============================================================================
-- Core helpers: settings accessor, role check, ledger primitive, signup trigger
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Settings accessor with a numeric fallback
-- ---------------------------------------------------------------------------
create or replace function public.setting_num(p_key text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = p_key), p_default);
$$;

create or replace function public.setting_json(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select value from public.app_settings where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Role check (used by RLS policies and admin RPCs)
-- ---------------------------------------------------------------------------
create or replace function public.is_admin(p_uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.user_roles where user_id = p_uid and role = 'admin');
$$;

-- Guard: the caller must be an active (non-banned/suspended) user
create or replace function public.assert_active_user(p_uid uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_status user_status;
begin
  select status into v_status from public.profiles where id = p_uid;
  if v_status is null then
    raise exception 'PROFILE_NOT_FOUND';
  end if;
  if v_status <> 'active' then
    raise exception 'ACCOUNT_%', upper(v_status::text);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ledger primitive — the ONLY way BCP moves. Locks the wallet row, appends an
-- immutable ledger entry, and updates the wallet cache atomically.
-- Positive amount = credit, negative = debit.
-- ---------------------------------------------------------------------------
create or replace function public._apply_ledger(
  p_user        uuid,
  p_amount      bigint,
  p_type        ledger_type,
  p_reference   uuid   default null,
  p_description text   default null,
  p_metadata    jsonb  default '{}'::jsonb,
  p_count_earned boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance bigint;
  v_new     bigint;
begin
  -- lock the wallet row for the duration of the transaction
  select balance into v_balance from public.wallets where user_id = p_user for update;
  if not found then
    insert into public.wallets(user_id, balance) values (p_user, 0)
      on conflict (user_id) do nothing;
    select balance into v_balance from public.wallets where user_id = p_user for update;
  end if;

  v_new := v_balance + p_amount;
  if v_new < 0 then
    raise exception 'INSUFFICIENT_BALANCE';
  end if;

  update public.wallets
     set balance      = v_new,
         total_earned = total_earned + (case when p_amount > 0 and p_count_earned then p_amount else 0 end),
         updated_at   = now()
   where user_id = p_user;

  insert into public.wallet_transactions(user_id, amount, balance_after, type, reference_id, description, metadata)
  values (p_user, p_amount, v_new, p_type, p_reference, p_description, coalesce(p_metadata, '{}'::jsonb));

  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Referral code generator
-- ---------------------------------------------------------------------------
create or replace function public._gen_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  loop
    v_code := 'BCP' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.profiles where referral_code = v_code);
  end loop;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------
-- New user handler — creates profile + wallet, resolves referral, pays bonuses.
-- Fired by a trigger on auth.users. The referral code is passed through
-- raw_user_meta_data.referral_code (set by the client at sign-up).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_code   text;
  v_referrer   uuid;
  v_signup_bonus bigint;
  v_ref_reward   bigint;
begin
  v_ref_code := nullif(trim(new.raw_user_meta_data->>'referral_code'), '');

  if v_ref_code is not null then
    select id into v_referrer from public.profiles where referral_code = upper(v_ref_code);
  end if;

  insert into public.profiles(id, email, full_name, avatar_url, referral_code, referred_by)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    public._gen_referral_code(),
    v_referrer
  );

  insert into public.wallets(user_id) values (new.id);
  insert into public.user_roles(user_id, role) values (new.id, 'user') on conflict do nothing;

  -- signup bonus
  v_signup_bonus := public.setting_num('signup_bonus', 0)::bigint;
  if v_signup_bonus > 0 then
    perform public._apply_ledger(new.id, v_signup_bonus, 'signup_bonus', null, 'Welcome bonus');
  end if;

  -- referral reward (self-referral impossible: referrer <> new user by construction)
  if v_referrer is not null and v_referrer <> new.id then
    v_ref_reward := public.setting_num('referral_reward_l1', 0)::bigint;
    insert into public.referrals(referrer_id, referred_id, level, reward_amount)
    values (v_referrer, new.id, 1, v_ref_reward)
    on conflict do nothing;
    if v_ref_reward > 0 then
      perform public._apply_ledger(
        v_referrer, v_ref_reward, 'referral', new.id,
        'Referral reward', jsonb_build_object('referred', new.id)
      );
      insert into public.notifications(user_id, title, body, type, data)
      values (v_referrer, 'New referral joined 🎉',
              'You earned ' || v_ref_reward || ' BCP from a referral.', 'reward',
              jsonb_build_object('referred', new.id));
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- keep profiles.updated_at fresh
create or replace function public._touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public._touch_updated_at();


-- ==========================================================================
-- >>> supabase/migrations/0003_earning_functions.sql
-- ==========================================================================
-- ============================================================================
-- Earning RPCs — every function is SECURITY DEFINER and server-authoritative.
-- The client sends intent only; amounts, eligibility and limits are decided here.
-- All return a jsonb envelope: { ok, ... } or raise a coded exception.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- DAILY REWARD
-- ---------------------------------------------------------------------------
create or replace function public.claim_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_last   record;
  v_streak int := 1;
  v_base   bigint;
  v_step   bigint;
  v_max    int;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- one claim per UTC day
  if exists (select 1 from public.daily_reward_claims where user_id = v_uid and claim_date = v_today) then
    raise exception 'ALREADY_CLAIMED';
  end if;

  select * into v_last from public.daily_reward_claims
    where user_id = v_uid order by claim_date desc limit 1;

  if found and v_last.claim_date = v_today - 1 then
    v_streak := v_last.streak + 1;
  end if;

  v_base := public.setting_num('daily_reward_base', 50)::bigint;
  v_step := public.setting_num('daily_reward_streak_step', 10)::bigint;
  v_max  := public.setting_num('daily_reward_streak_cap', 7)::int;
  if v_streak > v_max then v_streak := v_max; end if;

  v_amount := v_base + v_step * (v_streak - 1);

  insert into public.daily_reward_claims(user_id, claim_date, streak, amount)
  values (v_uid, v_today, v_streak, v_amount);

  v_new := public._apply_ledger(v_uid, v_amount, 'daily_reward', null,
             'Daily reward (day ' || v_streak || ')');

  insert into public.notifications(user_id, title, body, type)
  values (v_uid, 'Daily reward claimed', 'You earned ' || v_amount || ' BCP.', 'daily');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'streak', v_streak, 'balance', v_new);
end;
$$;

create or replace function public.daily_reward_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_last  record;
  v_claimed boolean;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  v_claimed := exists (select 1 from public.daily_reward_claims where user_id = v_uid and claim_date = v_today);
  select * into v_last from public.daily_reward_claims where user_id = v_uid order by claim_date desc limit 1;
  return jsonb_build_object(
    'ok', true,
    'claimed_today', v_claimed,
    'current_streak', coalesce(v_last.streak, 0),
    'next_available_utc', (v_today + 1)::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- MINING  (server-authoritative lazy accrual — survives app close/reopen)
-- ---------------------------------------------------------------------------

-- internal: recompute accrual for an active session, capped at ends_at
create or replace function public._mining_accrued(s public.mining_sessions)
returns bigint
language sql
stable
as $$
  select floor(
    extract(epoch from (least(now(), s.ends_at) - s.started_at)) / 3600.0 * s.rate_per_hour
  )::bigint;
$$;

create or replace function public.start_mining()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_rate     bigint;
  v_hours    numeric;
  v_id       uuid;
  v_ends     timestamptz;
  s          public.mining_sessions;
  v_acc      bigint;
  v_delta    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Auto-settle a completed-but-still-active session (credit any unclaimed
  -- accrual) so the user never loses BCP and a fresh session can begin.
  for s in
    select * from public.mining_sessions
    where user_id = v_uid and status = 'active' and ends_at < now()
    for update
  loop
    v_acc := public._mining_accrued(s);
    v_delta := v_acc - s.claimed;
    if v_delta > 0 then
      perform public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward (auto-settled)');
    end if;
    update public.mining_sessions
       set accrued = v_acc, claimed = v_acc, status = 'settled', last_settled_at = now()
     where id = s.id;
  end loop;

  if exists (select 1 from public.mining_sessions where user_id = v_uid and status = 'active') then
    raise exception 'MINING_ALREADY_ACTIVE';
  end if;

  v_rate  := public.setting_num('mining_rate_per_hour', 20)::bigint;
  v_hours := public.setting_num('mining_session_hours', 8);
  v_ends  := now() + (v_hours || ' hours')::interval;

  insert into public.mining_sessions(user_id, ends_at, rate_per_hour)
  values (v_uid, v_ends, v_rate)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id, 'ends_at', v_ends, 'rate_per_hour', v_rate);
end;
$$;

create or replace function public.mining_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s     public.mining_sessions;
  v_acc bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active' order by started_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'active', false,
      'rate_per_hour', public.setting_num('mining_rate_per_hour', 20),
      'session_hours', public.setting_num('mining_session_hours', 8));
  end if;
  v_acc := public._mining_accrued(s);
  return jsonb_build_object(
    'ok', true, 'active', true, 'session_id', s.id,
    'started_at', s.started_at, 'ends_at', s.ends_at,
    'rate_per_hour', s.rate_per_hour,
    'accrued', v_acc, 'claimable', greatest(v_acc - s.claimed, 0),
    'completed', now() >= s.ends_at
  );
end;
$$;

-- claim (settle) accrued BCP; when the session is finished it is marked settled
create or replace function public.claim_mining()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  s        public.mining_sessions;
  v_acc    bigint;
  v_delta  bigint;
  v_new    bigint;
  v_done   boolean;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active'
    order by started_at desc limit 1
    for update;
  if not found then raise exception 'NO_ACTIVE_MINING'; end if;

  v_acc   := public._mining_accrued(s);
  v_delta := v_acc - s.claimed;
  v_done  := now() >= s.ends_at;

  if v_delta <= 0 and not v_done then
    raise exception 'NOTHING_TO_CLAIM';
  end if;

  if v_delta > 0 then
    v_new := public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  update public.mining_sessions
     set accrued = v_acc,
         claimed = v_acc,
         last_settled_at = now(),
         status = case when v_done then 'settled'::mining_status else 'active'::mining_status end
   where id = s.id;

  return jsonb_build_object('ok', true, 'claimed', greatest(v_delta,0),
                            'balance', v_new, 'session_closed', v_done);
end;
$$;

-- ---------------------------------------------------------------------------
-- SCRATCH CARD  (reward fixed server-side at issue; revealed on scratch)
-- ---------------------------------------------------------------------------

-- pick a weighted reward from settings: scratch_rewards = [{amount, weight}, ...]
create or replace function public._scratch_roll()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg  jsonb := public.setting_json('scratch_rewards');
  v_total numeric := 0;
  v_r     numeric;
  v_acc   numeric := 0;
  it      jsonb;
begin
  if v_cfg is null or jsonb_array_length(v_cfg) = 0 then
    return (10 + floor(random()*40))::bigint;  -- sane fallback 10..50
  end if;
  for it in select * from jsonb_array_elements(v_cfg) loop
    v_total := v_total + coalesce((it->>'weight')::numeric, 1);
  end loop;
  v_r := random() * v_total;
  for it in select * from jsonb_array_elements(v_cfg) loop
    v_acc := v_acc + coalesce((it->>'weight')::numeric, 1);
    if v_r <= v_acc then
      return (it->>'amount')::bigint;
    end if;
  end loop;
  return (v_cfg->0->>'amount')::bigint;
end;
$$;

-- ensure the user has a card available today (issues one if under the daily cap)
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_cap   int;
  v_used  int;
  v_card  public.scratch_cards;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    return jsonb_build_object('ok', true, 'has_card', true, 'card_id', v_card.id);
  end if;

  v_cap  := public.setting_num('scratch_daily_cap', 3)::int;
  select count(*) into v_used from public.scratch_cards
    where user_id = v_uid and issued_date = v_today;
  if v_used >= v_cap then
    return jsonb_build_object('ok', true, 'has_card', false, 'remaining_today', 0);
  end if;

  insert into public.scratch_cards(user_id, reward_amount, source)
  values (v_uid, public._scratch_roll(), 'daily')
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'card_id', v_card.id,
                            'remaining_today', v_cap - v_used - 1);
end;
$$;

create or replace function public.scratch_reveal(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
  v_new  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
  if v_card.status <> 'available' then raise exception 'CARD_ALREADY_USED'; end if;

  update public.scratch_cards
     set status = 'scratched', scratched_at = now()
   where id = v_card.id;

  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id, 'Scratch card reward');

  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount, 'balance', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- WATCH ADS  (server rate-limited; reward amount from settings, not client)
-- If AdMob SSV is configured, the edge function marks rows verified and this
-- RPC can be tightened to require verified=true.
-- ---------------------------------------------------------------------------
create or replace function public.reward_ad()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_cap    int;
  v_used   int;
  v_amount bigint;
  v_min_gap int;
  v_last   timestamptz;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  v_cap := public.setting_num('ads_daily_cap', 20)::int;
  select count(*) into v_used from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  if v_used >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;

  -- minimum seconds between two rewarded ads (anti-spam)
  v_min_gap := public.setting_num('ads_min_gap_seconds', 20)::int;
  select max(created_at) into v_last from public.ad_rewards where user_id = v_uid;
  if v_last is not null and now() - v_last < (v_min_gap || ' seconds')::interval then
    raise exception 'AD_TOO_SOON';
  end if;

  v_amount := public.setting_num('ads_reward', 15)::bigint;

  insert into public.ad_rewards(user_id, reward_amount, network, verified)
  values (v_uid, v_amount, 'admob', false);

  v_new := public._apply_ledger(v_uid, v_amount, 'ad', null, 'Rewarded ad');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', v_cap - v_used - 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- DAILY QUIZ  (correct answers never leave the server; graded here)
-- p_answers: [{ "question_id": "...", "answer_index": 2 }, ...]
-- ---------------------------------------------------------------------------
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_quiz public.quizzes;
  v_qs   jsonb;
  v_attempt public.quiz_attempts;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_quiz from public.quizzes
    where active and quiz_date <= (now() at time zone 'utc')::date
    order by quiz_date desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'available', false);
  end if;

  select * into v_attempt from public.quiz_attempts where user_id = v_uid and quiz_id = v_quiz.id;

  -- questions WITHOUT correct_index
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'position', position, 'question', question, 'options', options
         ) order by position), '[]'::jsonb)
    into v_qs
    from public.quiz_questions where quiz_id = v_quiz.id;

  return jsonb_build_object(
    'ok', true, 'available', true, 'quiz_id', v_quiz.id, 'title', v_quiz.title,
    'reward', v_quiz.reward, 'questions', v_qs,
    'attempted', v_attempt.id is not null,
    'result', case when v_attempt.id is not null then
      jsonb_build_object('correct', v_attempt.correct_count, 'total', v_attempt.total_count, 'reward', v_attempt.reward)
      else null end
  );
end;
$$;

create or replace function public.submit_quiz(p_quiz_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_quiz    public.quizzes;
  v_total   int;
  v_correct int := 0;
  v_reward  bigint;
  v_new     bigint;
  ans       jsonb;
  v_ci      int;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_quiz from public.quizzes where id = p_quiz_id and active;
  if not found then raise exception 'QUIZ_NOT_FOUND'; end if;

  if exists (select 1 from public.quiz_attempts where user_id = v_uid and quiz_id = p_quiz_id) then
    raise exception 'ALREADY_ATTEMPTED';
  end if;

  select count(*) into v_total from public.quiz_questions where quiz_id = p_quiz_id;

  for ans in select * from jsonb_array_elements(coalesce(p_answers, '[]'::jsonb)) loop
    select correct_index into v_ci from public.quiz_questions
      where id = (ans->>'question_id')::uuid and quiz_id = p_quiz_id;
    if v_ci is not null and v_ci = (ans->>'answer_index')::int then
      v_correct := v_correct + 1;
    end if;
  end loop;

  -- reward is proportional to correctness, rounded down
  v_reward := case when v_total > 0 then floor(v_quiz.reward::numeric * v_correct / v_total)::bigint else 0 end;

  insert into public.quiz_attempts(user_id, quiz_id, correct_count, total_count, reward)
  values (v_uid, p_quiz_id, v_correct, v_total, v_reward);

  if v_reward > 0 then
    v_new := public._apply_ledger(v_uid, v_reward, 'quiz', p_quiz_id, 'Daily quiz reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'correct', v_correct, 'total', v_total,
                            'reward', v_reward, 'balance', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- TASKS  (client submits proof; reward only on verified/auto_verify)
-- ---------------------------------------------------------------------------
create or replace function public.submit_task(p_task_id uuid, p_proof jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_task  public.tasks;
  v_comp  public.task_completions;
  v_state task_state;
  v_reward bigint := null;
  v_new   bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_task from public.tasks where id = p_task_id and active;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;

  select * into v_comp from public.task_completions where task_id = p_task_id and user_id = v_uid;
  if found and v_comp.state in ('verified','rewarded') then
    raise exception 'TASK_ALREADY_DONE';
  end if;

  -- auto_verify tasks (e.g. link visit) are rewarded immediately; others go pending
  if v_task.auto_verify then
    v_state := 'rewarded'; v_reward := v_task.reward;
  else
    v_state := 'pending';
  end if;

  insert into public.task_completions(task_id, user_id, state, proof, reward)
  values (p_task_id, v_uid, v_state, coalesce(p_proof,'{}'::jsonb), v_reward)
  on conflict (task_id, user_id)
    do update set state = excluded.state, proof = excluded.proof, reward = excluded.reward, created_at = now();

  if v_state = 'rewarded' then
    v_new := public._apply_ledger(v_uid, v_task.reward, 'task', p_task_id, 'Task: ' || v_task.title);
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'state', v_state, 'reward', coalesce(v_reward,0), 'balance', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- WITHDRAWAL  (manual review; balance is held immediately)
-- ---------------------------------------------------------------------------
create or replace function public.request_withdrawal(p_amount bigint, p_method_key text, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_min   bigint;
  v_pm    public.payment_methods;
  v_wd    uuid;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  select * into v_pm from public.payment_methods where key = p_method_key and active;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_min := greatest(public.setting_num('withdrawal_min', 1000)::bigint, v_pm.min_amount);
  if p_amount < v_min then raise exception 'BELOW_MINIMUM'; end if;

  -- one pending withdrawal at a time
  if exists (select 1 from public.withdrawals where user_id = v_uid and status in ('pending','approved')) then
    raise exception 'WITHDRAWAL_IN_PROGRESS';
  end if;

  -- hold the balance atomically (debit; not counted against total_earned)
  perform public._apply_ledger(v_uid, -p_amount, 'withdrawal_hold', null,
            'Withdrawal request hold', jsonb_build_object('method', p_method_key), false);

  update public.wallets set pending_withdrawal = pending_withdrawal + p_amount where user_id = v_uid;

  insert into public.withdrawals(user_id, amount, method_key, details)
  values (v_uid, p_amount, p_method_key, coalesce(p_details,'{}'::jsonb))
  returning id into v_wd;

  insert into public.notifications(user_id, title, body, type, data)
  values (v_uid, 'Withdrawal submitted',
          'Your request for ' || p_amount || ' BCP is pending review.', 'withdrawal',
          jsonb_build_object('withdrawal_id', v_wd));

  return jsonb_build_object('ok', true, 'withdrawal_id', v_wd);
end;
$$;


-- ==========================================================================
-- >>> supabase/migrations/0004_admin_functions.sql
-- ==========================================================================
-- ============================================================================
-- Admin RPCs — all gate on public.is_admin(). Never callable by regular users.
-- ============================================================================

create or replace function public._assert_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'FORBIDDEN';
  end if;
end;
$$;

-- --- Withdrawals ------------------------------------------------------------
create or replace function public.admin_process_withdrawal(
  p_id uuid, p_status withdrawal_status, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_wd    public.withdrawals;
begin
  perform public._assert_admin();

  select * into v_wd from public.withdrawals where id = p_id for update;
  if not found then raise exception 'WITHDRAWAL_NOT_FOUND'; end if;
  if v_wd.status in ('rejected','paid') then raise exception 'ALREADY_FINALIZED'; end if;

  if p_status = 'rejected' then
    -- refund the held balance
    perform public._apply_ledger(v_wd.user_id, v_wd.amount, 'withdrawal_refund', v_wd.id,
              'Withdrawal rejected — refund', '{}'::jsonb, false);
    update public.wallets
       set pending_withdrawal = greatest(pending_withdrawal - v_wd.amount, 0)
     where user_id = v_wd.user_id;

  elsif p_status = 'paid' then
    -- money leaves the platform: clear the hold, record it as withdrawn
    update public.wallets
       set pending_withdrawal = greatest(pending_withdrawal - v_wd.amount, 0),
           total_withdrawn    = total_withdrawn + v_wd.amount
     where user_id = v_wd.user_id;
  end if;

  update public.withdrawals
     set status = p_status, admin_notes = coalesce(p_notes, admin_notes),
         processed_at = now(), processed_by = v_admin
   where id = p_id;

  insert into public.notifications(user_id, title, body, type, data)
  values (v_wd.user_id, 'Withdrawal ' || p_status,
          'Your withdrawal of ' || v_wd.amount || ' BCP is now ' || p_status || '.',
          'withdrawal', jsonb_build_object('withdrawal_id', p_id, 'status', p_status));

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'withdrawal.' || p_status, 'withdrawal', p_id::text,
          jsonb_build_object('amount', v_wd.amount));

  return jsonb_build_object('ok', true);
end;
$$;

-- --- Task review ------------------------------------------------------------
create or replace function public.admin_review_task(
  p_completion_id uuid, p_approve boolean, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_comp  public.task_completions;
  v_task  public.tasks;
  v_new   bigint;
begin
  perform public._assert_admin();

  select * into v_comp from public.task_completions where id = p_completion_id for update;
  if not found then raise exception 'COMPLETION_NOT_FOUND'; end if;
  if v_comp.state in ('rewarded','rejected') then raise exception 'ALREADY_REVIEWED'; end if;

  select * into v_task from public.tasks where id = v_comp.task_id;

  if p_approve then
    update public.task_completions
       set state = 'rewarded', reward = v_task.reward, reviewed_at = now(), reviewed_by = v_admin
     where id = p_completion_id;
    v_new := public._apply_ledger(v_comp.user_id, v_task.reward, 'task', v_task.id, 'Task: ' || v_task.title);
    insert into public.notifications(user_id, title, body, type)
    values (v_comp.user_id, 'Task approved', 'You earned ' || v_task.reward || ' BCP.', 'task');
  else
    update public.task_completions
       set state = 'rejected', reviewed_at = now(), reviewed_by = v_admin, proof = proof || jsonb_build_object('notes', p_notes)
     where id = p_completion_id;
    insert into public.notifications(user_id, title, body, type)
    values (v_comp.user_id, 'Task rejected', coalesce(p_notes, 'Your task submission was not approved.'), 'task');
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, case when p_approve then 'task.approve' else 'task.reject' end, 'task_completion', p_completion_id::text);

  return jsonb_build_object('ok', true);
end;
$$;

-- --- Balance adjustment -----------------------------------------------------
create or replace function public.admin_adjust_balance(p_user uuid, p_amount bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid(); v_new bigint;
begin
  perform public._assert_admin();
  v_new := public._apply_ledger(p_user, p_amount, 'admin_adjustment', null,
             coalesce(p_reason, 'Admin adjustment'), jsonb_build_object('by', v_admin),
             p_amount > 0);
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'balance.adjust', 'user', p_user::text,
          jsonb_build_object('amount', p_amount, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'balance', v_new);
end;
$$;

-- --- User status ------------------------------------------------------------
create or replace function public.admin_set_user_status(p_user uuid, p_status user_status)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  update public.profiles set status = p_status where id = p_user;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'user.status', 'user', p_user::text, jsonb_build_object('status', p_status));
  return jsonb_build_object('ok', true);
end;
$$;

-- --- Settings ---------------------------------------------------------------
create or replace function public.admin_set_setting(p_key text, p_value jsonb, p_desc text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  insert into public.app_settings(key, value, description, updated_by, updated_at)
  values (p_key, p_value, p_desc, v_admin, now())
  on conflict (key) do update
    set value = excluded.value,
        description = coalesce(excluded.description, public.app_settings.description),
        updated_by = v_admin, updated_at = now();
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'setting.update', 'setting', p_key, jsonb_build_object('value', p_value));
  return jsonb_build_object('ok', true);
end;
$$;

-- --- Broadcast notification -------------------------------------------------
create or replace function public.admin_broadcast(p_title text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  insert into public.notifications(user_id, title, body, type)
  values (null, p_title, p_body, 'announcement');
  insert into public.audit_logs(actor_id, action, entity) values (v_admin, 'broadcast', 'notification');
  return jsonb_build_object('ok', true);
end;
$$;

-- --- Dashboard stats --------------------------------------------------------
create or replace function public.admin_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return jsonb_build_object(
    'ok', true,
    'users', (select count(*) from public.profiles),
    'active_users', (select count(*) from public.profiles where status = 'active'),
    'total_balance', (select coalesce(sum(balance),0) from public.wallets),
    'total_earned', (select coalesce(sum(total_earned),0) from public.wallets),
    'pending_withdrawals', (select count(*) from public.withdrawals where status = 'pending'),
    'pending_withdrawal_amount', (select coalesce(sum(amount),0) from public.withdrawals where status = 'pending'),
    'pending_tasks', (select count(*) from public.task_completions where state = 'pending'),
    'active_mining', (select count(*) from public.mining_sessions where status = 'active')
  );
end;
$$;


-- ==========================================================================
-- >>> supabase/migrations/0005_rls.sql
-- ==========================================================================
-- ============================================================================
-- Row Level Security
-- Principle: the anon/authenticated client may READ its own rows (and public
-- catalog rows). It may NOT write anything money-related directly — every
-- mutation goes through a SECURITY DEFINER RPC. Admins read everything.
-- ============================================================================

alter table public.profiles            enable row level security;
alter table public.user_roles          enable row level security;
alter table public.wallets             enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.app_settings        enable row level security;
alter table public.daily_reward_claims enable row level security;
alter table public.mining_sessions     enable row level security;
alter table public.scratch_cards       enable row level security;
alter table public.ad_rewards          enable row level security;
alter table public.quizzes             enable row level security;
alter table public.quiz_questions      enable row level security;
alter table public.quiz_attempts       enable row level security;
alter table public.tasks               enable row level security;
alter table public.task_completions    enable row level security;
alter table public.referrals           enable row level security;
alter table public.payment_methods     enable row level security;
alter table public.withdrawals         enable row level security;
alter table public.notifications       enable row level security;
alter table public.audit_logs          enable row level security;

-- Helper macro pattern: is_admin() OR owns row.

-- ---- profiles --------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());
-- users may update a limited set of their own fields (columns guarded by a trigger below)
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- Prevent users from changing protected columns via the profiles_update policy.
create or replace function public._guard_profile_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin(auth.uid()) then return new; end if;
  new.id            := old.id;
  new.email         := old.email;
  new.referral_code := old.referral_code;
  new.referred_by   := old.referred_by;
  new.status        := old.status;
  new.created_at    := old.created_at;
  return new;
end; $$;
drop trigger if exists trg_guard_profile on public.profiles;
create trigger trg_guard_profile before update on public.profiles
  for each row execute function public._guard_profile_update();

-- ---- user_roles (read-only to owner; managed server-side) ------------------
drop policy if exists roles_select on public.user_roles;
create policy roles_select on public.user_roles for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- wallets (read own) ----------------------------------------------------
drop policy if exists wallets_select on public.wallets;
create policy wallets_select on public.wallets for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- ledger (read own) -----------------------------------------------------
drop policy if exists tx_select on public.wallet_transactions;
create policy tx_select on public.wallet_transactions for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- app_settings: public catalog values are readable; admin writes via RPC
drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings for select using (true);

-- ---- daily claims / mining / scratch / ads / quiz attempts (read own) ------
drop policy if exists daily_select on public.daily_reward_claims;
create policy daily_select on public.daily_reward_claims for select
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists mining_select on public.mining_sessions;
create policy mining_select on public.mining_sessions for select
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists scratch_select on public.scratch_cards;
create policy scratch_select on public.scratch_cards for select
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists ads_select on public.ad_rewards;
create policy ads_select on public.ad_rewards for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- quizzes: catalog readable; questions hide correct_index via RPC only --
drop policy if exists quizzes_select on public.quizzes;
create policy quizzes_select on public.quizzes for select using (active or public.is_admin());
-- quiz_questions are intentionally NOT selectable by clients (would leak answers).
drop policy if exists qq_select on public.quiz_questions;
create policy qq_select on public.quiz_questions for select using (public.is_admin());

drop policy if exists qa_select on public.quiz_attempts;
create policy qa_select on public.quiz_attempts for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- tasks: active catalog readable; completions read own -----------------
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select using (active or public.is_admin());

drop policy if exists taskcomp_select on public.task_completions;
create policy taskcomp_select on public.task_completions for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- referrals (read own as referrer or referred) --------------------------
drop policy if exists ref_select on public.referrals;
create policy ref_select on public.referrals for select
  using (referrer_id = auth.uid() or referred_id = auth.uid() or public.is_admin());

-- ---- payment methods: active catalog readable -----------------------------
drop policy if exists pm_select on public.payment_methods;
create policy pm_select on public.payment_methods for select using (active or public.is_admin());

-- ---- withdrawals (read own) ------------------------------------------------
drop policy if exists wd_select on public.withdrawals;
create policy wd_select on public.withdrawals for select
  using (user_id = auth.uid() or public.is_admin());

-- ---- notifications (read own + broadcasts) ---------------------------------
drop policy if exists notif_select on public.notifications;
create policy notif_select on public.notifications for select
  using (user_id = auth.uid() or user_id is null or public.is_admin());
-- users may mark their own notifications read
drop policy if exists notif_update on public.notifications;
create policy notif_update on public.notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---- audit logs: admin only ------------------------------------------------
drop policy if exists audit_select on public.audit_logs;
create policy audit_select on public.audit_logs for select using (public.is_admin());

-- ============================================================================
-- Grants: expose only the intended RPCs to authenticated users. No table-level
-- INSERT/UPDATE/DELETE is granted, so the ledger and all balances are only
-- reachable through SECURITY DEFINER functions.
-- ============================================================================
revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.user_roles, public.wallets,
  public.wallet_transactions, public.app_settings, public.daily_reward_claims,
  public.mining_sessions, public.scratch_cards, public.ad_rewards, public.quizzes,
  public.quiz_attempts, public.tasks, public.task_completions, public.referrals,
  public.payment_methods, public.withdrawals, public.notifications,
  public.quiz_questions, public.audit_logs
  to authenticated;
grant update (full_name, username, avatar_url, metadata) on public.profiles to authenticated;
grant update (read) on public.notifications to authenticated;

-- user-facing RPCs
grant execute on function
  public.claim_daily_reward(), public.daily_reward_status(),
  public.start_mining(), public.mining_status(), public.claim_mining(),
  public.scratch_status(), public.scratch_reveal(uuid),
  public.reward_ad(),
  public.quiz_today(), public.submit_quiz(uuid, jsonb),
  public.submit_task(uuid, jsonb),
  public.request_withdrawal(bigint, text, jsonb)
  to authenticated;

-- admin RPCs (defend again inside each fn via _assert_admin)
grant execute on function
  public.admin_process_withdrawal(uuid, withdrawal_status, text),
  public.admin_review_task(uuid, boolean, text),
  public.admin_adjust_balance(uuid, bigint, text),
  public.admin_set_user_status(uuid, user_status),
  public.admin_set_setting(text, jsonb, text),
  public.admin_broadcast(text, text),
  public.admin_stats()
  to authenticated;


-- ==========================================================================
-- >>> supabase/migrations/0006_seed.sql
-- ==========================================================================
-- ============================================================================
-- Seed: default admin-configurable settings, payment methods, and demo content.
-- Values here are safe defaults; the admin can change everything at runtime via
-- admin_set_setting / the admin panel — no APK release required.
-- ============================================================================

insert into public.app_settings(key, value, description) values
  ('signup_bonus',             '100',  'One-time BCP credited on registration'),
  ('daily_reward_base',        '50',   'Base BCP for a daily reward claim'),
  ('daily_reward_streak_step', '10',   'Extra BCP per consecutive day'),
  ('daily_reward_streak_cap',  '7',    'Streak day at which the bonus caps'),
  ('mining_rate_per_hour',     '20',   'BCP accrued per hour while mining'),
  ('mining_session_hours',     '8',    'Length of one mining session in hours'),
  ('scratch_daily_cap',        '3',    'Scratch cards issuable per user per day'),
  ('scratch_rewards',          '[{"amount":10,"weight":40},{"amount":25,"weight":30},{"amount":50,"weight":20},{"amount":100,"weight":9},{"amount":500,"weight":1}]', 'Weighted scratch outcomes'),
  ('ads_reward',               '15',   'BCP per completed rewarded ad'),
  ('ads_daily_cap',            '20',   'Rewarded ads per user per day'),
  ('ads_min_gap_seconds',      '20',   'Minimum seconds between rewarded ads'),
  ('referral_reward_l1',       '200',  'BCP to referrer when a referral signs up'),
  ('withdrawal_min',           '1000', 'Minimum BCP per withdrawal request'),
  ('bcp_to_currency_rate',     '0.001','Display: 1 BCP = this much fiat (info only)'),
  ('currency_symbol',          '"₹"',  'Display currency symbol for wallet estimates'),
  ('maintenance_mode',         'false','When true, earning is paused (client hint)')
on conflict (key) do nothing;

insert into public.payment_methods(key, name, fields, min_amount, position) values
  ('upi',   'UPI',        '[{"key":"upi_id","label":"UPI ID","type":"text"}]', 1000, 0),
  ('paytm', 'Paytm',      '[{"key":"phone","label":"Paytm Number","type":"phone"}]', 1000, 1),
  ('bank',  'Bank Transfer', '[{"key":"account_name","label":"Account Holder","type":"text"},{"key":"account_number","label":"Account Number","type":"text"},{"key":"ifsc","label":"IFSC","type":"text"}]', 5000, 2),
  ('usdt',  'USDT (TRC20)', '[{"key":"wallet","label":"USDT Wallet Address","type":"text"}]', 10000, 3)
on conflict (key) do nothing;

insert into public.tasks(title, description, type, reward, action_url, instructions, auto_verify, position) values
  ('Join our Telegram', 'Join the official BlueChip Telegram channel for updates.', 'telegram', 150, 'https://t.me/bluechiprewards', 'Tap the link, join, then come back and claim.', true, 0),
  ('Follow us on X', 'Follow @BlueChipRewards for announcements.', 'social', 100, 'https://x.com/bluechiprewards', 'Follow, then claim your reward.', true, 1),
  ('Rate the app', 'Leave a review on the Play Store.', 'link_visit', 200, 'https://play.google.com/store', 'Open the store listing and rate us.', true, 2),
  ('Invite a friend', 'Share your referral link with a friend.', 'invite', 0, null, 'Use your referral link from the Referral tab.', false, 3)
on conflict do nothing;

-- A starter quiz for today (UTC)
do $$
declare v_qid uuid; v_date date := (now() at time zone 'utc')::date;
begin
  if not exists (select 1 from public.quizzes where quiz_date = v_date) then
    insert into public.quizzes(quiz_date, title, reward) values (v_date, 'Daily Brain Teaser', 100)
      returning id into v_qid;
    insert into public.quiz_questions(quiz_id, position, question, options, correct_index) values
      (v_qid, 0, 'What does BCP stand for in this app?',
        '["BlueChip Points","Basic Credit Points","Bonus Coin Pay","Blue Cash Prize"]', 0),
      (v_qid, 1, 'Which of these is an earning method here?',
        '["Mining","Trading stocks","Selling data","None"]', 0),
      (v_qid, 2, 'Withdrawals in BlueChip Rewards are…',
        '["Automatic instantly","Manually reviewed by admin","Not supported","Random"]', 1);
  end if;
end $$;


-- ==========================================================================
-- >>> supabase/migrations/0007_ssv_function.sql
-- ==========================================================================
-- ============================================================================
-- Optional AdMob Server-Side Verification (SSV) support.
-- The admob-ssv-callback edge function verifies Google's RSA signature, then
-- calls this idempotent RPC (via the service role) to credit the reward exactly
-- once per unique signature. Safe to leave unused; reward_ad() is the default
-- client-confirmed + rate-limited path.
-- ============================================================================
create or replace function public.credit_verified_ad(
  p_user uuid, p_amount bigint, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_new bigint;
begin
  -- idempotency: the same signature never credits twice
  if exists (select 1 from public.ad_rewards where ssv_signature = p_signature) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  insert into public.ad_rewards(user_id, reward_amount, network, verified, ssv_signature)
  values (p_user, p_amount, 'admob', true, p_signature);

  v_new := public._apply_ledger(p_user, p_amount, 'ad', null, 'Rewarded ad (SSV verified)');
  return jsonb_build_object('ok', true, 'balance', v_new);
end;
$$;

create unique index if not exists uniq_ad_ssv on public.ad_rewards(ssv_signature)
  where ssv_signature is not null;

-- only the service role (edge function) may call this
revoke all on function public.credit_verified_ad(uuid, bigint, text) from public, anon, authenticated;


-- ==========================================================================
-- >>> supabase/migrations/0008_referral_apply.sql
-- ==========================================================================
-- ============================================================================
-- Apply a referral code after account creation (used by Google sign-in, or when
-- a user enters a code shortly after registering). Idempotent and abuse-guarded:
--   * no-op if the caller was already referred
--   * self-referral rejected
--   * code must belong to an existing active user
-- ============================================================================
create or replace function public.apply_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_referrer uuid;
  v_reward   bigint;
  v_created  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  -- only brand-new accounts (within a short grace window) may attach a referrer
  select referred_by, created_at into v_referrer, v_created
    from public.profiles where id = v_uid;
  if v_referrer is not null then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'already_referred');
  end if;
  if now() - v_created > interval '1 hour' then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'window_closed');
  end if;

  select id into v_referrer from public.profiles
    where referral_code = upper(p_code) and status = 'active';
  if v_referrer is null then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'invalid_code');
  end if;
  if v_referrer = v_uid then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'self_referral');
  end if;

  update public.profiles set referred_by = v_referrer where id = v_uid;

  v_reward := public.setting_num('referral_reward_l1', 0)::bigint;
  insert into public.referrals(referrer_id, referred_id, level, reward_amount)
  values (v_referrer, v_uid, 1, v_reward)
  on conflict do nothing;

  if v_reward > 0 then
    perform public._apply_ledger(v_referrer, v_reward, 'referral', v_uid, 'Referral reward');
    insert into public.notifications(user_id, title, body, type)
    values (v_referrer, 'New referral joined 🎉',
            'You earned ' || v_reward || ' BCP from a referral.', 'reward');
  end if;

  return jsonb_build_object('ok', true, 'applied', true);
end;
$$;

grant execute on function public.apply_referral_code(text) to authenticated;


-- ==========================================================================
-- >>> supabase/migrations/0009_admin_management.sql
-- ==========================================================================
-- ============================================================================
-- Admin content-management RPCs. All are SECURITY DEFINER and gate on
-- _assert_admin(); they never widen what a normal user can do. Every mutation
-- is written to audit_logs. No RLS policy is relaxed.
-- ============================================================================

-- ---- Tasks -----------------------------------------------------------------
create or replace function public.admin_save_task(
  p_id uuid,
  p_title text,
  p_description text,
  p_type task_type,
  p_reward bigint,
  p_action_url text,
  p_instructions text,
  p_auto_verify boolean,
  p_active boolean,
  p_position int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  if p_id is null then
    insert into public.tasks(title, description, type, reward, action_url,
                             instructions, auto_verify, active, position)
    values (p_title, p_description, p_type, p_reward, p_action_url,
            p_instructions, p_auto_verify, coalesce(p_active,true), coalesce(p_position,0))
    returning id into v_id;
  else
    update public.tasks set
      title = p_title, description = p_description, type = p_type,
      reward = p_reward, action_url = p_action_url, instructions = p_instructions,
      auto_verify = p_auto_verify, active = p_active, position = p_position
    where id = p_id returning id into v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, case when p_id is null then 'task.create' else 'task.update' end, 'task', v_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_delete_task(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.tasks where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'task.delete', 'task', p_id::text);
  return jsonb_build_object('ok', true);
end; $$;

-- ---- Quiz ------------------------------------------------------------------
create or replace function public.admin_create_quiz(
  p_quiz_date date, p_title text, p_reward bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  insert into public.quizzes(quiz_date, title, reward)
  values (p_quiz_date, p_title, p_reward)
  on conflict (quiz_date) do update set title = excluded.title, reward = excluded.reward
  returning id into v_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.upsert', 'quiz', v_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_add_quiz_question(
  p_quiz_id uuid, p_question text, p_options jsonb, p_correct_index int, p_position int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) < 2 then
    raise exception 'INVALID_OPTIONS';
  end if;
  if p_correct_index < 0 or p_correct_index >= jsonb_array_length(p_options) then
    raise exception 'INVALID_CORRECT_INDEX';
  end if;
  insert into public.quiz_questions(quiz_id, question, options, correct_index, position)
  values (p_quiz_id, p_question, p_options, p_correct_index, coalesce(p_position,0))
  returning id into v_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.question.add', 'quiz', p_quiz_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_delete_quiz_question(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.quiz_questions where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.question.delete', 'quiz_question', p_id::text);
  return jsonb_build_object('ok', true);
end; $$;

-- ---- Payment methods -------------------------------------------------------
create or replace function public.admin_save_payment_method(
  p_id uuid, p_key text, p_name text, p_fields jsonb,
  p_min_amount bigint, p_active boolean, p_position int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  if p_id is null then
    insert into public.payment_methods(key, name, fields, min_amount, active, position)
    values (p_key, p_name, coalesce(p_fields,'[]'::jsonb), coalesce(p_min_amount,0),
            coalesce(p_active,true), coalesce(p_position,0))
    returning id into v_id;
  else
    update public.payment_methods set
      key = p_key, name = p_name, fields = coalesce(p_fields,'[]'::jsonb),
      min_amount = p_min_amount, active = p_active, position = p_position
    where id = p_id returning id into v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'payment_method.save', 'payment_method', v_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_delete_payment_method(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.payment_methods where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'payment_method.delete', 'payment_method', p_id::text);
  return jsonb_build_object('ok', true);
end; $$;

-- ---- Admin role management -------------------------------------------------
-- Grant/revoke admin. Guard: never remove the last remaining admin.
create or replace function public.admin_set_admin(p_user uuid, p_grant boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_admin_count int;
begin
  perform public._assert_admin();
  if p_grant then
    insert into public.user_roles(user_id, role) values (p_user, 'admin')
    on conflict do nothing;
  else
    select count(*) into v_admin_count from public.user_roles where role = 'admin';
    if v_admin_count <= 1 then raise exception 'CANNOT_REMOVE_LAST_ADMIN'; end if;
    delete from public.user_roles where user_id = p_user and role = 'admin';
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, case when p_grant then 'role.grant_admin' else 'role.revoke_admin' end,
          'user', p_user::text, jsonb_build_object('grant', p_grant));
  return jsonb_build_object('ok', true);
end; $$;

grant execute on function
  public.admin_save_task(uuid, text, text, task_type, bigint, text, text, boolean, boolean, int),
  public.admin_delete_task(uuid),
  public.admin_create_quiz(date, text, bigint),
  public.admin_add_quiz_question(uuid, text, jsonb, int, int),
  public.admin_delete_quiz_question(uuid),
  public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int),
  public.admin_delete_payment_method(uuid),
  public.admin_set_admin(uuid, boolean)
  to authenticated;


-- >>> supabase/migrations/0010_referral_multilevel.sql
-- ============================================================================
-- Multi-level referral system (server-authoritative, idempotent, fraud-guarded)
--
--   * Levels and per-level rewards are admin-configurable via the app_settings
--     key `referral_levels` (a JSON array of BCP amounts, index 0 = level 1).
--   * A referral chain is walked upward from a new user's direct referrer and
--     each ancestor is credited for the corresponding level exactly once.
--   * Idempotency is enforced by referrals.unique(referred_id, level): a level
--     is credited only when its row is newly inserted.
--   * Self-referral / same-device abuse is scored; strong matches are withheld
--     and queued for admin review instead of being credited automatically.
--
-- This migration REPLACES the single-level logic in handle_new_user() and
-- apply_referral_code() with a shared chain walker. All existing behaviour
-- (signup bonus, profile/wallet creation, level-1 reward defaults) is preserved.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Devices seen per account (populated at signup + via register_device RPC).
-- Used to detect the same physical device creating and referring itself.
-- ---------------------------------------------------------------------------
create table if not exists public.account_devices (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  device_id  text not null,
  created_at timestamptz not null default now(),
  unique (user_id, device_id)
);
create index if not exists idx_account_devices_device on public.account_devices(device_id);

-- ---------------------------------------------------------------------------
-- Referral fraud review queue. A withheld (suspicious) referral lands here for
-- an admin to approve (pay it) or reject (discard it).
-- ---------------------------------------------------------------------------
do $$ begin
  create type referral_review_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.referral_reviews (
  id            uuid primary key default gen_random_uuid(),
  referrer_id   uuid not null references public.profiles(id) on delete cascade,
  referred_id   uuid not null references public.profiles(id) on delete cascade,
  level         int not null default 1,
  reward_amount bigint not null default 0,
  score         int not null default 0,
  reason        text,
  signals       jsonb not null default '{}'::jsonb,
  status        referral_review_status not null default 'pending',
  created_at    timestamptz not null default now(),
  reviewed_at   timestamptz,
  reviewed_by   uuid references public.profiles(id),
  unique (referred_id, level)
);
create index if not exists idx_ref_reviews_status on public.referral_reviews(status, created_at desc);

-- Enable RLS; only the owner reads their own reviews, admins manage via RPC.
alter table public.account_devices enable row level security;
alter table public.referral_reviews enable row level security;

do $$ begin
  create policy account_devices_self on public.account_devices
    for select using (user_id = auth.uid());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy referral_reviews_admin_read on public.referral_reviews
    for select using (public.is_admin());
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Read the configured per-level rewards as a bigint[]. Falls back to the legacy
-- single `referral_reward_l1` value when `referral_levels` is unset.
-- ---------------------------------------------------------------------------
create or replace function public._referral_level_rewards()
returns bigint[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_json   jsonb := public.setting_json('referral_levels');
  v_result bigint[];
  v_l1     bigint;
begin
  if v_json is not null and jsonb_typeof(v_json) = 'array'
     and jsonb_array_length(v_json) > 0 then
    select array_agg((elem #>> '{}')::bigint order by ord)
      into v_result
      from jsonb_array_elements(v_json) with ordinality as t(elem, ord);
    return v_result;
  end if;
  -- legacy fallback: single level
  v_l1 := public.setting_num('referral_reward_l1', 0)::bigint;
  return array[v_l1];
end;
$$;

-- ---------------------------------------------------------------------------
-- Self-referral / same-device abuse score for a (referrer, referred) pair.
-- Higher = more suspicious. Threshold for withholding is 80.
--   +100  referrer == referred (guard; impossible by construction)
--   +85   referred's signup device is already registered to the referrer
--   +45   referrer and referred share the same signup IP
-- "reason"/"signals" are surfaced to the admin review queue.
-- ---------------------------------------------------------------------------
create or replace function public._referral_abuse_score(
  p_referrer uuid,
  p_referred uuid,
  out score  int,
  out reason text,
  out signals jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ref_ip   text;
  v_new_ip   text;
  v_shared_device boolean := false;
  v_same_ip  boolean := false;
begin
  score := 0;
  signals := '{}'::jsonb;

  if p_referrer = p_referred then
    score := 100;
    reason := 'self_referral';
    signals := jsonb_build_object('self', true);
    return;
  end if;

  -- Shared device: any device_id registered to the referred user that also
  -- belongs to the referrer.
  select exists (
    select 1
      from public.account_devices d1
      join public.account_devices d2 on d1.device_id = d2.device_id
     where d1.user_id = p_referred and d2.user_id = p_referrer
  ) into v_shared_device;

  -- Shared signup IP (recorded in profiles.metadata by the client).
  select nullif(metadata->>'signup_ip', '') into v_ref_ip
    from public.profiles where id = p_referrer;
  select nullif(metadata->>'signup_ip', '') into v_new_ip
    from public.profiles where id = p_referred;
  v_same_ip := v_ref_ip is not null and v_ref_ip = v_new_ip;

  if v_shared_device then score := score + 85; end if;
  if v_same_ip then score := score + 45; end if;

  signals := jsonb_build_object('shared_device', v_shared_device, 'same_ip', v_same_ip);
  reason := case
    when v_shared_device then 'same_device'
    when v_same_ip then 'same_ip'
    else null
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Credit one referral level: pay the referrer and notify, exactly once.
-- Runs the abuse check for level 1 (the direct referral); strong matches are
-- queued for admin review instead of paid. Returns true if a reward was paid.
-- ---------------------------------------------------------------------------
create or replace function public._credit_referral_level(
  p_referrer uuid,
  p_referred uuid,
  p_level    int,
  p_reward   bigint
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_score   int;
  v_reason  text;
  v_signals jsonb;
  v_active  boolean;
begin
  if p_referrer is null or p_referred is null or p_referrer = p_referred then
    return false;
  end if;

  -- referrer must be an active account to receive rewards
  select status = 'active' into v_active from public.profiles where id = p_referrer;
  if v_active is not true then
    return false;
  end if;

  -- Fraud screen only the direct (level-1) relationship — deeper ancestors are
  -- structurally distinct accounts.
  if p_level = 1 then
    select score, reason, signals
      into v_score, v_reason, v_signals
      from public._referral_abuse_score(p_referrer, p_referred);

    if v_score >= 80 then
      -- withhold: record for admin review, do not create a referral or credit
      insert into public.referral_reviews(
        referrer_id, referred_id, level, reward_amount, score, reason, signals)
      values (p_referrer, p_referred, p_level, p_reward, v_score, v_reason, v_signals)
      on conflict (referred_id, level) do nothing;
      return false;
    end if;
  end if;

  -- Idempotent claim of this level. If the row already exists, another path
  -- already paid it — do nothing.
  insert into public.referrals(referrer_id, referred_id, level, reward_amount)
  values (p_referrer, p_referred, p_level, p_reward)
  on conflict (referred_id, level) do nothing;

  if not found then
    return false;
  end if;

  if p_reward > 0 then
    perform public._apply_ledger(
      p_referrer, p_reward, 'referral', p_referred,
      'Referral reward (level ' || p_level || ')',
      jsonb_build_object('referred', p_referred, 'level', p_level));
    insert into public.notifications(user_id, title, body, type, data)
    values (
      p_referrer,
      case when p_level = 1 then 'New referral joined 🎉'
           else 'Referral network reward 🎉' end,
      'You earned ' || p_reward || ' BCP from a level-' || p_level || ' referral.',
      'reward',
      jsonb_build_object('referred', p_referred, 'level', p_level));
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Walk the referral chain upward from p_user's direct referrer and pay each
-- configured level. Safe against cycles; idempotent across repeated calls.
-- ---------------------------------------------------------------------------
create or replace function public._pay_referral_chain(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rewards  bigint[] := public._referral_level_rewards();
  v_levels   int := coalesce(array_length(v_rewards, 1), 0);
  v_current  uuid;
  v_next     uuid;
  v_seen     uuid[] := array[p_user];
  v_i        int;
begin
  if v_levels = 0 then
    return;
  end if;

  -- level 1 = the user's direct referrer
  select referred_by into v_current from public.profiles where id = p_user;

  for v_i in 1..v_levels loop
    exit when v_current is null;
    exit when v_current = any(v_seen);           -- cycle / self guard

    perform public._credit_referral_level(v_current, p_user, v_i, v_rewards[v_i]);

    v_seen := v_seen || v_current;
    select referred_by into v_next from public.profiles where id = v_current;
    v_current := v_next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Register a device for the current user (client sends a stable device id).
-- Used for same-device abuse detection.
-- ---------------------------------------------------------------------------
create or replace function public.register_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(trim(p_device_id), '') is null then return; end if;
  insert into public.account_devices(user_id, device_id)
  values (v_uid, trim(p_device_id))
  on conflict (user_id, device_id) do nothing;
end;
$$;
grant execute on function public.register_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Level-wise referral overview for the current user (Refer page).
-- Returns per-level counts + earnings, plus totals and the per-level config.
-- ---------------------------------------------------------------------------
create or replace function public.referral_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_rewards bigint[] := public._referral_level_rewards();
  v_levels  int := coalesce(array_length(v_rewards, 1), 0);
  v_code    text;
  v_rows    jsonb;
  v_total_c bigint;
  v_total_e bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  select referral_code into v_code from public.profiles where id = v_uid;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'level', lvl,
      'reward', case when lvl <= v_levels then v_rewards[lvl] else 0 end,
      'count', coalesce(cnt, 0),
      'earnings', coalesce(earn, 0)
    ) order by lvl), '[]'::jsonb),
    coalesce(sum(cnt), 0),
    coalesce(sum(earn), 0)
  into v_rows, v_total_c, v_total_e
  from (
    select gs.lvl,
           count(r.id)              as cnt,
           coalesce(sum(r.reward_amount), 0) as earn
      from generate_series(1, greatest(v_levels, 1)) as gs(lvl)
      left join public.referrals r
        on r.referrer_id = v_uid and r.level = gs.lvl
     group by gs.lvl
  ) s;

  return jsonb_build_object(
    'code', v_code,
    'levels', v_levels,
    'per_level', v_rows,
    'total_referrals', v_total_c,
    'total_earnings', v_total_e
  );
end;
$$;
grant execute on function public.referral_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list pending referral reviews (with user labels).
-- ---------------------------------------------------------------------------
create or replace function public.admin_referral_reviews(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', rv.id,
      'referrer_id', rv.referrer_id,
      'referrer_email', pr.email,
      'referrer_name', pr.full_name,
      'referred_id', rv.referred_id,
      'referred_email', pd.email,
      'referred_name', pd.full_name,
      'level', rv.level,
      'reward_amount', rv.reward_amount,
      'score', rv.score,
      'reason', rv.reason,
      'signals', rv.signals,
      'status', rv.status,
      'created_at', rv.created_at
    ) order by rv.created_at desc)
    from public.referral_reviews rv
    join public.profiles pr on pr.id = rv.referrer_id
    join public.profiles pd on pd.id = rv.referred_id
    where p_status = 'all' or rv.status::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_referral_reviews(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve (pay) or reject a withheld referral review.
-- Approving credits the referrer through the ledger exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_referral_review(p_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_rev   public.referral_reviews%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;

  select * into v_rev from public.referral_reviews where id = p_id for update;
  if not found then raise exception 'REVIEW_NOT_FOUND'; end if;
  if v_rev.status <> 'pending' then
    return jsonb_build_object('ok', true, 'already', v_rev.status);
  end if;

  if p_approve then
    -- Pay through the idempotent referrals path (bypasses the abuse screen
    -- because an admin has explicitly cleared it).
    insert into public.referrals(referrer_id, referred_id, level, reward_amount)
    values (v_rev.referrer_id, v_rev.referred_id, v_rev.level, v_rev.reward_amount)
    on conflict (referred_id, level) do nothing;
    if found and v_rev.reward_amount > 0 then
      perform public._apply_ledger(
        v_rev.referrer_id, v_rev.reward_amount, 'referral', v_rev.referred_id,
        'Referral reward (level ' || v_rev.level || ', admin approved)',
        jsonb_build_object('referred', v_rev.referred_id, 'level', v_rev.level));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_rev.referrer_id, 'Referral approved 🎉',
              'You earned ' || v_rev.reward_amount || ' BCP from a referral.',
              'reward', jsonb_build_object('referred', v_rev.referred_id));
    end if;
  end if;

  update public.referral_reviews
     set status = case when p_approve then 'approved' else 'rejected' end,
         reviewed_at = now(),
         reviewed_by = v_admin
   where id = p_id;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin,
          case when p_approve then 'referral_review_approve' else 'referral_review_reject' end,
          'referral_review', p_id::text,
          jsonb_build_object('referrer', v_rev.referrer_id, 'referred', v_rev.referred_id));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_resolve_referral_review(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Replace handle_new_user(): record signup device/IP, then pay the full chain.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_code     text;
  v_referrer     uuid;
  v_signup_bonus bigint;
  v_device_id    text;
  v_signup_ip    text;
begin
  v_ref_code  := nullif(trim(new.raw_user_meta_data->>'referral_code'), '');
  v_device_id := nullif(trim(new.raw_user_meta_data->>'device_id'), '');
  v_signup_ip := nullif(trim(new.raw_user_meta_data->>'signup_ip'), '');

  if v_ref_code is not null then
    select id into v_referrer from public.profiles where referral_code = upper(v_ref_code);
  end if;

  insert into public.profiles(id, email, full_name, avatar_url, referral_code, referred_by, metadata)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    public._gen_referral_code(),
    v_referrer,
    jsonb_strip_nulls(jsonb_build_object('signup_ip', v_signup_ip, 'device_id', v_device_id))
  );

  insert into public.wallets(user_id) values (new.id);
  insert into public.user_roles(user_id, role) values (new.id, 'user') on conflict do nothing;

  if v_device_id is not null then
    insert into public.account_devices(user_id, device_id)
    values (new.id, v_device_id) on conflict do nothing;
  end if;

  v_signup_bonus := public.setting_num('signup_bonus', 0)::bigint;
  if v_signup_bonus > 0 then
    perform public._apply_ledger(new.id, v_signup_bonus, 'signup_bonus', null, 'Welcome bonus');
  end if;

  -- Pay the multi-level referral chain (idempotent + fraud-guarded).
  if v_referrer is not null then
    perform public._pay_referral_chain(new.id);
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Replace apply_referral_code(): attach a referrer post-signup (Google flow),
-- then pay the full chain instead of only level 1.
-- ---------------------------------------------------------------------------
create or replace function public.apply_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_referrer uuid;
  v_created  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  select referred_by, created_at into v_referrer, v_created
    from public.profiles where id = v_uid;
  if v_referrer is not null then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'already_referred');
  end if;
  if now() - v_created > interval '1 hour' then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'window_closed');
  end if;

  select id into v_referrer from public.profiles
    where referral_code = upper(p_code) and status = 'active';
  if v_referrer is null then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'invalid_code');
  end if;
  if v_referrer = v_uid then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'self_referral');
  end if;

  update public.profiles set referred_by = v_referrer where id = v_uid;

  perform public._pay_referral_chain(v_uid);

  return jsonb_build_object('ok', true, 'applied', true);
end;
$$;
grant execute on function public.apply_referral_code(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Seed the multi-level reward config (keeps legacy L1 value as level 1).
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('referral_levels', '[200, 50, 25]',
   'Per-level referral rewards in BCP (index 0 = level 1). Controls how many levels pay out.')
on conflict (key) do nothing;


-- >>> supabase/migrations/0011_invite_milestones.sql
-- ============================================================================
-- Invite milestone system (dedicated; replaces the old 'invite' task type)
--
--   * Milestones reward a user for reaching N successful referrals (e.g. 5, 10,
--     20 invites → BCP). Fully admin-managed (CRUD + enable/disable + verify mode).
--   * auto_verify = true  → the server checks the user's real referral count and
--                            credits immediately, exactly once.
--   * auto_verify = false → the user uploads screenshot proof; an admin approves
--                            or rejects; credit happens exactly once on approval.
--   * Every credit flows through the immutable ledger (type 'invite_milestone').
--
-- The legacy seeded 'invite' task is deactivated here. The task_type enum value
-- is left in place (Postgres can't drop enum values safely) but is no longer
-- offered in the admin task editor.
-- ============================================================================

-- Distinct ledger type for milestone rewards (safe, additive).
alter type ledger_type add value if not exists 'invite_milestone';

-- Retire the old invite-type task so it no longer shows in the Tasks list.
update public.tasks set active = false where type = 'invite';

-- ---------------------------------------------------------------------------
-- Claim state
-- ---------------------------------------------------------------------------
do $$ begin
  create type invite_claim_state as enum ('pending', 'credited', 'rejected');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Milestone definitions (admin-managed)
-- ---------------------------------------------------------------------------
create table if not exists public.invite_milestones (
  id          uuid primary key default gen_random_uuid(),
  threshold   int not null,                 -- referrals required
  reward      bigint not null,
  auto_verify boolean not null default true,
  active      boolean not null default true,
  position    int not null default 0,
  created_at  timestamptz not null default now(),
  unique (threshold)
);

-- ---------------------------------------------------------------------------
-- Per-user milestone claims (one row per user+milestone; credited once)
-- ---------------------------------------------------------------------------
create table if not exists public.invite_milestone_claims (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  milestone_id uuid not null references public.invite_milestones(id) on delete cascade,
  state        invite_claim_state not null default 'pending',
  reward       bigint not null default 0,
  proof        jsonb not null default '{}'::jsonb,   -- { "screenshot_url": "..." }
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid references public.profiles(id),
  unique (user_id, milestone_id)
);
create index if not exists idx_inv_claims_state on public.invite_milestone_claims(state, created_at desc);
create index if not exists idx_inv_claims_user on public.invite_milestone_claims(user_id);

alter table public.invite_milestones enable row level security;
alter table public.invite_milestone_claims enable row level security;

-- Milestone definitions are public config (read-only to clients).
do $$ begin
  create policy invite_milestones_read on public.invite_milestones
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;

-- Users read their own claims; admins read all.
do $$ begin
  create policy invite_claims_self on public.invite_milestone_claims
    for select using (user_id = auth.uid() or public.is_admin());
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- The user's verified referral count (successful direct referrals only).
-- ---------------------------------------------------------------------------
create or replace function public._invite_count(p_uid uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.referrals where referrer_id = p_uid and level = 1;
$$;

-- ---------------------------------------------------------------------------
-- Overview for the current user: each active milestone + progress + claim state.
-- ---------------------------------------------------------------------------
create or replace function public.invite_milestones_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  v_count := public._invite_count(v_uid);

  return jsonb_build_object(
    'invite_count', v_count,
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'threshold', m.threshold,
        'reward', m.reward,
        'auto_verify', m.auto_verify,
        'reached', v_count >= m.threshold,
        'state', coalesce(c.state::text, 'none'),
        'claimable', (v_count >= m.threshold and c.id is null)
      ) order by m.threshold)
      from public.invite_milestones m
      left join public.invite_milestone_claims c
        on c.milestone_id = m.id and c.user_id = v_uid
      where m.active
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.invite_milestones_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- Claim a milestone.
--   auto_verify  → verify count server-side and credit immediately (once).
--   manual       → require a screenshot url; create a pending claim for review.
-- Idempotent: a second call returns the existing claim's state.
-- ---------------------------------------------------------------------------
create or replace function public.claim_invite_milestone(
  p_milestone_id uuid,
  p_proof_url    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_m      public.invite_milestones%rowtype;
  v_count  int;
  v_existing public.invite_milestone_claims%rowtype;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_m from public.invite_milestones where id = p_milestone_id;
  if not found or not v_m.active then raise exception 'MILESTONE_UNAVAILABLE'; end if;

  -- already claimed?
  select * into v_existing from public.invite_milestone_claims
    where user_id = v_uid and milestone_id = p_milestone_id;
  if found then
    return jsonb_build_object('ok', true, 'state', v_existing.state, 'already', true);
  end if;

  v_count := public._invite_count(v_uid);
  if v_count < v_m.threshold then
    raise exception 'MILESTONE_NOT_REACHED';
  end if;

  if v_m.auto_verify then
    -- credit immediately, exactly once (unique constraint guards races)
    insert into public.invite_milestone_claims(user_id, milestone_id, state, reward)
    values (v_uid, p_milestone_id, 'credited', v_m.reward)
    on conflict (user_id, milestone_id) do nothing;
    if not found then
      select state into v_existing.state from public.invite_milestone_claims
        where user_id = v_uid and milestone_id = p_milestone_id;
      return jsonb_build_object('ok', true, 'state', v_existing.state, 'already', true);
    end if;
    if v_m.reward > 0 then
      perform public._apply_ledger(
        v_uid, v_m.reward, 'invite_milestone', p_milestone_id,
        'Invite milestone (' || v_m.threshold || ' invites)',
        jsonb_build_object('threshold', v_m.threshold));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_uid, 'Invite milestone reached 🎉',
              'You earned ' || v_m.reward || ' BCP for inviting ' || v_m.threshold || ' friends.',
              'reward', jsonb_build_object('milestone', p_milestone_id));
    end if;
    return jsonb_build_object('ok', true, 'state', 'credited');
  else
    -- manual review: proof required
    if nullif(trim(coalesce(p_proof_url, '')), '') is null then
      raise exception 'PROOF_REQUIRED';
    end if;
    insert into public.invite_milestone_claims(user_id, milestone_id, state, reward, proof)
    values (v_uid, p_milestone_id, 'pending', v_m.reward,
            jsonb_build_object('screenshot_url', trim(p_proof_url)))
    on conflict (user_id, milestone_id) do nothing;
    return jsonb_build_object('ok', true, 'state', 'pending');
  end if;
end;
$$;
grant execute on function public.claim_invite_milestone(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list milestone claims for review.
-- ---------------------------------------------------------------------------
create or replace function public.admin_invite_claims(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'user_id', c.user_id,
      'user_email', p.email,
      'user_name', p.full_name,
      'milestone_id', c.milestone_id,
      'threshold', m.threshold,
      'reward', c.reward,
      'state', c.state,
      'proof', c.proof,
      'invite_count', public._invite_count(c.user_id),
      'created_at', c.created_at
    ) order by c.created_at desc)
    from public.invite_milestone_claims c
    join public.profiles p on p.id = c.user_id
    join public.invite_milestones m on m.id = c.milestone_id
    where p_status = 'all' or c.state::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_invite_claims(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve/reject a pending (manual) milestone claim. Credits exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_invite_claim(p_claim_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_c     public.invite_milestone_claims%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;

  select * into v_c from public.invite_milestone_claims where id = p_claim_id for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  if v_c.state <> 'pending' then
    return jsonb_build_object('ok', true, 'already', v_c.state);
  end if;

  if p_approve then
    update public.invite_milestone_claims
       set state = 'credited', reviewed_at = now(), reviewed_by = v_admin
     where id = p_claim_id;
    if v_c.reward > 0 then
      perform public._apply_ledger(
        v_c.user_id, v_c.reward, 'invite_milestone', v_c.milestone_id,
        'Invite milestone (admin approved)',
        jsonb_build_object('milestone', v_c.milestone_id));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_c.user_id, 'Invite milestone approved 🎉',
              'You earned ' || v_c.reward || ' BCP.', 'reward',
              jsonb_build_object('milestone', v_c.milestone_id));
    end if;
  else
    update public.invite_milestone_claims
       set state = 'rejected', reviewed_at = now(), reviewed_by = v_admin
     where id = p_claim_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin,
          case when p_approve then 'invite_claim_approve' else 'invite_claim_reject' end,
          'invite_milestone_claim', p_claim_id::text,
          jsonb_build_object('user', v_c.user_id, 'milestone', v_c.milestone_id));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_resolve_invite_claim(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin CRUD for milestones.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_invite_milestone(
  p_id uuid, p_threshold int, p_reward bigint,
  p_auto_verify boolean, p_active boolean, p_position int
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_threshold is null or p_threshold < 1 then raise exception 'INVALID_THRESHOLD'; end if;

  if v_id is null then
    insert into public.invite_milestones(threshold, reward, auto_verify, active, position)
    values (p_threshold, p_reward, p_auto_verify, p_active, coalesce(p_position, 0))
    on conflict (threshold) do update
      set reward = excluded.reward, auto_verify = excluded.auto_verify,
          active = excluded.active, position = excluded.position
    returning id into v_id;
  else
    update public.invite_milestones
       set threshold = p_threshold, reward = p_reward, auto_verify = p_auto_verify,
           active = p_active, position = coalesce(p_position, 0)
     where id = v_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'invite_milestone.save', 'invite_milestone', v_id::text,
          jsonb_build_object('threshold', p_threshold, 'reward', p_reward));
  return v_id;
end;
$$;

create or replace function public.admin_delete_invite_milestone(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  delete from public.invite_milestones where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'invite_milestone.delete', 'invite_milestone', p_id::text, '{}'::jsonb);
end;
$$;

grant execute on function
  public.admin_save_invite_milestone(uuid, int, bigint, boolean, boolean, int),
  public.admin_delete_invite_milestone(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Storage bucket for milestone proof screenshots (private; per-user folder).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('proofs', 'proofs', false)
on conflict (id) do nothing;

-- Users may upload/read their own proofs (path prefix = their uid); admins read all.
do $$ begin
  create policy proofs_insert_own on storage.objects
    for insert to authenticated
    with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy proofs_read_own on storage.objects
    for select to authenticated
    using (bucket_id = 'proofs'
           and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Seed default milestones (5 / 10 / 20 invites). Auto-verified by default.
-- ---------------------------------------------------------------------------
insert into public.invite_milestones(threshold, reward, auto_verify, active, position) values
  (5,  500,  true, true, 0),
  (10, 1200, true, true, 1),
  (20, 3000, true, true, 2)
on conflict (threshold) do nothing;


-- >>> supabase/migrations/0012_mining_and_ads.sql
-- ============================================================================
-- Mining overhaul + rewarded-ad gating & ad-funnel accounting
--
-- MINING (all admin-configurable):
--   * 24h sessions, configurable base rate.
--   * Up to N boosts per session (default 3), each +X% of the BASE rate
--     (default 20%; non-compounding unless mining_boost_compounding = true),
--     with a cooldown between boosts (default 2h) and an optional ad requirement.
--   * Server-authoritative checkpoint accrual so a mid-session rate change is
--     accounted exactly (accrual is settled to `accrued` at each boost/claim).
--
-- ADS:
--   * ad_events records the full funnel per ad show: requested → impressed →
--     rewarded → credited, keyed by a server-issued nonce (no replay).
--   * Rewardable actions (daily, scratch, quiz, watch-ads, mining boost) can be
--     gated so BCP is credited ONLY after a successful, unconsumed ad reward.
--     Gating per placement is admin-configurable.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Ad funnel events
-- ---------------------------------------------------------------------------
do $$ begin
  create type ad_event_state as enum ('requested', 'impressed', 'rewarded', 'credited');
exception when duplicate_object then null; end $$;

create table if not exists public.ad_events (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  placement  text not null,                 -- daily | scratch | quiz | watch_ads | mining
  state      ad_event_state not null default 'requested',
  reward     bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_ad_events_user on public.ad_events(user_id, created_at desc);
create index if not exists idx_ad_events_state on public.ad_events(state, created_at desc);
create index if not exists idx_ad_events_placement on public.ad_events(placement, created_at desc);

alter table public.ad_events enable row level security;
do $$ begin
  create policy ad_events_self on public.ad_events
    for select using (user_id = auth.uid() or public.is_admin());
exception when duplicate_object then null; end $$;

-- Is a placement ad-gated? (admin setting ad_gate_<placement>, default true)
create or replace function public._ad_gated(p_placement text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select (value #>> '{}')::boolean from public.app_settings
      where key = 'ad_gate_' || p_placement),
    true);
$$;

-- Begin an ad show: records a 'requested' event and returns its nonce (id).
create or replace function public.ad_begin(p_placement text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);
  insert into public.ad_events(user_id, placement, state)
  values (v_uid, p_placement, 'requested')
  returning id into v_id;
  return jsonb_build_object('ok', true, 'nonce', v_id);
end;
$$;
grant execute on function public.ad_begin(text) to authenticated;

-- Advance an ad event forward (impressed → rewarded). Never moves backward.
create or replace function public.ad_mark(p_nonce uuid, p_state text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_cur ad_event_state;
  v_new ad_event_state;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_state not in ('impressed', 'rewarded') then raise exception 'BAD_STATE'; end if;
  v_new := p_state::ad_event_state;

  select state into v_cur from public.ad_events
    where id = p_nonce and user_id = v_uid for update;
  if not found then raise exception 'AD_EVENT_NOT_FOUND'; end if;

  -- forward-only: requested < impressed < rewarded < credited
  if array_position(array['requested','impressed','rewarded','credited']::text[], v_new::text)
     > array_position(array['requested','impressed','rewarded','credited']::text[], v_cur::text)
  then
    update public.ad_events set state = v_new, updated_at = now() where id = p_nonce;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.ad_mark(uuid, text) to authenticated;

-- Consume a rewarded ad nonce for a gated action. Returns true when the action
-- may proceed. If the placement isn't gated and no nonce is supplied, it's a
-- no-op pass. Marks the event 'credited' so it can't be replayed.
create or replace function public._consume_ad(p_uid uuid, p_placement text, p_nonce uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_state ad_event_state; v_place text;
begin
  if not public._ad_gated(p_placement) then
    -- not gated: if a nonce was supplied, still consume it for accounting
    if p_nonce is not null then
      update public.ad_events set state = 'credited', updated_at = now()
        where id = p_nonce and user_id = p_uid and state <> 'credited';
    end if;
    return true;
  end if;

  if p_nonce is null then raise exception 'AD_REQUIRED'; end if;

  select state, placement into v_state, v_place from public.ad_events
    where id = p_nonce and user_id = p_uid for update;
  if not found then raise exception 'AD_REQUIRED'; end if;
  if v_place <> p_placement then raise exception 'AD_REQUIRED'; end if;
  if v_state = 'credited' then raise exception 'AD_ALREADY_USED'; end if;
  if v_state <> 'rewarded' then raise exception 'AD_NOT_COMPLETED'; end if;

  update public.ad_events set state = 'credited', updated_at = now() where id = p_nonce;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Gate existing reward actions behind ads. The previous ungated signatures are
-- DROPPED so they can't be called to bypass the gate (and so the new
-- default-arg versions aren't ambiguous with the old fixed-arity ones).
-- ---------------------------------------------------------------------------
drop function if exists public.claim_daily_reward();
drop function if exists public.scratch_reveal(uuid);
drop function if exists public.submit_quiz(uuid, jsonb);
drop function if exists public.reward_ad();

-- Daily reward (gated: 'daily')
create or replace function public.claim_daily_reward(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_prev   date;
  v_streak int;
  v_base   bigint;
  v_step   bigint;
  v_cap    int;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  if exists (select 1 from public.daily_reward_claims where user_id = v_uid and claim_date = v_today) then
    raise exception 'ALREADY_CLAIMED_TODAY';
  end if;

  perform public._consume_ad(v_uid, 'daily', p_nonce);

  select claim_date, streak into v_prev, v_streak from public.daily_reward_claims
    where user_id = v_uid order by claim_date desc limit 1;

  if v_prev is null or v_prev < v_today - 1 then
    v_streak := 1;
  else
    v_streak := coalesce(v_streak, 0) + 1;
  end if;

  v_base := public.setting_num('daily_reward_base', 50)::bigint;
  v_step := public.setting_num('daily_reward_streak_step', 10)::bigint;
  v_cap  := public.setting_num('daily_reward_streak_cap', 7)::int;
  v_amount := v_base + v_step * (least(v_streak, v_cap) - 1);

  insert into public.daily_reward_claims(user_id, claim_date, streak, amount)
  values (v_uid, v_today, v_streak, v_amount);

  v_new := public._apply_ledger(v_uid, v_amount, 'daily_reward', null,
                                'Daily reward (day ' || v_streak || ')');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'streak', v_streak, 'balance', v_new);
end;
$$;

-- Scratch reveal (gated: 'scratch')
create or replace function public.scratch_reveal(p_card_id uuid, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
  v_new  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
  if v_card.status <> 'available' then raise exception 'CARD_ALREADY_USED'; end if;

  perform public._consume_ad(v_uid, 'scratch', p_nonce);

  update public.scratch_cards set status = 'scratched', scratched_at = now()
   where id = v_card.id;

  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id, 'Scratch card reward');
  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount, 'balance', v_new);
end;
$$;

-- Quiz submit (gated: 'quiz')
create or replace function public.submit_quiz(p_quiz_id uuid, p_answers jsonb, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_quiz    public.quizzes;
  v_total   int;
  v_correct int := 0;
  v_reward  bigint;
  v_new     bigint;
  ans       jsonb;
  v_ci      int;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_quiz from public.quizzes where id = p_quiz_id and active;
  if not found then raise exception 'QUIZ_NOT_FOUND'; end if;

  if exists (select 1 from public.quiz_attempts where user_id = v_uid and quiz_id = p_quiz_id) then
    raise exception 'ALREADY_ATTEMPTED';
  end if;

  perform public._consume_ad(v_uid, 'quiz', p_nonce);

  select count(*) into v_total from public.quiz_questions where quiz_id = p_quiz_id;

  for ans in select * from jsonb_array_elements(coalesce(p_answers, '[]'::jsonb)) loop
    select correct_index into v_ci from public.quiz_questions
      where id = (ans->>'question_id')::uuid and quiz_id = p_quiz_id;
    if v_ci is not null and v_ci = (ans->>'answer_index')::int then
      v_correct := v_correct + 1;
    end if;
  end loop;

  v_reward := case when v_total > 0 then floor(v_quiz.reward::numeric * v_correct / v_total)::bigint else 0 end;

  insert into public.quiz_attempts(user_id, quiz_id, correct_count, total_count, reward)
  values (v_uid, p_quiz_id, v_correct, v_total, v_reward);

  if v_reward > 0 then
    v_new := public._apply_ledger(v_uid, v_reward, 'quiz', p_quiz_id, 'Daily quiz reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'correct', v_correct, 'total', v_total,
                            'reward', v_reward, 'balance', v_new);
end;
$$;

-- Watch-ads credit (always ad-backed; requires a rewarded nonce)
create or replace function public.reward_ad(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_cap    int;
  v_used   int;
  v_amount bigint;
  v_min_gap int;
  v_last   timestamptz;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  v_cap := public.setting_num('ads_daily_cap', 20)::int;
  select count(*) into v_used from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  if v_used >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;

  v_min_gap := public.setting_num('ads_min_gap_seconds', 20)::int;
  select max(created_at) into v_last from public.ad_rewards where user_id = v_uid;
  if v_last is not null and now() - v_last < (v_min_gap || ' seconds')::interval then
    raise exception 'AD_TOO_SOON';
  end if;

  -- watch_ads is inherently ad-backed regardless of the gate setting
  if not public._ad_gated('watch_ads') then
    -- even when the gate is disabled we still require a completed nonce here,
    -- since the reward exists only because an ad was watched
    null;
  end if;
  if p_nonce is null then raise exception 'AD_REQUIRED'; end if;
  perform public._consume_ad(v_uid, 'watch_ads', p_nonce);

  v_amount := public.setting_num('ads_reward', 15)::bigint;

  insert into public.ad_rewards(user_id, reward_amount, network, verified)
  values (v_uid, v_amount, 'admob', false);
  update public.ad_events set reward = v_amount, updated_at = now() where id = p_nonce;

  v_new := public._apply_ledger(v_uid, v_amount, 'ad', null, 'Rewarded ad');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', v_cap - v_used - 1);
end;
$$;

grant execute on function public.claim_daily_reward(uuid) to authenticated;
grant execute on function public.scratch_reveal(uuid, uuid) to authenticated;
grant execute on function public.submit_quiz(uuid, jsonb, uuid) to authenticated;
grant execute on function public.reward_ad(uuid) to authenticated;

-- ============================================================================
-- MINING OVERHAUL
-- ============================================================================
alter table public.mining_sessions add column if not exists base_rate bigint;
alter table public.mining_sessions add column if not exists boosts int not null default 0;
alter table public.mining_sessions add column if not exists last_boost_at timestamptz;
update public.mining_sessions set base_rate = rate_per_hour where base_rate is null;

-- Checkpoint accrual: settled `accrued` + time since last checkpoint at the
-- current effective rate. Boosts/claims checkpoint so rate changes are exact.
create or replace function public._mining_accrued(s public.mining_sessions)
returns bigint
language sql
stable
as $$
  select s.accrued + floor(
    greatest(extract(epoch from (least(now(), s.ends_at) - s.last_settled_at)), 0)
    / 3600.0 * s.rate_per_hour
  )::bigint;
$$;

create or replace function public.start_mining()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_rate   bigint;
  v_hours  numeric;
  v_id     uuid;
  v_ends   timestamptz;
  s        public.mining_sessions;
  v_acc    bigint;
  v_delta  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  for s in
    select * from public.mining_sessions
    where user_id = v_uid and status = 'active' and ends_at < now()
    for update
  loop
    v_acc := public._mining_accrued(s);
    v_delta := v_acc - s.claimed;
    if v_delta > 0 then
      perform public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward (auto-settled)');
    end if;
    update public.mining_sessions
       set accrued = v_acc, claimed = v_acc, status = 'settled', last_settled_at = now()
     where id = s.id;
  end loop;

  if exists (select 1 from public.mining_sessions where user_id = v_uid and status = 'active') then
    raise exception 'MINING_ALREADY_ACTIVE';
  end if;

  v_rate  := public.setting_num('mining_rate_per_hour', 20)::bigint;
  v_hours := public.setting_num('mining_session_hours', 24);
  v_ends  := now() + (v_hours || ' hours')::interval;

  insert into public.mining_sessions(user_id, ends_at, rate_per_hour, base_rate, last_settled_at)
  values (v_uid, v_ends, v_rate, v_rate, now())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id, 'ends_at', v_ends, 'rate_per_hour', v_rate);
end;
$$;

create or replace function public.mining_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s     public.mining_sessions;
  v_acc bigint;
  v_max int := public.setting_num('mining_max_boosts', 3)::int;
  v_cool numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_pct  numeric := public.setting_num('mining_boost_pct', 20);
  v_next_boost_at timestamptz;
  v_can_boost boolean := false;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active' order by started_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'active', false,
      'rate_per_hour', public.setting_num('mining_rate_per_hour', 20),
      'session_hours', public.setting_num('mining_session_hours', 24),
      'max_boosts', v_max, 'boost_pct', v_pct,
      'boost_requires_ad', coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true));
  end if;
  v_acc := public._mining_accrued(s);
  if s.last_boost_at is not null then
    v_next_boost_at := s.last_boost_at + (v_cool || ' hours')::interval;
  end if;
  v_can_boost := (s.boosts < v_max)
                 and (now() < s.ends_at)
                 and (v_next_boost_at is null or now() >= v_next_boost_at);
  return jsonb_build_object(
    'ok', true, 'active', true, 'session_id', s.id,
    'started_at', s.started_at, 'ends_at', s.ends_at,
    'rate_per_hour', s.rate_per_hour, 'base_rate', coalesce(s.base_rate, s.rate_per_hour),
    'accrued', v_acc, 'claimable', greatest(v_acc - s.claimed, 0),
    'completed', now() >= s.ends_at,
    'boosts', s.boosts, 'max_boosts', v_max, 'boost_pct', v_pct,
    'can_boost', v_can_boost, 'next_boost_at', v_next_boost_at,
    'boost_requires_ad', coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true)
  );
end;
$$;

create or replace function public.claim_mining()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  s        public.mining_sessions;
  v_acc    bigint;
  v_delta  bigint;
  v_new    bigint;
  v_done   boolean;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active'
    order by started_at desc limit 1
    for update;
  if not found then raise exception 'NO_ACTIVE_MINING'; end if;

  v_acc   := public._mining_accrued(s);
  v_delta := v_acc - s.claimed;
  v_done  := now() >= s.ends_at;

  if v_delta <= 0 and not v_done then
    raise exception 'NOTHING_TO_CLAIM';
  end if;

  if v_delta > 0 then
    v_new := public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  update public.mining_sessions
     set accrued = v_acc,
         claimed = v_acc,
         last_settled_at = now(),
         status = case when v_done then 'settled'::mining_status else 'active'::mining_status end
   where id = s.id;

  return jsonb_build_object('ok', true, 'claimed', greatest(v_delta,0),
                            'balance', v_new, 'session_closed', v_done);
end;
$$;

-- Boost the active mining session (gated: 'mining' when boost_requires_ad).
create or replace function public.boost_mining(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  s       public.mining_sessions;
  v_max   int := public.setting_num('mining_max_boosts', 3)::int;
  v_cool  numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_pct   numeric := public.setting_num('mining_boost_pct', 20);
  v_comp  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_compounding'), false);
  v_needs_ad boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true);
  v_acc   bigint;
  v_base  bigint;
  v_new_rate bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active'
    order by started_at desc limit 1 for update;
  if not found then raise exception 'NO_ACTIVE_MINING'; end if;
  if now() >= s.ends_at then raise exception 'SESSION_ENDED'; end if;
  if s.boosts >= v_max then raise exception 'MAX_BOOSTS'; end if;
  if s.last_boost_at is not null and now() - s.last_boost_at < (v_cool || ' hours')::interval then
    raise exception 'BOOST_COOLDOWN';
  end if;

  if v_needs_ad then
    perform public._consume_ad(v_uid, 'mining', p_nonce);
  elsif p_nonce is not null then
    perform public._consume_ad(v_uid, 'mining', p_nonce);
  end if;

  -- checkpoint accrual at the current rate before changing it
  v_acc := public._mining_accrued(s);
  v_base := coalesce(s.base_rate, s.rate_per_hour);

  if v_comp then
    v_new_rate := floor(s.rate_per_hour * (1 + v_pct/100.0))::bigint;
  else
    v_new_rate := v_base + floor(v_base * v_pct/100.0)::bigint * (s.boosts + 1);
  end if;

  update public.mining_sessions
     set accrued = v_acc,
         last_settled_at = now(),
         rate_per_hour = v_new_rate,
         boosts = s.boosts + 1,
         last_boost_at = now()
   where id = s.id;

  return jsonb_build_object('ok', true, 'boosts', s.boosts + 1, 'rate_per_hour', v_new_rate);
end;
$$;
grant execute on function public.boost_mining(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Settings: mining overhaul + ad gating (admin-configurable; safe defaults).
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('mining_max_boosts',          '3',    'Max boosts allowed per mining session'),
  ('mining_boost_cooldown_hours','2',    'Hours required between mining boosts'),
  ('mining_boost_pct',           '20',   'Each boost adds this % of the base mining rate'),
  ('mining_boost_compounding',   'false','If true, each boost multiplies the current rate instead of adding % of base'),
  ('mining_boost_requires_ad',   'true', 'Require a rewarded ad to apply a mining boost'),
  ('ad_gate_daily',              'true', 'Require a rewarded ad to claim the daily reward'),
  ('ad_gate_scratch',            'true', 'Require a rewarded ad to reveal a scratch card'),
  ('ad_gate_quiz',               'true', 'Require a rewarded ad to submit the daily quiz'),
  ('ad_gate_watch_ads',          'true', 'Watch-ads placement (always ad-backed)'),
  ('banner_ads_enabled',         'true', 'Show banner ads at the bottom of earning screens')
on conflict (key) do nothing;

-- Move the default mining session length to 24h (only if still at the old 8h default).
update public.app_settings set value = '24'
  where key = 'mining_session_hours' and value #>> '{}' = '8';


-- >>> supabase/migrations/0013_links_and_reminders.sql
-- ============================================================================
-- Admin-managed page/external links + configurable notification reminders
--
--   * app_links: admin CRUD for buttons/links surfaced in the app (Support,
--     Telegram, FAQ, Website…). URLs are validated on save.
--   * generate_reminders(): produces (idempotent, non-spammy) reminder
--     notifications — daily reward ready, mining session ready, boost ready,
--     unclaimed reward. Each reminder type is admin-toggleable and deep-links
--     into the app. Intended to be run periodically (pg_cron / edge scheduler).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Configurable links
-- ---------------------------------------------------------------------------
create table if not exists public.app_links (
  id         uuid primary key default gen_random_uuid(),
  key        text unique not null,
  label      text not null,
  url        text not null,
  icon       text,                       -- material icon name hint for the app
  external   boolean not null default true,  -- external URL vs in-app route
  position   int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.app_links enable row level security;
do $$ begin
  create policy app_links_read on public.app_links
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;

create or replace function public.app_links_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'key', key, 'label', label, 'url', url,
    'icon', icon, 'external', external
  ) order by position, label), '[]'::jsonb)
  from public.app_links where active;
$$;
grant execute on function public.app_links_list() to authenticated;

create or replace function public.admin_save_app_link(
  p_id uuid, p_key text, p_label text, p_url text,
  p_icon text, p_external boolean, p_position int, p_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if nullif(trim(p_label), '') is null then raise exception 'INVALID_LABEL'; end if;
  if nullif(trim(p_url), '') is null then raise exception 'INVALID_URL'; end if;
  -- validate: external links must be http(s); internal must be an app route.
  if p_external then
    if p_url !~* '^https?://[^\s]+$' then raise exception 'INVALID_URL'; end if;
  else
    if left(p_url, 1) <> '/' then raise exception 'INVALID_ROUTE'; end if;
  end if;

  if v_id is null then
    insert into public.app_links(key, label, url, icon, external, position, active)
    values (coalesce(nullif(trim(p_key),''), 'link_' || substr(gen_random_uuid()::text,1,8)),
            trim(p_label), trim(p_url), nullif(trim(p_icon),''), p_external,
            coalesce(p_position,0), coalesce(p_active,true))
    on conflict (key) do update
      set label = excluded.label, url = excluded.url, icon = excluded.icon,
          external = excluded.external, position = excluded.position, active = excluded.active
    returning id into v_id;
  else
    update public.app_links
       set key = coalesce(nullif(trim(p_key),''), key),
           label = trim(p_label), url = trim(p_url), icon = nullif(trim(p_icon),''),
           external = p_external, position = coalesce(p_position,0), active = coalesce(p_active,true)
     where id = v_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'app_link.save', 'app_link', v_id::text,
          jsonb_build_object('label', p_label, 'url', p_url));
  return v_id;
end;
$$;

create or replace function public.admin_delete_app_link(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  delete from public.app_links where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'app_link.delete', 'app_link', p_id::text, '{}'::jsonb);
end;
$$;

-- Admin reads the full list (incl. inactive) directly via table select (RLS
-- select policy already allows any authenticated user to read active rows; the
-- admin editor uses a dedicated read that includes inactive).
create or replace function public.admin_app_links()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'key', key, 'label', label, 'url', url, 'icon', icon,
      'external', external, 'position', position, 'active', active
    ) order by position, label) from public.app_links
  ), '[]'::jsonb);
end;
$$;

grant execute on function
  public.admin_save_app_link(uuid, text, text, text, text, boolean, int, boolean),
  public.admin_delete_app_link(uuid),
  public.admin_app_links()
  to authenticated;

insert into public.app_links(key, label, url, icon, external, position) values
  ('support',  'Contact Support', 'https://t.me/bluechiprewards', 'support_agent', true, 0),
  ('telegram', 'Telegram Channel', 'https://t.me/bluechiprewards', 'send',          true, 1),
  ('faq',      'FAQ & Help',       'https://souvikpati11.github.io/BlueChipReward-/', 'help_center', true, 2),
  ('terms',    'Terms of Service', 'https://souvikpati11.github.io/BlueChipReward-/terms.html', 'description', true, 3),
  ('privacy',  'Privacy Policy',   'https://souvikpati11.github.io/BlueChipReward-/privacy.html', 'privacy_tip', true, 4)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Reminder notifications (admin-toggleable, deep-linked, de-duplicated).
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('reminder_daily_enabled',     'true', 'Send a reminder when the daily reward is ready again'),
  ('reminder_mining_enabled',    'true', 'Send a reminder when a mining session can be started/claimed'),
  ('reminder_boost_enabled',     'true', 'Send a reminder when a mining boost is available'),
  ('reminder_unclaimed_enabled', 'true', 'Send a reminder when there is unclaimed mined BCP')
on conflict (key) do nothing;

-- Insert one notification per user/type only if none of that type was sent in
-- the given window (spam guard). Returns rows inserted.
create or replace function public._remind(
  p_users uuid[], p_type notification_type, p_title text, p_body text,
  p_data jsonb, p_window interval
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  insert into public.notifications(user_id, title, body, type, data)
  select u, p_title, p_body, p_type, p_data
    from unnest(p_users) as u
   where not exists (
     select 1 from public.notifications n
      where n.user_id = u and n.type = p_type
        and n.data->>'reminder' = p_data->>'reminder'
        and n.created_at > now() - p_window
   );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.generate_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_daily int := 0; v_mining int := 0; v_boost int := 0; v_unclaimed int := 0;
  v_cool numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_max  int := public.setting_num('mining_max_boosts', 3)::int;
begin
  -- Daily reward ready: active users who can claim today but haven't.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_daily_enabled'), true) then
    v_daily := public._remind(
      array(
        select p.id from public.profiles p
        where p.status = 'active'
          and not exists (select 1 from public.daily_reward_claims d
                          where d.user_id = p.id and d.claim_date = v_today)
      ),
      'daily', 'Your daily reward is ready 🎁',
      'Claim your daily BCP before the day ends.',
      jsonb_build_object('reminder', 'daily', 'route', '/earn/daily'),
      interval '20 hours');
  end if;

  -- Mining session ready: active users with no running session.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_mining_enabled'), true) then
    v_mining := public._remind(
      array(
        select p.id from public.profiles p
        where p.status = 'active'
          and not exists (select 1 from public.mining_sessions m
                          where m.user_id = p.id and m.status = 'active' and m.ends_at > now())
      ),
      'system', 'Start mining ⛏️',
      'Your miner is idle — start a session to keep earning BCP.',
      jsonb_build_object('reminder', 'mining', 'route', '/earn/mining'),
      interval '20 hours');
  end if;

  -- Boost ready: active sessions where a boost is available now.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_boost_enabled'), true) then
    v_boost := public._remind(
      array(
        select m.user_id from public.mining_sessions m
        where m.status = 'active' and m.ends_at > now()
          and m.boosts < v_max
          and (m.last_boost_at is null or now() >= m.last_boost_at + (v_cool || ' hours')::interval)
      ),
      'system', 'Mining boost ready 🚀',
      'A boost is available — increase your mining rate now.',
      jsonb_build_object('reminder', 'boost', 'route', '/earn/mining'),
      (v_cool || ' hours')::interval);
  end if;

  -- Unclaimed mined BCP: active sessions with claimable accrual.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_unclaimed_enabled'), true) then
    v_unclaimed := public._remind(
      array(
        select m.user_id from public.mining_sessions m
        where m.status = 'active'
          and public._mining_accrued(m) - m.claimed >= greatest(m.rate_per_hour, 1)
      ),
      'system', 'You have unclaimed BCP 💰',
      'Mined BCP is waiting — open the app to claim it.',
      jsonb_build_object('reminder', 'unclaimed', 'route', '/earn/mining'),
      interval '12 hours');
  end if;

  return jsonb_build_object('ok', true, 'daily', v_daily, 'mining', v_mining,
                            'boost', v_boost, 'unclaimed', v_unclaimed);
end;
$$;

-- Schedule every 30 minutes if pg_cron is available (safe no-op otherwise).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bcp_generate_reminders', '*/30 * * * *',
                          $cron$select public.generate_reminders();$cron$);
  end if;
exception when others then
  -- scheduling is best-effort; ignore if unavailable or already scheduled
  null;
end $$;


-- >>> supabase/migrations/0014_admin_analytics.sql
-- ============================================================================
-- Admin analytics (server-side date filtering) + rich withdrawal listing
--
--   * admin_analytics(from, to): user/BCP/withdrawal totals, the ad funnel
--     (requests vs impressions vs rewarded completions vs credits), and
--     per-feature reward activity — all computed server-side over the range.
--   * admin_withdrawals(status): withdrawals joined with the requester's
--     name/email/id and the payment method label for the detail view.
-- ============================================================================

create or replace function public.admin_analytics(
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz := coalesce(p_from, '-infinity'::timestamptz);
  v_to   timestamptz := coalesce(p_to, 'infinity'::timestamptz);
  v_ads  jsonb;
  v_feat jsonb;
begin
  perform public._assert_admin();

  -- Ad funnel over the range. A row's state is terminal, so a 'credited' row
  -- also counts as an impression and a rewarded completion.
  select jsonb_build_object(
    'requests',   count(*),
    'impressions', count(*) filter (where state in ('impressed','rewarded','credited')),
    'rewarded',    count(*) filter (where state in ('rewarded','credited')),
    'credits',     count(*) filter (where state = 'credited'),
    'credited_bcp', coalesce(sum(reward) filter (where state = 'credited'), 0),
    'by_placement', coalesce((
      select jsonb_object_agg(placement, cnt) from (
        select placement, count(*) filter (where state = 'credited') as cnt
          from public.ad_events
         where created_at >= v_from and created_at <= v_to
         group by placement
      ) p
    ), '{}'::jsonb)
  )
  into v_ads
  from public.ad_events
  where created_at >= v_from and created_at <= v_to;

  -- Per-feature reward activity (positive ledger credits by type over range).
  select coalesce(jsonb_object_agg(t, jsonb_build_object('count', c, 'bcp', s)), '{}'::jsonb)
  into v_feat
  from (
    select type::text as t, count(*) as c, coalesce(sum(amount),0) as s
      from public.wallet_transactions
     where amount > 0 and created_at >= v_from and created_at <= v_to
     group by type
  ) x;

  return jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'total_users', (select count(*) from public.profiles),
    'new_users', (select count(*) from public.profiles
                   where created_at >= v_from and created_at <= v_to),
    'active_users', (select count(distinct user_id) from public.wallet_transactions
                      where created_at >= v_from and created_at <= v_to),
    'bcp_earned', (select coalesce(sum(amount),0) from public.wallet_transactions
                    where amount > 0 and created_at >= v_from and created_at <= v_to),
    'bcp_withdrawn', (select coalesce(sum(amount),0) from public.withdrawals
                       where status = 'paid'
                         and coalesce(processed_at, created_at) >= v_from
                         and coalesce(processed_at, created_at) <= v_to),
    'pending_withdrawals', (select count(*) from public.withdrawals where status = 'pending'),
    'pending_withdrawal_amount', (select coalesce(sum(amount),0) from public.withdrawals where status = 'pending'),
    'ads', v_ads,
    'features', v_feat
  );
end;
$$;
grant execute on function public.admin_analytics(timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Withdrawals with requester + method detail for the admin review screen.
-- ---------------------------------------------------------------------------
create or replace function public.admin_withdrawals(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id,
      'user_id', w.user_id,
      'user_name', p.full_name,
      'user_email', p.email,
      'referral_code', p.referral_code,
      'amount', w.amount,
      'method_key', w.method_key,
      'method_name', coalesce(pm.name, w.method_key),
      'details', w.details,
      'status', w.status,
      'admin_notes', w.admin_notes,
      'created_at', w.created_at,
      'processed_at', w.processed_at,
      'balance', wl.balance
    ) order by w.created_at desc)
    from public.withdrawals w
    join public.profiles p on p.id = w.user_id
    left join public.payment_methods pm on pm.key = w.method_key
    left join public.wallets wl on wl.user_id = w.user_id
    where p_status = 'all' or w.status::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_withdrawals(text) to authenticated;


-- >>> supabase/migrations/0015_referral_modes_and_daily_days.sql
-- ============================================================================
-- Referral reward modes (fixed / percent, per-level enable, system toggle)
-- + day-wise Daily Reward (a configurable amount per day of a 7-day cycle).
--
-- Forward-only. Existing behaviour is preserved: legacy numeric referral_levels
-- are converted in place to the new object shape; daily reward falls back to the
-- old base+streak formula if the day-wise schedule is unset.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Settings + one-time legacy conversion
-- ---------------------------------------------------------------------------
-- Convert legacy referral_levels ([200,50,25]) -> objects with mode/enable.
do $$
declare v jsonb := public.setting_json('referral_levels');
begin
  if v is not null and jsonb_typeof(v) = 'array' and jsonb_array_length(v) > 0
     and jsonb_typeof(v->0) = 'number' then
    update public.app_settings
       set value = (
             select jsonb_agg(jsonb_build_object(
                      'enabled', true, 'type', 'fixed', 'value', (e #>> '{}')::numeric))
             from jsonb_array_elements(v) e)
     where key = 'referral_levels';
  end if;
end $$;

insert into public.app_settings(key, value, description) values
  ('referral_system_enabled', 'true',
   'Master switch for the referral rewards system'),
  ('referral_levels',
   '[{"enabled":true,"type":"fixed","value":100},{"enabled":true,"type":"fixed","value":50},{"enabled":true,"type":"fixed","value":25}]',
   'Per-level referral rewards: each = {enabled, type: fixed|percent, value}'),
  ('referral_qualifying_amount', '500',
   'Base amount a percentage referral reward is calculated from (e.g. 10% of 500 = 50)'),
  ('daily_reward_days', '[10,20,30,40,50,70,100]',
   'BCP reward for each day of the 7-day daily-reward cycle (day 1..7)'),
  ('mining_enabled', 'true', 'Master switch for the mining feature')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Referral config helpers
-- ---------------------------------------------------------------------------
-- Normalised array of level configs (objects). Converts legacy numbers on read
-- as a safety net.
create or replace function public._referral_levels_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v jsonb := public.setting_json('referral_levels');
begin
  if v is null or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
    return jsonb_build_array(jsonb_build_object(
      'enabled', true, 'type', 'fixed',
      'value', public.setting_num('referral_reward_l1', 0)));
  end if;
  if jsonb_typeof(v->0) = 'number' then
    return (select jsonb_agg(jsonb_build_object(
              'enabled', true, 'type', 'fixed', 'value', (e #>> '{}')::numeric))
            from jsonb_array_elements(v) e);
  end if;
  return v;
end;
$$;

-- Base used for percentage rewards (falls back to the signup bonus).
create or replace function public._referral_qualifying_amount()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(public.setting_num('referral_qualifying_amount', 0), 0),
                  public.setting_num('signup_bonus', 0));
$$;

-- Resolve one level config object to a concrete BCP reward (0 when disabled).
create or replace function public._referral_reward_for(cfg jsonb)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_enabled boolean := coalesce((cfg->>'enabled')::boolean, true);
  v_type    text    := coalesce(cfg->>'type', 'fixed');
  v_value   numeric := coalesce((cfg->>'value')::numeric, 0);
begin
  if not v_enabled then return 0; end if;
  if v_type = 'percent' then
    return floor(public._referral_qualifying_amount() * v_value / 100.0)::bigint;
  end if;
  return floor(v_value)::bigint;
end;
$$;

-- Keep the legacy accessor working (used nowhere critical now) — resolved amounts.
create or replace function public._referral_level_rewards()
returns bigint[]
language sql
stable
security definer
set search_path = public
as $$
  select array_agg(public._referral_reward_for(e) order by ord)
  from jsonb_array_elements(public._referral_levels_config()) with ordinality as t(e, ord);
$$;

-- ---------------------------------------------------------------------------
-- Replace the chain walker to honour system toggle + per-level enable/mode.
-- ---------------------------------------------------------------------------
create or replace function public._pay_referral_chain(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg      jsonb := public._referral_levels_config();
  v_levels   int   := coalesce(jsonb_array_length(v_cfg), 0);
  v_current  uuid;
  v_next     uuid;
  v_seen     uuid[] := array[p_user];
  v_i        int;
  v_lvlcfg   jsonb;
  v_reward   bigint;
begin
  if not coalesce((select (value #>> '{}')::boolean from public.app_settings
                    where key = 'referral_system_enabled'), true) then
    return;
  end if;
  if v_levels = 0 then return; end if;

  select referred_by into v_current from public.profiles where id = p_user;

  for v_i in 1..v_levels loop
    exit when v_current is null;
    exit when v_current = any(v_seen);

    v_lvlcfg := v_cfg->(v_i - 1);
    if coalesce((v_lvlcfg->>'enabled')::boolean, true) then
      v_reward := public._referral_reward_for(v_lvlcfg);
      perform public._credit_referral_level(v_current, p_user, v_i, v_reward);
    end if;

    v_seen := v_seen || v_current;
    select referred_by into v_next from public.profiles where id = v_current;
    v_current := v_next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Replace referral_overview to expose modes + resolved rewards.
-- ---------------------------------------------------------------------------
create or replace function public.referral_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_cfg     jsonb := public._referral_levels_config();
  v_levels  int   := coalesce(jsonb_array_length(v_cfg), 0);
  v_code    text;
  v_rows    jsonb;
  v_total_c bigint;
  v_total_e bigint;
  v_enabled boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings
                                 where key='referral_system_enabled'), true);
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select referral_code into v_code from public.profiles where id = v_uid;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'level', lvl,
      'enabled', coalesce(((v_cfg->(lvl-1))->>'enabled')::boolean, true),
      'type', coalesce((v_cfg->(lvl-1))->>'type', 'fixed'),
      'value', coalesce(((v_cfg->(lvl-1))->>'value')::numeric, 0),
      'reward', public._referral_reward_for(v_cfg->(lvl-1)),
      'count', coalesce(cnt, 0),
      'earnings', coalesce(earn, 0)
    ) order by lvl), '[]'::jsonb),
    coalesce(sum(cnt), 0),
    coalesce(sum(earn), 0)
  into v_rows, v_total_c, v_total_e
  from (
    select gs.lvl,
           count(r.id) as cnt,
           coalesce(sum(r.reward_amount), 0) as earn
      from generate_series(1, greatest(v_levels, 1)) as gs(lvl)
      left join public.referrals r on r.referrer_id = v_uid and r.level = gs.lvl
     group by gs.lvl
  ) s;

  return jsonb_build_object(
    'code', v_code,
    'system_enabled', v_enabled,
    'levels', v_levels,
    'qualifying_amount', public._referral_qualifying_amount(),
    'per_level', v_rows,
    'total_referrals', v_total_c,
    'total_earnings', v_total_e
  );
end;
$$;
grant execute on function public.referral_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- Day-wise Daily Reward. Replaces claim_daily_reward(uuid) from 0012.
-- ---------------------------------------------------------------------------
create or replace function public._daily_amount_for_streak(p_streak int)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days jsonb := public.setting_json('daily_reward_days');
  v_len  int;
  v_idx  int;
  v_base bigint;
  v_step bigint;
  v_cap  int;
begin
  if v_days is not null and jsonb_typeof(v_days) = 'array' and jsonb_array_length(v_days) > 0 then
    v_len := jsonb_array_length(v_days);
    v_idx := ((greatest(p_streak, 1) - 1) % v_len);   -- 0-based cycle index
    return floor((v_days->>v_idx)::numeric)::bigint;
  end if;
  -- legacy fallback: base + step*(min(streak,cap)-1)
  v_base := public.setting_num('daily_reward_base', 50)::bigint;
  v_step := public.setting_num('daily_reward_streak_step', 10)::bigint;
  v_cap  := public.setting_num('daily_reward_streak_cap', 7)::int;
  return v_base + v_step * (least(greatest(p_streak,1), v_cap) - 1);
end;
$$;

create or replace function public.claim_daily_reward(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_prev   date;
  v_streak int;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  if exists (select 1 from public.daily_reward_claims where user_id = v_uid and claim_date = v_today) then
    raise exception 'ALREADY_CLAIMED_TODAY';
  end if;

  perform public._consume_ad(v_uid, 'daily', p_nonce);

  select claim_date, streak into v_prev, v_streak from public.daily_reward_claims
    where user_id = v_uid order by claim_date desc limit 1;

  if v_prev is null or v_prev < v_today - 1 then
    v_streak := 1;
  else
    v_streak := coalesce(v_streak, 0) + 1;
  end if;

  v_amount := public._daily_amount_for_streak(v_streak);

  insert into public.daily_reward_claims(user_id, claim_date, streak, amount)
  values (v_uid, v_today, v_streak, v_amount);

  v_new := public._apply_ledger(v_uid, v_amount, 'daily_reward', null,
                                'Daily reward (day ' || v_streak || ')');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'streak', v_streak, 'balance', v_new);
end;
$$;
grant execute on function public.claim_daily_reward(uuid) to authenticated;

-- Extend daily_reward_status to expose the day-wise schedule for the UI.
create or replace function public.daily_reward_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_prev   date;
  v_streak int;
  v_claimed boolean;
  v_next_streak int;
  v_days jsonb := public.setting_json('daily_reward_days');
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  select claim_date, streak into v_prev, v_streak from public.daily_reward_claims
    where user_id = v_uid order by claim_date desc limit 1;

  v_claimed := (v_prev is not null and v_prev = v_today);

  if v_prev is null or v_prev < v_today - 1 then
    v_next_streak := 1;
  elsif v_prev = v_today then
    v_next_streak := coalesce(v_streak, 0);         -- already claimed today
  else
    v_next_streak := coalesce(v_streak, 0) + 1;
  end if;

  return jsonb_build_object(
    'ok', true,
    'claimed_today', v_claimed,
    'current_streak', coalesce(v_streak, 0),
    'next_streak', v_next_streak,
    'next_amount', public._daily_amount_for_streak(greatest(v_next_streak,1)),
    'next_available_utc', (v_today + 1)::text,
    'days', coalesce(v_days, '[]'::jsonb)
  );
end;
$$;
grant execute on function public.daily_reward_status() to authenticated;


-- >>> supabase/migrations/0016_ads_config_and_withdrawal.sql
-- ============================================================================
-- Ads control model (global + per-section) and withdrawal conversion / fee /
-- unique transaction id. Forward-only, non-destructive.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- ADS SETTINGS (section 17)
--   ads_system_enabled     master switch for ALL ads
--   rewarded_ads_enabled   master switch for rewarded ads
--   banner_ads_enabled     master switch for banner ads (already seeded)
--   ad_gate_<section>      rewarded required for that section (from 0012)
--   banner_<section>       banner shown on that section
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('ads_system_enabled',  'true', 'Master switch for all ads (banner + rewarded)'),
  ('rewarded_ads_enabled','true', 'Master switch for rewarded ads'),
  ('banner_daily',    'true', 'Show banner on Daily Reward'),
  ('banner_scratch',  'true', 'Show banner on Scratch Card'),
  ('banner_mining',   'true', 'Show banner on Mining'),
  ('banner_watch_ads','true', 'Show banner on Watch Ads'),
  ('banner_quiz',     'true', 'Show banner on Daily Quiz'),
  ('banner_tasks',    'true', 'Show banner on Tasks')
on conflict (key) do nothing;

-- Rewarded gate now also respects the global switches.
create or replace function public._ad_gated(p_placement text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true)
    and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true)
    and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_' || p_placement), true);
$$;

-- Effective ad configuration for the client (so the UI knows whether to run the
-- rewarded flow and whether to render a banner per section).
create or replace function public.ads_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sys  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true);
  v_rew  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true);
  v_ban  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_ads_enabled'), true);
  v_sections text[] := array['daily','scratch','mining','watch_ads','quiz','tasks'];
  v_out jsonb := '{}'::jsonb;
  s text;
begin
  foreach s in array v_sections loop
    v_out := v_out || jsonb_build_object(s, jsonb_build_object(
      'rewarded', v_sys and v_rew and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_'||s), true),
      'banner',   v_sys and v_ban and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_'||s), true)
    ));
  end loop;
  return jsonb_build_object('system', v_sys, 'rewarded_global', v_rew,
                            'banner_global', v_ban, 'sections', v_out);
end;
$$;
grant execute on function public.ads_config() to authenticated;

-- ============================================================================
-- WITHDRAWAL: per-method conversion, fee, and unique transaction id
-- ============================================================================

-- Per-method conversion rate: `rate` currency units per `rate_base` BCP.
alter table public.payment_methods add column if not exists currency  text   not null default '₹';
alter table public.payment_methods add column if not exists rate      numeric not null default 0;
alter table public.payment_methods add column if not exists rate_base bigint  not null default 1000;

-- Stored breakdown + transaction id on each withdrawal.
alter table public.withdrawals add column if not exists txn_id       text;
alter table public.withdrawals add column if not exists currency     text;
alter table public.withdrawals add column if not exists rate         numeric;
alter table public.withdrawals add column if not exists gross_amount numeric;
alter table public.withdrawals add column if not exists fee_amount   numeric;
alter table public.withdrawals add column if not exists net_amount   numeric;

-- Fee settings.
insert into public.app_settings(key, value, description) values
  ('withdrawal_fee_enabled', 'false', 'Charge a withdrawal fee'),
  ('withdrawal_fee_percent', '0',     'Withdrawal fee percentage (of the converted amount)'),
  ('withdrawal_fee_fixed',   '0',     'Fixed withdrawal fee (in the payout currency)')
on conflict (key) do nothing;

-- Seed sensible default rates on the shipped methods (only if still 0).
update public.payment_methods set currency='₹', rate=95,  rate_base=1000 where key in ('upi','paytm') and rate = 0;
update public.payment_methods set currency='₹', rate=95,  rate_base=1000 where key = 'bank' and rate = 0;
update public.payment_methods set currency='$', rate=1,   rate_base=1000 where key = 'usdt' and rate = 0;

-- Unique transaction id generator + backfill + auto-assign trigger.
create or replace function public._gen_txn_id()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_id text;
begin
  loop
    v_id := 'BCW' || to_char(now(), 'YYMMDD') ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.withdrawals where txn_id = v_id);
  end loop;
  return v_id;
end;
$$;

update public.withdrawals set txn_id = public._gen_txn_id() where txn_id is null;

do $$ begin
  alter table public.withdrawals add constraint withdrawals_txn_id_key unique (txn_id);
exception when duplicate_object then null; end $$;

create or replace function public._withdrawals_set_txn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.txn_id is null then new.txn_id := public._gen_txn_id(); end if;
  return new;
end;
$$;

drop trigger if exists trg_withdrawals_txn on public.withdrawals;
create trigger trg_withdrawals_txn before insert on public.withdrawals
  for each row execute function public._withdrawals_set_txn();

-- Server-authoritative conversion + fee computation.
create or replace function public._withdrawal_compute(p_method_key text, p_bcp bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pm      public.payment_methods;
  v_gross   numeric;
  v_feeon   boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='withdrawal_fee_enabled'), false);
  v_feepct  numeric := public.setting_num('withdrawal_fee_percent', 0);
  v_feefix  numeric := public.setting_num('withdrawal_fee_fixed', 0);
  v_fee     numeric := 0;
  v_net     numeric;
begin
  select * into v_pm from public.payment_methods where key = p_method_key;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_gross := round((p_bcp::numeric / greatest(v_pm.rate_base, 1)) * v_pm.rate, 2);
  if v_feeon then
    v_fee := round(v_gross * v_feepct / 100.0 + v_feefix, 2);
  end if;
  v_fee := least(v_fee, v_gross);
  v_net := round(v_gross - v_fee, 2);

  return jsonb_build_object(
    'bcp', p_bcp,
    'currency', v_pm.currency,
    'rate', v_pm.rate,
    'rate_base', v_pm.rate_base,
    'gross', v_gross,
    'fee_enabled', v_feeon,
    'fee', v_fee,
    'net', v_net
  );
end;
$$;

-- Read-only quote for the withdraw screen.
create or replace function public.withdrawal_quote(p_method_key text, p_amount bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;
  return public._withdrawal_compute(p_method_key, p_amount);
end;
$$;
grant execute on function public.withdrawal_quote(text, bigint) to authenticated;

-- Replace request_withdrawal to persist the conversion breakdown.
create or replace function public.request_withdrawal(p_amount bigint, p_method_key text, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_min   bigint;
  v_pm    public.payment_methods;
  v_wd    uuid;
  v_calc  jsonb;
  v_txn   text;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  select * into v_pm from public.payment_methods where key = p_method_key and active;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_min := greatest(public.setting_num('withdrawal_min', 1000)::bigint, v_pm.min_amount);
  if p_amount < v_min then raise exception 'BELOW_MINIMUM'; end if;

  if exists (select 1 from public.withdrawals where user_id = v_uid and status in ('pending','approved')) then
    raise exception 'WITHDRAWAL_IN_PROGRESS';
  end if;

  v_calc := public._withdrawal_compute(p_method_key, p_amount);

  perform public._apply_ledger(v_uid, -p_amount, 'withdrawal_hold', null,
            'Withdrawal request hold', jsonb_build_object('method', p_method_key), false);

  update public.wallets set pending_withdrawal = pending_withdrawal + p_amount where user_id = v_uid;

  insert into public.withdrawals(user_id, amount, method_key, details,
    currency, rate, gross_amount, fee_amount, net_amount)
  values (v_uid, p_amount, p_method_key, coalesce(p_details,'{}'::jsonb),
    v_calc->>'currency', (v_calc->>'rate')::numeric,
    (v_calc->>'gross')::numeric, (v_calc->>'fee')::numeric, (v_calc->>'net')::numeric)
  returning id, txn_id into v_wd, v_txn;

  insert into public.notifications(user_id, title, body, type, data)
  values (v_uid, 'Withdrawal submitted',
          'Your request for ' || p_amount || ' BCP is pending review.', 'withdrawal',
          jsonb_build_object('withdrawal_id', v_wd, 'txn_id', v_txn));

  return jsonb_build_object('ok', true, 'withdrawal_id', v_wd, 'txn_id', v_txn,
                            'breakdown', v_calc);
end;
$$;
grant execute on function public.request_withdrawal(bigint, text, jsonb) to authenticated;

-- Update admin_withdrawals to surface the breakdown + txn id + payment details.
create or replace function public.admin_withdrawals(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id,
      'txn_id', w.txn_id,
      'user_id', w.user_id,
      'user_name', p.full_name,
      'user_email', p.email,
      'referral_code', p.referral_code,
      'amount', w.amount,
      'currency', w.currency,
      'rate', w.rate,
      'gross_amount', w.gross_amount,
      'fee_amount', w.fee_amount,
      'net_amount', w.net_amount,
      'method_key', w.method_key,
      'method_name', coalesce(pm.name, w.method_key),
      'details', w.details,
      'status', w.status,
      'admin_notes', w.admin_notes,
      'created_at', w.created_at,
      'processed_at', w.processed_at,
      'balance', wl.balance
    ) order by w.created_at desc)
    from public.withdrawals w
    join public.profiles p on p.id = w.user_id
    left join public.payment_methods pm on pm.key = w.method_key
    left join public.wallets wl on wl.user_id = w.user_id
    where p_status = 'all' or w.status::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_withdrawals(text) to authenticated;

-- Extend admin_save_payment_method to manage conversion rate fields.
-- Drop the prior 7-arg signature so the new one isn't shadowed by overload.
drop function if exists public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int);
create or replace function public.admin_save_payment_method(
  p_id uuid, p_key text, p_name text, p_fields jsonb, p_min_amount bigint,
  p_active boolean, p_position int,
  p_currency text default null, p_rate numeric default null, p_rate_base bigint default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.payment_methods(key, name, fields, min_amount, active, position,
      currency, rate, rate_base)
    values (p_key, p_name, coalesce(p_fields,'[]'::jsonb), coalesce(p_min_amount,0),
      coalesce(p_active,true), coalesce(p_position,0),
      coalesce(p_currency,'₹'), coalesce(p_rate,0), coalesce(p_rate_base,1000))
    on conflict (key) do update
      set name=excluded.name, fields=excluded.fields, min_amount=excluded.min_amount,
          active=excluded.active, position=excluded.position,
          currency=excluded.currency, rate=excluded.rate, rate_base=excluded.rate_base
    returning id into v_id;
  else
    update public.payment_methods
       set key=p_key, name=p_name, fields=coalesce(p_fields,'[]'::jsonb),
           min_amount=coalesce(p_min_amount,0), active=coalesce(p_active,true),
           position=coalesce(p_position,0),
           currency=coalesce(p_currency, currency),
           rate=coalesce(p_rate, rate),
           rate_base=coalesce(p_rate_base, rate_base)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'payment_method.save', 'payment_method', v_id::text,
          jsonb_build_object('key', p_key));
  return v_id;
end;
$$;
grant execute on function
  public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int, text, numeric, bigint)
  to authenticated;


-- >>> supabase/migrations/0017_task_proof_methods.sql
-- ============================================================================
-- Task proof methods (screenshot / username-link) + per-task ad requirement.
-- Forward-only, non-destructive. Existing tasks default to proof_method 'none'
-- (behaviour unchanged: auto-verify rewards immediately, others go pending).
-- ============================================================================

alter table public.tasks add column if not exists proof_method      text    not null default 'none'; -- none | screenshot | text
alter table public.tasks add column if not exists proof_instruction text;   -- shown to the user for the 'text' method
alter table public.tasks add column if not exists requires_ad       boolean not null default false;

-- ---------------------------------------------------------------------------
-- submit_task with proof validation + optional rewarded-ad gate.
-- ---------------------------------------------------------------------------
create or replace function public.submit_task(
  p_task_id uuid, p_proof jsonb default '{}'::jsonb, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_task   public.tasks;
  v_comp   public.task_completions;
  v_state  task_state;
  v_reward bigint := null;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_task from public.tasks where id = p_task_id and active;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;

  select * into v_comp from public.task_completions where task_id = p_task_id and user_id = v_uid;
  if found and v_comp.state in ('verified','rewarded','pending') then
    raise exception 'TASK_ALREADY_DONE';
  end if;

  -- Optional rewarded-ad requirement (honours the section gate + global switch).
  if v_task.requires_ad then
    perform public._consume_ad(v_uid, 'tasks', p_nonce);
  end if;

  -- Proof validation for manual tasks.
  if not v_task.auto_verify then
    if v_task.proof_method = 'screenshot'
       and nullif(trim(coalesce(p_proof->>'screenshot_url','')), '') is null then
      raise exception 'PROOF_REQUIRED';
    elsif v_task.proof_method = 'text'
       and nullif(trim(coalesce(p_proof->>'text','')), '') is null then
      raise exception 'PROOF_REQUIRED';
    end if;
  end if;

  if v_task.auto_verify then
    v_state := 'rewarded'; v_reward := v_task.reward;
  else
    v_state := 'pending';
  end if;

  insert into public.task_completions(task_id, user_id, state, proof, reward)
  values (p_task_id, v_uid, v_state, coalesce(p_proof,'{}'::jsonb), v_reward)
  on conflict (task_id, user_id)
    do update set state = excluded.state, proof = excluded.proof,
                  reward = excluded.reward, created_at = now();

  if v_state = 'rewarded' then
    v_new := public._apply_ledger(v_uid, v_task.reward, 'task', p_task_id, 'Task: ' || v_task.title);
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'state', v_state, 'reward', coalesce(v_reward,0), 'balance', v_new);
end;
$$;
grant execute on function public.submit_task(uuid, jsonb, uuid) to authenticated;
-- retire the 2-arg signature so callers use the proof-aware one
drop function if exists public.submit_task(uuid, jsonb);

-- ---------------------------------------------------------------------------
-- admin_save_task gains proof_method / proof_instruction / requires_ad.
-- Drop the previous 10-arg signature so it isn't shadowed.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_save_task(uuid, text, text, task_type, bigint, text, text, boolean, boolean, int);
create or replace function public.admin_save_task(
  p_id uuid, p_title text, p_description text, p_type task_type, p_reward bigint,
  p_action_url text, p_instructions text, p_auto_verify boolean, p_active boolean, p_position int,
  p_proof_method text default 'none', p_proof_instruction text default null,
  p_requires_ad boolean default false)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.tasks(title, description, type, reward, action_url, instructions,
      auto_verify, active, position, proof_method, proof_instruction, requires_ad)
    values (p_title, p_description, p_type, p_reward, p_action_url, p_instructions,
      coalesce(p_auto_verify,false), coalesce(p_active,true), coalesce(p_position,0),
      coalesce(p_proof_method,'none'), p_proof_instruction, coalesce(p_requires_ad,false))
    returning id into v_id;
  else
    update public.tasks
       set title=p_title, description=p_description, type=p_type, reward=p_reward,
           action_url=p_action_url, instructions=p_instructions,
           auto_verify=coalesce(p_auto_verify,false), active=coalesce(p_active,true),
           position=coalesce(p_position,0), proof_method=coalesce(p_proof_method,'none'),
           proof_instruction=p_proof_instruction, requires_ad=coalesce(p_requires_ad,false)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'task.save', 'task', v_id::text, jsonb_build_object('title', p_title));
  return v_id;
end;
$$;
grant execute on function
  public.admin_save_task(uuid, text, text, task_type, bigint, text, text, boolean, boolean, int, text, text, boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: task submissions awaiting review (with user + task + proof detail).
-- ---------------------------------------------------------------------------
create or replace function public.admin_task_submissions(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'user_id', c.user_id,
      'user_name', p.full_name,
      'user_email', p.email,
      'task_id', t.id,
      'task_title', t.title,
      'reward', t.reward,
      'proof_method', t.proof_method,
      'proof_instruction', t.proof_instruction,
      'proof', c.proof,
      'state', c.state,
      'created_at', c.created_at
    ) order by c.created_at desc)
    from public.task_completions c
    join public.tasks t on t.id = c.task_id
    join public.profiles p on p.id = c.user_id
    where p_status = 'all' or c.state::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_task_submissions(text) to authenticated;


-- >>> supabase/migrations/0018_referral_fixed_plus_percent.sql
-- ============================================================================
-- Referral rewards: Fixed AND Percentage simultaneously, per level.
-- One authoritative config (app_settings.referral_levels). Forward-only.
--
-- New per-level shape:
--   { "enabled": true,
--     "fixed_enabled": true,  "fixed": 100,
--     "percent_enabled": true, "percent": 10 }
-- Total level reward = (fixed_enabled ? fixed : 0)
--                    + (percent_enabled ? floor(qualifying * percent/100) : 0)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Migrate existing referral_levels to the new shape.
--   legacy numeric [200,50]            -> fixed
--   {enabled,type:'fixed',value}       -> fixed
--   {enabled,type:'percent',value}     -> percent
--   already-new objects are left as-is
-- ---------------------------------------------------------------------------
do $$
declare v jsonb := public.setting_json('referral_levels'); v_new jsonb;
begin
  if v is null or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
    return;
  end if;
  select jsonb_agg(
    case
      when jsonb_typeof(e) = 'number' then
        jsonb_build_object('enabled', true, 'fixed_enabled', true,
                           'fixed', (e #>> '{}')::numeric,
                           'percent_enabled', false, 'percent', 0)
      when e ? 'type' then
        jsonb_build_object(
          'enabled', coalesce((e->>'enabled')::boolean, true),
          'fixed_enabled', (e->>'type') = 'fixed',
          'fixed', case when (e->>'type')='fixed' then coalesce((e->>'value')::numeric,0) else 0 end,
          'percent_enabled', (e->>'type') = 'percent',
          'percent', case when (e->>'type')='percent' then coalesce((e->>'value')::numeric,0) else 0 end)
      else e
    end
    order by ord)
  into v_new
  from jsonb_array_elements(v) with ordinality as t(e, ord);

  update public.app_settings set value = v_new where key = 'referral_levels';
end $$;

-- Default (used only on a fresh DB where the key is absent).
insert into public.app_settings(key, value, description) values
  ('referral_levels',
   '[{"enabled":true,"fixed_enabled":true,"fixed":100,"percent_enabled":false,"percent":0},{"enabled":true,"fixed_enabled":true,"fixed":50,"percent_enabled":false,"percent":0},{"enabled":true,"fixed_enabled":true,"fixed":25,"percent_enabled":false,"percent":0}]',
   'Per-level referral rewards: {enabled, fixed_enabled, fixed, percent_enabled, percent}')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Normalising reader (handles all historical shapes → new shape).
-- ---------------------------------------------------------------------------
create or replace function public._referral_levels_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v jsonb := public.setting_json('referral_levels');
begin
  if v is null or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
    return '[]'::jsonb;
  end if;
  return (
    select jsonb_agg(
      case
        when jsonb_typeof(e) = 'number' then
          jsonb_build_object('enabled', true, 'fixed_enabled', true,
                             'fixed', (e #>> '{}')::numeric,
                             'percent_enabled', false, 'percent', 0)
        when e ? 'type' then
          jsonb_build_object(
            'enabled', coalesce((e->>'enabled')::boolean, true),
            'fixed_enabled', (e->>'type') = 'fixed',
            'fixed', case when (e->>'type')='fixed' then coalesce((e->>'value')::numeric,0) else 0 end,
            'percent_enabled', (e->>'type') = 'percent',
            'percent', case when (e->>'type')='percent' then coalesce((e->>'value')::numeric,0) else 0 end)
        else e
      end order by ord)
    from jsonb_array_elements(v) with ordinality as t(e, ord));
end;
$$;

-- ---------------------------------------------------------------------------
-- Resolve one level config to a concrete reward (fixed + percent).
-- ---------------------------------------------------------------------------
create or replace function public._referral_reward_for(cfg jsonb)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_reward numeric := 0;
  v_qual   numeric := public._referral_qualifying_amount();
begin
  if not coalesce((cfg->>'enabled')::boolean, true) then return 0; end if;
  if coalesce((cfg->>'fixed_enabled')::boolean, false) then
    v_reward := v_reward + coalesce((cfg->>'fixed')::numeric, 0);
  end if;
  if coalesce((cfg->>'percent_enabled')::boolean, false) then
    v_reward := v_reward + floor(v_qual * coalesce((cfg->>'percent')::numeric,0) / 100.0);
  end if;
  return floor(v_reward)::bigint;
end;
$$;

-- ---------------------------------------------------------------------------
-- referral_overview exposes the full per-level config for the card UI + refer page.
-- ---------------------------------------------------------------------------
create or replace function public.referral_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_cfg     jsonb := public._referral_levels_config();
  v_levels  int   := coalesce(jsonb_array_length(v_cfg), 0);
  v_code    text;
  v_rows    jsonb;
  v_total_c bigint;
  v_total_e bigint;
  v_enabled boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings
                                 where key='referral_system_enabled'), true);
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select referral_code into v_code from public.profiles where id = v_uid;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'level', lvl,
      'enabled', coalesce(((v_cfg->(lvl-1))->>'enabled')::boolean, true),
      'fixed_enabled', coalesce(((v_cfg->(lvl-1))->>'fixed_enabled')::boolean, false),
      'fixed', coalesce(((v_cfg->(lvl-1))->>'fixed')::numeric, 0),
      'percent_enabled', coalesce(((v_cfg->(lvl-1))->>'percent_enabled')::boolean, false),
      'percent', coalesce(((v_cfg->(lvl-1))->>'percent')::numeric, 0),
      'reward', public._referral_reward_for(v_cfg->(lvl-1)),
      'count', coalesce(cnt, 0),
      'earnings', coalesce(earn, 0)
    ) order by lvl), '[]'::jsonb),
    coalesce(sum(cnt), 0),
    coalesce(sum(earn), 0)
  into v_rows, v_total_c, v_total_e
  from (
    select gs.lvl,
           count(r.id) as cnt,
           coalesce(sum(r.reward_amount), 0) as earn
      from generate_series(1, greatest(v_levels, 1)) as gs(lvl)
      left join public.referrals r on r.referrer_id = v_uid and r.level = gs.lvl
     group by gs.lvl
  ) s;

  return jsonb_build_object(
    'code', v_code,
    'system_enabled', v_enabled,
    'levels', v_levels,
    'qualifying_amount', public._referral_qualifying_amount(),
    'per_level', v_rows,
    'total_referrals', v_total_c,
    'total_earnings', v_total_e
  );
end;
$$;
grant execute on function public.referral_overview() to authenticated;

-- Admin RPC to persist the referral levels config from the card UI (validated).
create or replace function public.admin_set_referral_levels(p_levels jsonb, p_enabled boolean, p_qualifying numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  if jsonb_typeof(p_levels) <> 'array' then raise exception 'INVALID_LEVELS'; end if;
  perform public.admin_set_setting('referral_levels', p_levels, null);
  perform public.admin_set_setting('referral_system_enabled', to_jsonb(coalesce(p_enabled, true)), null);
  if p_qualifying is not null then
    perform public.admin_set_setting('referral_qualifying_amount', to_jsonb(p_qualifying), null);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_referral_levels(jsonb, boolean, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Config cleanup: remove obsolete settings (functions keep literal defaults,
-- so deleting the rows changes no behaviour).
-- ---------------------------------------------------------------------------
delete from public.app_settings where key in (
  'currency_symbol',
  'bcp_to_currency_rate',
  'daily_reward_base',
  'daily_reward_streak_step',
  'daily_reward_streak_cap',
  'referral_reward_l1'
);

-- >>> supabase/migrations/0019_contests.sql
-- ============================================================================
-- Contest system (section 32). User-specific start timestamps + independent
-- deadlines, server-authoritative progress from the ledger / referral data,
-- ad-gated claim, admin review, idempotent, new cycle after completion.
-- Forward-only.
-- ============================================================================

-- Distinct ledger type for contest rewards (additive, safe).
alter type ledger_type add value if not exists 'contest';

do $$ begin
  create type contest_target as enum ('bcp_earned', 'referral_count');
exception when duplicate_object then null; end $$;

do $$ begin
  create type contest_state as enum ('active', 'claim_pending', 'completed', 'expired', 'rejected');
exception when duplicate_object then null; end $$;

-- Admin-defined contest templates.
create table if not exists public.contests (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  target_type    contest_target not null,
  target_value   bigint not null,
  reward         bigint not null,
  duration_hours int not null default 168,      -- 7 days
  requires_ad    boolean not null default false,
  rules          text,
  active         boolean not null default true,
  position       int not null default 0,
  created_at     timestamptz not null default now()
);

-- Per-user contest cycle (independent start/deadline).
create table if not exists public.contest_participations (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  contest_id    uuid not null references public.contests(id) on delete cascade,
  target_type   contest_target not null,
  target_value  bigint not null,
  reward        bigint not null,
  started_at    timestamptz not null default now(),
  ends_at       timestamptz not null,
  baseline      bigint not null default 0,       -- earned/referrals at start
  state         contest_state not null default 'active',
  claimed_at    timestamptz,
  reviewed_at   timestamptz,
  reviewed_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);
create index if not exists idx_contest_part_user on public.contest_participations(user_id, state);
create index if not exists idx_contest_part_state on public.contest_participations(state, ends_at);
-- Only one live cycle per (user, contest).
create unique index if not exists uniq_active_contest
  on public.contest_participations(user_id, contest_id)
  where (state in ('active','claim_pending'));

alter table public.contests enable row level security;
alter table public.contest_participations enable row level security;
do $$ begin
  create policy contests_read on public.contests
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy contest_part_self on public.contest_participations
    for select using (user_id = auth.uid() or public.is_admin());
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Authoritative metric for a user at "now": total BCP earned or referral count.
-- ---------------------------------------------------------------------------
create or replace function public._contest_metric(p_uid uuid, p_type contest_target)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_type = 'referral_count' then
    return (select count(*)::bigint from public.referrals where referrer_id = p_uid and level = 1);
  end if;
  -- bcp_earned: cumulative positive ledger credits (excludes withdrawals/holds)
  return (select coalesce(sum(amount),0)::bigint from public.wallet_transactions
          where user_id = p_uid and amount > 0);
end;
$$;

-- Progress within a participation window (never negative).
create or replace function public._contest_progress(p public.contest_participations)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select greatest(public._contest_metric(p.user_id, p.target_type) - p.baseline, 0);
$$;

-- ---------------------------------------------------------------------------
-- User: overview of active contests + this user's participation/progress.
-- ---------------------------------------------------------------------------
create or replace function public.contests_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'target_type', c.target_type,
      'target_value', c.target_value,
      'reward', c.reward,
      'duration_hours', c.duration_hours,
      'requires_ad', c.requires_ad,
      'rules', c.rules,
      'participation', (
        select jsonb_build_object(
          'id', p.id,
          'state', (case when p.state = 'active' and now() > p.ends_at then 'expired' else p.state end),
          'started_at', p.started_at,
          'ends_at', p.ends_at,
          'progress', public._contest_progress(p),
          'target_value', p.target_value,
          'reward', p.reward,
          'reached', public._contest_progress(p) >= p.target_value,
          'claimable', (p.state = 'active' and now() <= p.ends_at
                        and public._contest_progress(p) >= p.target_value)
        )
        from public.contest_participations p
        where p.user_id = v_uid and p.contest_id = c.id
          and p.state in ('active','claim_pending')
        order by p.started_at desc limit 1
      )
    ) order by c.position, c.created_at)
    from public.contests c
    where c.active
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.contests_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- User: start a contest cycle (captures baseline + personal deadline).
-- ---------------------------------------------------------------------------
create or replace function public.start_contest(p_contest_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_c   public.contests;
  v_id  uuid;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_c from public.contests where id = p_contest_id and active;
  if not found then raise exception 'CONTEST_UNAVAILABLE'; end if;

  if exists (select 1 from public.contest_participations
             where user_id = v_uid and contest_id = p_contest_id
               and state in ('active','claim_pending')) then
    raise exception 'CONTEST_ALREADY_ACTIVE';
  end if;

  insert into public.contest_participations(
    user_id, contest_id, target_type, target_value, reward, ends_at, baseline)
  values (v_uid, p_contest_id, v_c.target_type, v_c.target_value, v_c.reward,
          now() + make_interval(hours => v_c.duration_hours),
          public._contest_metric(v_uid, v_c.target_type))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'participation_id', v_id);
end;
$$;
grant execute on function public.start_contest(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- User: claim a reached contest (ad-gated if configured) → pending review.
-- ---------------------------------------------------------------------------
create or replace function public.claim_contest(p_participation_id uuid, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_p   public.contest_participations;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_p from public.contest_participations
    where id = p_participation_id and user_id = v_uid for update;
  if not found then raise exception 'PARTICIPATION_NOT_FOUND'; end if;
  if v_p.state <> 'active' then raise exception 'CONTEST_NOT_CLAIMABLE'; end if;
  if now() > v_p.ends_at then
    update public.contest_participations set state='expired' where id = v_p.id;
    raise exception 'CONTEST_EXPIRED';
  end if;
  if public._contest_progress(v_p) < v_p.target_value then
    raise exception 'CONTEST_TARGET_NOT_REACHED';
  end if;

  -- Ad gate for contest claims (uses the same funnel; placement 'contest').
  if v_p.reward is not null and (select requires_ad from public.contests where id = v_p.contest_id) then
    perform public._consume_ad(v_uid, 'contest', p_nonce);
  end if;

  update public.contest_participations
     set state = 'claim_pending', claimed_at = now()
   where id = v_p.id;

  return jsonb_build_object('ok', true, 'state', 'claim_pending');
end;
$$;
grant execute on function public.claim_contest(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list contest claims for review.
-- ---------------------------------------------------------------------------
create or replace function public.admin_contest_claims(p_status text default 'claim_pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'user_id', p.user_id,
      'user_name', pr.full_name,
      'user_email', pr.email,
      'contest_name', c.name,
      'target_type', p.target_type,
      'target_value', p.target_value,
      'progress', public._contest_progress(p),
      'reward', p.reward,
      'started_at', p.started_at,
      'ends_at', p.ends_at,
      'claimed_at', p.claimed_at,
      'state', p.state
    ) order by p.claimed_at desc nulls last)
    from public.contest_participations p
    join public.profiles pr on pr.id = p.user_id
    join public.contests c on c.id = p.contest_id
    where p_status = 'all' or p.state::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_contest_claims(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve/reject a contest claim. Approve credits once (idempotent).
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_contest_claim(p_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_p public.contest_participations;
begin
  perform public._assert_admin();
  select * into v_p from public.contest_participations where id = p_id for update;
  if not found then raise exception 'PARTICIPATION_NOT_FOUND'; end if;
  if v_p.state <> 'claim_pending' then
    return jsonb_build_object('ok', true, 'already', v_p.state);
  end if;

  if p_approve then
    update public.contest_participations
       set state='completed', reviewed_at=now(), reviewed_by=v_admin where id=p_id;
    if v_p.reward > 0 then
      perform public._apply_ledger(v_p.user_id, v_p.reward, 'contest', v_p.contest_id,
        'Contest reward', jsonb_build_object('contest', v_p.contest_id));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_p.user_id, 'Contest reward 🏆',
              'You earned ' || v_p.reward || ' BCP from a contest.', 'reward',
              jsonb_build_object('route', '/contests'));
    end if;
  else
    update public.contest_participations
       set state='rejected', reviewed_at=now(), reviewed_by=v_admin where id=p_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, case when p_approve then 'contest_claim.approve' else 'contest_claim.reject' end,
          'contest_participation', p_id::text, jsonb_build_object('user', v_p.user_id));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_resolve_contest_claim(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin CRUD for contests.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_contest(
  p_id uuid, p_name text, p_target_type text, p_target_value bigint, p_reward bigint,
  p_duration_hours int, p_requires_ad boolean, p_rules text, p_active boolean, p_position int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.contests(name, target_type, target_value, reward, duration_hours,
      requires_ad, rules, active, position)
    values (p_name, p_target_type::contest_target, p_target_value, p_reward,
      coalesce(p_duration_hours,168), coalesce(p_requires_ad,false), p_rules,
      coalesce(p_active,true), coalesce(p_position,0))
    returning id into v_id;
  else
    update public.contests
       set name=p_name, target_type=p_target_type::contest_target, target_value=p_target_value,
           reward=p_reward, duration_hours=coalesce(p_duration_hours,168),
           requires_ad=coalesce(p_requires_ad,false), rules=p_rules,
           active=coalesce(p_active,true), position=coalesce(p_position,0)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'contest.save', 'contest', v_id::text, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.admin_delete_contest(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.contests where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'contest.delete', 'contest', p_id::text, '{}'::jsonb);
end;
$$;

grant execute on function
  public.admin_save_contest(uuid, text, text, bigint, bigint, int, boolean, text, boolean, int),
  public.admin_delete_contest(uuid)
  to authenticated;

-- Seed example contests.
insert into public.contests(name, target_type, target_value, reward, duration_hours, rules, position) values
  ('Earn 500 BCP in 7 days', 'bcp_earned', 500, 100, 168, 'Earn 500 BCP within 7 days of starting.', 0),
  ('Earn 1000 BCP in 30 days', 'bcp_earned', 1000, 200, 720, 'Earn 1000 BCP within 30 days of starting.', 1),
  ('Refer 5 friends in 30 days', 'referral_count', 5, 200, 720, 'Get 5 successful referrals within 30 days.', 2)
on conflict do nothing;

-- Ad-gate flag for the contest placement (so ads_config / _ad_gated cover it).
insert into public.app_settings(key, value, description) values
  ('ad_gate_contest', 'true', 'Contest claim · rewarded ad required (when contest requires_ad)')
on conflict (key) do nothing;

-- Redefine ads_config to include the 'contest' placement so the client's ad
-- decision matches the server gate.
create or replace function public.ads_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sys  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true);
  v_rew  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true);
  v_ban  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_ads_enabled'), true);
  v_sections text[] := array['daily','scratch','mining','watch_ads','quiz','tasks','contest'];
  v_out jsonb := '{}'::jsonb;
  s text;
begin
  foreach s in array v_sections loop
    v_out := v_out || jsonb_build_object(s, jsonb_build_object(
      'rewarded', v_sys and v_rew and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_'||s), true),
      'banner',   v_sys and v_ban and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_'||s), true)
    ));
  end loop;
  return jsonb_build_object('system', v_sys, 'rewarded_global', v_rew,
                            'banner_global', v_ban, 'sections', v_out);
end;
$$;
grant execute on function public.ads_config() to authenticated;

-- >>> supabase/migrations/0020_mining_scratch_ads_fee.sql
-- ============================================================================
-- Mining claim/start ad + max-claim-count, global completed-rewarded-ad daily
-- cap, scratch per-card min/max ranges, and per-payment-method withdrawal fee.
-- Forward-only, non-destructive.
-- ============================================================================

alter table public.mining_sessions add column if not exists claim_count int not null default 0;

insert into public.app_settings(key, value, description) values
  ('mining_start_requires_ad', 'false', 'Require a rewarded ad to START mining'),
  ('mining_claim_requires_ad', 'false', 'Require a rewarded ad to CLAIM mining BCP'),
  ('mining_max_claims', '5', 'Maximum claims allowed per mining session'),
  ('rewarded_daily_cap', '20', 'Max successfully-completed rewarded ads per user per day (all sections)'),
  ('scratch_cards_config', '[{"enabled":true,"min":50,"max":100},{"enabled":true,"min":40,"max":80},{"enabled":true,"min":20,"max":50}]',
   'Per-card scratch reward ranges (index 0 = card 1)')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Global completed-rewarded-ad daily cap enforced inside _consume_ad.
-- Only counts CREDITED ad_events (i.e. actually completed + consumed).
-- ---------------------------------------------------------------------------
create or replace function public._consume_ad(p_uid uuid, p_placement text, p_nonce uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state ad_event_state;
  v_place text;
  v_cap   int;
  v_used  int;
begin
  if not public._ad_gated(p_placement) then
    if p_nonce is not null then
      update public.ad_events set state = 'credited', updated_at = now()
        where id = p_nonce and user_id = p_uid and state <> 'credited';
    end if;
    return true;
  end if;

  if p_nonce is null then raise exception 'AD_REQUIRED'; end if;

  select state, placement into v_state, v_place from public.ad_events
    where id = p_nonce and user_id = p_uid for update;
  if not found then raise exception 'AD_REQUIRED'; end if;
  if v_place <> p_placement then raise exception 'AD_REQUIRED'; end if;
  if v_state = 'credited' then raise exception 'AD_ALREADY_USED'; end if;
  if v_state <> 'rewarded' then raise exception 'AD_NOT_COMPLETED'; end if;

  -- Global daily cap on completed rewarded ads (server-authoritative; cannot be
  -- bypassed by reinstall/account switch — counted per user id per UTC day).
  v_cap := public.setting_num('rewarded_daily_cap', 20)::int;
  if v_cap > 0 then
    select count(*) into v_used from public.ad_events
      where user_id = p_uid and state = 'credited'
        and created_at >= (now() at time zone 'utc')::date;
    if v_used >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;
  end if;

  update public.ad_events set state = 'credited', updated_at = now() where id = p_nonce;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Mining: start/claim ad gates + claim-count limit.
-- ---------------------------------------------------------------------------
drop function if exists public.start_mining();
create or replace function public.start_mining(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_rate   bigint;
  v_hours  numeric;
  v_id     uuid;
  v_ends   timestamptz;
  s        public.mining_sessions;
  v_acc    bigint;
  v_delta  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  if not coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_enabled'), true) then
    raise exception 'MINING_DISABLED';
  end if;

  -- settle any finished-but-active sessions first
  for s in
    select * from public.mining_sessions
    where user_id = v_uid and status = 'active' and ends_at < now() for update
  loop
    v_acc := public._mining_accrued(s);
    v_delta := v_acc - s.claimed;
    if v_delta > 0 then
      perform public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward (auto-settled)');
    end if;
    update public.mining_sessions
       set accrued = v_acc, claimed = v_acc, status = 'settled', last_settled_at = now()
     where id = s.id;
  end loop;

  if exists (select 1 from public.mining_sessions where user_id = v_uid and status = 'active') then
    raise exception 'MINING_ALREADY_ACTIVE';
  end if;

  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_start_requires_ad'), false) then
    perform public._consume_ad(v_uid, 'mining', p_nonce);
  end if;

  v_rate  := public.setting_num('mining_rate_per_hour', 20)::bigint;
  v_hours := public.setting_num('mining_session_hours', 24);
  v_ends  := now() + (v_hours || ' hours')::interval;

  insert into public.mining_sessions(user_id, ends_at, rate_per_hour, base_rate, last_settled_at)
  values (v_uid, v_ends, v_rate, v_rate, now())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id, 'ends_at', v_ends, 'rate_per_hour', v_rate);
end;
$$;
grant execute on function public.start_mining(uuid) to authenticated;

drop function if exists public.claim_mining();
create or replace function public.claim_mining(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  s        public.mining_sessions;
  v_acc    bigint;
  v_delta  bigint;
  v_new    bigint;
  v_done   boolean;
  v_max    int := public.setting_num('mining_max_claims', 5)::int;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active'
    order by started_at desc limit 1 for update;
  if not found then raise exception 'NO_ACTIVE_MINING'; end if;

  v_acc   := public._mining_accrued(s);
  v_delta := v_acc - s.claimed;
  v_done  := now() >= s.ends_at;

  if v_delta <= 0 and not v_done then raise exception 'NOTHING_TO_CLAIM'; end if;

  -- Enforce per-session claim count for actual (non-empty) claims.
  if v_delta > 0 and v_max > 0 and s.claim_count >= v_max then
    raise exception 'CLAIM_LIMIT';
  end if;

  -- Ad gate for claims (only when there is something to credit).
  if v_delta > 0
     and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_claim_requires_ad'), false) then
    perform public._consume_ad(v_uid, 'mining', p_nonce);
  end if;

  if v_delta > 0 then
    v_new := public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  update public.mining_sessions
     set accrued = v_acc, claimed = v_acc, last_settled_at = now(),
         claim_count = claim_count + (case when v_delta > 0 then 1 else 0 end),
         status = case when v_done then 'settled'::mining_status else 'active'::mining_status end
   where id = s.id;

  return jsonb_build_object('ok', true, 'claimed', greatest(v_delta,0),
                            'balance', v_new, 'session_closed', v_done);
end;
$$;
grant execute on function public.claim_mining(uuid) to authenticated;

-- Extend mining_status with start/claim ad + claim limit info.
create or replace function public.mining_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s     public.mining_sessions;
  v_acc bigint;
  v_max int := public.setting_num('mining_max_boosts', 3)::int;
  v_cool numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_pct  numeric := public.setting_num('mining_boost_pct', 20);
  v_maxclaims int := public.setting_num('mining_max_claims', 5)::int;
  v_next_boost_at timestamptz;
  v_can_boost boolean := false;
  v_start_ad boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_start_requires_ad'), false);
  v_claim_ad boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_claim_requires_ad'), false);
  v_enabled boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_enabled'), true);
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active' order by started_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'active', false, 'enabled', v_enabled,
      'rate_per_hour', public.setting_num('mining_rate_per_hour', 20),
      'session_hours', public.setting_num('mining_session_hours', 24),
      'max_boosts', v_max, 'boost_pct', v_pct, 'max_claims', v_maxclaims,
      'start_requires_ad', v_start_ad, 'claim_requires_ad', v_claim_ad,
      'boost_requires_ad', coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true));
  end if;
  v_acc := public._mining_accrued(s);
  if s.last_boost_at is not null then
    v_next_boost_at := s.last_boost_at + (v_cool || ' hours')::interval;
  end if;
  v_can_boost := (s.boosts < v_max) and (now() < s.ends_at)
                 and (v_next_boost_at is null or now() >= v_next_boost_at);
  return jsonb_build_object(
    'ok', true, 'active', true, 'enabled', v_enabled, 'session_id', s.id,
    'started_at', s.started_at, 'ends_at', s.ends_at,
    'rate_per_hour', s.rate_per_hour, 'base_rate', coalesce(s.base_rate, s.rate_per_hour),
    'accrued', v_acc, 'claimable', greatest(v_acc - s.claimed, 0),
    'completed', now() >= s.ends_at,
    'boosts', s.boosts, 'max_boosts', v_max, 'boost_pct', v_pct,
    'can_boost', v_can_boost, 'next_boost_at', v_next_boost_at,
    'claim_count', s.claim_count, 'max_claims', v_maxclaims,
    'claims_remaining', greatest(v_maxclaims - s.claim_count, 0),
    'start_requires_ad', v_start_ad, 'claim_requires_ad', v_claim_ad,
    'boost_requires_ad', coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true)
  );
end;
$$;
grant execute on function public.mining_status() to authenticated;

-- ---------------------------------------------------------------------------
-- Scratch: per-card min/max ranges (server-random reward within the range).
-- ---------------------------------------------------------------------------
-- Roll a reward for the next card slot the user will receive today.
create or replace function public._scratch_roll_for(p_uid uuid)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg   jsonb := public.setting_json('scratch_cards_config');
  v_today date := (now() at time zone 'utc')::date;
  v_used  int;
  v_slot  jsonb;
  v_min   numeric;
  v_max   numeric;
begin
  if v_cfg is null or jsonb_typeof(v_cfg) <> 'array' or jsonb_array_length(v_cfg) = 0 then
    return (10 + floor(random()*40))::bigint;  -- safe fallback
  end if;
  select count(*) into v_used from public.scratch_cards
    where user_id = p_uid and issued_date = v_today;
  -- pick the config for this card index (cap at last)
  v_slot := v_cfg->least(v_used, jsonb_array_length(v_cfg)-1);
  if not coalesce((v_slot->>'enabled')::boolean, true) then
    -- find the first enabled slot as a fallback
    select e into v_slot from jsonb_array_elements(v_cfg) e
      where coalesce((e->>'enabled')::boolean, true) limit 1;
  end if;
  v_min := coalesce((v_slot->>'min')::numeric, 10);
  v_max := greatest(coalesce((v_slot->>'max')::numeric, v_min), v_min);
  return (v_min + floor(random() * (v_max - v_min + 1)))::bigint;
end;
$$;

-- Reissue scratch_status to use the per-card ranges.
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_cap   int;
  v_used  int;
  v_card  public.scratch_cards;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    return jsonb_build_object('ok', true, 'has_card', true, 'card_id', v_card.id);
  end if;

  v_cap  := public.setting_num('scratch_daily_cap', 3)::int;
  select count(*) into v_used from public.scratch_cards
    where user_id = v_uid and issued_date = v_today;
  if v_used >= v_cap then
    return jsonb_build_object('ok', true, 'has_card', false, 'remaining_today', 0);
  end if;

  insert into public.scratch_cards(user_id, reward_amount, source)
  values (v_uid, public._scratch_roll_for(v_uid), 'daily')
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'card_id', v_card.id,
                            'remaining_today', v_cap - v_used - 1);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- Read the configured card ranges + remaining, for the user's Scratch screen.
create or replace function public.scratch_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_cap int := public.setting_num('scratch_daily_cap', 3)::int;
  v_used int := 0;
begin
  if v_uid is not null then
    select count(*) into v_used from public.scratch_cards
      where user_id = v_uid and issued_date = v_today;
  end if;
  return jsonb_build_object(
    'daily_cap', v_cap,
    'remaining_today', greatest(v_cap - v_used, 0),
    'cards', coalesce(public.setting_json('scratch_cards_config'), '[]'::jsonb));
end;
$$;
grant execute on function public.scratch_config() to authenticated;

-- ---------------------------------------------------------------------------
-- Per-payment-method withdrawal fee.
-- ---------------------------------------------------------------------------
alter table public.payment_methods add column if not exists fee_enabled boolean not null default false;
alter table public.payment_methods add column if not exists fee_type    text    not null default 'percent'; -- percent | fixed | both
alter table public.payment_methods add column if not exists fee_percent numeric not null default 0;
alter table public.payment_methods add column if not exists fee_fixed   numeric not null default 0;

-- Recompute using the METHOD's fee (falls back to global fee only if method
-- fee is disabled AND the global fee is enabled, for backward compatibility).
create or replace function public._withdrawal_compute(p_method_key text, p_bcp bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pm      public.payment_methods;
  v_gross   numeric;
  v_feeon   boolean;
  v_fee     numeric := 0;
  v_net     numeric;
  v_gfeeon  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='withdrawal_fee_enabled'), false);
begin
  select * into v_pm from public.payment_methods where key = p_method_key;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_gross := round((p_bcp::numeric / greatest(v_pm.rate_base, 1)) * v_pm.rate, 2);

  v_feeon := v_pm.fee_enabled;
  if v_feeon then
    if v_pm.fee_type in ('percent','both') then
      v_fee := v_fee + v_gross * v_pm.fee_percent / 100.0;
    end if;
    if v_pm.fee_type in ('fixed','both') then
      v_fee := v_fee + v_pm.fee_fixed;
    end if;
  elsif v_gfeeon then
    -- legacy global fee fallback
    v_fee := v_gross * public.setting_num('withdrawal_fee_percent', 0) / 100.0
             + public.setting_num('withdrawal_fee_fixed', 0);
    v_feeon := true;
  end if;

  v_fee := round(least(v_fee, v_gross), 2);
  v_net := round(v_gross - v_fee, 2);

  return jsonb_build_object(
    'bcp', p_bcp, 'currency', v_pm.currency, 'rate', v_pm.rate,
    'rate_base', v_pm.rate_base, 'gross', v_gross,
    'fee_enabled', v_feeon, 'fee', v_fee, 'net', v_net);
end;
$$;

-- Extend admin_save_payment_method with fee fields (drop prior 10-arg version).
drop function if exists public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int, text, numeric, bigint);
create or replace function public.admin_save_payment_method(
  p_id uuid, p_key text, p_name text, p_fields jsonb, p_min_amount bigint,
  p_active boolean, p_position int,
  p_currency text default null, p_rate numeric default null, p_rate_base bigint default null,
  p_fee_enabled boolean default null, p_fee_type text default null,
  p_fee_percent numeric default null, p_fee_fixed numeric default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.payment_methods(key, name, fields, min_amount, active, position,
      currency, rate, rate_base, fee_enabled, fee_type, fee_percent, fee_fixed)
    values (p_key, p_name, coalesce(p_fields,'[]'::jsonb), coalesce(p_min_amount,0),
      coalesce(p_active,true), coalesce(p_position,0),
      coalesce(p_currency,'₹'), coalesce(p_rate,0), coalesce(p_rate_base,1000),
      coalesce(p_fee_enabled,false), coalesce(p_fee_type,'percent'),
      coalesce(p_fee_percent,0), coalesce(p_fee_fixed,0))
    on conflict (key) do update
      set name=excluded.name, fields=excluded.fields, min_amount=excluded.min_amount,
          active=excluded.active, position=excluded.position, currency=excluded.currency,
          rate=excluded.rate, rate_base=excluded.rate_base, fee_enabled=excluded.fee_enabled,
          fee_type=excluded.fee_type, fee_percent=excluded.fee_percent, fee_fixed=excluded.fee_fixed
    returning id into v_id;
  else
    update public.payment_methods
       set key=p_key, name=p_name, fields=coalesce(p_fields,'[]'::jsonb),
           min_amount=coalesce(p_min_amount,0), active=coalesce(p_active,true),
           position=coalesce(p_position,0), currency=coalesce(p_currency, currency),
           rate=coalesce(p_rate, rate), rate_base=coalesce(p_rate_base, rate_base),
           fee_enabled=coalesce(p_fee_enabled, fee_enabled),
           fee_type=coalesce(p_fee_type, fee_type),
           fee_percent=coalesce(p_fee_percent, fee_percent),
           fee_fixed=coalesce(p_fee_fixed, fee_fixed)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'payment_method.save', 'payment_method', v_id::text, jsonb_build_object('key', p_key));
  return v_id;
end;
$$;
grant execute on function
  public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int, text, numeric, bigint, boolean, text, numeric, numeric)
  to authenticated;

-- Withdrawal fee is now payment-method-specific: remove the obsolete global
-- fee settings (the compute fallback keeps literal defaults, so no behaviour
-- change for methods that don't define their own fee).
delete from public.app_settings where key in (
  'withdrawal_fee_enabled', 'withdrawal_fee_percent', 'withdrawal_fee_fixed'
);


-- >>> supabase/migrations/0021_notifications_editable_custom.sql
-- ============================================================================
-- 0021  Editable automatic reminders (§28) + custom notifications (§29/§30)
-- ----------------------------------------------------------------------------
-- Forward-only, non-destructive.
--
-- §28  Every automatic reminder (daily / mining / boost / unclaimed) becomes
--      fully editable: ON/OFF (already), TITLE, MESSAGE and TIMING (the re-send
--      window, in hours). generate_reminders() now reads these from settings
--      with the previous hard-coded copy as the fallback default, so behaviour
--      is unchanged until an admin edits them.
--
-- §29/§30  Custom notifications: an admin can compose a title + message, choose
--      to target ALL users or a SPECIFIC set, Send Now, and see a history of
--      what was sent. Delivery is real: rows are fanned out into
--      public.notifications (the same feed the in-app Notifications screen and
--      the home banner already read). Every send is recorded in
--      custom_notifications for the admin history.
--
--      NOTE (§43 external dependency): true push delivery to a BACKGROUND or
--      CLOSED app requires Firebase Cloud Messaging (a server key / service
--      account + per-device FCM tokens). Those are external credentials that
--      are not present in this repo and must NOT be hard-coded. This migration
--      implements the full in-app notification pipeline and leaves a
--      device_tokens table + push hook point ready; wiring the FCM sender is a
--      configuration step (documented in the release notes), not code that can
--      ship a secret.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Text settings accessor (mirror of setting_num for string values).
-- ---------------------------------------------------------------------------
create or replace function public.setting_text(p_key text, p_default text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    nullif((select value #>> '{}' from public.app_settings where key = p_key), ''),
    p_default);
$$;

-- ---------------------------------------------------------------------------
-- §28  Editable copy + timing for each automatic reminder.
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('reminder_daily_title',       '"Your daily reward is ready 🎁"',                  'Daily reminder — title'),
  ('reminder_daily_body',        '"Claim your daily BCP before the day ends."',       'Daily reminder — message'),
  ('reminder_daily_window_hours','20',                                                'Daily reminder — min hours between sends'),

  ('reminder_mining_title',      '"Start mining ⛏️"',                                 'Mining reminder — title'),
  ('reminder_mining_body',       '"Your miner is idle — start a session to keep earning BCP."', 'Mining reminder — message'),
  ('reminder_mining_window_hours','20',                                               'Mining reminder — min hours between sends'),

  ('reminder_boost_title',       '"Mining boost ready 🚀"',                           'Boost reminder — title'),
  ('reminder_boost_body',        '"A boost is available — increase your mining rate now."', 'Boost reminder — message'),
  ('reminder_boost_window_hours','0',                                                 'Boost reminder — min hours between sends (0 = use boost cooldown)'),

  ('reminder_unclaimed_title',   '"You have unclaimed BCP 💰"',                       'Unclaimed reminder — title'),
  ('reminder_unclaimed_body',    '"Mined BCP is waiting — open the app to claim it."', 'Unclaimed reminder — message'),
  ('reminder_unclaimed_window_hours','12',                                            'Unclaimed reminder — min hours between sends')
on conflict (key) do nothing;

-- Redefine generate_reminders() to source title/body/window from settings.
create or replace function public.generate_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_daily int := 0; v_mining int := 0; v_boost int := 0; v_unclaimed int := 0;
  v_cool numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_max  int := public.setting_num('mining_max_boosts', 3)::int;
  v_boost_win numeric;
begin
  -- Daily reward ready: active users who can claim today but haven't.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_daily_enabled'), true) then
    v_daily := public._remind(
      array(
        select p.id from public.profiles p
        where p.status = 'active'
          and not exists (select 1 from public.daily_reward_claims d
                          where d.user_id = p.id and d.claim_date = v_today)
      ),
      'daily',
      public.setting_text('reminder_daily_title', 'Your daily reward is ready 🎁'),
      public.setting_text('reminder_daily_body',  'Claim your daily BCP before the day ends.'),
      jsonb_build_object('reminder', 'daily', 'route', '/earn/daily'),
      (public.setting_num('reminder_daily_window_hours', 20) || ' hours')::interval);
  end if;

  -- Mining session ready: active users with no running session.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_mining_enabled'), true) then
    v_mining := public._remind(
      array(
        select p.id from public.profiles p
        where p.status = 'active'
          and not exists (select 1 from public.mining_sessions m
                          where m.user_id = p.id and m.status = 'active' and m.ends_at > now())
      ),
      'system',
      public.setting_text('reminder_mining_title', 'Start mining ⛏️'),
      public.setting_text('reminder_mining_body',  'Your miner is idle — start a session to keep earning BCP.'),
      jsonb_build_object('reminder', 'mining', 'route', '/earn/mining'),
      (public.setting_num('reminder_mining_window_hours', 20) || ' hours')::interval);
  end if;

  -- Boost ready: active sessions where a boost is available now.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_boost_enabled'), true) then
    v_boost_win := public.setting_num('reminder_boost_window_hours', 0);
    if v_boost_win <= 0 then v_boost_win := v_cool; end if;
    v_boost := public._remind(
      array(
        select m.user_id from public.mining_sessions m
        where m.status = 'active' and m.ends_at > now()
          and m.boosts < v_max
          and (m.last_boost_at is null or now() >= m.last_boost_at + (v_cool || ' hours')::interval)
      ),
      'system',
      public.setting_text('reminder_boost_title', 'Mining boost ready 🚀'),
      public.setting_text('reminder_boost_body',  'A boost is available — increase your mining rate now.'),
      jsonb_build_object('reminder', 'boost', 'route', '/earn/mining'),
      (v_boost_win || ' hours')::interval);
  end if;

  -- Unclaimed mined BCP: active sessions with claimable accrual.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_unclaimed_enabled'), true) then
    v_unclaimed := public._remind(
      array(
        select m.user_id from public.mining_sessions m
        where m.status = 'active'
          and public._mining_accrued(m) - m.claimed >= greatest(m.rate_per_hour, 1)
      ),
      'system',
      public.setting_text('reminder_unclaimed_title', 'You have unclaimed BCP 💰'),
      public.setting_text('reminder_unclaimed_body',  'Mined BCP is waiting — open the app to claim it.'),
      jsonb_build_object('reminder', 'unclaimed', 'route', '/earn/mining'),
      (public.setting_num('reminder_unclaimed_window_hours', 12) || ' hours')::interval);
  end if;

  return jsonb_build_object('ok', true, 'daily', v_daily, 'mining', v_mining,
                            'boost', v_boost, 'unclaimed', v_unclaimed);
end;
$$;

-- ---------------------------------------------------------------------------
-- §29/§30  Custom notifications — history table.
-- ---------------------------------------------------------------------------
create table if not exists public.custom_notifications (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  body        text,
  target      text not null default 'all',      -- 'all' | 'specific'
  recipients  int  not null default 0,          -- fan-out count
  sent_by     uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);
create index if not exists idx_custom_notif_created
  on public.custom_notifications(created_at desc);

alter table public.custom_notifications enable row level security;

-- Admins only (read history). Writes go through the SECURITY DEFINER RPC.
drop policy if exists custom_notif_admin_read on public.custom_notifications;
create policy custom_notif_admin_read on public.custom_notifications
  for select using (public.is_admin());

-- ---------------------------------------------------------------------------
-- §29 (external, §43)  Device push tokens — table + hook point, no secrets.
-- The FCM sender is an external configuration step; storing tokens here keeps
-- the app ready without embedding any credential.
-- ---------------------------------------------------------------------------
create table if not exists public.device_tokens (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  token       text not null,
  platform    text not null default 'android',
  updated_at  timestamptz not null default now(),
  primary key (user_id, token)
);
alter table public.device_tokens enable row level security;

drop policy if exists device_tokens_own on public.device_tokens;
create policy device_tokens_own on public.device_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Upsert the caller's current FCM token (called by the app after it obtains one).
create or replace function public.register_device_token(p_token text, p_platform text default 'android')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if coalesce(p_token,'') = '' then return; end if;
  insert into public.device_tokens(user_id, token, platform, updated_at)
  values (v_uid, p_token, coalesce(p_platform,'android'), now())
  on conflict (user_id, token) do update set updated_at = now(),
                                             platform = excluded.platform;
end;
$$;
grant execute on function public.register_device_token(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- §29/§30  Send a custom notification now. Target 'all' (broadcast, one row
-- with null user_id) or 'specific' (one row per selected user). Recorded in
-- custom_notifications for history. Real, immediate, idempotent per call.
-- ---------------------------------------------------------------------------
create or replace function public.admin_send_notification(
  p_title text, p_body text,
  p_target text default 'all', p_user_ids uuid[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_count int := 0;
  v_data  jsonb := jsonb_build_object('custom', true);
begin
  perform public._assert_admin();
  if coalesce(trim(p_title),'') = '' then raise exception 'TITLE_REQUIRED'; end if;

  if p_target = 'specific' then
    if p_user_ids is null or array_length(p_user_ids, 1) is null then
      raise exception 'NO_RECIPIENTS';
    end if;
    insert into public.notifications(user_id, title, body, type, data)
    select u, p_title, p_body, 'announcement', v_data
      from unnest(p_user_ids) as u
      where exists (select 1 from public.profiles p where p.id = u);
    get diagnostics v_count = row_count;
  else
    -- Broadcast: single row with null user_id (read by every user via RLS).
    insert into public.notifications(user_id, title, body, type, data)
    values (null, p_title, p_body, 'announcement', v_data);
    v_count := (select count(*) from public.profiles where status = 'active');
  end if;

  insert into public.custom_notifications(title, body, target, recipients, sent_by)
  values (p_title, p_body, case when p_target = 'specific' then 'specific' else 'all' end,
          v_count, v_admin);

  insert into public.audit_logs(actor_id, action, entity, meta)
  values (v_admin, 'notification.send', 'custom_notification',
          jsonb_build_object('target', p_target, 'recipients', v_count));

  return jsonb_build_object('ok', true, 'recipients', v_count);
end;
$$;
grant execute on function public.admin_send_notification(text, text, text, uuid[]) to authenticated;

-- Admin history of custom notifications sent.
create or replace function public.admin_notification_history(p_limit int default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'title', c.title, 'body', c.body, 'target', c.target,
      'recipients', c.recipients, 'created_at', c.created_at)
      order by c.created_at desc)
    from (select * from public.custom_notifications
          order by created_at desc limit greatest(p_limit, 1)) c
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_notification_history(int) to authenticated;

-- Lightweight user list for the "specific users" picker (admin only).
create or replace function public.admin_user_options(p_search text default null, p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', coalesce(p.full_name, p.username, p.email, 'User'),
      'email', p.email)
      order by p.created_at desc)
    from (
      select * from public.profiles p
      where p_search is null or p_search = ''
         or p.full_name ilike '%'||p_search||'%'
         or p.username ilike '%'||p_search||'%'
         or p.email ilike '%'||p_search||'%'
      order by created_at desc
      limit greatest(p_limit, 1)
    ) p
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_user_options(text, int) to authenticated;

-- ---------------------------------------------------------------------------
-- §31  Contest activity in admin analytics. Redefine admin_analytics to add a
-- `contests` block (started/completed/rejected over the range, plus live
-- active / awaiting-review counts). Reward BCP paid via contests already flows
-- into the `features` block through the ledger `contest` type.
-- ---------------------------------------------------------------------------
create or replace function public.admin_analytics(
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz := coalesce(p_from, '-infinity'::timestamptz);
  v_to   timestamptz := coalesce(p_to, 'infinity'::timestamptz);
  v_ads  jsonb;
  v_feat jsonb;
  v_contest jsonb;
begin
  perform public._assert_admin();

  select jsonb_build_object(
    'requests',   count(*),
    'impressions', count(*) filter (where state in ('impressed','rewarded','credited')),
    'rewarded',    count(*) filter (where state in ('rewarded','credited')),
    'credits',     count(*) filter (where state = 'credited'),
    'credited_bcp', coalesce(sum(reward) filter (where state = 'credited'), 0),
    'by_placement', coalesce((
      select jsonb_object_agg(placement, cnt) from (
        select placement, count(*) filter (where state = 'credited') as cnt
          from public.ad_events
         where created_at >= v_from and created_at <= v_to
         group by placement
      ) p
    ), '{}'::jsonb)
  )
  into v_ads
  from public.ad_events
  where created_at >= v_from and created_at <= v_to;

  select coalesce(jsonb_object_agg(t, jsonb_build_object('count', c, 'bcp', s)), '{}'::jsonb)
  into v_feat
  from (
    select type::text as t, count(*) as c, coalesce(sum(amount),0) as s
      from public.wallet_transactions
     where amount > 0 and created_at >= v_from and created_at <= v_to
     group by type
  ) x;

  -- Contest participation activity. "started/completed/rejected" are counted
  -- within the range; "active/claim_pending" are current live counts.
  select jsonb_build_object(
    'started',       count(*) filter (where started_at >= v_from and started_at <= v_to),
    'completed',     count(*) filter (where state = 'completed'
                        and coalesce(reviewed_at, claimed_at, started_at) >= v_from
                        and coalesce(reviewed_at, claimed_at, started_at) <= v_to),
    'rejected',      count(*) filter (where state = 'rejected'
                        and coalesce(reviewed_at, started_at) >= v_from
                        and coalesce(reviewed_at, started_at) <= v_to),
    'active',        count(*) filter (where state = 'active'),
    'claim_pending', count(*) filter (where state = 'claim_pending')
  )
  into v_contest
  from public.contest_participations;

  return jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'total_users', (select count(*) from public.profiles),
    'new_users', (select count(*) from public.profiles
                   where created_at >= v_from and created_at <= v_to),
    'active_users', (select count(distinct user_id) from public.wallet_transactions
                      where created_at >= v_from and created_at <= v_to),
    'bcp_earned', (select coalesce(sum(amount),0) from public.wallet_transactions
                    where amount > 0 and created_at >= v_from and created_at <= v_to),
    'bcp_withdrawn', (select coalesce(sum(amount),0) from public.withdrawals
                       where status = 'paid'
                         and coalesce(processed_at, created_at) >= v_from
                         and coalesce(processed_at, created_at) <= v_to),
    'pending_withdrawals', (select count(*) from public.withdrawals where status = 'pending'),
    'pending_withdrawal_amount', (select coalesce(sum(amount),0) from public.withdrawals where status = 'pending'),
    'ads', v_ads,
    'features', v_feat,
    'contests', v_contest
  );
end;
$$;
grant execute on function public.admin_analytics(timestamptz, timestamptz) to authenticated;


-- >>> supabase/migrations/0022_push_unregister.sql
-- ============================================================================
-- 0022  Push token unregister (sign-out / device change) + push audit helper
-- ----------------------------------------------------------------------------
-- Forward-only, non-destructive. Complements 0021's device_tokens table and
-- register_device_token(). The `push` edge function does invalid-token cleanup
-- automatically (FCM UNREGISTERED → delete); this RPC lets the client remove
-- its own token deliberately on sign-out, before the session ends.
-- ============================================================================

-- Redefine admin_send_notification to stamp a shared notification id into the
-- in-app rows' data and return it, so the push layer can use the SAME id for
-- de-duplication / collapsing (one logical notification, one banner).
create or replace function public.admin_send_notification(
  p_title text, p_body text,
  p_target text default 'all', p_user_ids uuid[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_count int := 0;
  v_id uuid := gen_random_uuid();
  v_data jsonb;
begin
  perform public._assert_admin();
  if coalesce(trim(p_title),'') = '' then raise exception 'TITLE_REQUIRED'; end if;

  v_data := jsonb_build_object('custom', true, 'id', v_id::text,
                               'route', '/notifications');

  if p_target = 'specific' then
    if p_user_ids is null or array_length(p_user_ids, 1) is null then
      raise exception 'NO_RECIPIENTS';
    end if;
    insert into public.notifications(user_id, title, body, type, data)
    select u, p_title, p_body, 'announcement', v_data
      from unnest(p_user_ids) as u
      where exists (select 1 from public.profiles p where p.id = u);
    get diagnostics v_count = row_count;
  else
    insert into public.notifications(user_id, title, body, type, data)
    values (null, p_title, p_body, 'announcement', v_data);
    v_count := (select count(*) from public.profiles where status = 'active');
  end if;

  insert into public.custom_notifications(id, title, body, target, recipients, sent_by)
  values (v_id, p_title, p_body,
          case when p_target = 'specific' then 'specific' else 'all' end,
          v_count, v_admin);

  insert into public.audit_logs(actor_id, action, entity, meta)
  values (v_admin, 'notification.send', 'custom_notification',
          jsonb_build_object('target', p_target, 'recipients', v_count));

  return jsonb_build_object('ok', true, 'recipients', v_count, 'id', v_id::text);
end;
$$;
grant execute on function public.admin_send_notification(text, text, text, uuid[]) to authenticated;

create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return; end if;
  if coalesce(p_token,'') = '' then
    -- No token given: clear all of this user's tokens (full sign-out cleanup).
    delete from public.device_tokens where user_id = v_uid;
  else
    delete from public.device_tokens where user_id = v_uid and token = p_token;
  end if;
end;
$$;
grant execute on function public.unregister_device_token(text) to authenticated;


-- >>> supabase/migrations/0023_scratch_watch_rules.sql
-- ============================================================================
-- 0023  Admin-configurable Scratch Card rules + Watch Ads rules (server-side),
--       plus mining-claim rewarded-ad default. Forward-only, non-destructive.
--
-- Everything reward/cooldown/limit-related is decided and enforced on the
-- server. The client can never set a reward, skip a cooldown, bypass the ad
-- requirement, or exceed a limit. Cooldowns are derived from authoritative
-- timestamps, so they survive app close/reopen, logout/login and refresh.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- SCRATCH RULES  (a band of the user's scratch sequence number → reward range,
-- ads required, search-card delay, and next-scratch cooldown).
-- ---------------------------------------------------------------------------
create table if not exists public.scratch_rules (
  id                   uuid primary key default gen_random_uuid(),
  from_card            int  not null,                 -- inclusive sequence lower bound
  to_card              int  not null,                 -- inclusive sequence upper bound
  min_reward           bigint not null,
  max_reward           bigint not null,
  ads_required         int  not null default 1,
  search_delay_seconds int  not null default 10,      -- delay after ad → Search Card
  cooldown_seconds     int  not null default 3600,    -- cooldown before next scratch
  active               boolean not null default true,
  position             int  not null default 0,
  created_at           timestamptz not null default now()
);
create index if not exists idx_scratch_rules_order on public.scratch_rules(from_card);
alter table public.scratch_rules enable row level security;
drop policy if exists scratch_rules_read on public.scratch_rules;
create policy scratch_rules_read on public.scratch_rules
  for select using (true);  -- ranges are public info; writes go through RPCs

-- Capture the applied rule on each issued card so cooldown/delay/ads are stable
-- for that card regardless of later admin edits.
alter table public.scratch_cards add column if not exists seq int;
alter table public.scratch_cards add column if not exists ads_required int not null default 1;
alter table public.scratch_cards add column if not exists search_delay_seconds int not null default 10;
alter table public.scratch_cards add column if not exists cooldown_seconds int not null default 3600;

-- Seed example rules (only if the admin has none yet). Non-overlapping bands.
insert into public.scratch_rules(from_card, to_card, min_reward, max_reward, ads_required, search_delay_seconds, cooldown_seconds, position)
select * from (values
  (1, 4,  20::bigint, 40::bigint, 1, 10, 3600, 0),
  (5, 10, 20::bigint, 30::bigint, 1, 20, 7200, 1)
) v
where not exists (select 1 from public.scratch_rules);

-- Pick the active rule whose band contains sequence number N (fallback: the
-- active rule with the highest band, so past the last band the last rule holds).
create or replace function public._scratch_rule_for(p_seq int)
returns public.scratch_rules
language plpgsql
stable
security definer
set search_path = public
as $$
declare r public.scratch_rules;
begin
  select * into r from public.scratch_rules
   where active and p_seq between from_card and to_card
   order by from_card limit 1;
  if found then return r; end if;
  select * into r from public.scratch_rules
   where active order by to_card desc limit 1;
  return r; -- may be null if no rules configured
end;
$$;

-- Scratch status: cooldown-aware, rule-driven. Returns the user's current
-- state so the screen can show a live countdown and the reward range.
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_card   public.scratch_cards;
  v_last   public.scratch_cards;
  v_seq    int;
  v_rule   public.scratch_rules;
  v_next   timestamptz;
  v_reward bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Already holding an un-scratched card? Return it with its captured rule.
  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
      'card_id', v_card.id, 'seq', v_card.seq,
      'ads_required', v_card.ads_required,
      'search_delay_seconds', v_card.search_delay_seconds,
      'cooldown_seconds', v_card.cooldown_seconds);
  end if;

  -- Cooldown gate: next-available = last scratched card time + its cooldown.
  select * into v_last from public.scratch_cards
    where user_id = v_uid and status = 'scratched' and scratched_at is not null
    order by scratched_at desc limit 1;
  if found then
    v_next := v_last.scratched_at + (v_last.cooldown_seconds || ' seconds')::interval;
    if now() < v_next then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'next_available_at', v_next);
    end if;
  end if;

  -- Eligible now → issue the next card, capturing the applicable rule.
  v_seq  := coalesce((select count(*) from public.scratch_cards
                       where user_id = v_uid and status = 'scratched'), 0) + 1;
  v_rule := public._scratch_rule_for(v_seq);
  if v_rule.id is null then
    -- No rules configured → nothing to offer (never breaks the screen).
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false);
  end if;
  v_reward := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;

  insert into public.scratch_cards(user_id, reward_amount, source, seq,
      ads_required, search_delay_seconds, cooldown_seconds)
  values (v_uid, v_reward, 'rule', v_seq,
      greatest(v_rule.ads_required, 0), greatest(v_rule.search_delay_seconds, 0),
      greatest(v_rule.cooldown_seconds, 0))
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
    'card_id', v_card.id, 'seq', v_card.seq,
    'ads_required', v_card.ads_required,
    'search_delay_seconds', v_card.search_delay_seconds,
    'cooldown_seconds', v_card.cooldown_seconds);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- Reveal with N rewarded ads (ads_required) + server-enforced search delay.
-- p_nonces: the completed 'scratch' ad_event ids the user watched.
create or replace function public.scratch_reveal(p_card_id uuid, p_nonces uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_card   public.scratch_cards;
  v_need   int;
  v_have   int := 0;
  v_last_ad timestamptz;
  v_new    bigint;
  n        uuid;
  v_ad     public.ad_events;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
  if v_card.status <> 'available' then raise exception 'CARD_ALREADY_USED'; end if;

  v_need := greatest(v_card.ads_required, 0);

  -- Validate + consume each required rewarded ad (idempotent, replay-proof).
  if v_need > 0 then
    if p_nonces is null or array_length(p_nonces, 1) is null
       or array_length(p_nonces, 1) < v_need then
      raise exception 'AD_REQUIRED';
    end if;
    foreach n in array p_nonces loop
      exit when v_have >= v_need;
      select * into v_ad from public.ad_events
        where id = n and user_id = v_uid and placement = 'scratch' for update;
      if not found then raise exception 'AD_REQUIRED'; end if;
      if v_ad.state = 'credited' then raise exception 'AD_ALREADY_USED'; end if;
      if v_ad.state <> 'rewarded' then raise exception 'AD_NOT_COMPLETED'; end if;
      if v_last_ad is null or v_ad.updated_at > v_last_ad then
        v_last_ad := v_ad.updated_at;
      end if;
      -- consume (this also enforces the global daily rewarded cap)
      perform public._consume_ad(v_uid, 'scratch', n);
      v_have := v_have + 1;
    end loop;

    -- Server-enforced Search-Card delay: reveal only after the delay elapses
    -- from the last completed ad. The client shows the same countdown.
    if v_last_ad is not null
       and now() < v_last_ad + (v_card.search_delay_seconds || ' seconds')::interval then
      raise exception 'SEARCH_DELAY_ACTIVE';
    end if;
  end if;

  update public.scratch_cards set status = 'scratched', scratched_at = now()
   where id = v_card.id;

  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id,
                                'Scratch card reward');
  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount, 'balance', v_new);
end;
$$;
grant execute on function public.scratch_reveal(uuid, uuid[]) to authenticated;

-- scratch_config: the configured rules (for the user screen's range display).
create or replace function public.scratch_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'from_card', from_card, 'to_card', to_card,
        'min', min_reward, 'max', max_reward,
        'ads_required', ads_required,
        'search_delay_seconds', search_delay_seconds,
        'cooldown_seconds', cooldown_seconds)
        order by from_card)
      from public.scratch_rules where active), '[]'::jsonb));
end;
$$;
grant execute on function public.scratch_config() to authenticated;

-- Admin: list / save / delete scratch rules with validation.
create or replace function public.admin_scratch_rules()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'from_card', from_card, 'to_card', to_card,
      'min_reward', min_reward, 'max_reward', max_reward,
      'ads_required', ads_required, 'search_delay_seconds', search_delay_seconds,
      'cooldown_seconds', cooldown_seconds, 'active', active, 'position', position)
      order by from_card)
    from public.scratch_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_scratch_rules() to authenticated;

create or replace function public.admin_save_scratch_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_ads int, p_search_delay int, p_cooldown int, p_active boolean)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  -- Validation (server-authoritative; the admin UI mirrors these).
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_ads,0) < 0 or coalesce(p_search_delay,0) < 0 or coalesce(p_cooldown,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  -- No overlap with other ACTIVE rules.
  if coalesce(p_active, true) and exists (
    select 1 from public.scratch_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_card, to_card, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.scratch_rules(from_card, to_card, min_reward, max_reward,
        ads_required, search_delay_seconds, cooldown_seconds, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_ads,1),
        coalesce(p_search_delay,10), coalesce(p_cooldown,3600),
        coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.scratch_rules
       set from_card=p_from, to_card=p_to, min_reward=p_min, max_reward=p_max,
           ads_required=coalesce(p_ads,1), search_delay_seconds=coalesce(p_search_delay,10),
           cooldown_seconds=coalesce(p_cooldown,3600), active=coalesce(p_active,true),
           position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'scratch_rule.save', 'scratch_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_scratch_rule(uuid, int, int, bigint, bigint, int, int, int, boolean) to authenticated;

create or replace function public.admin_delete_scratch_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.scratch_rules where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'scratch_rule.delete', 'scratch_rule', p_id::text);
end;
$$;
grant execute on function public.admin_delete_scratch_rule(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- WATCH ADS RULES  (a band of the day's ad number → reward range + cooldown).
-- ---------------------------------------------------------------------------
create table if not exists public.watch_ad_rules (
  id               uuid primary key default gen_random_uuid(),
  from_ad          int not null,               -- inclusive daily ad index lower bound
  to_ad            int not null,               -- inclusive daily ad index upper bound
  min_reward       bigint not null,
  max_reward       bigint not null,
  cooldown_seconds int not null default 30,
  daily_limit      int not null default 0,     -- optional explicit daily cap (0 = derive from bands)
  active           boolean not null default true,
  position         int not null default 0,
  created_at       timestamptz not null default now()
);
create index if not exists idx_watch_ad_rules_order on public.watch_ad_rules(from_ad);
alter table public.watch_ad_rules enable row level security;
drop policy if exists watch_ad_rules_read on public.watch_ad_rules;
create policy watch_ad_rules_read on public.watch_ad_rules
  for select using (true);

insert into public.watch_ad_rules(from_ad, to_ad, min_reward, max_reward, cooldown_seconds, position)
select * from (values
  (1,  5,  10::bigint, 30::bigint, 30,  0),
  (6,  10, 10::bigint, 25::bigint, 60,  1),
  (11, 20, 5::bigint,  20::bigint, 300, 2)
) v
where not exists (select 1 from public.watch_ad_rules);

create or replace function public._watch_ad_rule_for(p_n int)
returns public.watch_ad_rules
language plpgsql stable security definer set search_path = public
as $$
declare r public.watch_ad_rules;
begin
  select * into r from public.watch_ad_rules
   where active and p_n between from_ad and to_ad order by from_ad limit 1;
  if found then return r; end if;
  select * into r from public.watch_ad_rules
   where active order by to_ad desc limit 1;
  return r;
end;
$$;

-- Effective total daily ad cap: explicit daily_limit if any set, else max band.
create or replace function public._watch_ad_daily_cap()
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select max(daily_limit) from public.watch_ad_rules where active and daily_limit > 0),
    (select max(to_ad) from public.watch_ad_rules where active),
    public.setting_num('ads_daily_cap', 20)::int);
$$;

-- Watch-ads status for the user screen: current/next reward band, cooldown
-- countdown target, and remaining today. Server-authoritative.
create or replace function public.watch_ads_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_cap   int := public._watch_ad_daily_cap();
  v_last  timestamptz;
  v_next_rule public.watch_ad_rules;
  v_prev_rule public.watch_ad_rules;
  v_next  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select count(*), max(created_at) into v_count, v_last
    from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);

  v_next_rule := public._watch_ad_rule_for(v_count + 1); -- band of the next ad
  if v_last is not null and v_count > 0 then
    v_prev_rule := public._watch_ad_rule_for(v_count);   -- cooldown from last ad
    if v_prev_rule.id is not null then
      v_next := v_last + (v_prev_rule.cooldown_seconds || ' seconds')::interval;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'daily_cap', v_cap,
    'used_today', v_count,
    'remaining_today', greatest(v_cap - v_count, 0),
    'min_reward', coalesce(v_next_rule.min_reward, public.setting_num('ads_reward', 15)::bigint),
    'max_reward', coalesce(v_next_rule.max_reward, public.setting_num('ads_reward', 15)::bigint),
    'next_available_at', v_next,
    'available', (v_count < v_cap) and (v_next is null or now() >= v_next));
end;
$$;
grant execute on function public.watch_ads_status() to authenticated;

-- Watch-ads credit: rule-based reward range + server-authoritative cooldown +
-- daily cap. Requires a completed rewarded nonce (existing replay protection).
create or replace function public.reward_ad(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_count  int;
  v_cap    int := public._watch_ad_daily_cap();
  v_last   timestamptz;
  v_rule   public.watch_ad_rules;
  v_prev   public.watch_ad_rules;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select count(*), max(created_at) into v_count, v_last
    from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_count >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;

  -- Server-authoritative cooldown from the previous ad's band.
  if v_count > 0 and v_last is not null then
    v_prev := public._watch_ad_rule_for(v_count);
    if v_prev.id is not null and now() - v_last < (v_prev.cooldown_seconds || ' seconds')::interval then
      raise exception 'AD_TOO_SOON';
    end if;
  end if;

  -- Reward exists only because an ad was watched → a completed nonce is required.
  if p_nonce is null then raise exception 'AD_REQUIRED'; end if;
  perform public._consume_ad(v_uid, 'watch_ads', p_nonce);

  v_rule := public._watch_ad_rule_for(v_count + 1);
  if v_rule.id is not null then
    v_amount := (v_rule.min_reward
                 + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                      - v_rule.min_reward + 1)))::bigint;
  else
    v_amount := public.setting_num('ads_reward', 15)::bigint; -- fallback
  end if;

  insert into public.ad_rewards(user_id, reward_amount, network, verified)
  values (v_uid, v_amount, 'admob', false);
  update public.ad_events set reward = v_amount, updated_at = now() where id = p_nonce;

  v_new := public._apply_ledger(v_uid, v_amount, 'ad', null, 'Rewarded ad');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', greatest(v_cap - v_count - 1, 0));
end;
$$;
grant execute on function public.reward_ad(uuid) to authenticated;

-- Admin: list / save / delete watch-ad rules with validation.
create or replace function public.admin_watch_ad_rules()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'from_ad', from_ad, 'to_ad', to_ad,
      'min_reward', min_reward, 'max_reward', max_reward,
      'cooldown_seconds', cooldown_seconds, 'daily_limit', daily_limit,
      'active', active, 'position', position)
      order by from_ad)
    from public.watch_ad_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_watch_ad_rules() to authenticated;

create or replace function public.admin_save_watch_ad_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_cooldown int, p_daily_limit int, p_active boolean)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_cooldown,0) < 0 or coalesce(p_daily_limit,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  if coalesce(p_active, true) and exists (
    select 1 from public.watch_ad_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_ad, to_ad, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.watch_ad_rules(from_ad, to_ad, min_reward, max_reward,
        cooldown_seconds, daily_limit, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_cooldown,30),
        coalesce(p_daily_limit,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.watch_ad_rules
       set from_ad=p_from, to_ad=p_to, min_reward=p_min, max_reward=p_max,
           cooldown_seconds=coalesce(p_cooldown,30), daily_limit=coalesce(p_daily_limit,0),
           active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'watch_ad_rule.save', 'watch_ad_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_watch_ad_rule(uuid, int, int, bigint, bigint, int, int, boolean) to authenticated;

create or replace function public.admin_delete_watch_ad_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.watch_ad_rules where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'watch_ad_rule.delete', 'watch_ad_rule', p_id::text);
end;
$$;
grant execute on function public.admin_delete_watch_ad_rule(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Mining: claiming BCP requires a completed rewarded ad by default now.
-- (Admin can still toggle mining_claim_requires_ad in Config.)
-- ---------------------------------------------------------------------------
update public.app_settings set value = 'true' where key = 'mining_claim_requires_ad';


-- >>> supabase/migrations/0024_rule_wait_after.sql
-- ============================================================================
-- 0024  "Wait after previous rule" timing for Watch-Ads and Scratch rules,
--       plus a per-rule daily limit for Scratch. Forward-only, non-destructive.
--
-- Two DISTINCT timers (do not confuse them):
--   * cooldown_seconds  — the gap BETWEEN ads/cards WITHIN the same rule band.
--   * wait_after_seconds — the wait BEFORE the FIRST ad/card of a rule becomes
--     available, measured from the completion of the LAST ad/card of the
--     PREVIOUS rule. Only applies when crossing a rule boundary.
--
-- All timers are derived from authoritative server timestamps, so they survive
-- app close/reopen, logout/login and refresh.
-- ============================================================================

alter table public.watch_ad_rules add column if not exists wait_after_seconds int not null default 0;
alter table public.scratch_rules   add column if not exists wait_after_seconds int not null default 0;
alter table public.scratch_rules   add column if not exists daily_limit        int not null default 0;

-- ---------------------------------------------------------------------------
-- §14/§16: the REWARDED-ADS MASTER must be authoritative server-side. Make a
-- placement "ad-gated" only when BOTH masters (ads_system_enabled AND
-- rewarded_ads_enabled) are on AND the per-section gate is on. So when the
-- Reward-ads master is OFF, _consume_ad treats every placement as ungated and
-- no rewarded ad is required anywhere (matching the client, which skips the ad).
-- ---------------------------------------------------------------------------
create or replace function public._ad_gated(p_placement text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true)
     and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true)
     and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_' || p_placement), true);
$$;

-- Scratch reveal becomes master-aware: when scratch is not ad-gated (master or
-- section off) the ad requirement is skipped entirely and the card reveals
-- directly, so a disabled Reward-ads master never blocks the reward.
create or replace function public.scratch_reveal(p_card_id uuid, p_nonces uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_card   public.scratch_cards;
  v_need   int;
  v_have   int := 0;
  v_last_ad timestamptz;
  v_new    bigint;
  n        uuid;
  v_ad     public.ad_events;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
  if v_card.status <> 'available' then raise exception 'CARD_ALREADY_USED'; end if;

  -- Master/section OFF → no ad required for scratch at all.
  v_need := case when public._ad_gated('scratch') then greatest(v_card.ads_required, 0) else 0 end;

  if v_need > 0 then
    if p_nonces is null or array_length(p_nonces, 1) is null
       or array_length(p_nonces, 1) < v_need then
      raise exception 'AD_REQUIRED';
    end if;
    foreach n in array p_nonces loop
      exit when v_have >= v_need;
      select * into v_ad from public.ad_events
        where id = n and user_id = v_uid and placement = 'scratch' for update;
      if not found then raise exception 'AD_REQUIRED'; end if;
      if v_ad.state = 'credited' then raise exception 'AD_ALREADY_USED'; end if;
      if v_ad.state <> 'rewarded' then raise exception 'AD_NOT_COMPLETED'; end if;
      if v_last_ad is null or v_ad.updated_at > v_last_ad then
        v_last_ad := v_ad.updated_at;
      end if;
      perform public._consume_ad(v_uid, 'scratch', n);
      v_have := v_have + 1;
    end loop;

    if v_last_ad is not null
       and now() < v_last_ad + (v_card.search_delay_seconds || ' seconds')::interval then
      raise exception 'SEARCH_DELAY_ACTIVE';
    end if;
  end if;

  update public.scratch_cards set status = 'scratched', scratched_at = now()
   where id = v_card.id;

  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id,
                                'Scratch card reward');
  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount, 'balance', v_new);
end;
$$;
grant execute on function public.scratch_reveal(uuid, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- WATCH ADS: availability now distinguishes within-rule cooldown from the
-- rule-boundary wait. Helper returns the next-available timestamp (or null).
-- ---------------------------------------------------------------------------
create or replace function public._watch_next_available(p_uid uuid)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_last  timestamptz;
  v_next_rule public.watch_ad_rules;
  v_prev_rule public.watch_ad_rules;
begin
  select count(*), max(created_at) into v_count, v_last
    from public.ad_rewards where user_id = p_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_count = 0 or v_last is null then
    return null; -- first ad of the day is immediately available
  end if;
  v_next_rule := public._watch_ad_rule_for(v_count + 1);
  v_prev_rule := public._watch_ad_rule_for(v_count);
  if v_next_rule.id is null then return null; end if;

  if v_prev_rule.id is not null and v_next_rule.id <> v_prev_rule.id
     and (v_count + 1) = v_next_rule.from_ad then
    -- Crossing into a new rule at its first ad → wait-after-previous-rule.
    return v_last + (greatest(v_next_rule.wait_after_seconds, 0) || ' seconds')::interval;
  else
    -- Same rule → between-ads cooldown.
    return v_last + (greatest(v_prev_rule.cooldown_seconds, 0) || ' seconds')::interval;
  end if;
end;
$$;

create or replace function public.watch_ads_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_cap   int := public._watch_ad_daily_cap();
  v_next_rule public.watch_ad_rules;
  v_next  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select count(*) into v_count from public.ad_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  v_next_rule := public._watch_ad_rule_for(v_count + 1);
  v_next := public._watch_next_available(v_uid);

  return jsonb_build_object(
    'ok', true,
    'daily_cap', v_cap,
    'used_today', v_count,
    'remaining_today', greatest(v_cap - v_count, 0),
    'min_reward', coalesce(v_next_rule.min_reward, public.setting_num('ads_reward', 15)::bigint),
    'max_reward', coalesce(v_next_rule.max_reward, public.setting_num('ads_reward', 15)::bigint),
    'next_available_at', v_next,
    'available', (v_count < v_cap) and (v_next is null or now() >= v_next));
end;
$$;
grant execute on function public.watch_ads_status() to authenticated;

create or replace function public.reward_ad(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_count  int;
  v_cap    int := public._watch_ad_daily_cap();
  v_next   timestamptz;
  v_rule   public.watch_ad_rules;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select count(*) into v_count from public.ad_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_count >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;

  -- Server-authoritative timing: within-rule cooldown OR rule-boundary wait.
  v_next := public._watch_next_available(v_uid);
  if v_next is not null and now() < v_next then raise exception 'AD_TOO_SOON'; end if;

  if p_nonce is null then raise exception 'AD_REQUIRED'; end if;
  perform public._consume_ad(v_uid, 'watch_ads', p_nonce);

  v_rule := public._watch_ad_rule_for(v_count + 1);
  if v_rule.id is not null then
    v_amount := (v_rule.min_reward
                 + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                      - v_rule.min_reward + 1)))::bigint;
  else
    v_amount := public.setting_num('ads_reward', 15)::bigint;
  end if;

  insert into public.ad_rewards(user_id, reward_amount, network, verified)
  values (v_uid, v_amount, 'admob', false);
  update public.ad_events set reward = v_amount, updated_at = now() where id = p_nonce;

  v_new := public._apply_ledger(v_uid, v_amount, 'ad', null, 'Rewarded ad');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', greatest(v_cap - v_count - 1, 0));
end;
$$;
grant execute on function public.reward_ad(uuid) to authenticated;

-- Admin save gains wait_after_seconds (drops the prior 8-arg signature).
drop function if exists public.admin_save_watch_ad_rule(uuid, int, int, bigint, bigint, int, int, boolean);
create or replace function public.admin_save_watch_ad_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_cooldown int, p_daily_limit int, p_active boolean, p_wait_after int default 0)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_cooldown,0) < 0 or coalesce(p_daily_limit,0) < 0 or coalesce(p_wait_after,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  if coalesce(p_active, true) and exists (
    select 1 from public.watch_ad_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_ad, to_ad, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.watch_ad_rules(from_ad, to_ad, min_reward, max_reward,
        cooldown_seconds, daily_limit, wait_after_seconds, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_cooldown,30),
        coalesce(p_daily_limit,0), coalesce(p_wait_after,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.watch_ad_rules
       set from_ad=p_from, to_ad=p_to, min_reward=p_min, max_reward=p_max,
           cooldown_seconds=coalesce(p_cooldown,30), daily_limit=coalesce(p_daily_limit,0),
           wait_after_seconds=coalesce(p_wait_after,0), active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'watch_ad_rule.save', 'watch_ad_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_watch_ad_rule(uuid, int, int, bigint, bigint, int, int, boolean, int) to authenticated;

create or replace function public.admin_watch_ad_rules()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'from_ad', from_ad, 'to_ad', to_ad,
      'min_reward', min_reward, 'max_reward', max_reward,
      'cooldown_seconds', cooldown_seconds, 'wait_after_seconds', wait_after_seconds,
      'daily_limit', daily_limit, 'active', active, 'position', position)
      order by from_ad)
    from public.watch_ad_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_watch_ad_rules() to authenticated;

-- ---------------------------------------------------------------------------
-- SCRATCH: rule-boundary wait + per-rule daily cap in scratch_status.
-- ---------------------------------------------------------------------------
create or replace function public._scratch_daily_cap()
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select max(daily_limit) from public.scratch_rules where active and daily_limit > 0),
    0);  -- 0 = no explicit daily cap (cooldown governs pacing)
$$;

create or replace function public.scratch_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_card   public.scratch_cards;
  v_last   public.scratch_cards;
  v_seq    int;
  v_rule   public.scratch_rules;
  v_prev   public.scratch_rules;
  v_next   timestamptz;
  v_reward bigint;
  v_cap    int := public._scratch_daily_cap();
  v_used   int := 0;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Already holding an un-scratched card? Return it with its captured rule.
  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
      'card_id', v_card.id, 'seq', v_card.seq,
      'ads_required', v_card.ads_required,
      'search_delay_seconds', v_card.search_delay_seconds,
      'cooldown_seconds', v_card.cooldown_seconds);
  end if;

  -- Daily cap (per-rule daily_limit, taken as the max across active rules).
  if v_cap > 0 then
    select count(*) into v_used from public.scratch_cards
      where user_id = v_uid and status = 'scratched'
        and (scratched_at at time zone 'utc')::date = v_today;
    if v_used >= v_cap then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'daily_limit_reached', true, 'remaining_today', 0);
    end if;
  end if;

  v_seq := coalesce((select count(*) from public.scratch_cards
                      where user_id = v_uid and status = 'scratched'), 0) + 1;
  v_rule := public._scratch_rule_for(v_seq);
  if v_rule.id is null then
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false);
  end if;

  -- Timing gate: within-rule cooldown OR rule-boundary wait-after-previous.
  select * into v_last from public.scratch_cards
    where user_id = v_uid and status = 'scratched' and scratched_at is not null
    order by scratched_at desc limit 1;
  if found then
    v_prev := public._scratch_rule_for(v_last.seq);
    if v_prev.id is not null and v_rule.id <> v_prev.id and v_seq = v_rule.from_card then
      v_next := v_last.scratched_at + (greatest(v_rule.wait_after_seconds,0) || ' seconds')::interval;
    else
      v_next := v_last.scratched_at + (greatest(v_last.cooldown_seconds,0) || ' seconds')::interval;
    end if;
    if now() < v_next then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'next_available_at', v_next);
    end if;
  end if;

  v_reward := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;
  insert into public.scratch_cards(user_id, reward_amount, source, seq,
      ads_required, search_delay_seconds, cooldown_seconds)
  values (v_uid, v_reward, 'rule', v_seq,
      greatest(v_rule.ads_required,0), greatest(v_rule.search_delay_seconds,0),
      greatest(v_rule.cooldown_seconds,0))
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
    'card_id', v_card.id, 'seq', v_card.seq,
    'ads_required', v_card.ads_required,
    'search_delay_seconds', v_card.search_delay_seconds,
    'cooldown_seconds', v_card.cooldown_seconds,
    'remaining_today', case when v_cap > 0 then greatest(v_cap - v_used, 0) else null end);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- Admin save/list gain wait_after_seconds + daily_limit (drop the 9-arg form).
drop function if exists public.admin_save_scratch_rule(uuid, int, int, bigint, bigint, int, int, int, boolean);
create or replace function public.admin_save_scratch_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_ads int, p_search_delay int, p_cooldown int, p_active boolean,
  p_wait_after int default 0, p_daily_limit int default 0)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_ads,0) < 0 or coalesce(p_search_delay,0) < 0 or coalesce(p_cooldown,0) < 0
     or coalesce(p_wait_after,0) < 0 or coalesce(p_daily_limit,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  if coalesce(p_active, true) and exists (
    select 1 from public.scratch_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_card, to_card, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.scratch_rules(from_card, to_card, min_reward, max_reward,
        ads_required, search_delay_seconds, cooldown_seconds, wait_after_seconds,
        daily_limit, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_ads,1),
        coalesce(p_search_delay,10), coalesce(p_cooldown,3600),
        coalesce(p_wait_after,0), coalesce(p_daily_limit,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.scratch_rules
       set from_card=p_from, to_card=p_to, min_reward=p_min, max_reward=p_max,
           ads_required=coalesce(p_ads,1), search_delay_seconds=coalesce(p_search_delay,10),
           cooldown_seconds=coalesce(p_cooldown,3600), wait_after_seconds=coalesce(p_wait_after,0),
           daily_limit=coalesce(p_daily_limit,0), active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'scratch_rule.save', 'scratch_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_scratch_rule(uuid, int, int, bigint, bigint, int, int, int, boolean, int, int) to authenticated;

create or replace function public.admin_scratch_rules()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'from_card', from_card, 'to_card', to_card,
      'min_reward', min_reward, 'max_reward', max_reward,
      'ads_required', ads_required, 'search_delay_seconds', search_delay_seconds,
      'cooldown_seconds', cooldown_seconds, 'wait_after_seconds', wait_after_seconds,
      'daily_limit', daily_limit, 'active', active, 'position', position)
      order by from_card)
    from public.scratch_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_scratch_rules() to authenticated;


-- >>> supabase/migrations/0025_search_card.sql
-- ============================================================================
-- 0025  Search Card — admin rule system + real, server-authoritative rewards.
-- Mirrors the Watch-Ads rule system (bands, cooldown, wait-after-previous-rule,
-- daily limit, ad gating). Forward-only, non-destructive.
--
-- Flow: the user performs a Search → gets a result → reward step. If Search is
-- ad-gated (section + masters ON) a completed rewarded ad is required and
-- verified server-side; otherwise the reward is granted directly. Searching
-- alone never credits BCP — only search_card_reward() credits, and it enforces
-- the applicable rule, cooldown, wait-after-rule, daily cap and ad requirement.
-- ============================================================================

-- Ledger type for search-card rewards (late-bound; safe to add + use in bodies).
alter type ledger_type add value if not exists 'search_card';

-- Section ad-gate + banner flags for the 'search' placement.
insert into public.app_settings(key, value, description) values
  ('ad_gate_search', 'true', 'Search Card · rewarded ad required'),
  ('banner_search',  'true', 'Search Card · banner')
on conflict (key) do nothing;

-- Per-user daily search counter (mirrors ad_rewards) — authoritative timestamps.
create table if not exists public.search_rewards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  reward_amount bigint not null,
  reward_date   date not null default (now() at time zone 'utc')::date,
  created_at    timestamptz not null default now()
);
create index if not exists idx_search_rewards_user_date
  on public.search_rewards(user_id, reward_date);
alter table public.search_rewards enable row level security;
drop policy if exists search_rewards_self on public.search_rewards;
create policy search_rewards_self on public.search_rewards
  for select using (user_id = auth.uid() or public.is_admin());

-- Rule bands: a band of the day's search index → reward range + timing + limit.
create table if not exists public.search_card_rules (
  id                 uuid primary key default gen_random_uuid(),
  from_search        int not null,
  to_search          int not null,
  min_reward         bigint not null,
  max_reward         bigint not null,
  cooldown_seconds   int not null default 30,   -- gap between searches within a rule
  wait_after_seconds int not null default 0,    -- wait before the first search of a NEW rule
  daily_limit        int not null default 0,    -- explicit daily cap (0 = derive from bands)
  active             boolean not null default true,
  position           int not null default 0,
  created_at         timestamptz not null default now()
);
create index if not exists idx_search_rules_order on public.search_card_rules(from_search);
alter table public.search_card_rules enable row level security;
drop policy if exists search_rules_read on public.search_card_rules;
create policy search_rules_read on public.search_card_rules for select using (true);

insert into public.search_card_rules(from_search, to_search, min_reward, max_reward, cooldown_seconds, wait_after_seconds, daily_limit, position)
select * from (values
  (1,  5,  10::bigint, 30::bigint, 30,  0,    0, 0),
  (6,  10, 20::bigint, 40::bigint, 60,  3600, 0, 1)
) v
where not exists (select 1 from public.search_card_rules);

create or replace function public._search_rule_for(p_n int)
returns public.search_card_rules
language plpgsql stable security definer set search_path = public
as $$
declare r public.search_card_rules;
begin
  select * into r from public.search_card_rules
   where active and p_n between from_search and to_search order by from_search limit 1;
  if found then return r; end if;
  select * into r from public.search_card_rules
   where active order by to_search desc limit 1;
  return r;
end;
$$;

create or replace function public._search_daily_cap()
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select max(daily_limit) from public.search_card_rules where active and daily_limit > 0),
    (select max(to_search) from public.search_card_rules where active),
    0);
$$;

-- Next-available timestamp: within-rule cooldown OR rule-boundary wait.
create or replace function public._search_next_available(p_uid uuid)
returns timestamptz
language plpgsql stable security definer set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_last  timestamptz;
  v_next_rule public.search_card_rules;
  v_prev_rule public.search_card_rules;
begin
  select count(*), max(created_at) into v_count, v_last
    from public.search_rewards where user_id = p_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_count = 0 or v_last is null then return null; end if;
  v_next_rule := public._search_rule_for(v_count + 1);
  v_prev_rule := public._search_rule_for(v_count);
  if v_next_rule.id is null then return null; end if;
  if v_prev_rule.id is not null and v_next_rule.id <> v_prev_rule.id
     and (v_count + 1) = v_next_rule.from_search then
    return v_last + (greatest(v_next_rule.wait_after_seconds,0) || ' seconds')::interval;
  else
    return v_last + (greatest(v_prev_rule.cooldown_seconds,0) || ' seconds')::interval;
  end if;
end;
$$;

-- Status for the user screen: current reward band, cooldown/wait target,
-- remaining today, and whether an ad is required (section + masters).
create or replace function public.search_card_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_cap   int := public._search_daily_cap();
  v_rule  public.search_card_rules;
  v_next  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select count(*) into v_count from public.search_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  v_rule := public._search_rule_for(v_count + 1);
  v_next := public._search_next_available(v_uid);

  return jsonb_build_object(
    'ok', true,
    'daily_cap', v_cap,
    'used_today', v_count,
    'remaining_today', case when v_cap > 0 then greatest(v_cap - v_count, 0) else null end,
    'min_reward', coalesce(v_rule.min_reward, 0),
    'max_reward', coalesce(v_rule.max_reward, 0),
    'ad_required', public._ad_gated('search'),
    'next_available_at', v_next,
    'has_rule', v_rule.id is not null,
    'available', (v_rule.id is not null)
                 and (v_cap = 0 or v_count < v_cap)
                 and (v_next is null or now() >= v_next));
end;
$$;
grant execute on function public.search_card_status() to authenticated;

-- Grant the reward for a completed search. Server-authoritative: enforces the
-- daily cap, cooldown, wait-after-rule and (when gated) a completed rewarded ad.
create or replace function public.search_card_reward(p_nonce uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_count  int;
  v_cap    int := public._search_daily_cap();
  v_next   timestamptz;
  v_rule   public.search_card_rules;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select count(*) into v_count from public.search_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_cap > 0 and v_count >= v_cap then raise exception 'SEARCH_DAILY_LIMIT'; end if;

  v_next := public._search_next_available(v_uid);
  if v_next is not null and now() < v_next then raise exception 'SEARCH_TOO_SOON'; end if;

  -- Ad requirement is authoritative on the server: gated → require + consume a
  -- completed nonce; ungated (section/master OFF) → no ad required.
  if public._ad_gated('search') then
    perform public._consume_ad(v_uid, 'search', p_nonce);
  elsif p_nonce is not null then
    perform public._consume_ad(v_uid, 'search', p_nonce);
  end if;

  v_rule := public._search_rule_for(v_count + 1);
  if v_rule.id is null then raise exception 'NO_SEARCH_RULE'; end if;
  v_amount := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;

  insert into public.search_rewards(user_id, reward_amount) values (v_uid, v_amount);
  if p_nonce is not null then
    update public.ad_events set reward = v_amount, updated_at = now() where id = p_nonce;
  end if;

  v_new := public._apply_ledger(v_uid, v_amount, 'search_card', null, 'Search Card reward');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', case when v_cap > 0 then greatest(v_cap - v_count - 1, 0) else null end);
end;
$$;
grant execute on function public.search_card_reward(uuid) to authenticated;

-- Read the active rules for the user screen (range display).
create or replace function public.search_card_config()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  return jsonb_build_object(
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'from_search', from_search, 'to_search', to_search,
        'min', min_reward, 'max', max_reward,
        'cooldown_seconds', cooldown_seconds, 'wait_after_seconds', wait_after_seconds)
        order by from_search)
      from public.search_card_rules where active), '[]'::jsonb));
end;
$$;
grant execute on function public.search_card_config() to authenticated;

-- Admin: list / save / delete with validation (mirrors watch-ad rules).
create or replace function public.admin_search_rules()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'from_search', from_search, 'to_search', to_search,
      'min_reward', min_reward, 'max_reward', max_reward,
      'cooldown_seconds', cooldown_seconds, 'wait_after_seconds', wait_after_seconds,
      'daily_limit', daily_limit, 'active', active, 'position', position)
      order by from_search)
    from public.search_card_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_search_rules() to authenticated;

create or replace function public.admin_save_search_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_cooldown int, p_wait_after int, p_daily_limit int, p_active boolean)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_cooldown,0) < 0 or coalesce(p_wait_after,0) < 0 or coalesce(p_daily_limit,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  if coalesce(p_active, true) and exists (
    select 1 from public.search_card_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_search, to_search, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.search_card_rules(from_search, to_search, min_reward, max_reward,
        cooldown_seconds, wait_after_seconds, daily_limit, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_cooldown,30),
        coalesce(p_wait_after,0), coalesce(p_daily_limit,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.search_card_rules
       set from_search=p_from, to_search=p_to, min_reward=p_min, max_reward=p_max,
           cooldown_seconds=coalesce(p_cooldown,30), wait_after_seconds=coalesce(p_wait_after,0),
           daily_limit=coalesce(p_daily_limit,0), active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'search_rule.save', 'search_card_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_search_rule(uuid, int, int, bigint, bigint, int, int, int, boolean) to authenticated;

create or replace function public.admin_delete_search_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.search_card_rules where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'search_rule.delete', 'search_card_rule', p_id::text);
end;
$$;
grant execute on function public.admin_delete_search_rule(uuid) to authenticated;

-- Include 'search' in ads_config so the client's rewardedFor('search') /
-- bannerFor('search') reflect the admin section toggles + masters.
create or replace function public.ads_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sys  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true);
  v_rew  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true);
  v_ban  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_ads_enabled'), true);
  v_sections text[] := array['daily','scratch','mining','watch_ads','quiz','tasks','contest','search'];
  v_out jsonb := '{}'::jsonb;
  s text;
begin
  foreach s in array v_sections loop
    v_out := v_out || jsonb_build_object(s, jsonb_build_object(
      'rewarded', v_sys and v_rew and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_'||s), true),
      'banner',   v_sys and v_ban and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_'||s), true)
    ));
  end loop;
  return jsonb_build_object('system', v_sys, 'rewarded_global', v_rew,
                            'banner_global', v_ban, 'sections', v_out);
end;
$$;
grant execute on function public.ads_config() to authenticated;


-- >>> supabase/migrations/0026_mining_boost_duration.sql
-- ============================================================================
-- 0026  Mining Boost becomes TIME-LIMITED and server-authoritative, so the
-- client can show a real "Boost Active" state (ring colour, countdown, boosted
-- rate) that only appears after a verified activation and disappears on expiry.
-- Forward-only, non-destructive.
--
-- Model: a boost sets rate_per_hour to the boosted rate and boost_ends_at to
-- now()+duration (capped at the session end). Accrual is piecewise — boosted
-- rate up to boost_ends_at, base rate after — so expiry is handled by the
-- server regardless of app state or device clock. Re-boosting checkpoints the
-- accrued amount and refreshes the window.
-- ============================================================================

alter table public.mining_sessions add column if not exists boost_ends_at timestamptz;

insert into public.app_settings(key, value, description) values
  ('mining_boost_duration_minutes', '60', 'How long a mining boost stays active (minutes)')
on conflict (key) do nothing;

-- Piecewise accrual: boosted rate during [last_settled_at, boost_ends_at),
-- base rate afterwards. Everything is derived from server timestamps.
create or replace function public._mining_accrued(s public.mining_sessions)
returns bigint
language sql
stable
as $$
  select s.accrued + case
    when least(now(), s.ends_at) <= s.last_settled_at then 0
    when s.boost_ends_at is not null and s.boost_ends_at > s.last_settled_at then
      floor(
        greatest(extract(epoch from (least(least(now(), s.ends_at), s.boost_ends_at) - s.last_settled_at)), 0) / 3600.0 * s.rate_per_hour
        + greatest(extract(epoch from (least(now(), s.ends_at) - least(least(now(), s.ends_at), s.boost_ends_at))), 0) / 3600.0 * coalesce(s.base_rate, s.rate_per_hour)
      )::bigint
    else
      floor(greatest(extract(epoch from (least(now(), s.ends_at) - s.last_settled_at)), 0) / 3600.0 * coalesce(s.base_rate, s.rate_per_hour))::bigint
  end;
$$;

-- Boost the active session for the configured duration (gated: 'mining').
create or replace function public.boost_mining(p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  s       public.mining_sessions;
  v_max   int := public.setting_num('mining_max_boosts', 3)::int;
  v_cool  numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_pct   numeric := public.setting_num('mining_boost_pct', 20);
  v_dur   numeric := public.setting_num('mining_boost_duration_minutes', 60);
  v_comp  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_compounding'), false);
  v_needs_ad boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true);
  v_acc   bigint;
  v_base  bigint;
  v_new_rate bigint;
  v_boost_ends timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active'
    order by started_at desc limit 1 for update;
  if not found then raise exception 'NO_ACTIVE_MINING'; end if;
  if now() >= s.ends_at then raise exception 'SESSION_ENDED'; end if;
  if s.boosts >= v_max then raise exception 'MAX_BOOSTS'; end if;
  if s.last_boost_at is not null and now() - s.last_boost_at < (v_cool || ' hours')::interval then
    raise exception 'BOOST_COOLDOWN';
  end if;

  -- Ad requirement (verified, single-use). Only after this succeeds is the
  -- boost actually applied — so the client only shows Boost Active on success.
  if v_needs_ad then
    perform public._consume_ad(v_uid, 'mining', p_nonce);
  elsif p_nonce is not null then
    perform public._consume_ad(v_uid, 'mining', p_nonce);
  end if;

  -- Checkpoint accrual at the pre-boost rate/window before changing the rate.
  v_acc := public._mining_accrued(s);
  v_base := coalesce(s.base_rate, s.rate_per_hour);

  if v_comp then
    v_new_rate := floor(v_base * power(1 + v_pct/100.0, s.boosts + 1))::bigint;
  else
    v_new_rate := v_base + floor(v_base * v_pct/100.0)::bigint * (s.boosts + 1);
  end if;

  v_boost_ends := least(now() + (v_dur || ' minutes')::interval, s.ends_at);

  update public.mining_sessions
     set accrued = v_acc,
         last_settled_at = now(),
         rate_per_hour = v_new_rate,
         boost_ends_at = v_boost_ends,
         boosts = s.boosts + 1,
         last_boost_at = now()
   where id = s.id;

  return jsonb_build_object('ok', true, 'boosts', s.boosts + 1,
                            'rate_per_hour', v_new_rate, 'boost_ends_at', v_boost_ends);
end;
$$;
grant execute on function public.boost_mining(uuid) to authenticated;

-- mining_status: adds boost_active / boost_ends_at and reports the CURRENT
-- effective rate (base once the boost has expired). Preserves the claim fields.
create or replace function public.mining_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s     public.mining_sessions;
  v_acc bigint;
  v_max int := public.setting_num('mining_max_boosts', 3)::int;
  v_cool numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_pct  numeric := public.setting_num('mining_boost_pct', 20);
  v_maxclaims int := public.setting_num('mining_max_claims', 5)::int;
  v_next_boost_at timestamptz;
  v_can_boost boolean := false;
  v_boost_active boolean := false;
  v_cur_rate bigint;
  v_base bigint;
  v_start_ad boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_start_requires_ad'), false);
  v_claim_ad boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_claim_requires_ad'), false);
  v_enabled boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_enabled'), true);
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active' order by started_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'active', false, 'enabled', v_enabled,
      'rate_per_hour', public.setting_num('mining_rate_per_hour', 20),
      'session_hours', public.setting_num('mining_session_hours', 24),
      'max_boosts', v_max, 'boost_pct', v_pct, 'max_claims', v_maxclaims,
      'start_requires_ad', v_start_ad, 'claim_requires_ad', v_claim_ad,
      'boost_active', false,
      'boost_requires_ad', coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true));
  end if;
  v_acc := public._mining_accrued(s);
  v_base := coalesce(s.base_rate, s.rate_per_hour);
  v_boost_active := s.boost_ends_at is not null and now() < s.boost_ends_at and now() < s.ends_at;
  v_cur_rate := case when v_boost_active then s.rate_per_hour else v_base end;

  if s.last_boost_at is not null then
    v_next_boost_at := s.last_boost_at + (v_cool || ' hours')::interval;
  end if;
  v_can_boost := (s.boosts < v_max) and (now() < s.ends_at)
                 and (v_next_boost_at is null or now() >= v_next_boost_at);
  return jsonb_build_object(
    'ok', true, 'active', true, 'enabled', v_enabled, 'session_id', s.id,
    'started_at', s.started_at, 'ends_at', s.ends_at,
    'rate_per_hour', v_cur_rate, 'base_rate', v_base,
    'accrued', v_acc, 'claimable', greatest(v_acc - s.claimed, 0),
    'completed', now() >= s.ends_at,
    'boosts', s.boosts, 'max_boosts', v_max, 'boost_pct', v_pct,
    'can_boost', v_can_boost, 'next_boost_at', v_next_boost_at,
    'boost_active', v_boost_active, 'boost_ends_at', s.boost_ends_at,
    'claim_count', s.claim_count, 'max_claims', v_maxclaims,
    'claims_remaining', greatest(v_maxclaims - s.claim_count, 0),
    'start_requires_ad', v_start_ad, 'claim_requires_ad', v_claim_ad,
    'boost_requires_ad', coalesce((select (value #>> '{}')::boolean from public.app_settings where key='mining_boost_requires_ad'), true)
  );
end;
$$;
grant execute on function public.mining_status() to authenticated;

-- ---------------------------------------------------------------------------
-- Referral hardening (defensive): the signup trigger already sets referred_by
-- from the code, and self-referral by own code is impossible at signup (the
-- new user has no code yet). This guard makes self-linkage structurally
-- impossible even if a future flow reuses the resolver. (Verification only —
-- the abuse scorer + review queue from 0010 remain the enforcement path.)
-- ---------------------------------------------------------------------------
-- (No-op safeguard documented here; enforcement stays in _credit_referral_level
--  and _referral_abuse_score.)

-- >>> supabase/migrations/0027_daily_cycle_and_quiz_delete.sql
-- ============================================================================
-- 0027  Server-authoritative DAILY CYCLE completion for Scratch, Search and
--       Watch-Ads, plus Scratch daily-reset + range output, Scratch fixed to
--       exactly ONE rewarded ad, and the missing admin_delete_quiz RPC.
--       Forward-only, non-destructive (preserves existing production data).
--
-- Daily cycle model (§4/§7/§8): each feature progresses through its admin rule
-- bands (e.g. 1–5 then 6–10). When the user completes the last band for the
-- day, the feature is "cycle complete" and returns next_cycle_at = the start of
-- the next UTC day. The client shows "come back tomorrow" + a countdown to that
-- absolute server timestamp, so it stays correct across app close/reopen,
-- logout/login, reinstall and device-clock changes (the value is derived from
-- the server clock, never the device). At UTC midnight the counters (scoped by
-- reward_date / scratched_at::date) reset and Rule 1 becomes available again.
-- ============================================================================

-- Start of the next UTC day, as an absolute timestamptz. Single source of the
-- "come back tomorrow" target used by all three features.
create or replace function public._next_daily_cycle_at()
returns timestamptz
language sql
stable
as $$
  select (((now() at time zone 'utc')::date + 1)::timestamp) at time zone 'utc';
$$;

-- ---------------------------------------------------------------------------
-- SCRATCH — daily cap now derives from the top band (like Watch-Ads/Search),
-- so with rules 1–5 & 6–10 the day's cap is 10 even when no explicit
-- daily_limit is set. An explicit per-rule daily_limit still wins.
-- ---------------------------------------------------------------------------
create or replace function public._scratch_daily_cap()
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select max(daily_limit) from public.scratch_rules where active and daily_limit > 0),
    (select max(to_card)     from public.scratch_rules where active),
    0);
$$;

-- Scratch status: DAILY rule progression (counts reset at UTC midnight), the
-- applicable rule's reward RANGE (for "Win X–Y BCP"), the cooldown / wait-after
-- countdown, and the cycle-complete "come back tomorrow" state.
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_card   public.scratch_cards;
  v_last   public.scratch_cards;
  v_seq    int;
  v_rule   public.scratch_rules;
  v_prev   public.scratch_rules;
  v_next   timestamptz;
  v_reward bigint;
  v_cap    int := public._scratch_daily_cap();
  v_used   int := 0;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Already holding an un-scratched card? Return it with its captured rule so
  -- the user finishes the outstanding card first (range comes from its band).
  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    v_rule := public._scratch_rule_for(v_card.seq);
    return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
      'card_id', v_card.id, 'seq', v_card.seq,
      'ads_required', v_card.ads_required,
      'search_delay_seconds', v_card.search_delay_seconds,
      'cooldown_seconds', v_card.cooldown_seconds,
      'min_reward', coalesce(v_rule.min_reward, 0),
      'max_reward', coalesce(v_rule.max_reward, 0));
  end if;

  -- Cards scratched TODAY (UTC) — the day's progression index.
  select count(*) into v_used from public.scratch_cards
    where user_id = v_uid and status = 'scratched'
      and (scratched_at at time zone 'utc')::date = v_today;
  v_used := coalesce(v_used, 0);

  -- Daily cycle complete → "come back tomorrow" with a countdown to UTC midnight.
  if v_cap > 0 and v_used >= v_cap then
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
      'cycle_complete', true, 'next_cycle_at', public._next_daily_cycle_at(),
      'used_today', v_used, 'remaining_today', 0);
  end if;

  v_seq  := v_used + 1;
  v_rule := public._scratch_rule_for(v_seq);
  if v_rule.id is null then
    -- No rules configured → nothing to offer (never breaks the screen).
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false);
  end if;

  -- Timing gate from TODAY's last scratched card only, so a cooldown from the
  -- previous day never blocks the new day's first card.
  select * into v_last from public.scratch_cards
    where user_id = v_uid and status = 'scratched' and scratched_at is not null
      and (scratched_at at time zone 'utc')::date = v_today
    order by scratched_at desc limit 1;
  if found then
    v_prev := public._scratch_rule_for(v_last.seq);
    if v_prev.id is not null and v_rule.id <> v_prev.id and v_seq = v_rule.from_card then
      v_next := v_last.scratched_at + (greatest(v_rule.wait_after_seconds,0) || ' seconds')::interval;
    else
      v_next := v_last.scratched_at + (greatest(v_last.cooldown_seconds,0) || ' seconds')::interval;
    end if;
    if now() < v_next then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'next_available_at', v_next,
        'min_reward', v_rule.min_reward, 'max_reward', v_rule.max_reward);
    end if;
  end if;

  -- Eligible now → issue the next card. Reward is decided server-side and kept
  -- hidden (not returned) until scratch_reveal, so the client never learns it.
  v_reward := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;
  insert into public.scratch_cards(user_id, reward_amount, source, seq,
      ads_required, search_delay_seconds, cooldown_seconds)
  values (v_uid, v_reward, 'rule', v_seq,
      greatest(v_rule.ads_required,0), greatest(v_rule.search_delay_seconds,0),
      greatest(v_rule.cooldown_seconds,0))
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
    'card_id', v_card.id, 'seq', v_card.seq,
    'ads_required', v_card.ads_required,
    'search_delay_seconds', v_card.search_delay_seconds,
    'cooldown_seconds', v_card.cooldown_seconds,
    'min_reward', v_rule.min_reward, 'max_reward', v_rule.max_reward,
    'remaining_today', case when v_cap > 0 then greatest(v_cap - v_used, 0) else null end);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- ---------------------------------------------------------------------------
-- SCRATCH admin: exactly ONE rewarded ad per card (business rule, not admin
-- configurable) and no artificial search-delay. The p_ads / p_search_delay
-- parameters are kept for signature stability but IGNORED and forced server-
-- side to 1 / 0, so the admin can never change the ad count.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_scratch_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_ads int, p_search_delay int, p_cooldown int, p_active boolean,
  p_wait_after int default 0, p_daily_limit int default 0)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_cooldown,0) < 0 or coalesce(p_wait_after,0) < 0 or coalesce(p_daily_limit,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  if coalesce(p_active, true) and exists (
    select 1 from public.scratch_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_card, to_card, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.scratch_rules(from_card, to_card, min_reward, max_reward,
        ads_required, search_delay_seconds, cooldown_seconds, wait_after_seconds,
        daily_limit, active, position)
    values (p_from, p_to, p_min, p_max, 1, 0, coalesce(p_cooldown,3600),
        coalesce(p_wait_after,0), coalesce(p_daily_limit,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.scratch_rules
       set from_card=p_from, to_card=p_to, min_reward=p_min, max_reward=p_max,
           ads_required=1, search_delay_seconds=0,
           cooldown_seconds=coalesce(p_cooldown,3600), wait_after_seconds=coalesce(p_wait_after,0),
           daily_limit=coalesce(p_daily_limit,0), active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'scratch_rule.save', 'scratch_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_scratch_rule(uuid, int, int, bigint, bigint, int, int, int, boolean, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- WATCH ADS — add the cycle-complete "come back tomorrow" state. When every
-- rule band for the day is used (used_today >= daily cap) the feature returns
-- cycle_complete + next_cycle_at instead of staying "available".
-- ---------------------------------------------------------------------------
create or replace function public.watch_ads_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_today     date := (now() at time zone 'utc')::date;
  v_count     int;
  v_cap       int := public._watch_ad_daily_cap();
  v_has_rules boolean := exists (select 1 from public.watch_ad_rules where active);
  v_next_rule public.watch_ad_rules;
  v_next      timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select count(*) into v_count from public.ad_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);

  -- All rule bands exhausted for today → come back tomorrow.
  if v_has_rules and v_count >= v_cap then
    return jsonb_build_object('ok', true, 'daily_cap', v_cap, 'used_today', v_count,
      'remaining_today', 0, 'available', false,
      'cycle_complete', true, 'next_cycle_at', public._next_daily_cycle_at());
  end if;

  v_next_rule := public._watch_ad_rule_for(v_count + 1);
  v_next := public._watch_next_available(v_uid);

  return jsonb_build_object(
    'ok', true,
    'daily_cap', v_cap,
    'used_today', v_count,
    'remaining_today', greatest(v_cap - v_count, 0),
    'min_reward', coalesce(v_next_rule.min_reward, public.setting_num('ads_reward', 15)::bigint),
    'max_reward', coalesce(v_next_rule.max_reward, public.setting_num('ads_reward', 15)::bigint),
    'next_available_at', v_next,
    'available', (v_count < v_cap) and (v_next is null or now() >= v_next));
end;
$$;
grant execute on function public.watch_ads_status() to authenticated;

-- ---------------------------------------------------------------------------
-- SEARCH — same cycle-complete state when the daily cap is reached.
-- ---------------------------------------------------------------------------
create or replace function public.search_card_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_cap   int := public._search_daily_cap();
  v_rule  public.search_card_rules;
  v_next  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select count(*) into v_count from public.search_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);

  -- Daily cap reached → come back tomorrow (only meaningful when a cap exists).
  if v_cap > 0 and v_count >= v_cap then
    return jsonb_build_object('ok', true, 'daily_cap', v_cap, 'used_today', v_count,
      'remaining_today', 0, 'has_rule', true,
      'ad_required', public._ad_gated('search'), 'available', false,
      'cycle_complete', true, 'next_cycle_at', public._next_daily_cycle_at());
  end if;

  v_rule := public._search_rule_for(v_count + 1);
  v_next := public._search_next_available(v_uid);

  return jsonb_build_object(
    'ok', true,
    'daily_cap', v_cap,
    'used_today', v_count,
    'remaining_today', case when v_cap > 0 then greatest(v_cap - v_count, 0) else null end,
    'min_reward', coalesce(v_rule.min_reward, 0),
    'max_reward', coalesce(v_rule.max_reward, 0),
    'ad_required', public._ad_gated('search'),
    'next_available_at', v_next,
    'has_rule', v_rule.id is not null,
    'available', (v_rule.id is not null)
                 and (v_cap = 0 or v_count < v_cap)
                 and (v_next is null or now() >= v_next));
end;
$$;
grant execute on function public.search_card_status() to authenticated;

-- ---------------------------------------------------------------------------
-- QUIZ — the missing hard delete. Removing a quiz cascades to quiz_questions
-- and quiz_attempts via existing ON DELETE CASCADE foreign keys, so the quiz
-- disappears from the admin panel AND becomes unavailable to users in one
-- integrity-preserving operation. Admin role is re-checked server-side.
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_quiz(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.quizzes where id = p_id;  -- cascades questions + attempts
  if not found then raise exception 'QUIZ_NOT_FOUND'; end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.delete', 'quiz', p_id::text);
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_delete_quiz(uuid) to authenticated;

-- >>> supabase/migrations/0028_scratch_reveal_then_ad.sql
-- ============================================================================
-- 0028  Scratch Card: reveal-the-amount FIRST, then the rewarded ad, then credit.
--
-- New flow (server-authoritative, duplicate-safe):
--   1. scratch_status issues a card; the reward is chosen ON THE SERVER at
--      issue time (random within the rule's Min/Max) and stored hidden.
--   2. scratch_reveal(card_id) — NO ad — exposes that exact amount and marks the
--      card 'revealed' (revealed_at). It does NOT credit anything.
--   3. scratch_claim(card_id, nonce) — verifies the required rewarded ad (unless
--      the Reward-ads master/section is OFF) and ONLY THEN credits the exact
--      revealed amount to the immutable ledger, marking the card 'scratched'.
--
-- Duplicate protection: the 'available' → 'scratched' transition happens under a
-- row lock (FOR UPDATE); a second claim sees 'scratched' and returns idempotently
-- without crediting again. The client never decides the reward.
--
-- A revealed-but-unclaimed card stays status='available' (with revealed_at set),
-- so it is still the user's single outstanding card and cannot be skipped by
-- reloading to get a new card. Forward-only, non-destructive.
-- ============================================================================

alter table public.scratch_cards add column if not exists revealed_at timestamptz;

-- ---------------------------------------------------------------------------
-- scratch_status: returns the outstanding card (available OR already-revealed),
-- the rule's reward RANGE, whether an ad is required, and — only once revealed —
-- the exact amount so the screen can resume the claim step after a reload.
-- ---------------------------------------------------------------------------
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_card   public.scratch_cards;
  v_last   public.scratch_cards;
  v_seq    int;
  v_rule   public.scratch_rules;
  v_prev   public.scratch_rules;
  v_next   timestamptz;
  v_reward bigint;
  v_cap    int := public._scratch_daily_cap();
  v_used   int := 0;
  v_gated  boolean := public._ad_gated('scratch');
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Outstanding card (not yet credited). 'available' covers both un-revealed and
  -- revealed-but-unclaimed (revealed_at set) — the user must finish this one.
  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    v_rule := public._scratch_rule_for(v_card.seq);
    return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
      'card_id', v_card.id, 'seq', v_card.seq,
      'ads_required', v_card.ads_required,
      'ad_required', v_gated,
      'cooldown_seconds', v_card.cooldown_seconds,
      'min_reward', coalesce(v_rule.min_reward, 0),
      'max_reward', coalesce(v_rule.max_reward, 0),
      'revealed', v_card.revealed_at is not null,
      -- The exact amount is exposed only AFTER a reveal, never before.
      'amount', case when v_card.revealed_at is not null then v_card.reward_amount else null end);
  end if;

  -- Cards credited TODAY (UTC) — the day's progression index.
  select count(*) into v_used from public.scratch_cards
    where user_id = v_uid and status = 'scratched'
      and (scratched_at at time zone 'utc')::date = v_today;
  v_used := coalesce(v_used, 0);

  -- Daily cycle complete → come back tomorrow.
  if v_cap > 0 and v_used >= v_cap then
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
      'cycle_complete', true, 'next_cycle_at', public._next_daily_cycle_at(),
      'used_today', v_used, 'remaining_today', 0);
  end if;

  v_seq  := v_used + 1;
  v_rule := public._scratch_rule_for(v_seq);
  if v_rule.id is null then
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false);
  end if;

  -- Timing gate from TODAY's last credited card only.
  select * into v_last from public.scratch_cards
    where user_id = v_uid and status = 'scratched' and scratched_at is not null
      and (scratched_at at time zone 'utc')::date = v_today
    order by scratched_at desc limit 1;
  if found then
    v_prev := public._scratch_rule_for(v_last.seq);
    if v_prev.id is not null and v_rule.id <> v_prev.id and v_seq = v_rule.from_card then
      v_next := v_last.scratched_at + (greatest(v_rule.wait_after_seconds,0) || ' seconds')::interval;
    else
      v_next := v_last.scratched_at + (greatest(v_last.cooldown_seconds,0) || ' seconds')::interval;
    end if;
    if now() < v_next then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'next_available_at', v_next,
        'min_reward', v_rule.min_reward, 'max_reward', v_rule.max_reward);
    end if;
  end if;

  -- Issue the next card. Reward is decided server-side now and kept HIDDEN
  -- (not returned) until scratch_reveal.
  v_reward := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;
  insert into public.scratch_cards(user_id, reward_amount, source, seq,
      ads_required, search_delay_seconds, cooldown_seconds)
  values (v_uid, v_reward, 'rule', v_seq,
      greatest(v_rule.ads_required,0), 0, greatest(v_rule.cooldown_seconds,0))
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
    'card_id', v_card.id, 'seq', v_card.seq,
    'ads_required', v_card.ads_required,
    'ad_required', v_gated,
    'cooldown_seconds', v_card.cooldown_seconds,
    'min_reward', v_rule.min_reward, 'max_reward', v_rule.max_reward,
    'revealed', false, 'amount', null,
    'remaining_today', case when v_cap > 0 then greatest(v_cap - v_used, 0) else null end);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- ---------------------------------------------------------------------------
-- scratch_reveal(card_id): expose the exact server-decided amount and mark the
-- card revealed. NO ad, NO credit. Idempotent.
-- (Replaces the previous scratch_reveal(uuid, uuid[]) which credited on reveal.)
-- ---------------------------------------------------------------------------
drop function if exists public.scratch_reveal(uuid, uuid[]);
create or replace function public.scratch_reveal(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;

  -- Already credited → return the amount idempotently (no state change).
  if v_card.status = 'scratched' then
    return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
      'credited', true, 'ad_required', public._ad_gated('scratch'));
  end if;

  -- Mark revealed once; keep the same revealed_at on repeat calls.
  if v_card.revealed_at is null then
    update public.scratch_cards set revealed_at = now() where id = v_card.id;
  end if;

  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
    'revealed', true, 'credited', false,
    'ad_required', public._ad_gated('scratch'));
end;
$$;
grant execute on function public.scratch_reveal(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- scratch_claim(card_id, nonce): verify the rewarded ad (when gated) and credit
-- the exact revealed amount. Duplicate-safe. When the Reward-ads master/section
-- is OFF, no ad is required and the reward is credited directly.
-- ---------------------------------------------------------------------------
create or replace function public.scratch_claim(p_card_id uuid, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
  v_bal  bigint;
  v_new  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;

  -- Already credited → idempotent success, never a second credit.
  if v_card.status = 'scratched' then
    select balance into v_bal from public.wallets where user_id = v_uid;
    return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
      'balance', coalesce(v_bal, 0), 'already', true);
  end if;

  -- Must be revealed first (the user has seen the amount).
  if v_card.revealed_at is null then raise exception 'NOT_REVEALED'; end if;

  -- Ad requirement is authoritative on the server: gated → require + consume a
  -- completed rewarded nonce; ungated (master/section OFF) → no ad required.
  if public._ad_gated('scratch') then
    if p_nonce is null then raise exception 'AD_REQUIRED'; end if;
    perform public._consume_ad(v_uid, 'scratch', p_nonce);
  elsif p_nonce is not null then
    perform public._consume_ad(v_uid, 'scratch', p_nonce);
  end if;

  -- Commit the credit and close the card (the lock above prevents double credit).
  update public.scratch_cards set status = 'scratched', scratched_at = now()
   where id = v_card.id;
  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id,
                                'Scratch card reward');

  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
    'balance', v_new, 'already', false);
end;
$$;
grant execute on function public.scratch_claim(uuid, uuid) to authenticated;

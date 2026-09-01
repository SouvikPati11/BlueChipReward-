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

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

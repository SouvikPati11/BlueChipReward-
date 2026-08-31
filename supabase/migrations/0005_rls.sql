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

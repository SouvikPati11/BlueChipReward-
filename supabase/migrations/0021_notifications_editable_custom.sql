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

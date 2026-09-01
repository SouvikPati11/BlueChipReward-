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

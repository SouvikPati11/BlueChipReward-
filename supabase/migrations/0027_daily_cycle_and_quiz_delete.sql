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

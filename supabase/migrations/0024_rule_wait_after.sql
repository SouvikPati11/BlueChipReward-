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

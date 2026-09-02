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

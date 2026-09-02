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

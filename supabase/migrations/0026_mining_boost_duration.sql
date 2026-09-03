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

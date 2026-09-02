-- ============================================================================
-- 0023  Admin-configurable Scratch Card rules + Watch Ads rules (server-side),
--       plus mining-claim rewarded-ad default. Forward-only, non-destructive.
--
-- Everything reward/cooldown/limit-related is decided and enforced on the
-- server. The client can never set a reward, skip a cooldown, bypass the ad
-- requirement, or exceed a limit. Cooldowns are derived from authoritative
-- timestamps, so they survive app close/reopen, logout/login and refresh.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- SCRATCH RULES  (a band of the user's scratch sequence number → reward range,
-- ads required, search-card delay, and next-scratch cooldown).
-- ---------------------------------------------------------------------------
create table if not exists public.scratch_rules (
  id                   uuid primary key default gen_random_uuid(),
  from_card            int  not null,                 -- inclusive sequence lower bound
  to_card              int  not null,                 -- inclusive sequence upper bound
  min_reward           bigint not null,
  max_reward           bigint not null,
  ads_required         int  not null default 1,
  search_delay_seconds int  not null default 10,      -- delay after ad → Search Card
  cooldown_seconds     int  not null default 3600,    -- cooldown before next scratch
  active               boolean not null default true,
  position             int  not null default 0,
  created_at           timestamptz not null default now()
);
create index if not exists idx_scratch_rules_order on public.scratch_rules(from_card);
alter table public.scratch_rules enable row level security;
drop policy if exists scratch_rules_read on public.scratch_rules;
create policy scratch_rules_read on public.scratch_rules
  for select using (true);  -- ranges are public info; writes go through RPCs

-- Capture the applied rule on each issued card so cooldown/delay/ads are stable
-- for that card regardless of later admin edits.
alter table public.scratch_cards add column if not exists seq int;
alter table public.scratch_cards add column if not exists ads_required int not null default 1;
alter table public.scratch_cards add column if not exists search_delay_seconds int not null default 10;
alter table public.scratch_cards add column if not exists cooldown_seconds int not null default 3600;

-- Seed example rules (only if the admin has none yet). Non-overlapping bands.
insert into public.scratch_rules(from_card, to_card, min_reward, max_reward, ads_required, search_delay_seconds, cooldown_seconds, position)
select * from (values
  (1, 4,  20::bigint, 40::bigint, 1, 10, 3600, 0),
  (5, 10, 20::bigint, 30::bigint, 1, 20, 7200, 1)
) v
where not exists (select 1 from public.scratch_rules);

-- Pick the active rule whose band contains sequence number N (fallback: the
-- active rule with the highest band, so past the last band the last rule holds).
create or replace function public._scratch_rule_for(p_seq int)
returns public.scratch_rules
language plpgsql
stable
security definer
set search_path = public
as $$
declare r public.scratch_rules;
begin
  select * into r from public.scratch_rules
   where active and p_seq between from_card and to_card
   order by from_card limit 1;
  if found then return r; end if;
  select * into r from public.scratch_rules
   where active order by to_card desc limit 1;
  return r; -- may be null if no rules configured
end;
$$;

-- Scratch status: cooldown-aware, rule-driven. Returns the user's current
-- state so the screen can show a live countdown and the reward range.
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_card   public.scratch_cards;
  v_last   public.scratch_cards;
  v_seq    int;
  v_rule   public.scratch_rules;
  v_next   timestamptz;
  v_reward bigint;
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

  -- Cooldown gate: next-available = last scratched card time + its cooldown.
  select * into v_last from public.scratch_cards
    where user_id = v_uid and status = 'scratched' and scratched_at is not null
    order by scratched_at desc limit 1;
  if found then
    v_next := v_last.scratched_at + (v_last.cooldown_seconds || ' seconds')::interval;
    if now() < v_next then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'next_available_at', v_next);
    end if;
  end if;

  -- Eligible now → issue the next card, capturing the applicable rule.
  v_seq  := coalesce((select count(*) from public.scratch_cards
                       where user_id = v_uid and status = 'scratched'), 0) + 1;
  v_rule := public._scratch_rule_for(v_seq);
  if v_rule.id is null then
    -- No rules configured → nothing to offer (never breaks the screen).
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false);
  end if;
  v_reward := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;

  insert into public.scratch_cards(user_id, reward_amount, source, seq,
      ads_required, search_delay_seconds, cooldown_seconds)
  values (v_uid, v_reward, 'rule', v_seq,
      greatest(v_rule.ads_required, 0), greatest(v_rule.search_delay_seconds, 0),
      greatest(v_rule.cooldown_seconds, 0))
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
    'card_id', v_card.id, 'seq', v_card.seq,
    'ads_required', v_card.ads_required,
    'search_delay_seconds', v_card.search_delay_seconds,
    'cooldown_seconds', v_card.cooldown_seconds);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- Reveal with N rewarded ads (ads_required) + server-enforced search delay.
-- p_nonces: the completed 'scratch' ad_event ids the user watched.
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

  v_need := greatest(v_card.ads_required, 0);

  -- Validate + consume each required rewarded ad (idempotent, replay-proof).
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
      -- consume (this also enforces the global daily rewarded cap)
      perform public._consume_ad(v_uid, 'scratch', n);
      v_have := v_have + 1;
    end loop;

    -- Server-enforced Search-Card delay: reveal only after the delay elapses
    -- from the last completed ad. The client shows the same countdown.
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

-- scratch_config: the configured rules (for the user screen's range display).
create or replace function public.scratch_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'from_card', from_card, 'to_card', to_card,
        'min', min_reward, 'max', max_reward,
        'ads_required', ads_required,
        'search_delay_seconds', search_delay_seconds,
        'cooldown_seconds', cooldown_seconds)
        order by from_card)
      from public.scratch_rules where active), '[]'::jsonb));
end;
$$;
grant execute on function public.scratch_config() to authenticated;

-- Admin: list / save / delete scratch rules with validation.
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
      'cooldown_seconds', cooldown_seconds, 'active', active, 'position', position)
      order by from_card)
    from public.scratch_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_scratch_rules() to authenticated;

create or replace function public.admin_save_scratch_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_ads int, p_search_delay int, p_cooldown int, p_active boolean)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  -- Validation (server-authoritative; the admin UI mirrors these).
  if p_from is null or p_to is null or p_from < 1 or p_to < p_from then
    raise exception 'INVALID_RANGE';
  end if;
  if p_min is null or p_max is null or p_min < 0 or p_max < p_min then
    raise exception 'INVALID_REWARD';
  end if;
  if coalesce(p_ads,0) < 0 or coalesce(p_search_delay,0) < 0 or coalesce(p_cooldown,0) < 0 then
    raise exception 'INVALID_NEGATIVE';
  end if;
  -- No overlap with other ACTIVE rules.
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
        ads_required, search_delay_seconds, cooldown_seconds, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_ads,1),
        coalesce(p_search_delay,10), coalesce(p_cooldown,3600),
        coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.scratch_rules
       set from_card=p_from, to_card=p_to, min_reward=p_min, max_reward=p_max,
           ads_required=coalesce(p_ads,1), search_delay_seconds=coalesce(p_search_delay,10),
           cooldown_seconds=coalesce(p_cooldown,3600), active=coalesce(p_active,true),
           position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'scratch_rule.save', 'scratch_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_scratch_rule(uuid, int, int, bigint, bigint, int, int, int, boolean) to authenticated;

create or replace function public.admin_delete_scratch_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.scratch_rules where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'scratch_rule.delete', 'scratch_rule', p_id::text);
end;
$$;
grant execute on function public.admin_delete_scratch_rule(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- WATCH ADS RULES  (a band of the day's ad number → reward range + cooldown).
-- ---------------------------------------------------------------------------
create table if not exists public.watch_ad_rules (
  id               uuid primary key default gen_random_uuid(),
  from_ad          int not null,               -- inclusive daily ad index lower bound
  to_ad            int not null,               -- inclusive daily ad index upper bound
  min_reward       bigint not null,
  max_reward       bigint not null,
  cooldown_seconds int not null default 30,
  daily_limit      int not null default 0,     -- optional explicit daily cap (0 = derive from bands)
  active           boolean not null default true,
  position         int not null default 0,
  created_at       timestamptz not null default now()
);
create index if not exists idx_watch_ad_rules_order on public.watch_ad_rules(from_ad);
alter table public.watch_ad_rules enable row level security;
drop policy if exists watch_ad_rules_read on public.watch_ad_rules;
create policy watch_ad_rules_read on public.watch_ad_rules
  for select using (true);

insert into public.watch_ad_rules(from_ad, to_ad, min_reward, max_reward, cooldown_seconds, position)
select * from (values
  (1,  5,  10::bigint, 30::bigint, 30,  0),
  (6,  10, 10::bigint, 25::bigint, 60,  1),
  (11, 20, 5::bigint,  20::bigint, 300, 2)
) v
where not exists (select 1 from public.watch_ad_rules);

create or replace function public._watch_ad_rule_for(p_n int)
returns public.watch_ad_rules
language plpgsql stable security definer set search_path = public
as $$
declare r public.watch_ad_rules;
begin
  select * into r from public.watch_ad_rules
   where active and p_n between from_ad and to_ad order by from_ad limit 1;
  if found then return r; end if;
  select * into r from public.watch_ad_rules
   where active order by to_ad desc limit 1;
  return r;
end;
$$;

-- Effective total daily ad cap: explicit daily_limit if any set, else max band.
create or replace function public._watch_ad_daily_cap()
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select max(daily_limit) from public.watch_ad_rules where active and daily_limit > 0),
    (select max(to_ad) from public.watch_ad_rules where active),
    public.setting_num('ads_daily_cap', 20)::int);
$$;

-- Watch-ads status for the user screen: current/next reward band, cooldown
-- countdown target, and remaining today. Server-authoritative.
create or replace function public.watch_ads_status()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_cap   int := public._watch_ad_daily_cap();
  v_last  timestamptz;
  v_next_rule public.watch_ad_rules;
  v_prev_rule public.watch_ad_rules;
  v_next  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select count(*), max(created_at) into v_count, v_last
    from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);

  v_next_rule := public._watch_ad_rule_for(v_count + 1); -- band of the next ad
  if v_last is not null and v_count > 0 then
    v_prev_rule := public._watch_ad_rule_for(v_count);   -- cooldown from last ad
    if v_prev_rule.id is not null then
      v_next := v_last + (v_prev_rule.cooldown_seconds || ' seconds')::interval;
    end if;
  end if;

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

-- Watch-ads credit: rule-based reward range + server-authoritative cooldown +
-- daily cap. Requires a completed rewarded nonce (existing replay protection).
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
  v_last   timestamptz;
  v_rule   public.watch_ad_rules;
  v_prev   public.watch_ad_rules;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select count(*), max(created_at) into v_count, v_last
    from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_count >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;

  -- Server-authoritative cooldown from the previous ad's band.
  if v_count > 0 and v_last is not null then
    v_prev := public._watch_ad_rule_for(v_count);
    if v_prev.id is not null and now() - v_last < (v_prev.cooldown_seconds || ' seconds')::interval then
      raise exception 'AD_TOO_SOON';
    end if;
  end if;

  -- Reward exists only because an ad was watched → a completed nonce is required.
  if p_nonce is null then raise exception 'AD_REQUIRED'; end if;
  perform public._consume_ad(v_uid, 'watch_ads', p_nonce);

  v_rule := public._watch_ad_rule_for(v_count + 1);
  if v_rule.id is not null then
    v_amount := (v_rule.min_reward
                 + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                      - v_rule.min_reward + 1)))::bigint;
  else
    v_amount := public.setting_num('ads_reward', 15)::bigint; -- fallback
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

-- Admin: list / save / delete watch-ad rules with validation.
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
      'cooldown_seconds', cooldown_seconds, 'daily_limit', daily_limit,
      'active', active, 'position', position)
      order by from_ad)
    from public.watch_ad_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_watch_ad_rules() to authenticated;

create or replace function public.admin_save_watch_ad_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_cooldown int, p_daily_limit int, p_active boolean)
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
  if coalesce(p_cooldown,0) < 0 or coalesce(p_daily_limit,0) < 0 then
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
        cooldown_seconds, daily_limit, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_cooldown,30),
        coalesce(p_daily_limit,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.watch_ad_rules
       set from_ad=p_from, to_ad=p_to, min_reward=p_min, max_reward=p_max,
           cooldown_seconds=coalesce(p_cooldown,30), daily_limit=coalesce(p_daily_limit,0),
           active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'watch_ad_rule.save', 'watch_ad_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_watch_ad_rule(uuid, int, int, bigint, bigint, int, int, boolean) to authenticated;

create or replace function public.admin_delete_watch_ad_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.watch_ad_rules where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'watch_ad_rule.delete', 'watch_ad_rule', p_id::text);
end;
$$;
grant execute on function public.admin_delete_watch_ad_rule(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Mining: claiming BCP requires a completed rewarded ad by default now.
-- (Admin can still toggle mining_claim_requires_ad in Config.)
-- ---------------------------------------------------------------------------
update public.app_settings set value = 'true' where key = 'mining_claim_requires_ad';

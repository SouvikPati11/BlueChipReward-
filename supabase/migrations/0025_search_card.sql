-- ============================================================================
-- 0025  Search Card — admin rule system + real, server-authoritative rewards.
-- Mirrors the Watch-Ads rule system (bands, cooldown, wait-after-previous-rule,
-- daily limit, ad gating). Forward-only, non-destructive.
--
-- Flow: the user performs a Search → gets a result → reward step. If Search is
-- ad-gated (section + masters ON) a completed rewarded ad is required and
-- verified server-side; otherwise the reward is granted directly. Searching
-- alone never credits BCP — only search_card_reward() credits, and it enforces
-- the applicable rule, cooldown, wait-after-rule, daily cap and ad requirement.
-- ============================================================================

-- Ledger type for search-card rewards (late-bound; safe to add + use in bodies).
alter type ledger_type add value if not exists 'search_card';

-- Section ad-gate + banner flags for the 'search' placement.
insert into public.app_settings(key, value, description) values
  ('ad_gate_search', 'true', 'Search Card · rewarded ad required'),
  ('banner_search',  'true', 'Search Card · banner')
on conflict (key) do nothing;

-- Per-user daily search counter (mirrors ad_rewards) — authoritative timestamps.
create table if not exists public.search_rewards (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  reward_amount bigint not null,
  reward_date   date not null default (now() at time zone 'utc')::date,
  created_at    timestamptz not null default now()
);
create index if not exists idx_search_rewards_user_date
  on public.search_rewards(user_id, reward_date);
alter table public.search_rewards enable row level security;
drop policy if exists search_rewards_self on public.search_rewards;
create policy search_rewards_self on public.search_rewards
  for select using (user_id = auth.uid() or public.is_admin());

-- Rule bands: a band of the day's search index → reward range + timing + limit.
create table if not exists public.search_card_rules (
  id                 uuid primary key default gen_random_uuid(),
  from_search        int not null,
  to_search          int not null,
  min_reward         bigint not null,
  max_reward         bigint not null,
  cooldown_seconds   int not null default 30,   -- gap between searches within a rule
  wait_after_seconds int not null default 0,    -- wait before the first search of a NEW rule
  daily_limit        int not null default 0,    -- explicit daily cap (0 = derive from bands)
  active             boolean not null default true,
  position           int not null default 0,
  created_at         timestamptz not null default now()
);
create index if not exists idx_search_rules_order on public.search_card_rules(from_search);
alter table public.search_card_rules enable row level security;
drop policy if exists search_rules_read on public.search_card_rules;
create policy search_rules_read on public.search_card_rules for select using (true);

insert into public.search_card_rules(from_search, to_search, min_reward, max_reward, cooldown_seconds, wait_after_seconds, daily_limit, position)
select * from (values
  (1,  5,  10::bigint, 30::bigint, 30,  0,    0, 0),
  (6,  10, 20::bigint, 40::bigint, 60,  3600, 0, 1)
) v
where not exists (select 1 from public.search_card_rules);

create or replace function public._search_rule_for(p_n int)
returns public.search_card_rules
language plpgsql stable security definer set search_path = public
as $$
declare r public.search_card_rules;
begin
  select * into r from public.search_card_rules
   where active and p_n between from_search and to_search order by from_search limit 1;
  if found then return r; end if;
  select * into r from public.search_card_rules
   where active order by to_search desc limit 1;
  return r;
end;
$$;

create or replace function public._search_daily_cap()
returns int
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select max(daily_limit) from public.search_card_rules where active and daily_limit > 0),
    (select max(to_search) from public.search_card_rules where active),
    0);
$$;

-- Next-available timestamp: within-rule cooldown OR rule-boundary wait.
create or replace function public._search_next_available(p_uid uuid)
returns timestamptz
language plpgsql stable security definer set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_count int;
  v_last  timestamptz;
  v_next_rule public.search_card_rules;
  v_prev_rule public.search_card_rules;
begin
  select count(*), max(created_at) into v_count, v_last
    from public.search_rewards where user_id = p_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_count = 0 or v_last is null then return null; end if;
  v_next_rule := public._search_rule_for(v_count + 1);
  v_prev_rule := public._search_rule_for(v_count);
  if v_next_rule.id is null then return null; end if;
  if v_prev_rule.id is not null and v_next_rule.id <> v_prev_rule.id
     and (v_count + 1) = v_next_rule.from_search then
    return v_last + (greatest(v_next_rule.wait_after_seconds,0) || ' seconds')::interval;
  else
    return v_last + (greatest(v_prev_rule.cooldown_seconds,0) || ' seconds')::interval;
  end if;
end;
$$;

-- Status for the user screen: current reward band, cooldown/wait target,
-- remaining today, and whether an ad is required (section + masters).
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

-- Grant the reward for a completed search. Server-authoritative: enforces the
-- daily cap, cooldown, wait-after-rule and (when gated) a completed rewarded ad.
create or replace function public.search_card_reward(p_nonce uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_count  int;
  v_cap    int := public._search_daily_cap();
  v_next   timestamptz;
  v_rule   public.search_card_rules;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select count(*) into v_count from public.search_rewards
    where user_id = v_uid and reward_date = v_today;
  v_count := coalesce(v_count, 0);
  if v_cap > 0 and v_count >= v_cap then raise exception 'SEARCH_DAILY_LIMIT'; end if;

  v_next := public._search_next_available(v_uid);
  if v_next is not null and now() < v_next then raise exception 'SEARCH_TOO_SOON'; end if;

  -- Ad requirement is authoritative on the server: gated → require + consume a
  -- completed nonce; ungated (section/master OFF) → no ad required.
  if public._ad_gated('search') then
    perform public._consume_ad(v_uid, 'search', p_nonce);
  elsif p_nonce is not null then
    perform public._consume_ad(v_uid, 'search', p_nonce);
  end if;

  v_rule := public._search_rule_for(v_count + 1);
  if v_rule.id is null then raise exception 'NO_SEARCH_RULE'; end if;
  v_amount := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;

  insert into public.search_rewards(user_id, reward_amount) values (v_uid, v_amount);
  if p_nonce is not null then
    update public.ad_events set reward = v_amount, updated_at = now() where id = p_nonce;
  end if;

  v_new := public._apply_ledger(v_uid, v_amount, 'search_card', null, 'Search Card reward');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', case when v_cap > 0 then greatest(v_cap - v_count - 1, 0) else null end);
end;
$$;
grant execute on function public.search_card_reward(uuid) to authenticated;

-- Read the active rules for the user screen (range display).
create or replace function public.search_card_config()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  return jsonb_build_object(
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'from_search', from_search, 'to_search', to_search,
        'min', min_reward, 'max', max_reward,
        'cooldown_seconds', cooldown_seconds, 'wait_after_seconds', wait_after_seconds)
        order by from_search)
      from public.search_card_rules where active), '[]'::jsonb));
end;
$$;
grant execute on function public.search_card_config() to authenticated;

-- Admin: list / save / delete with validation (mirrors watch-ad rules).
create or replace function public.admin_search_rules()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'from_search', from_search, 'to_search', to_search,
      'min_reward', min_reward, 'max_reward', max_reward,
      'cooldown_seconds', cooldown_seconds, 'wait_after_seconds', wait_after_seconds,
      'daily_limit', daily_limit, 'active', active, 'position', position)
      order by from_search)
    from public.search_card_rules), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_search_rules() to authenticated;

create or replace function public.admin_save_search_rule(
  p_id uuid, p_from int, p_to int, p_min bigint, p_max bigint,
  p_cooldown int, p_wait_after int, p_daily_limit int, p_active boolean)
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
    select 1 from public.search_card_rules
     where id <> coalesce(v_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and active
       and int4range(from_search, to_search, '[]') && int4range(p_from, p_to, '[]')
  ) then
    raise exception 'RANGE_OVERLAP';
  end if;

  if v_id is null then
    insert into public.search_card_rules(from_search, to_search, min_reward, max_reward,
        cooldown_seconds, wait_after_seconds, daily_limit, active, position)
    values (p_from, p_to, p_min, p_max, coalesce(p_cooldown,30),
        coalesce(p_wait_after,0), coalesce(p_daily_limit,0), coalesce(p_active,true), p_from)
    returning id into v_id;
  else
    update public.search_card_rules
       set from_search=p_from, to_search=p_to, min_reward=p_min, max_reward=p_max,
           cooldown_seconds=coalesce(p_cooldown,30), wait_after_seconds=coalesce(p_wait_after,0),
           daily_limit=coalesce(p_daily_limit,0), active=coalesce(p_active,true), position=p_from
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'search_rule.save', 'search_card_rule', v_id::text);
  return v_id;
end;
$$;
grant execute on function public.admin_save_search_rule(uuid, int, int, bigint, bigint, int, int, int, boolean) to authenticated;

create or replace function public.admin_delete_search_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.search_card_rules where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (auth.uid(), 'search_rule.delete', 'search_card_rule', p_id::text);
end;
$$;
grant execute on function public.admin_delete_search_rule(uuid) to authenticated;

-- Include 'search' in ads_config so the client's rewardedFor('search') /
-- bannerFor('search') reflect the admin section toggles + masters.
create or replace function public.ads_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sys  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true);
  v_rew  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true);
  v_ban  boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_ads_enabled'), true);
  v_sections text[] := array['daily','scratch','mining','watch_ads','quiz','tasks','contest','search'];
  v_out jsonb := '{}'::jsonb;
  s text;
begin
  foreach s in array v_sections loop
    v_out := v_out || jsonb_build_object(s, jsonb_build_object(
      'rewarded', v_sys and v_rew and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_'||s), true),
      'banner',   v_sys and v_ban and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_'||s), true)
    ));
  end loop;
  return jsonb_build_object('system', v_sys, 'rewarded_global', v_rew,
                            'banner_global', v_ban, 'sections', v_out);
end;
$$;
grant execute on function public.ads_config() to authenticated;

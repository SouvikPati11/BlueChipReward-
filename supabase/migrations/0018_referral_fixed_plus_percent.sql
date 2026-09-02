-- ============================================================================
-- Referral rewards: Fixed AND Percentage simultaneously, per level.
-- One authoritative config (app_settings.referral_levels). Forward-only.
--
-- New per-level shape:
--   { "enabled": true,
--     "fixed_enabled": true,  "fixed": 100,
--     "percent_enabled": true, "percent": 10 }
-- Total level reward = (fixed_enabled ? fixed : 0)
--                    + (percent_enabled ? floor(qualifying * percent/100) : 0)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Migrate existing referral_levels to the new shape.
--   legacy numeric [200,50]            -> fixed
--   {enabled,type:'fixed',value}       -> fixed
--   {enabled,type:'percent',value}     -> percent
--   already-new objects are left as-is
-- ---------------------------------------------------------------------------
do $$
declare v jsonb := public.setting_json('referral_levels'); v_new jsonb;
begin
  if v is null or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) = 0 then
    return;
  end if;
  select jsonb_agg(
    case
      when jsonb_typeof(e) = 'number' then
        jsonb_build_object('enabled', true, 'fixed_enabled', true,
                           'fixed', (e #>> '{}')::numeric,
                           'percent_enabled', false, 'percent', 0)
      when e ? 'type' then
        jsonb_build_object(
          'enabled', coalesce((e->>'enabled')::boolean, true),
          'fixed_enabled', (e->>'type') = 'fixed',
          'fixed', case when (e->>'type')='fixed' then coalesce((e->>'value')::numeric,0) else 0 end,
          'percent_enabled', (e->>'type') = 'percent',
          'percent', case when (e->>'type')='percent' then coalesce((e->>'value')::numeric,0) else 0 end)
      else e
    end
    order by ord)
  into v_new
  from jsonb_array_elements(v) with ordinality as t(e, ord);

  update public.app_settings set value = v_new where key = 'referral_levels';
end $$;

-- Default (used only on a fresh DB where the key is absent).
insert into public.app_settings(key, value, description) values
  ('referral_levels',
   '[{"enabled":true,"fixed_enabled":true,"fixed":100,"percent_enabled":false,"percent":0},{"enabled":true,"fixed_enabled":true,"fixed":50,"percent_enabled":false,"percent":0},{"enabled":true,"fixed_enabled":true,"fixed":25,"percent_enabled":false,"percent":0}]',
   'Per-level referral rewards: {enabled, fixed_enabled, fixed, percent_enabled, percent}')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Normalising reader (handles all historical shapes → new shape).
-- ---------------------------------------------------------------------------
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
    return '[]'::jsonb;
  end if;
  return (
    select jsonb_agg(
      case
        when jsonb_typeof(e) = 'number' then
          jsonb_build_object('enabled', true, 'fixed_enabled', true,
                             'fixed', (e #>> '{}')::numeric,
                             'percent_enabled', false, 'percent', 0)
        when e ? 'type' then
          jsonb_build_object(
            'enabled', coalesce((e->>'enabled')::boolean, true),
            'fixed_enabled', (e->>'type') = 'fixed',
            'fixed', case when (e->>'type')='fixed' then coalesce((e->>'value')::numeric,0) else 0 end,
            'percent_enabled', (e->>'type') = 'percent',
            'percent', case when (e->>'type')='percent' then coalesce((e->>'value')::numeric,0) else 0 end)
        else e
      end order by ord)
    from jsonb_array_elements(v) with ordinality as t(e, ord));
end;
$$;

-- ---------------------------------------------------------------------------
-- Resolve one level config to a concrete reward (fixed + percent).
-- ---------------------------------------------------------------------------
create or replace function public._referral_reward_for(cfg jsonb)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_reward numeric := 0;
  v_qual   numeric := public._referral_qualifying_amount();
begin
  if not coalesce((cfg->>'enabled')::boolean, true) then return 0; end if;
  if coalesce((cfg->>'fixed_enabled')::boolean, false) then
    v_reward := v_reward + coalesce((cfg->>'fixed')::numeric, 0);
  end if;
  if coalesce((cfg->>'percent_enabled')::boolean, false) then
    v_reward := v_reward + floor(v_qual * coalesce((cfg->>'percent')::numeric,0) / 100.0);
  end if;
  return floor(v_reward)::bigint;
end;
$$;

-- ---------------------------------------------------------------------------
-- referral_overview exposes the full per-level config for the card UI + refer page.
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
      'fixed_enabled', coalesce(((v_cfg->(lvl-1))->>'fixed_enabled')::boolean, false),
      'fixed', coalesce(((v_cfg->(lvl-1))->>'fixed')::numeric, 0),
      'percent_enabled', coalesce(((v_cfg->(lvl-1))->>'percent_enabled')::boolean, false),
      'percent', coalesce(((v_cfg->(lvl-1))->>'percent')::numeric, 0),
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

-- Admin RPC to persist the referral levels config from the card UI (validated).
create or replace function public.admin_set_referral_levels(p_levels jsonb, p_enabled boolean, p_qualifying numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  if jsonb_typeof(p_levels) <> 'array' then raise exception 'INVALID_LEVELS'; end if;
  perform public.admin_set_setting('referral_levels', p_levels, null);
  perform public.admin_set_setting('referral_system_enabled', to_jsonb(coalesce(p_enabled, true)), null);
  if p_qualifying is not null then
    perform public.admin_set_setting('referral_qualifying_amount', to_jsonb(p_qualifying), null);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_referral_levels(jsonb, boolean, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Config cleanup: remove obsolete settings (functions keep literal defaults,
-- so deleting the rows changes no behaviour).
-- ---------------------------------------------------------------------------
delete from public.app_settings where key in (
  'currency_symbol',
  'bcp_to_currency_rate',
  'daily_reward_base',
  'daily_reward_streak_step',
  'daily_reward_streak_cap',
  'referral_reward_l1'
);

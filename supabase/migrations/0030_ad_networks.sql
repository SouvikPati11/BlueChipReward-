-- ============================================================================
-- 0030  Per-placement ad NETWORK selection (AdMob / AppLovin / Unity).
--
-- Admin can pick, per placement, which ad network serves the rewarded ad and
-- the banner. The choice is stored in app_settings (ad_network_<placement> /
-- banner_network_<placement>) and surfaced through ads_config() so the client
-- can show the right SDK. The existing masters (ads_system_enabled /
-- rewarded_ads_enabled / banner_ads_enabled) and per-section gates are
-- unchanged, and server-side reward verification (_consume_ad on the ad_events
-- funnel) is network-AGNOSTIC — it validates the nonce/funnel, not which
-- network served the ad — so network selection never weakens verification.
-- Forward-only, non-destructive.
-- ============================================================================

-- Audit only: which network a given ad event used (does not affect verification).
alter table public.ad_events add column if not exists network text;

-- Seed a default network ('admob') for every placement — rewarded + banner.
insert into public.app_settings(key, value, description)
select 'ad_network_' || p, '"admob"'::jsonb, 'Rewarded ad network for ' || p
from unnest(array['daily','scratch','mining','watch_ads','quiz','tasks','contest','search']) as p
on conflict (key) do nothing;

insert into public.app_settings(key, value, description)
select 'banner_network_' || p, '"admob"'::jsonb, 'Banner ad network for ' || p
from unnest(array['daily','scratch','mining','watch_ads','quiz','tasks','contest','search']) as p
on conflict (key) do nothing;

-- Validated network resolvers: only admob / applovin / unity are honoured; any
-- other stored value (or an unset one) falls back to admob so a bad value can
-- never break ad serving.
create or replace function public._ad_network(p_placement text)
returns text language sql stable security definer set search_path = public as $$
  select case lower(coalesce(
           (select value #>> '{}' from public.app_settings where key = 'ad_network_' || p_placement),
           'admob'))
    when 'applovin' then 'applovin'
    when 'unity'    then 'unity'
    else 'admob' end;
$$;

create or replace function public._banner_network(p_placement text)
returns text language sql stable security definer set search_path = public as $$
  select case lower(coalesce(
           (select value #>> '{}' from public.app_settings where key = 'banner_network_' || p_placement),
           'admob'))
    when 'applovin' then 'applovin'
    when 'unity'    then 'unity'
    else 'admob' end;
$$;

-- Record the configured rewarded network on each ad event (audit).
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
  insert into public.ad_events(user_id, placement, state, network)
  values (v_uid, p_placement, 'requested', public._ad_network(p_placement))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'nonce', v_id);
end;
$$;
grant execute on function public.ad_begin(text) to authenticated;

-- ads_config() now also reports the selected network + banner_network per
-- section, alongside the existing masters and rewarded/banner flags.
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
      'banner',   v_sys and v_ban and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='banner_'||s), true),
      'network',        public._ad_network(s),
      'banner_network', public._banner_network(s)
    ));
  end loop;
  return jsonb_build_object('system', v_sys, 'rewarded_global', v_rew,
                            'banner_global', v_ban, 'sections', v_out);
end;
$$;
grant execute on function public.ads_config() to authenticated;

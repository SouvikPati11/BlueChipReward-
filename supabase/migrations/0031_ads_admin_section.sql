-- ============================================================================
-- 0031  Admin "Ads" section — dynamic Ad IDs, test/production mode, analytics.
--
-- Backs the new top-level Admin → Ads panel. It adds three things and changes
-- nothing about how rewards are verified:
--
--   1. Dynamic, admin-editable Ad IDs / Placement IDs per network, stored in
--      app_settings and surfaced through ads_config() so the client can serve
--      the right unit. AdMob rewarded/banner unit ids, plus AppLovin and Unity
--      rewarded/banner placement ids.
--   2. A global Test/Production mode flag (ads_test_mode). When ON (default),
--      the client serves Google/AppLovin/Unity TEST inventory regardless of the
--      stored ids — safe to ship without real ad accounts.
--   3. A real, DB-backed ads analytics RPC (admin_ads_analytics) computed from
--      the ad_events funnel: requests / impressions / rewarded completions /
--      verified credits, overall and per network.
--
-- SECURITY: no SDK secret is ever stored here. The AppLovin MAX SDK key and the
-- Unity Game ID stay build-time only (GitHub Actions secrets injected into the
-- APK); the Admin panel manages ONLY dynamic Ad unit / placement IDs and the
-- per-placement network selection. Reward verification remains the network-
-- agnostic ad_events funnel (_consume_ad), unchanged.
-- Forward-only, non-destructive.
-- ============================================================================

-- 1. Global test/production toggle. Default TRUE so a fresh deploy serves test
--    ads and never accidentally bills a real ad account.
insert into public.app_settings(key, value, description) values
  ('ads_test_mode', 'true'::jsonb,
   'Ads test mode — ON serves test inventory; OFF uses the real Ad IDs below')
on conflict (key) do nothing;

-- 2. Dynamic Ad unit / placement IDs per network (NOT SDK keys). Empty by
--    default; while empty (or while test mode is ON) the client uses that
--    network's public test unit. AdMob uses ad-unit ids; AppLovin/Unity use
--    ad-unit / placement ids.
insert into public.app_settings(key, value, description) values
  ('admob_rewarded_id',    '""'::jsonb, 'AdMob rewarded ad unit ID (production)'),
  ('admob_banner_id',      '""'::jsonb, 'AdMob banner ad unit ID (production)'),
  ('applovin_rewarded_id', '""'::jsonb, 'AppLovin MAX rewarded ad unit ID (production)'),
  ('applovin_banner_id',   '""'::jsonb, 'AppLovin MAX banner ad unit ID (production)'),
  ('unity_rewarded_id',    '""'::jsonb, 'Unity Ads rewarded placement ID (production)'),
  ('unity_banner_id',      '""'::jsonb, 'Unity Ads banner placement ID (production)')
on conflict (key) do nothing;

-- Helper: read a text setting as a plain string ('' when unset/null).
create or replace function public._ads_text(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select value #>> '{}' from public.app_settings where key = p_key), '');
$$;

-- 3. ads_config() now also returns:
--      test_mode : the global test/production flag, and
--      networks  : per-network rewarded/banner IDs { admob, applovin, unity }.
--    Existing shape (system / rewarded_global / banner_global / sections with
--    per-placement rewarded, banner, network, banner_network) is preserved so
--    older clients keep working.
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
  v_test boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_test_mode'), true);
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
  return jsonb_build_object(
    'system', v_sys,
    'rewarded_global', v_rew,
    'banner_global', v_ban,
    'test_mode', v_test,
    'networks', jsonb_build_object(
      'admob',    jsonb_build_object('rewarded', public._ads_text('admob_rewarded_id'),    'banner', public._ads_text('admob_banner_id')),
      'applovin', jsonb_build_object('rewarded', public._ads_text('applovin_rewarded_id'), 'banner', public._ads_text('applovin_banner_id')),
      'unity',    jsonb_build_object('rewarded', public._ads_text('unity_rewarded_id'),    'banner', public._ads_text('unity_banner_id'))
    ),
    'sections', v_out);
end;
$$;
grant execute on function public.ads_config() to authenticated;

-- 4. Ads analytics from the ad_events funnel. A row's state is terminal and
--    monotonic (requested → impressed → rewarded → credited), so a 'credited'
--    row also counts toward impressions and rewarded completions.
--      totals     : requests / impressions / rewarded / credited / credited_bcp
--      by_network : same counts grouped by the network that served (audit column)
--      by_placement: credited count per placement
create or replace function public.admin_ads_analytics(
  p_from timestamptz default null,
  p_to   timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz := coalesce(p_from, '-infinity'::timestamptz);
  v_to   timestamptz := coalesce(p_to, 'infinity'::timestamptz);
  v_totals jsonb;
  v_by_net jsonb;
  v_by_plc jsonb;
begin
  perform public._assert_admin();

  select jsonb_build_object(
    'requests',     count(*),
    'impressions',  count(*) filter (where state in ('impressed','rewarded','credited')),
    'rewarded',     count(*) filter (where state in ('rewarded','credited')),
    'credited',     count(*) filter (where state = 'credited'),
    'credited_bcp', coalesce(sum(reward) filter (where state = 'credited'), 0)
  )
  into v_totals
  from public.ad_events
  where created_at >= v_from and created_at <= v_to;

  select coalesce(jsonb_agg(rec order by net), '[]'::jsonb)
  into v_by_net
  from (
    select coalesce(nullif(network,''), 'admob') as net,
           jsonb_build_object(
             'network',      coalesce(nullif(network,''), 'admob'),
             'requests',     count(*),
             'impressions',  count(*) filter (where state in ('impressed','rewarded','credited')),
             'rewarded',     count(*) filter (where state in ('rewarded','credited')),
             'credited',     count(*) filter (where state = 'credited'),
             'credited_bcp', coalesce(sum(reward) filter (where state = 'credited'), 0)
           ) as rec
      from public.ad_events
     where created_at >= v_from and created_at <= v_to
     group by coalesce(nullif(network,''), 'admob')
  ) n;

  select coalesce(jsonb_object_agg(placement, cnt), '{}'::jsonb)
  into v_by_plc
  from (
    select placement, count(*) filter (where state = 'credited') as cnt
      from public.ad_events
     where created_at >= v_from and created_at <= v_to
     group by placement
  ) p;

  return jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'totals', coalesce(v_totals, jsonb_build_object(
      'requests',0,'impressions',0,'rewarded',0,'credited',0,'credited_bcp',0)),
    'by_network', coalesce(v_by_net, '[]'::jsonb),
    'by_placement', v_by_plc
  );
end;
$$;
grant execute on function public.admin_ads_analytics(timestamptz, timestamptz) to authenticated;

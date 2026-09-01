-- ============================================================================
-- Admin-managed page/external links + configurable notification reminders
--
--   * app_links: admin CRUD for buttons/links surfaced in the app (Support,
--     Telegram, FAQ, Website…). URLs are validated on save.
--   * generate_reminders(): produces (idempotent, non-spammy) reminder
--     notifications — daily reward ready, mining session ready, boost ready,
--     unclaimed reward. Each reminder type is admin-toggleable and deep-links
--     into the app. Intended to be run periodically (pg_cron / edge scheduler).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Configurable links
-- ---------------------------------------------------------------------------
create table if not exists public.app_links (
  id         uuid primary key default gen_random_uuid(),
  key        text unique not null,
  label      text not null,
  url        text not null,
  icon       text,                       -- material icon name hint for the app
  external   boolean not null default true,  -- external URL vs in-app route
  position   int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.app_links enable row level security;
do $$ begin
  create policy app_links_read on public.app_links
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;

create or replace function public.app_links_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'key', key, 'label', label, 'url', url,
    'icon', icon, 'external', external
  ) order by position, label), '[]'::jsonb)
  from public.app_links where active;
$$;
grant execute on function public.app_links_list() to authenticated;

create or replace function public.admin_save_app_link(
  p_id uuid, p_key text, p_label text, p_url text,
  p_icon text, p_external boolean, p_position int, p_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if nullif(trim(p_label), '') is null then raise exception 'INVALID_LABEL'; end if;
  if nullif(trim(p_url), '') is null then raise exception 'INVALID_URL'; end if;
  -- validate: external links must be http(s); internal must be an app route.
  if p_external then
    if p_url !~* '^https?://[^\s]+$' then raise exception 'INVALID_URL'; end if;
  else
    if left(p_url, 1) <> '/' then raise exception 'INVALID_ROUTE'; end if;
  end if;

  if v_id is null then
    insert into public.app_links(key, label, url, icon, external, position, active)
    values (coalesce(nullif(trim(p_key),''), 'link_' || substr(gen_random_uuid()::text,1,8)),
            trim(p_label), trim(p_url), nullif(trim(p_icon),''), p_external,
            coalesce(p_position,0), coalesce(p_active,true))
    on conflict (key) do update
      set label = excluded.label, url = excluded.url, icon = excluded.icon,
          external = excluded.external, position = excluded.position, active = excluded.active
    returning id into v_id;
  else
    update public.app_links
       set key = coalesce(nullif(trim(p_key),''), key),
           label = trim(p_label), url = trim(p_url), icon = nullif(trim(p_icon),''),
           external = p_external, position = coalesce(p_position,0), active = coalesce(p_active,true)
     where id = v_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'app_link.save', 'app_link', v_id::text,
          jsonb_build_object('label', p_label, 'url', p_url));
  return v_id;
end;
$$;

create or replace function public.admin_delete_app_link(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  delete from public.app_links where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'app_link.delete', 'app_link', p_id::text, '{}'::jsonb);
end;
$$;

-- Admin reads the full list (incl. inactive) directly via table select (RLS
-- select policy already allows any authenticated user to read active rows; the
-- admin editor uses a dedicated read that includes inactive).
create or replace function public.admin_app_links()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'key', key, 'label', label, 'url', url, 'icon', icon,
      'external', external, 'position', position, 'active', active
    ) order by position, label) from public.app_links
  ), '[]'::jsonb);
end;
$$;

grant execute on function
  public.admin_save_app_link(uuid, text, text, text, text, boolean, int, boolean),
  public.admin_delete_app_link(uuid),
  public.admin_app_links()
  to authenticated;

insert into public.app_links(key, label, url, icon, external, position) values
  ('support',  'Contact Support', 'https://t.me/bluechiprewards', 'support_agent', true, 0),
  ('telegram', 'Telegram Channel', 'https://t.me/bluechiprewards', 'send',          true, 1),
  ('faq',      'FAQ & Help',       'https://souvikpati11.github.io/BlueChipReward-/', 'help_center', true, 2),
  ('terms',    'Terms of Service', 'https://souvikpati11.github.io/BlueChipReward-/terms.html', 'description', true, 3),
  ('privacy',  'Privacy Policy',   'https://souvikpati11.github.io/BlueChipReward-/privacy.html', 'privacy_tip', true, 4)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Reminder notifications (admin-toggleable, deep-linked, de-duplicated).
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('reminder_daily_enabled',     'true', 'Send a reminder when the daily reward is ready again'),
  ('reminder_mining_enabled',    'true', 'Send a reminder when a mining session can be started/claimed'),
  ('reminder_boost_enabled',     'true', 'Send a reminder when a mining boost is available'),
  ('reminder_unclaimed_enabled', 'true', 'Send a reminder when there is unclaimed mined BCP')
on conflict (key) do nothing;

-- Insert one notification per user/type only if none of that type was sent in
-- the given window (spam guard). Returns rows inserted.
create or replace function public._remind(
  p_users uuid[], p_type notification_type, p_title text, p_body text,
  p_data jsonb, p_window interval
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  insert into public.notifications(user_id, title, body, type, data)
  select u, p_title, p_body, p_type, p_data
    from unnest(p_users) as u
   where not exists (
     select 1 from public.notifications n
      where n.user_id = u and n.type = p_type
        and n.data->>'reminder' = p_data->>'reminder'
        and n.created_at > now() - p_window
   );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.generate_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_daily int := 0; v_mining int := 0; v_boost int := 0; v_unclaimed int := 0;
  v_cool numeric := public.setting_num('mining_boost_cooldown_hours', 2);
  v_max  int := public.setting_num('mining_max_boosts', 3)::int;
begin
  -- Daily reward ready: active users who can claim today but haven't.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_daily_enabled'), true) then
    v_daily := public._remind(
      array(
        select p.id from public.profiles p
        where p.status = 'active'
          and not exists (select 1 from public.daily_reward_claims d
                          where d.user_id = p.id and d.claim_date = v_today)
      ),
      'daily', 'Your daily reward is ready 🎁',
      'Claim your daily BCP before the day ends.',
      jsonb_build_object('reminder', 'daily', 'route', '/earn/daily'),
      interval '20 hours');
  end if;

  -- Mining session ready: active users with no running session.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_mining_enabled'), true) then
    v_mining := public._remind(
      array(
        select p.id from public.profiles p
        where p.status = 'active'
          and not exists (select 1 from public.mining_sessions m
                          where m.user_id = p.id and m.status = 'active' and m.ends_at > now())
      ),
      'system', 'Start mining ⛏️',
      'Your miner is idle — start a session to keep earning BCP.',
      jsonb_build_object('reminder', 'mining', 'route', '/earn/mining'),
      interval '20 hours');
  end if;

  -- Boost ready: active sessions where a boost is available now.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_boost_enabled'), true) then
    v_boost := public._remind(
      array(
        select m.user_id from public.mining_sessions m
        where m.status = 'active' and m.ends_at > now()
          and m.boosts < v_max
          and (m.last_boost_at is null or now() >= m.last_boost_at + (v_cool || ' hours')::interval)
      ),
      'system', 'Mining boost ready 🚀',
      'A boost is available — increase your mining rate now.',
      jsonb_build_object('reminder', 'boost', 'route', '/earn/mining'),
      (v_cool || ' hours')::interval);
  end if;

  -- Unclaimed mined BCP: active sessions with claimable accrual.
  if coalesce((select (value #>> '{}')::boolean from public.app_settings where key='reminder_unclaimed_enabled'), true) then
    v_unclaimed := public._remind(
      array(
        select m.user_id from public.mining_sessions m
        where m.status = 'active'
          and public._mining_accrued(m) - m.claimed >= greatest(m.rate_per_hour, 1)
      ),
      'system', 'You have unclaimed BCP 💰',
      'Mined BCP is waiting — open the app to claim it.',
      jsonb_build_object('reminder', 'unclaimed', 'route', '/earn/mining'),
      interval '12 hours');
  end if;

  return jsonb_build_object('ok', true, 'daily', v_daily, 'mining', v_mining,
                            'boost', v_boost, 'unclaimed', v_unclaimed);
end;
$$;

-- Schedule every 30 minutes if pg_cron is available (safe no-op otherwise).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bcp_generate_reminders', '*/30 * * * *',
                          $cron$select public.generate_reminders();$cron$);
  end if;
exception when others then
  -- scheduling is best-effort; ignore if unavailable or already scheduled
  null;
end $$;

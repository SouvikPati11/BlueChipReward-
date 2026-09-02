-- ============================================================================
-- Contest system (section 32). User-specific start timestamps + independent
-- deadlines, server-authoritative progress from the ledger / referral data,
-- ad-gated claim, admin review, idempotent, new cycle after completion.
-- Forward-only.
-- ============================================================================

-- Distinct ledger type for contest rewards (additive, safe).
alter type ledger_type add value if not exists 'contest';

do $$ begin
  create type contest_target as enum ('bcp_earned', 'referral_count');
exception when duplicate_object then null; end $$;

do $$ begin
  create type contest_state as enum ('active', 'claim_pending', 'completed', 'expired', 'rejected');
exception when duplicate_object then null; end $$;

-- Admin-defined contest templates.
create table if not exists public.contests (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  target_type    contest_target not null,
  target_value   bigint not null,
  reward         bigint not null,
  duration_hours int not null default 168,      -- 7 days
  requires_ad    boolean not null default false,
  rules          text,
  active         boolean not null default true,
  position       int not null default 0,
  created_at     timestamptz not null default now()
);

-- Per-user contest cycle (independent start/deadline).
create table if not exists public.contest_participations (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  contest_id    uuid not null references public.contests(id) on delete cascade,
  target_type   contest_target not null,
  target_value  bigint not null,
  reward        bigint not null,
  started_at    timestamptz not null default now(),
  ends_at       timestamptz not null,
  baseline      bigint not null default 0,       -- earned/referrals at start
  state         contest_state not null default 'active',
  claimed_at    timestamptz,
  reviewed_at   timestamptz,
  reviewed_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);
create index if not exists idx_contest_part_user on public.contest_participations(user_id, state);
create index if not exists idx_contest_part_state on public.contest_participations(state, ends_at);
-- Only one live cycle per (user, contest).
create unique index if not exists uniq_active_contest
  on public.contest_participations(user_id, contest_id)
  where (state in ('active','claim_pending'));

alter table public.contests enable row level security;
alter table public.contest_participations enable row level security;
do $$ begin
  create policy contests_read on public.contests
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy contest_part_self on public.contest_participations
    for select using (user_id = auth.uid() or public.is_admin());
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Authoritative metric for a user at "now": total BCP earned or referral count.
-- ---------------------------------------------------------------------------
create or replace function public._contest_metric(p_uid uuid, p_type contest_target)
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_type = 'referral_count' then
    return (select count(*)::bigint from public.referrals where referrer_id = p_uid and level = 1);
  end if;
  -- bcp_earned: cumulative positive ledger credits (excludes withdrawals/holds)
  return (select coalesce(sum(amount),0)::bigint from public.wallet_transactions
          where user_id = p_uid and amount > 0);
end;
$$;

-- Progress within a participation window (never negative).
create or replace function public._contest_progress(p public.contest_participations)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select greatest(public._contest_metric(p.user_id, p.target_type) - p.baseline, 0);
$$;

-- ---------------------------------------------------------------------------
-- User: overview of active contests + this user's participation/progress.
-- ---------------------------------------------------------------------------
create or replace function public.contests_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'target_type', c.target_type,
      'target_value', c.target_value,
      'reward', c.reward,
      'duration_hours', c.duration_hours,
      'requires_ad', c.requires_ad,
      'rules', c.rules,
      'participation', (
        select jsonb_build_object(
          'id', p.id,
          'state', (case when p.state = 'active' and now() > p.ends_at then 'expired' else p.state end),
          'started_at', p.started_at,
          'ends_at', p.ends_at,
          'progress', public._contest_progress(p),
          'target_value', p.target_value,
          'reward', p.reward,
          'reached', public._contest_progress(p) >= p.target_value,
          'claimable', (p.state = 'active' and now() <= p.ends_at
                        and public._contest_progress(p) >= p.target_value)
        )
        from public.contest_participations p
        where p.user_id = v_uid and p.contest_id = c.id
          and p.state in ('active','claim_pending')
        order by p.started_at desc limit 1
      )
    ) order by c.position, c.created_at)
    from public.contests c
    where c.active
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.contests_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- User: start a contest cycle (captures baseline + personal deadline).
-- ---------------------------------------------------------------------------
create or replace function public.start_contest(p_contest_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_c   public.contests;
  v_id  uuid;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_c from public.contests where id = p_contest_id and active;
  if not found then raise exception 'CONTEST_UNAVAILABLE'; end if;

  if exists (select 1 from public.contest_participations
             where user_id = v_uid and contest_id = p_contest_id
               and state in ('active','claim_pending')) then
    raise exception 'CONTEST_ALREADY_ACTIVE';
  end if;

  insert into public.contest_participations(
    user_id, contest_id, target_type, target_value, reward, ends_at, baseline)
  values (v_uid, p_contest_id, v_c.target_type, v_c.target_value, v_c.reward,
          now() + make_interval(hours => v_c.duration_hours),
          public._contest_metric(v_uid, v_c.target_type))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'participation_id', v_id);
end;
$$;
grant execute on function public.start_contest(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- User: claim a reached contest (ad-gated if configured) → pending review.
-- ---------------------------------------------------------------------------
create or replace function public.claim_contest(p_participation_id uuid, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_p   public.contest_participations;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_p from public.contest_participations
    where id = p_participation_id and user_id = v_uid for update;
  if not found then raise exception 'PARTICIPATION_NOT_FOUND'; end if;
  if v_p.state <> 'active' then raise exception 'CONTEST_NOT_CLAIMABLE'; end if;
  if now() > v_p.ends_at then
    update public.contest_participations set state='expired' where id = v_p.id;
    raise exception 'CONTEST_EXPIRED';
  end if;
  if public._contest_progress(v_p) < v_p.target_value then
    raise exception 'CONTEST_TARGET_NOT_REACHED';
  end if;

  -- Ad gate for contest claims (uses the same funnel; placement 'contest').
  if v_p.reward is not null and (select requires_ad from public.contests where id = v_p.contest_id) then
    perform public._consume_ad(v_uid, 'contest', p_nonce);
  end if;

  update public.contest_participations
     set state = 'claim_pending', claimed_at = now()
   where id = v_p.id;

  return jsonb_build_object('ok', true, 'state', 'claim_pending');
end;
$$;
grant execute on function public.claim_contest(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list contest claims for review.
-- ---------------------------------------------------------------------------
create or replace function public.admin_contest_claims(p_status text default 'claim_pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'user_id', p.user_id,
      'user_name', pr.full_name,
      'user_email', pr.email,
      'contest_name', c.name,
      'target_type', p.target_type,
      'target_value', p.target_value,
      'progress', public._contest_progress(p),
      'reward', p.reward,
      'started_at', p.started_at,
      'ends_at', p.ends_at,
      'claimed_at', p.claimed_at,
      'state', p.state
    ) order by p.claimed_at desc nulls last)
    from public.contest_participations p
    join public.profiles pr on pr.id = p.user_id
    join public.contests c on c.id = p.contest_id
    where p_status = 'all' or p.state::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_contest_claims(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve/reject a contest claim. Approve credits once (idempotent).
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_contest_claim(p_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_p public.contest_participations;
begin
  perform public._assert_admin();
  select * into v_p from public.contest_participations where id = p_id for update;
  if not found then raise exception 'PARTICIPATION_NOT_FOUND'; end if;
  if v_p.state <> 'claim_pending' then
    return jsonb_build_object('ok', true, 'already', v_p.state);
  end if;

  if p_approve then
    update public.contest_participations
       set state='completed', reviewed_at=now(), reviewed_by=v_admin where id=p_id;
    if v_p.reward > 0 then
      perform public._apply_ledger(v_p.user_id, v_p.reward, 'contest', v_p.contest_id,
        'Contest reward', jsonb_build_object('contest', v_p.contest_id));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_p.user_id, 'Contest reward 🏆',
              'You earned ' || v_p.reward || ' BCP from a contest.', 'reward',
              jsonb_build_object('route', '/contests'));
    end if;
  else
    update public.contest_participations
       set state='rejected', reviewed_at=now(), reviewed_by=v_admin where id=p_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, case when p_approve then 'contest_claim.approve' else 'contest_claim.reject' end,
          'contest_participation', p_id::text, jsonb_build_object('user', v_p.user_id));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_resolve_contest_claim(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin CRUD for contests.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_contest(
  p_id uuid, p_name text, p_target_type text, p_target_value bigint, p_reward bigint,
  p_duration_hours int, p_requires_ad boolean, p_rules text, p_active boolean, p_position int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.contests(name, target_type, target_value, reward, duration_hours,
      requires_ad, rules, active, position)
    values (p_name, p_target_type::contest_target, p_target_value, p_reward,
      coalesce(p_duration_hours,168), coalesce(p_requires_ad,false), p_rules,
      coalesce(p_active,true), coalesce(p_position,0))
    returning id into v_id;
  else
    update public.contests
       set name=p_name, target_type=p_target_type::contest_target, target_value=p_target_value,
           reward=p_reward, duration_hours=coalesce(p_duration_hours,168),
           requires_ad=coalesce(p_requires_ad,false), rules=p_rules,
           active=coalesce(p_active,true), position=coalesce(p_position,0)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'contest.save', 'contest', v_id::text, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.admin_delete_contest(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  delete from public.contests where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'contest.delete', 'contest', p_id::text, '{}'::jsonb);
end;
$$;

grant execute on function
  public.admin_save_contest(uuid, text, text, bigint, bigint, int, boolean, text, boolean, int),
  public.admin_delete_contest(uuid)
  to authenticated;

-- Seed example contests.
insert into public.contests(name, target_type, target_value, reward, duration_hours, rules, position) values
  ('Earn 500 BCP in 7 days', 'bcp_earned', 500, 100, 168, 'Earn 500 BCP within 7 days of starting.', 0),
  ('Earn 1000 BCP in 30 days', 'bcp_earned', 1000, 200, 720, 'Earn 1000 BCP within 30 days of starting.', 1),
  ('Refer 5 friends in 30 days', 'referral_count', 5, 200, 720, 'Get 5 successful referrals within 30 days.', 2)
on conflict do nothing;

-- Ad-gate flag for the contest placement (so ads_config / _ad_gated cover it).
insert into public.app_settings(key, value, description) values
  ('ad_gate_contest', 'true', 'Contest claim · rewarded ad required (when contest requires_ad)')
on conflict (key) do nothing;

-- Redefine ads_config to include the 'contest' placement so the client's ad
-- decision matches the server gate.
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
  v_sections text[] := array['daily','scratch','mining','watch_ads','quiz','tasks','contest'];
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

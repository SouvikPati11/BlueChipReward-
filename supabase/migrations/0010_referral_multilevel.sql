-- ============================================================================
-- Multi-level referral system (server-authoritative, idempotent, fraud-guarded)
--
--   * Levels and per-level rewards are admin-configurable via the app_settings
--     key `referral_levels` (a JSON array of BCP amounts, index 0 = level 1).
--   * A referral chain is walked upward from a new user's direct referrer and
--     each ancestor is credited for the corresponding level exactly once.
--   * Idempotency is enforced by referrals.unique(referred_id, level): a level
--     is credited only when its row is newly inserted.
--   * Self-referral / same-device abuse is scored; strong matches are withheld
--     and queued for admin review instead of being credited automatically.
--
-- This migration REPLACES the single-level logic in handle_new_user() and
-- apply_referral_code() with a shared chain walker. All existing behaviour
-- (signup bonus, profile/wallet creation, level-1 reward defaults) is preserved.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Devices seen per account (populated at signup + via register_device RPC).
-- Used to detect the same physical device creating and referring itself.
-- ---------------------------------------------------------------------------
create table if not exists public.account_devices (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  device_id  text not null,
  created_at timestamptz not null default now(),
  unique (user_id, device_id)
);
create index if not exists idx_account_devices_device on public.account_devices(device_id);

-- ---------------------------------------------------------------------------
-- Referral fraud review queue. A withheld (suspicious) referral lands here for
-- an admin to approve (pay it) or reject (discard it).
-- ---------------------------------------------------------------------------
do $$ begin
  create type referral_review_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.referral_reviews (
  id            uuid primary key default gen_random_uuid(),
  referrer_id   uuid not null references public.profiles(id) on delete cascade,
  referred_id   uuid not null references public.profiles(id) on delete cascade,
  level         int not null default 1,
  reward_amount bigint not null default 0,
  score         int not null default 0,
  reason        text,
  signals       jsonb not null default '{}'::jsonb,
  status        referral_review_status not null default 'pending',
  created_at    timestamptz not null default now(),
  reviewed_at   timestamptz,
  reviewed_by   uuid references public.profiles(id),
  unique (referred_id, level)
);
create index if not exists idx_ref_reviews_status on public.referral_reviews(status, created_at desc);

-- Enable RLS; only the owner reads their own reviews, admins manage via RPC.
alter table public.account_devices enable row level security;
alter table public.referral_reviews enable row level security;

do $$ begin
  create policy account_devices_self on public.account_devices
    for select using (user_id = auth.uid());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy referral_reviews_admin_read on public.referral_reviews
    for select using (public.is_admin());
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Read the configured per-level rewards as a bigint[]. Falls back to the legacy
-- single `referral_reward_l1` value when `referral_levels` is unset.
-- ---------------------------------------------------------------------------
create or replace function public._referral_level_rewards()
returns bigint[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_json   jsonb := public.setting_json('referral_levels');
  v_result bigint[];
  v_l1     bigint;
begin
  if v_json is not null and jsonb_typeof(v_json) = 'array'
     and jsonb_array_length(v_json) > 0 then
    select array_agg((elem #>> '{}')::bigint order by ord)
      into v_result
      from jsonb_array_elements(v_json) with ordinality as t(elem, ord);
    return v_result;
  end if;
  -- legacy fallback: single level
  v_l1 := public.setting_num('referral_reward_l1', 0)::bigint;
  return array[v_l1];
end;
$$;

-- ---------------------------------------------------------------------------
-- Self-referral / same-device abuse score for a (referrer, referred) pair.
-- Higher = more suspicious. Threshold for withholding is 80.
--   +100  referrer == referred (guard; impossible by construction)
--   +85   referred's signup device is already registered to the referrer
--   +45   referrer and referred share the same signup IP
-- "reason"/"signals" are surfaced to the admin review queue.
-- ---------------------------------------------------------------------------
create or replace function public._referral_abuse_score(
  p_referrer uuid,
  p_referred uuid,
  out score  int,
  out reason text,
  out signals jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ref_ip   text;
  v_new_ip   text;
  v_shared_device boolean := false;
  v_same_ip  boolean := false;
begin
  score := 0;
  signals := '{}'::jsonb;

  if p_referrer = p_referred then
    score := 100;
    reason := 'self_referral';
    signals := jsonb_build_object('self', true);
    return;
  end if;

  -- Shared device: any device_id registered to the referred user that also
  -- belongs to the referrer.
  select exists (
    select 1
      from public.account_devices d1
      join public.account_devices d2 on d1.device_id = d2.device_id
     where d1.user_id = p_referred and d2.user_id = p_referrer
  ) into v_shared_device;

  -- Shared signup IP (recorded in profiles.metadata by the client).
  select nullif(metadata->>'signup_ip', '') into v_ref_ip
    from public.profiles where id = p_referrer;
  select nullif(metadata->>'signup_ip', '') into v_new_ip
    from public.profiles where id = p_referred;
  v_same_ip := v_ref_ip is not null and v_ref_ip = v_new_ip;

  if v_shared_device then score := score + 85; end if;
  if v_same_ip then score := score + 45; end if;

  signals := jsonb_build_object('shared_device', v_shared_device, 'same_ip', v_same_ip);
  reason := case
    when v_shared_device then 'same_device'
    when v_same_ip then 'same_ip'
    else null
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Credit one referral level: pay the referrer and notify, exactly once.
-- Runs the abuse check for level 1 (the direct referral); strong matches are
-- queued for admin review instead of paid. Returns true if a reward was paid.
-- ---------------------------------------------------------------------------
create or replace function public._credit_referral_level(
  p_referrer uuid,
  p_referred uuid,
  p_level    int,
  p_reward   bigint
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_score   int;
  v_reason  text;
  v_signals jsonb;
  v_active  boolean;
begin
  if p_referrer is null or p_referred is null or p_referrer = p_referred then
    return false;
  end if;

  -- referrer must be an active account to receive rewards
  select status = 'active' into v_active from public.profiles where id = p_referrer;
  if v_active is not true then
    return false;
  end if;

  -- Fraud screen only the direct (level-1) relationship — deeper ancestors are
  -- structurally distinct accounts.
  if p_level = 1 then
    select score, reason, signals
      into v_score, v_reason, v_signals
      from public._referral_abuse_score(p_referrer, p_referred);

    if v_score >= 80 then
      -- withhold: record for admin review, do not create a referral or credit
      insert into public.referral_reviews(
        referrer_id, referred_id, level, reward_amount, score, reason, signals)
      values (p_referrer, p_referred, p_level, p_reward, v_score, v_reason, v_signals)
      on conflict (referred_id, level) do nothing;
      return false;
    end if;
  end if;

  -- Idempotent claim of this level. If the row already exists, another path
  -- already paid it — do nothing.
  insert into public.referrals(referrer_id, referred_id, level, reward_amount)
  values (p_referrer, p_referred, p_level, p_reward)
  on conflict (referred_id, level) do nothing;

  if not found then
    return false;
  end if;

  if p_reward > 0 then
    perform public._apply_ledger(
      p_referrer, p_reward, 'referral', p_referred,
      'Referral reward (level ' || p_level || ')',
      jsonb_build_object('referred', p_referred, 'level', p_level));
    insert into public.notifications(user_id, title, body, type, data)
    values (
      p_referrer,
      case when p_level = 1 then 'New referral joined 🎉'
           else 'Referral network reward 🎉' end,
      'You earned ' || p_reward || ' BCP from a level-' || p_level || ' referral.',
      'reward',
      jsonb_build_object('referred', p_referred, 'level', p_level));
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Walk the referral chain upward from p_user's direct referrer and pay each
-- configured level. Safe against cycles; idempotent across repeated calls.
-- ---------------------------------------------------------------------------
create or replace function public._pay_referral_chain(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rewards  bigint[] := public._referral_level_rewards();
  v_levels   int := coalesce(array_length(v_rewards, 1), 0);
  v_current  uuid;
  v_next     uuid;
  v_seen     uuid[] := array[p_user];
  v_i        int;
begin
  if v_levels = 0 then
    return;
  end if;

  -- level 1 = the user's direct referrer
  select referred_by into v_current from public.profiles where id = p_user;

  for v_i in 1..v_levels loop
    exit when v_current is null;
    exit when v_current = any(v_seen);           -- cycle / self guard

    perform public._credit_referral_level(v_current, p_user, v_i, v_rewards[v_i]);

    v_seen := v_seen || v_current;
    select referred_by into v_next from public.profiles where id = v_current;
    v_current := v_next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Register a device for the current user (client sends a stable device id).
-- Used for same-device abuse detection.
-- ---------------------------------------------------------------------------
create or replace function public.register_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(trim(p_device_id), '') is null then return; end if;
  insert into public.account_devices(user_id, device_id)
  values (v_uid, trim(p_device_id))
  on conflict (user_id, device_id) do nothing;
end;
$$;
grant execute on function public.register_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Level-wise referral overview for the current user (Refer page).
-- Returns per-level counts + earnings, plus totals and the per-level config.
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
  v_rewards bigint[] := public._referral_level_rewards();
  v_levels  int := coalesce(array_length(v_rewards, 1), 0);
  v_code    text;
  v_rows    jsonb;
  v_total_c bigint;
  v_total_e bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  select referral_code into v_code from public.profiles where id = v_uid;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'level', lvl,
      'reward', case when lvl <= v_levels then v_rewards[lvl] else 0 end,
      'count', coalesce(cnt, 0),
      'earnings', coalesce(earn, 0)
    ) order by lvl), '[]'::jsonb),
    coalesce(sum(cnt), 0),
    coalesce(sum(earn), 0)
  into v_rows, v_total_c, v_total_e
  from (
    select gs.lvl,
           count(r.id)              as cnt,
           coalesce(sum(r.reward_amount), 0) as earn
      from generate_series(1, greatest(v_levels, 1)) as gs(lvl)
      left join public.referrals r
        on r.referrer_id = v_uid and r.level = gs.lvl
     group by gs.lvl
  ) s;

  return jsonb_build_object(
    'code', v_code,
    'levels', v_levels,
    'per_level', v_rows,
    'total_referrals', v_total_c,
    'total_earnings', v_total_e
  );
end;
$$;
grant execute on function public.referral_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list pending referral reviews (with user labels).
-- ---------------------------------------------------------------------------
create or replace function public.admin_referral_reviews(p_status text default 'pending')
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
      'id', rv.id,
      'referrer_id', rv.referrer_id,
      'referrer_email', pr.email,
      'referrer_name', pr.full_name,
      'referred_id', rv.referred_id,
      'referred_email', pd.email,
      'referred_name', pd.full_name,
      'level', rv.level,
      'reward_amount', rv.reward_amount,
      'score', rv.score,
      'reason', rv.reason,
      'signals', rv.signals,
      'status', rv.status,
      'created_at', rv.created_at
    ) order by rv.created_at desc)
    from public.referral_reviews rv
    join public.profiles pr on pr.id = rv.referrer_id
    join public.profiles pd on pd.id = rv.referred_id
    where p_status = 'all' or rv.status::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_referral_reviews(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve (pay) or reject a withheld referral review.
-- Approving credits the referrer through the ledger exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_referral_review(p_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_rev   public.referral_reviews%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;

  select * into v_rev from public.referral_reviews where id = p_id for update;
  if not found then raise exception 'REVIEW_NOT_FOUND'; end if;
  if v_rev.status <> 'pending' then
    return jsonb_build_object('ok', true, 'already', v_rev.status);
  end if;

  if p_approve then
    -- Pay through the idempotent referrals path (bypasses the abuse screen
    -- because an admin has explicitly cleared it).
    insert into public.referrals(referrer_id, referred_id, level, reward_amount)
    values (v_rev.referrer_id, v_rev.referred_id, v_rev.level, v_rev.reward_amount)
    on conflict (referred_id, level) do nothing;
    if found and v_rev.reward_amount > 0 then
      perform public._apply_ledger(
        v_rev.referrer_id, v_rev.reward_amount, 'referral', v_rev.referred_id,
        'Referral reward (level ' || v_rev.level || ', admin approved)',
        jsonb_build_object('referred', v_rev.referred_id, 'level', v_rev.level));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_rev.referrer_id, 'Referral approved 🎉',
              'You earned ' || v_rev.reward_amount || ' BCP from a referral.',
              'reward', jsonb_build_object('referred', v_rev.referred_id));
    end if;
  end if;

  update public.referral_reviews
     set status = case when p_approve then 'approved' else 'rejected' end,
         reviewed_at = now(),
         reviewed_by = v_admin
   where id = p_id;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin,
          case when p_approve then 'referral_review_approve' else 'referral_review_reject' end,
          'referral_review', p_id::text,
          jsonb_build_object('referrer', v_rev.referrer_id, 'referred', v_rev.referred_id));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_resolve_referral_review(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Replace handle_new_user(): record signup device/IP, then pay the full chain.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_code     text;
  v_referrer     uuid;
  v_signup_bonus bigint;
  v_device_id    text;
  v_signup_ip    text;
begin
  v_ref_code  := nullif(trim(new.raw_user_meta_data->>'referral_code'), '');
  v_device_id := nullif(trim(new.raw_user_meta_data->>'device_id'), '');
  v_signup_ip := nullif(trim(new.raw_user_meta_data->>'signup_ip'), '');

  if v_ref_code is not null then
    select id into v_referrer from public.profiles where referral_code = upper(v_ref_code);
  end if;

  insert into public.profiles(id, email, full_name, avatar_url, referral_code, referred_by, metadata)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    public._gen_referral_code(),
    v_referrer,
    jsonb_strip_nulls(jsonb_build_object('signup_ip', v_signup_ip, 'device_id', v_device_id))
  );

  insert into public.wallets(user_id) values (new.id);
  insert into public.user_roles(user_id, role) values (new.id, 'user') on conflict do nothing;

  if v_device_id is not null then
    insert into public.account_devices(user_id, device_id)
    values (new.id, v_device_id) on conflict do nothing;
  end if;

  v_signup_bonus := public.setting_num('signup_bonus', 0)::bigint;
  if v_signup_bonus > 0 then
    perform public._apply_ledger(new.id, v_signup_bonus, 'signup_bonus', null, 'Welcome bonus');
  end if;

  -- Pay the multi-level referral chain (idempotent + fraud-guarded).
  if v_referrer is not null then
    perform public._pay_referral_chain(new.id);
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Replace apply_referral_code(): attach a referrer post-signup (Google flow),
-- then pay the full chain instead of only level 1.
-- ---------------------------------------------------------------------------
create or replace function public.apply_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_referrer uuid;
  v_created  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  select referred_by, created_at into v_referrer, v_created
    from public.profiles where id = v_uid;
  if v_referrer is not null then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'already_referred');
  end if;
  if now() - v_created > interval '1 hour' then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'window_closed');
  end if;

  select id into v_referrer from public.profiles
    where referral_code = upper(p_code) and status = 'active';
  if v_referrer is null then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'invalid_code');
  end if;
  if v_referrer = v_uid then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'self_referral');
  end if;

  update public.profiles set referred_by = v_referrer where id = v_uid;

  perform public._pay_referral_chain(v_uid);

  return jsonb_build_object('ok', true, 'applied', true);
end;
$$;
grant execute on function public.apply_referral_code(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Seed the multi-level reward config (keeps legacy L1 value as level 1).
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('referral_levels', '[200, 50, 25]',
   'Per-level referral rewards in BCP (index 0 = level 1). Controls how many levels pay out.')
on conflict (key) do nothing;

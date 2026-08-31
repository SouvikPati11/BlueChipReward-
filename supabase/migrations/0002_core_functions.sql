-- ============================================================================
-- Core helpers: settings accessor, role check, ledger primitive, signup trigger
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Settings accessor with a numeric fallback
-- ---------------------------------------------------------------------------
create or replace function public.setting_num(p_key text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = p_key), p_default);
$$;

create or replace function public.setting_json(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select value from public.app_settings where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Role check (used by RLS policies and admin RPCs)
-- ---------------------------------------------------------------------------
create or replace function public.is_admin(p_uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.user_roles where user_id = p_uid and role = 'admin');
$$;

-- Guard: the caller must be an active (non-banned/suspended) user
create or replace function public.assert_active_user(p_uid uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_status user_status;
begin
  select status into v_status from public.profiles where id = p_uid;
  if v_status is null then
    raise exception 'PROFILE_NOT_FOUND';
  end if;
  if v_status <> 'active' then
    raise exception 'ACCOUNT_%', upper(v_status::text);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ledger primitive — the ONLY way BCP moves. Locks the wallet row, appends an
-- immutable ledger entry, and updates the wallet cache atomically.
-- Positive amount = credit, negative = debit.
-- ---------------------------------------------------------------------------
create or replace function public._apply_ledger(
  p_user        uuid,
  p_amount      bigint,
  p_type        ledger_type,
  p_reference   uuid   default null,
  p_description text   default null,
  p_metadata    jsonb  default '{}'::jsonb,
  p_count_earned boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance bigint;
  v_new     bigint;
begin
  -- lock the wallet row for the duration of the transaction
  select balance into v_balance from public.wallets where user_id = p_user for update;
  if not found then
    insert into public.wallets(user_id, balance) values (p_user, 0)
      on conflict (user_id) do nothing;
    select balance into v_balance from public.wallets where user_id = p_user for update;
  end if;

  v_new := v_balance + p_amount;
  if v_new < 0 then
    raise exception 'INSUFFICIENT_BALANCE';
  end if;

  update public.wallets
     set balance      = v_new,
         total_earned = total_earned + (case when p_amount > 0 and p_count_earned then p_amount else 0 end),
         updated_at   = now()
   where user_id = p_user;

  insert into public.wallet_transactions(user_id, amount, balance_after, type, reference_id, description, metadata)
  values (p_user, p_amount, v_new, p_type, p_reference, p_description, coalesce(p_metadata, '{}'::jsonb));

  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Referral code generator
-- ---------------------------------------------------------------------------
create or replace function public._gen_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  loop
    v_code := 'BCP' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.profiles where referral_code = v_code);
  end loop;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------
-- New user handler — creates profile + wallet, resolves referral, pays bonuses.
-- Fired by a trigger on auth.users. The referral code is passed through
-- raw_user_meta_data.referral_code (set by the client at sign-up).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_code   text;
  v_referrer   uuid;
  v_signup_bonus bigint;
  v_ref_reward   bigint;
begin
  v_ref_code := nullif(trim(new.raw_user_meta_data->>'referral_code'), '');

  if v_ref_code is not null then
    select id into v_referrer from public.profiles where referral_code = upper(v_ref_code);
  end if;

  insert into public.profiles(id, email, full_name, avatar_url, referral_code, referred_by)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    public._gen_referral_code(),
    v_referrer
  );

  insert into public.wallets(user_id) values (new.id);
  insert into public.user_roles(user_id, role) values (new.id, 'user') on conflict do nothing;

  -- signup bonus
  v_signup_bonus := public.setting_num('signup_bonus', 0)::bigint;
  if v_signup_bonus > 0 then
    perform public._apply_ledger(new.id, v_signup_bonus, 'signup_bonus', null, 'Welcome bonus');
  end if;

  -- referral reward (self-referral impossible: referrer <> new user by construction)
  if v_referrer is not null and v_referrer <> new.id then
    v_ref_reward := public.setting_num('referral_reward_l1', 0)::bigint;
    insert into public.referrals(referrer_id, referred_id, level, reward_amount)
    values (v_referrer, new.id, 1, v_ref_reward)
    on conflict do nothing;
    if v_ref_reward > 0 then
      perform public._apply_ledger(
        v_referrer, v_ref_reward, 'referral', new.id,
        'Referral reward', jsonb_build_object('referred', new.id)
      );
      insert into public.notifications(user_id, title, body, type, data)
      values (v_referrer, 'New referral joined 🎉',
              'You earned ' || v_ref_reward || ' BCP from a referral.', 'reward',
              jsonb_build_object('referred', new.id));
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- keep profiles.updated_at fresh
create or replace function public._touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public._touch_updated_at();

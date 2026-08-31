-- ============================================================================
-- Apply a referral code after account creation (used by Google sign-in, or when
-- a user enters a code shortly after registering). Idempotent and abuse-guarded:
--   * no-op if the caller was already referred
--   * self-referral rejected
--   * code must belong to an existing active user
-- ============================================================================
create or replace function public.apply_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_referrer uuid;
  v_reward   bigint;
  v_created  timestamptz;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;

  -- only brand-new accounts (within a short grace window) may attach a referrer
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

  v_reward := public.setting_num('referral_reward_l1', 0)::bigint;
  insert into public.referrals(referrer_id, referred_id, level, reward_amount)
  values (v_referrer, v_uid, 1, v_reward)
  on conflict do nothing;

  if v_reward > 0 then
    perform public._apply_ledger(v_referrer, v_reward, 'referral', v_uid, 'Referral reward');
    insert into public.notifications(user_id, title, body, type)
    values (v_referrer, 'New referral joined 🎉',
            'You earned ' || v_reward || ' BCP from a referral.', 'reward');
  end if;

  return jsonb_build_object('ok', true, 'applied', true);
end;
$$;

grant execute on function public.apply_referral_code(text) to authenticated;

-- ============================================================================
-- Optional AdMob Server-Side Verification (SSV) support.
-- The admob-ssv-callback edge function verifies Google's RSA signature, then
-- calls this idempotent RPC (via the service role) to credit the reward exactly
-- once per unique signature. Safe to leave unused; reward_ad() is the default
-- client-confirmed + rate-limited path.
-- ============================================================================
create or replace function public.credit_verified_ad(
  p_user uuid, p_amount bigint, p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_new bigint;
begin
  -- idempotency: the same signature never credits twice
  if exists (select 1 from public.ad_rewards where ssv_signature = p_signature) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  insert into public.ad_rewards(user_id, reward_amount, network, verified, ssv_signature)
  values (p_user, p_amount, 'admob', true, p_signature);

  v_new := public._apply_ledger(p_user, p_amount, 'ad', null, 'Rewarded ad (SSV verified)');
  return jsonb_build_object('ok', true, 'balance', v_new);
end;
$$;

create unique index if not exists uniq_ad_ssv on public.ad_rewards(ssv_signature)
  where ssv_signature is not null;

-- only the service role (edge function) may call this
revoke all on function public.credit_verified_ad(uuid, bigint, text) from public, anon, authenticated;

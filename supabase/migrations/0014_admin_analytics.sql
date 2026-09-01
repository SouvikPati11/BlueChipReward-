-- ============================================================================
-- Admin analytics (server-side date filtering) + rich withdrawal listing
--
--   * admin_analytics(from, to): user/BCP/withdrawal totals, the ad funnel
--     (requests vs impressions vs rewarded completions vs credits), and
--     per-feature reward activity — all computed server-side over the range.
--   * admin_withdrawals(status): withdrawals joined with the requester's
--     name/email/id and the payment method label for the detail view.
-- ============================================================================

create or replace function public.admin_analytics(
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
  v_ads  jsonb;
  v_feat jsonb;
begin
  perform public._assert_admin();

  -- Ad funnel over the range. A row's state is terminal, so a 'credited' row
  -- also counts as an impression and a rewarded completion.
  select jsonb_build_object(
    'requests',   count(*),
    'impressions', count(*) filter (where state in ('impressed','rewarded','credited')),
    'rewarded',    count(*) filter (where state in ('rewarded','credited')),
    'credits',     count(*) filter (where state = 'credited'),
    'credited_bcp', coalesce(sum(reward) filter (where state = 'credited'), 0),
    'by_placement', coalesce((
      select jsonb_object_agg(placement, cnt) from (
        select placement, count(*) filter (where state = 'credited') as cnt
          from public.ad_events
         where created_at >= v_from and created_at <= v_to
         group by placement
      ) p
    ), '{}'::jsonb)
  )
  into v_ads
  from public.ad_events
  where created_at >= v_from and created_at <= v_to;

  -- Per-feature reward activity (positive ledger credits by type over range).
  select coalesce(jsonb_object_agg(t, jsonb_build_object('count', c, 'bcp', s)), '{}'::jsonb)
  into v_feat
  from (
    select type::text as t, count(*) as c, coalesce(sum(amount),0) as s
      from public.wallet_transactions
     where amount > 0 and created_at >= v_from and created_at <= v_to
     group by type
  ) x;

  return jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'total_users', (select count(*) from public.profiles),
    'new_users', (select count(*) from public.profiles
                   where created_at >= v_from and created_at <= v_to),
    'active_users', (select count(distinct user_id) from public.wallet_transactions
                      where created_at >= v_from and created_at <= v_to),
    'bcp_earned', (select coalesce(sum(amount),0) from public.wallet_transactions
                    where amount > 0 and created_at >= v_from and created_at <= v_to),
    'bcp_withdrawn', (select coalesce(sum(amount),0) from public.withdrawals
                       where status = 'paid'
                         and coalesce(processed_at, created_at) >= v_from
                         and coalesce(processed_at, created_at) <= v_to),
    'pending_withdrawals', (select count(*) from public.withdrawals where status = 'pending'),
    'pending_withdrawal_amount', (select coalesce(sum(amount),0) from public.withdrawals where status = 'pending'),
    'ads', v_ads,
    'features', v_feat
  );
end;
$$;
grant execute on function public.admin_analytics(timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Withdrawals with requester + method detail for the admin review screen.
-- ---------------------------------------------------------------------------
create or replace function public.admin_withdrawals(p_status text default 'pending')
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
      'id', w.id,
      'user_id', w.user_id,
      'user_name', p.full_name,
      'user_email', p.email,
      'referral_code', p.referral_code,
      'amount', w.amount,
      'method_key', w.method_key,
      'method_name', coalesce(pm.name, w.method_key),
      'details', w.details,
      'status', w.status,
      'admin_notes', w.admin_notes,
      'created_at', w.created_at,
      'processed_at', w.processed_at,
      'balance', wl.balance
    ) order by w.created_at desc)
    from public.withdrawals w
    join public.profiles p on p.id = w.user_id
    left join public.payment_methods pm on pm.key = w.method_key
    left join public.wallets wl on wl.user_id = w.user_id
    where p_status = 'all' or w.status::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_withdrawals(text) to authenticated;

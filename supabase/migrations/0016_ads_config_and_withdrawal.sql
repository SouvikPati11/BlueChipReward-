-- ============================================================================
-- Ads control model (global + per-section) and withdrawal conversion / fee /
-- unique transaction id. Forward-only, non-destructive.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- ADS SETTINGS (section 17)
--   ads_system_enabled     master switch for ALL ads
--   rewarded_ads_enabled   master switch for rewarded ads
--   banner_ads_enabled     master switch for banner ads (already seeded)
--   ad_gate_<section>      rewarded required for that section (from 0012)
--   banner_<section>       banner shown on that section
-- ---------------------------------------------------------------------------
insert into public.app_settings(key, value, description) values
  ('ads_system_enabled',  'true', 'Master switch for all ads (banner + rewarded)'),
  ('rewarded_ads_enabled','true', 'Master switch for rewarded ads'),
  ('banner_daily',    'true', 'Show banner on Daily Reward'),
  ('banner_scratch',  'true', 'Show banner on Scratch Card'),
  ('banner_mining',   'true', 'Show banner on Mining'),
  ('banner_watch_ads','true', 'Show banner on Watch Ads'),
  ('banner_quiz',     'true', 'Show banner on Daily Quiz'),
  ('banner_tasks',    'true', 'Show banner on Tasks')
on conflict (key) do nothing;

-- Rewarded gate now also respects the global switches.
create or replace function public._ad_gated(p_placement text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ads_system_enabled'), true)
    and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='rewarded_ads_enabled'), true)
    and coalesce((select (value #>> '{}')::boolean from public.app_settings where key='ad_gate_' || p_placement), true);
$$;

-- Effective ad configuration for the client (so the UI knows whether to run the
-- rewarded flow and whether to render a banner per section).
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
  v_sections text[] := array['daily','scratch','mining','watch_ads','quiz','tasks'];
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

-- ============================================================================
-- WITHDRAWAL: per-method conversion, fee, and unique transaction id
-- ============================================================================

-- Per-method conversion rate: `rate` currency units per `rate_base` BCP.
alter table public.payment_methods add column if not exists currency  text   not null default '₹';
alter table public.payment_methods add column if not exists rate      numeric not null default 0;
alter table public.payment_methods add column if not exists rate_base bigint  not null default 1000;

-- Stored breakdown + transaction id on each withdrawal.
alter table public.withdrawals add column if not exists txn_id       text;
alter table public.withdrawals add column if not exists currency     text;
alter table public.withdrawals add column if not exists rate         numeric;
alter table public.withdrawals add column if not exists gross_amount numeric;
alter table public.withdrawals add column if not exists fee_amount   numeric;
alter table public.withdrawals add column if not exists net_amount   numeric;

-- Fee settings.
insert into public.app_settings(key, value, description) values
  ('withdrawal_fee_enabled', 'false', 'Charge a withdrawal fee'),
  ('withdrawal_fee_percent', '0',     'Withdrawal fee percentage (of the converted amount)'),
  ('withdrawal_fee_fixed',   '0',     'Fixed withdrawal fee (in the payout currency)')
on conflict (key) do nothing;

-- Seed sensible default rates on the shipped methods (only if still 0).
update public.payment_methods set currency='₹', rate=95,  rate_base=1000 where key in ('upi','paytm') and rate = 0;
update public.payment_methods set currency='₹', rate=95,  rate_base=1000 where key = 'bank' and rate = 0;
update public.payment_methods set currency='$', rate=1,   rate_base=1000 where key = 'usdt' and rate = 0;

-- Unique transaction id generator + backfill + auto-assign trigger.
create or replace function public._gen_txn_id()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_id text;
begin
  loop
    v_id := 'BCW' || to_char(now(), 'YYMMDD') ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.withdrawals where txn_id = v_id);
  end loop;
  return v_id;
end;
$$;

update public.withdrawals set txn_id = public._gen_txn_id() where txn_id is null;

do $$ begin
  alter table public.withdrawals add constraint withdrawals_txn_id_key unique (txn_id);
exception when duplicate_object then null; end $$;

create or replace function public._withdrawals_set_txn()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.txn_id is null then new.txn_id := public._gen_txn_id(); end if;
  return new;
end;
$$;

drop trigger if exists trg_withdrawals_txn on public.withdrawals;
create trigger trg_withdrawals_txn before insert on public.withdrawals
  for each row execute function public._withdrawals_set_txn();

-- Server-authoritative conversion + fee computation.
create or replace function public._withdrawal_compute(p_method_key text, p_bcp bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pm      public.payment_methods;
  v_gross   numeric;
  v_feeon   boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings where key='withdrawal_fee_enabled'), false);
  v_feepct  numeric := public.setting_num('withdrawal_fee_percent', 0);
  v_feefix  numeric := public.setting_num('withdrawal_fee_fixed', 0);
  v_fee     numeric := 0;
  v_net     numeric;
begin
  select * into v_pm from public.payment_methods where key = p_method_key;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_gross := round((p_bcp::numeric / greatest(v_pm.rate_base, 1)) * v_pm.rate, 2);
  if v_feeon then
    v_fee := round(v_gross * v_feepct / 100.0 + v_feefix, 2);
  end if;
  v_fee := least(v_fee, v_gross);
  v_net := round(v_gross - v_fee, 2);

  return jsonb_build_object(
    'bcp', p_bcp,
    'currency', v_pm.currency,
    'rate', v_pm.rate,
    'rate_base', v_pm.rate_base,
    'gross', v_gross,
    'fee_enabled', v_feeon,
    'fee', v_fee,
    'net', v_net
  );
end;
$$;

-- Read-only quote for the withdraw screen.
create or replace function public.withdrawal_quote(p_method_key text, p_amount bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;
  return public._withdrawal_compute(p_method_key, p_amount);
end;
$$;
grant execute on function public.withdrawal_quote(text, bigint) to authenticated;

-- Replace request_withdrawal to persist the conversion breakdown.
create or replace function public.request_withdrawal(p_amount bigint, p_method_key text, p_details jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_min   bigint;
  v_pm    public.payment_methods;
  v_wd    uuid;
  v_calc  jsonb;
  v_txn   text;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  select * into v_pm from public.payment_methods where key = p_method_key and active;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_min := greatest(public.setting_num('withdrawal_min', 1000)::bigint, v_pm.min_amount);
  if p_amount < v_min then raise exception 'BELOW_MINIMUM'; end if;

  if exists (select 1 from public.withdrawals where user_id = v_uid and status in ('pending','approved')) then
    raise exception 'WITHDRAWAL_IN_PROGRESS';
  end if;

  v_calc := public._withdrawal_compute(p_method_key, p_amount);

  perform public._apply_ledger(v_uid, -p_amount, 'withdrawal_hold', null,
            'Withdrawal request hold', jsonb_build_object('method', p_method_key), false);

  update public.wallets set pending_withdrawal = pending_withdrawal + p_amount where user_id = v_uid;

  insert into public.withdrawals(user_id, amount, method_key, details,
    currency, rate, gross_amount, fee_amount, net_amount)
  values (v_uid, p_amount, p_method_key, coalesce(p_details,'{}'::jsonb),
    v_calc->>'currency', (v_calc->>'rate')::numeric,
    (v_calc->>'gross')::numeric, (v_calc->>'fee')::numeric, (v_calc->>'net')::numeric)
  returning id, txn_id into v_wd, v_txn;

  insert into public.notifications(user_id, title, body, type, data)
  values (v_uid, 'Withdrawal submitted',
          'Your request for ' || p_amount || ' BCP is pending review.', 'withdrawal',
          jsonb_build_object('withdrawal_id', v_wd, 'txn_id', v_txn));

  return jsonb_build_object('ok', true, 'withdrawal_id', v_wd, 'txn_id', v_txn,
                            'breakdown', v_calc);
end;
$$;
grant execute on function public.request_withdrawal(bigint, text, jsonb) to authenticated;

-- Update admin_withdrawals to surface the breakdown + txn id + payment details.
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
      'txn_id', w.txn_id,
      'user_id', w.user_id,
      'user_name', p.full_name,
      'user_email', p.email,
      'referral_code', p.referral_code,
      'amount', w.amount,
      'currency', w.currency,
      'rate', w.rate,
      'gross_amount', w.gross_amount,
      'fee_amount', w.fee_amount,
      'net_amount', w.net_amount,
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

-- Extend admin_save_payment_method to manage conversion rate fields.
-- Drop the prior 7-arg signature so the new one isn't shadowed by overload.
drop function if exists public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int);
create or replace function public.admin_save_payment_method(
  p_id uuid, p_key text, p_name text, p_fields jsonb, p_min_amount bigint,
  p_active boolean, p_position int,
  p_currency text default null, p_rate numeric default null, p_rate_base bigint default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.payment_methods(key, name, fields, min_amount, active, position,
      currency, rate, rate_base)
    values (p_key, p_name, coalesce(p_fields,'[]'::jsonb), coalesce(p_min_amount,0),
      coalesce(p_active,true), coalesce(p_position,0),
      coalesce(p_currency,'₹'), coalesce(p_rate,0), coalesce(p_rate_base,1000))
    on conflict (key) do update
      set name=excluded.name, fields=excluded.fields, min_amount=excluded.min_amount,
          active=excluded.active, position=excluded.position,
          currency=excluded.currency, rate=excluded.rate, rate_base=excluded.rate_base
    returning id into v_id;
  else
    update public.payment_methods
       set key=p_key, name=p_name, fields=coalesce(p_fields,'[]'::jsonb),
           min_amount=coalesce(p_min_amount,0), active=coalesce(p_active,true),
           position=coalesce(p_position,0),
           currency=coalesce(p_currency, currency),
           rate=coalesce(p_rate, rate),
           rate_base=coalesce(p_rate_base, rate_base)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'payment_method.save', 'payment_method', v_id::text,
          jsonb_build_object('key', p_key));
  return v_id;
end;
$$;
grant execute on function
  public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int, text, numeric, bigint)
  to authenticated;

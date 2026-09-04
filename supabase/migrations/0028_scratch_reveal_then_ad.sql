-- ============================================================================
-- 0028  Scratch Card: reveal-the-amount FIRST, then the rewarded ad, then credit.
--
-- New flow (server-authoritative, duplicate-safe):
--   1. scratch_status issues a card; the reward is chosen ON THE SERVER at
--      issue time (random within the rule's Min/Max) and stored hidden.
--   2. scratch_reveal(card_id) — NO ad — exposes that exact amount and marks the
--      card 'revealed' (revealed_at). It does NOT credit anything.
--   3. scratch_claim(card_id, nonce) — verifies the required rewarded ad (unless
--      the Reward-ads master/section is OFF) and ONLY THEN credits the exact
--      revealed amount to the immutable ledger, marking the card 'scratched'.
--
-- Duplicate protection: the 'available' → 'scratched' transition happens under a
-- row lock (FOR UPDATE); a second claim sees 'scratched' and returns idempotently
-- without crediting again. The client never decides the reward.
--
-- A revealed-but-unclaimed card stays status='available' (with revealed_at set),
-- so it is still the user's single outstanding card and cannot be skipped by
-- reloading to get a new card. Forward-only, non-destructive.
-- ============================================================================

alter table public.scratch_cards add column if not exists revealed_at timestamptz;

-- ---------------------------------------------------------------------------
-- scratch_status: returns the outstanding card (available OR already-revealed),
-- the rule's reward RANGE, whether an ad is required, and — only once revealed —
-- the exact amount so the screen can resume the claim step after a reload.
-- ---------------------------------------------------------------------------
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_card   public.scratch_cards;
  v_last   public.scratch_cards;
  v_seq    int;
  v_rule   public.scratch_rules;
  v_prev   public.scratch_rules;
  v_next   timestamptz;
  v_reward bigint;
  v_cap    int := public._scratch_daily_cap();
  v_used   int := 0;
  v_gated  boolean := public._ad_gated('scratch');
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Outstanding card (not yet credited). 'available' covers both un-revealed and
  -- revealed-but-unclaimed (revealed_at set) — the user must finish this one.
  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    v_rule := public._scratch_rule_for(v_card.seq);
    return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
      'card_id', v_card.id, 'seq', v_card.seq,
      'ads_required', v_card.ads_required,
      'ad_required', v_gated,
      'cooldown_seconds', v_card.cooldown_seconds,
      'min_reward', coalesce(v_rule.min_reward, 0),
      'max_reward', coalesce(v_rule.max_reward, 0),
      'revealed', v_card.revealed_at is not null,
      -- The exact amount is exposed only AFTER a reveal, never before.
      'amount', case when v_card.revealed_at is not null then v_card.reward_amount else null end);
  end if;

  -- Cards credited TODAY (UTC) — the day's progression index.
  select count(*) into v_used from public.scratch_cards
    where user_id = v_uid and status = 'scratched'
      and (scratched_at at time zone 'utc')::date = v_today;
  v_used := coalesce(v_used, 0);

  -- Daily cycle complete → come back tomorrow.
  if v_cap > 0 and v_used >= v_cap then
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
      'cycle_complete', true, 'next_cycle_at', public._next_daily_cycle_at(),
      'used_today', v_used, 'remaining_today', 0);
  end if;

  v_seq  := v_used + 1;
  v_rule := public._scratch_rule_for(v_seq);
  if v_rule.id is null then
    return jsonb_build_object('ok', true, 'has_card', false, 'available', false);
  end if;

  -- Timing gate from TODAY's last credited card only.
  select * into v_last from public.scratch_cards
    where user_id = v_uid and status = 'scratched' and scratched_at is not null
      and (scratched_at at time zone 'utc')::date = v_today
    order by scratched_at desc limit 1;
  if found then
    v_prev := public._scratch_rule_for(v_last.seq);
    if v_prev.id is not null and v_rule.id <> v_prev.id and v_seq = v_rule.from_card then
      v_next := v_last.scratched_at + (greatest(v_rule.wait_after_seconds,0) || ' seconds')::interval;
    else
      v_next := v_last.scratched_at + (greatest(v_last.cooldown_seconds,0) || ' seconds')::interval;
    end if;
    if now() < v_next then
      return jsonb_build_object('ok', true, 'has_card', false, 'available', false,
        'next_available_at', v_next,
        'min_reward', v_rule.min_reward, 'max_reward', v_rule.max_reward);
    end if;
  end if;

  -- Issue the next card. Reward is decided server-side now and kept HIDDEN
  -- (not returned) until scratch_reveal.
  v_reward := (v_rule.min_reward
               + floor(random() * (greatest(v_rule.max_reward, v_rule.min_reward)
                                    - v_rule.min_reward + 1)))::bigint;
  insert into public.scratch_cards(user_id, reward_amount, source, seq,
      ads_required, search_delay_seconds, cooldown_seconds)
  values (v_uid, v_reward, 'rule', v_seq,
      greatest(v_rule.ads_required,0), 0, greatest(v_rule.cooldown_seconds,0))
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'available', true,
    'card_id', v_card.id, 'seq', v_card.seq,
    'ads_required', v_card.ads_required,
    'ad_required', v_gated,
    'cooldown_seconds', v_card.cooldown_seconds,
    'min_reward', v_rule.min_reward, 'max_reward', v_rule.max_reward,
    'revealed', false, 'amount', null,
    'remaining_today', case when v_cap > 0 then greatest(v_cap - v_used, 0) else null end);
end;
$$;
grant execute on function public.scratch_status() to authenticated;

-- ---------------------------------------------------------------------------
-- scratch_reveal(card_id): expose the exact server-decided amount and mark the
-- card revealed. NO ad, NO credit. Idempotent.
-- (Replaces the previous scratch_reveal(uuid, uuid[]) which credited on reveal.)
-- ---------------------------------------------------------------------------
drop function if exists public.scratch_reveal(uuid, uuid[]);
create or replace function public.scratch_reveal(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;

  -- Already credited → return the amount idempotently (no state change).
  if v_card.status = 'scratched' then
    return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
      'credited', true, 'ad_required', public._ad_gated('scratch'));
  end if;

  -- Mark revealed once; keep the same revealed_at on repeat calls.
  if v_card.revealed_at is null then
    update public.scratch_cards set revealed_at = now() where id = v_card.id;
  end if;

  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
    'revealed', true, 'credited', false,
    'ad_required', public._ad_gated('scratch'));
end;
$$;
grant execute on function public.scratch_reveal(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- scratch_claim(card_id, nonce): verify the rewarded ad (when gated) and credit
-- the exact revealed amount. Duplicate-safe. When the Reward-ads master/section
-- is OFF, no ad is required and the reward is credited directly.
-- ---------------------------------------------------------------------------
create or replace function public.scratch_claim(p_card_id uuid, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
  v_bal  bigint;
  v_new  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;

  -- Already credited → idempotent success, never a second credit.
  if v_card.status = 'scratched' then
    select balance into v_bal from public.wallets where user_id = v_uid;
    return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
      'balance', coalesce(v_bal, 0), 'already', true);
  end if;

  -- Must be revealed first (the user has seen the amount).
  if v_card.revealed_at is null then raise exception 'NOT_REVEALED'; end if;

  -- Ad requirement is authoritative on the server: gated → require + consume a
  -- completed rewarded nonce; ungated (master/section OFF) → no ad required.
  if public._ad_gated('scratch') then
    if p_nonce is null then raise exception 'AD_REQUIRED'; end if;
    perform public._consume_ad(v_uid, 'scratch', p_nonce);
  elsif p_nonce is not null then
    perform public._consume_ad(v_uid, 'scratch', p_nonce);
  end if;

  -- Commit the credit and close the card (the lock above prevents double credit).
  update public.scratch_cards set status = 'scratched', scratched_at = now()
   where id = v_card.id;
  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id,
                                'Scratch card reward');

  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount,
    'balance', v_new, 'already', false);
end;
$$;
grant execute on function public.scratch_claim(uuid, uuid) to authenticated;

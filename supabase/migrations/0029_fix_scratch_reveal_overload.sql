-- ============================================================================
-- 0029  Fix ambiguous scratch_reveal() overloads.
--
-- History left more than one scratch_reveal in the database:
--   * 0012 created scratch_reveal(p_card_id uuid, p_nonce uuid default null)
--   * 0023/0024 added the overload scratch_reveal(p_card_id uuid, p_nonces uuid[])
--   * 0028 dropped ONLY the uuid[] overload and added scratch_reveal(p_card_id uuid)
-- The 0012 scalar (uuid, uuid) overload was never dropped, so a one-argument
-- call (p_card_id only) matches BOTH scratch_reveal(uuid) and
-- scratch_reveal(uuid, uuid default null) → PostgREST/Postgres raises
-- "Could not choose the best candidate function ...".
--
-- This migration removes EVERY scratch_reveal overload (whatever a given
-- database happens to have) and recreates only the intended single-argument
-- reveal RPC, so the flow stays: Scratch → reveal exact BCP → rewarded ad
-- (scratch_claim) → verify → credit. Forward-only, non-destructive to data.
-- ============================================================================

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'scratch_reveal'
  loop
    execute 'drop function ' || r.sig::text;
  end loop;
end $$;

-- The single intended reveal RPC (identical to 0028): exposes the exact
-- server-decided amount and marks the card revealed. NO ad, NO credit.
-- Idempotent. Crediting happens only in scratch_claim after the rewarded ad.
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

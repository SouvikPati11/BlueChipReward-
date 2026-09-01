-- ============================================================================
-- Invite milestone system (dedicated; replaces the old 'invite' task type)
--
--   * Milestones reward a user for reaching N successful referrals (e.g. 5, 10,
--     20 invites → BCP). Fully admin-managed (CRUD + enable/disable + verify mode).
--   * auto_verify = true  → the server checks the user's real referral count and
--                            credits immediately, exactly once.
--   * auto_verify = false → the user uploads screenshot proof; an admin approves
--                            or rejects; credit happens exactly once on approval.
--   * Every credit flows through the immutable ledger (type 'invite_milestone').
--
-- The legacy seeded 'invite' task is deactivated here. The task_type enum value
-- is left in place (Postgres can't drop enum values safely) but is no longer
-- offered in the admin task editor.
-- ============================================================================

-- Distinct ledger type for milestone rewards (safe, additive).
alter type ledger_type add value if not exists 'invite_milestone';

-- Retire the old invite-type task so it no longer shows in the Tasks list.
update public.tasks set active = false where type = 'invite';

-- ---------------------------------------------------------------------------
-- Claim state
-- ---------------------------------------------------------------------------
do $$ begin
  create type invite_claim_state as enum ('pending', 'credited', 'rejected');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Milestone definitions (admin-managed)
-- ---------------------------------------------------------------------------
create table if not exists public.invite_milestones (
  id          uuid primary key default gen_random_uuid(),
  threshold   int not null,                 -- referrals required
  reward      bigint not null,
  auto_verify boolean not null default true,
  active      boolean not null default true,
  position    int not null default 0,
  created_at  timestamptz not null default now(),
  unique (threshold)
);

-- ---------------------------------------------------------------------------
-- Per-user milestone claims (one row per user+milestone; credited once)
-- ---------------------------------------------------------------------------
create table if not exists public.invite_milestone_claims (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  milestone_id uuid not null references public.invite_milestones(id) on delete cascade,
  state        invite_claim_state not null default 'pending',
  reward       bigint not null default 0,
  proof        jsonb not null default '{}'::jsonb,   -- { "screenshot_url": "..." }
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid references public.profiles(id),
  unique (user_id, milestone_id)
);
create index if not exists idx_inv_claims_state on public.invite_milestone_claims(state, created_at desc);
create index if not exists idx_inv_claims_user on public.invite_milestone_claims(user_id);

alter table public.invite_milestones enable row level security;
alter table public.invite_milestone_claims enable row level security;

-- Milestone definitions are public config (read-only to clients).
do $$ begin
  create policy invite_milestones_read on public.invite_milestones
    for select using (auth.uid() is not null);
exception when duplicate_object then null; end $$;

-- Users read their own claims; admins read all.
do $$ begin
  create policy invite_claims_self on public.invite_milestone_claims
    for select using (user_id = auth.uid() or public.is_admin());
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- The user's verified referral count (successful direct referrals only).
-- ---------------------------------------------------------------------------
create or replace function public._invite_count(p_uid uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.referrals where referrer_id = p_uid and level = 1;
$$;

-- ---------------------------------------------------------------------------
-- Overview for the current user: each active milestone + progress + claim state.
-- ---------------------------------------------------------------------------
create or replace function public.invite_milestones_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  v_count := public._invite_count(v_uid);

  return jsonb_build_object(
    'invite_count', v_count,
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'threshold', m.threshold,
        'reward', m.reward,
        'auto_verify', m.auto_verify,
        'reached', v_count >= m.threshold,
        'state', coalesce(c.state::text, 'none'),
        'claimable', (v_count >= m.threshold and c.id is null)
      ) order by m.threshold)
      from public.invite_milestones m
      left join public.invite_milestone_claims c
        on c.milestone_id = m.id and c.user_id = v_uid
      where m.active
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.invite_milestones_overview() to authenticated;

-- ---------------------------------------------------------------------------
-- Claim a milestone.
--   auto_verify  → verify count server-side and credit immediately (once).
--   manual       → require a screenshot url; create a pending claim for review.
-- Idempotent: a second call returns the existing claim's state.
-- ---------------------------------------------------------------------------
create or replace function public.claim_invite_milestone(
  p_milestone_id uuid,
  p_proof_url    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_m      public.invite_milestones%rowtype;
  v_count  int;
  v_existing public.invite_milestone_claims%rowtype;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_m from public.invite_milestones where id = p_milestone_id;
  if not found or not v_m.active then raise exception 'MILESTONE_UNAVAILABLE'; end if;

  -- already claimed?
  select * into v_existing from public.invite_milestone_claims
    where user_id = v_uid and milestone_id = p_milestone_id;
  if found then
    return jsonb_build_object('ok', true, 'state', v_existing.state, 'already', true);
  end if;

  v_count := public._invite_count(v_uid);
  if v_count < v_m.threshold then
    raise exception 'MILESTONE_NOT_REACHED';
  end if;

  if v_m.auto_verify then
    -- credit immediately, exactly once (unique constraint guards races)
    insert into public.invite_milestone_claims(user_id, milestone_id, state, reward)
    values (v_uid, p_milestone_id, 'credited', v_m.reward)
    on conflict (user_id, milestone_id) do nothing;
    if not found then
      select state into v_existing.state from public.invite_milestone_claims
        where user_id = v_uid and milestone_id = p_milestone_id;
      return jsonb_build_object('ok', true, 'state', v_existing.state, 'already', true);
    end if;
    if v_m.reward > 0 then
      perform public._apply_ledger(
        v_uid, v_m.reward, 'invite_milestone', p_milestone_id,
        'Invite milestone (' || v_m.threshold || ' invites)',
        jsonb_build_object('threshold', v_m.threshold));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_uid, 'Invite milestone reached 🎉',
              'You earned ' || v_m.reward || ' BCP for inviting ' || v_m.threshold || ' friends.',
              'reward', jsonb_build_object('milestone', p_milestone_id));
    end if;
    return jsonb_build_object('ok', true, 'state', 'credited');
  else
    -- manual review: proof required
    if nullif(trim(coalesce(p_proof_url, '')), '') is null then
      raise exception 'PROOF_REQUIRED';
    end if;
    insert into public.invite_milestone_claims(user_id, milestone_id, state, reward, proof)
    values (v_uid, p_milestone_id, 'pending', v_m.reward,
            jsonb_build_object('screenshot_url', trim(p_proof_url)))
    on conflict (user_id, milestone_id) do nothing;
    return jsonb_build_object('ok', true, 'state', 'pending');
  end if;
end;
$$;
grant execute on function public.claim_invite_milestone(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: list milestone claims for review.
-- ---------------------------------------------------------------------------
create or replace function public.admin_invite_claims(p_status text default 'pending')
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
      'id', c.id,
      'user_id', c.user_id,
      'user_email', p.email,
      'user_name', p.full_name,
      'milestone_id', c.milestone_id,
      'threshold', m.threshold,
      'reward', c.reward,
      'state', c.state,
      'proof', c.proof,
      'invite_count', public._invite_count(c.user_id),
      'created_at', c.created_at
    ) order by c.created_at desc)
    from public.invite_milestone_claims c
    join public.profiles p on p.id = c.user_id
    join public.invite_milestones m on m.id = c.milestone_id
    where p_status = 'all' or c.state::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_invite_claims(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: approve/reject a pending (manual) milestone claim. Credits exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_invite_claim(p_claim_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_c     public.invite_milestone_claims%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;

  select * into v_c from public.invite_milestone_claims where id = p_claim_id for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  if v_c.state <> 'pending' then
    return jsonb_build_object('ok', true, 'already', v_c.state);
  end if;

  if p_approve then
    update public.invite_milestone_claims
       set state = 'credited', reviewed_at = now(), reviewed_by = v_admin
     where id = p_claim_id;
    if v_c.reward > 0 then
      perform public._apply_ledger(
        v_c.user_id, v_c.reward, 'invite_milestone', v_c.milestone_id,
        'Invite milestone (admin approved)',
        jsonb_build_object('milestone', v_c.milestone_id));
      insert into public.notifications(user_id, title, body, type, data)
      values (v_c.user_id, 'Invite milestone approved 🎉',
              'You earned ' || v_c.reward || ' BCP.', 'reward',
              jsonb_build_object('milestone', v_c.milestone_id));
    end if;
  else
    update public.invite_milestone_claims
       set state = 'rejected', reviewed_at = now(), reviewed_by = v_admin
     where id = p_claim_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin,
          case when p_approve then 'invite_claim_approve' else 'invite_claim_reject' end,
          'invite_milestone_claim', p_claim_id::text,
          jsonb_build_object('user', v_c.user_id, 'milestone', v_c.milestone_id));

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_resolve_invite_claim(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin CRUD for milestones.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_invite_milestone(
  p_id uuid, p_threshold int, p_reward bigint,
  p_auto_verify boolean, p_active boolean, p_position int
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_threshold is null or p_threshold < 1 then raise exception 'INVALID_THRESHOLD'; end if;

  if v_id is null then
    insert into public.invite_milestones(threshold, reward, auto_verify, active, position)
    values (p_threshold, p_reward, p_auto_verify, p_active, coalesce(p_position, 0))
    on conflict (threshold) do update
      set reward = excluded.reward, auto_verify = excluded.auto_verify,
          active = excluded.active, position = excluded.position
    returning id into v_id;
  else
    update public.invite_milestones
       set threshold = p_threshold, reward = p_reward, auto_verify = p_auto_verify,
           active = p_active, position = coalesce(p_position, 0)
     where id = v_id;
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'invite_milestone.save', 'invite_milestone', v_id::text,
          jsonb_build_object('threshold', p_threshold, 'reward', p_reward));
  return v_id;
end;
$$;

create or replace function public.admin_delete_invite_milestone(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  delete from public.invite_milestones where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'invite_milestone.delete', 'invite_milestone', p_id::text, '{}'::jsonb);
end;
$$;

grant execute on function
  public.admin_save_invite_milestone(uuid, int, bigint, boolean, boolean, int),
  public.admin_delete_invite_milestone(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Storage bucket for milestone proof screenshots (private; per-user folder).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('proofs', 'proofs', false)
on conflict (id) do nothing;

-- Users may upload/read their own proofs (path prefix = their uid); admins read all.
do $$ begin
  create policy proofs_insert_own on storage.objects
    for insert to authenticated
    with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy proofs_read_own on storage.objects
    for select to authenticated
    using (bucket_id = 'proofs'
           and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Seed default milestones (5 / 10 / 20 invites). Auto-verified by default.
-- ---------------------------------------------------------------------------
insert into public.invite_milestones(threshold, reward, auto_verify, active, position) values
  (5,  500,  true, true, 0),
  (10, 1200, true, true, 1),
  (20, 3000, true, true, 2)
on conflict (threshold) do nothing;

-- ============================================================================
-- Task proof methods (screenshot / username-link) + per-task ad requirement.
-- Forward-only, non-destructive. Existing tasks default to proof_method 'none'
-- (behaviour unchanged: auto-verify rewards immediately, others go pending).
-- ============================================================================

alter table public.tasks add column if not exists proof_method      text    not null default 'none'; -- none | screenshot | text
alter table public.tasks add column if not exists proof_instruction text;   -- shown to the user for the 'text' method
alter table public.tasks add column if not exists requires_ad       boolean not null default false;

-- ---------------------------------------------------------------------------
-- submit_task with proof validation + optional rewarded-ad gate.
-- ---------------------------------------------------------------------------
create or replace function public.submit_task(
  p_task_id uuid, p_proof jsonb default '{}'::jsonb, p_nonce uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_task   public.tasks;
  v_comp   public.task_completions;
  v_state  task_state;
  v_reward bigint := null;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_task from public.tasks where id = p_task_id and active;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;

  select * into v_comp from public.task_completions where task_id = p_task_id and user_id = v_uid;
  if found and v_comp.state in ('verified','rewarded','pending') then
    raise exception 'TASK_ALREADY_DONE';
  end if;

  -- Optional rewarded-ad requirement (honours the section gate + global switch).
  if v_task.requires_ad then
    perform public._consume_ad(v_uid, 'tasks', p_nonce);
  end if;

  -- Proof validation for manual tasks.
  if not v_task.auto_verify then
    if v_task.proof_method = 'screenshot'
       and nullif(trim(coalesce(p_proof->>'screenshot_url','')), '') is null then
      raise exception 'PROOF_REQUIRED';
    elsif v_task.proof_method = 'text'
       and nullif(trim(coalesce(p_proof->>'text','')), '') is null then
      raise exception 'PROOF_REQUIRED';
    end if;
  end if;

  if v_task.auto_verify then
    v_state := 'rewarded'; v_reward := v_task.reward;
  else
    v_state := 'pending';
  end if;

  insert into public.task_completions(task_id, user_id, state, proof, reward)
  values (p_task_id, v_uid, v_state, coalesce(p_proof,'{}'::jsonb), v_reward)
  on conflict (task_id, user_id)
    do update set state = excluded.state, proof = excluded.proof,
                  reward = excluded.reward, created_at = now();

  if v_state = 'rewarded' then
    v_new := public._apply_ledger(v_uid, v_task.reward, 'task', p_task_id, 'Task: ' || v_task.title);
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'state', v_state, 'reward', coalesce(v_reward,0), 'balance', v_new);
end;
$$;
grant execute on function public.submit_task(uuid, jsonb, uuid) to authenticated;
-- retire the 2-arg signature so callers use the proof-aware one
drop function if exists public.submit_task(uuid, jsonb);

-- ---------------------------------------------------------------------------
-- admin_save_task gains proof_method / proof_instruction / requires_ad.
-- Drop the previous 10-arg signature so it isn't shadowed.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_save_task(uuid, text, text, task_type, bigint, text, text, boolean, boolean, int);
create or replace function public.admin_save_task(
  p_id uuid, p_title text, p_description text, p_type task_type, p_reward bigint,
  p_action_url text, p_instructions text, p_auto_verify boolean, p_active boolean, p_position int,
  p_proof_method text default 'none', p_proof_instruction text default null,
  p_requires_ad boolean default false)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid := p_id;
begin
  perform public._assert_admin();
  if v_id is null then
    insert into public.tasks(title, description, type, reward, action_url, instructions,
      auto_verify, active, position, proof_method, proof_instruction, requires_ad)
    values (p_title, p_description, p_type, p_reward, p_action_url, p_instructions,
      coalesce(p_auto_verify,false), coalesce(p_active,true), coalesce(p_position,0),
      coalesce(p_proof_method,'none'), p_proof_instruction, coalesce(p_requires_ad,false))
    returning id into v_id;
  else
    update public.tasks
       set title=p_title, description=p_description, type=p_type, reward=p_reward,
           action_url=p_action_url, instructions=p_instructions,
           auto_verify=coalesce(p_auto_verify,false), active=coalesce(p_active,true),
           position=coalesce(p_position,0), proof_method=coalesce(p_proof_method,'none'),
           proof_instruction=p_proof_instruction, requires_ad=coalesce(p_requires_ad,false)
     where id=v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (auth.uid(), 'task.save', 'task', v_id::text, jsonb_build_object('title', p_title));
  return v_id;
end;
$$;
grant execute on function
  public.admin_save_task(uuid, text, text, task_type, bigint, text, text, boolean, boolean, int, text, text, boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: task submissions awaiting review (with user + task + proof detail).
-- ---------------------------------------------------------------------------
create or replace function public.admin_task_submissions(p_status text default 'pending')
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
      'id', c.id,
      'user_id', c.user_id,
      'user_name', p.full_name,
      'user_email', p.email,
      'task_id', t.id,
      'task_title', t.title,
      'reward', t.reward,
      'proof_method', t.proof_method,
      'proof_instruction', t.proof_instruction,
      'proof', c.proof,
      'state', c.state,
      'created_at', c.created_at
    ) order by c.created_at desc)
    from public.task_completions c
    join public.tasks t on t.id = c.task_id
    join public.profiles p on p.id = c.user_id
    where p_status = 'all' or c.state::text = p_status
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_task_submissions(text) to authenticated;

-- ============================================================================
-- Admin RPCs — all gate on public.is_admin(). Never callable by regular users.
-- ============================================================================

create or replace function public._assert_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'FORBIDDEN';
  end if;
end;
$$;

-- --- Withdrawals ------------------------------------------------------------
create or replace function public.admin_process_withdrawal(
  p_id uuid, p_status withdrawal_status, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_wd    public.withdrawals;
begin
  perform public._assert_admin();

  select * into v_wd from public.withdrawals where id = p_id for update;
  if not found then raise exception 'WITHDRAWAL_NOT_FOUND'; end if;
  if v_wd.status in ('rejected','paid') then raise exception 'ALREADY_FINALIZED'; end if;

  if p_status = 'rejected' then
    -- refund the held balance
    perform public._apply_ledger(v_wd.user_id, v_wd.amount, 'withdrawal_refund', v_wd.id,
              'Withdrawal rejected — refund', '{}'::jsonb, false);
    update public.wallets
       set pending_withdrawal = greatest(pending_withdrawal - v_wd.amount, 0)
     where user_id = v_wd.user_id;

  elsif p_status = 'paid' then
    -- money leaves the platform: clear the hold, record it as withdrawn
    update public.wallets
       set pending_withdrawal = greatest(pending_withdrawal - v_wd.amount, 0),
           total_withdrawn    = total_withdrawn + v_wd.amount
     where user_id = v_wd.user_id;
  end if;

  update public.withdrawals
     set status = p_status, admin_notes = coalesce(p_notes, admin_notes),
         processed_at = now(), processed_by = v_admin
   where id = p_id;

  insert into public.notifications(user_id, title, body, type, data)
  values (v_wd.user_id, 'Withdrawal ' || p_status,
          'Your withdrawal of ' || v_wd.amount || ' BCP is now ' || p_status || '.',
          'withdrawal', jsonb_build_object('withdrawal_id', p_id, 'status', p_status));

  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'withdrawal.' || p_status, 'withdrawal', p_id::text,
          jsonb_build_object('amount', v_wd.amount));

  return jsonb_build_object('ok', true);
end;
$$;

-- --- Task review ------------------------------------------------------------
create or replace function public.admin_review_task(
  p_completion_id uuid, p_approve boolean, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_comp  public.task_completions;
  v_task  public.tasks;
  v_new   bigint;
begin
  perform public._assert_admin();

  select * into v_comp from public.task_completions where id = p_completion_id for update;
  if not found then raise exception 'COMPLETION_NOT_FOUND'; end if;
  if v_comp.state in ('rewarded','rejected') then raise exception 'ALREADY_REVIEWED'; end if;

  select * into v_task from public.tasks where id = v_comp.task_id;

  if p_approve then
    update public.task_completions
       set state = 'rewarded', reward = v_task.reward, reviewed_at = now(), reviewed_by = v_admin
     where id = p_completion_id;
    v_new := public._apply_ledger(v_comp.user_id, v_task.reward, 'task', v_task.id, 'Task: ' || v_task.title);
    insert into public.notifications(user_id, title, body, type)
    values (v_comp.user_id, 'Task approved', 'You earned ' || v_task.reward || ' BCP.', 'task');
  else
    update public.task_completions
       set state = 'rejected', reviewed_at = now(), reviewed_by = v_admin, proof = proof || jsonb_build_object('notes', p_notes)
     where id = p_completion_id;
    insert into public.notifications(user_id, title, body, type)
    values (v_comp.user_id, 'Task rejected', coalesce(p_notes, 'Your task submission was not approved.'), 'task');
  end if;

  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, case when p_approve then 'task.approve' else 'task.reject' end, 'task_completion', p_completion_id::text);

  return jsonb_build_object('ok', true);
end;
$$;

-- --- Balance adjustment -----------------------------------------------------
create or replace function public.admin_adjust_balance(p_user uuid, p_amount bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid(); v_new bigint;
begin
  perform public._assert_admin();
  v_new := public._apply_ledger(p_user, p_amount, 'admin_adjustment', null,
             coalesce(p_reason, 'Admin adjustment'), jsonb_build_object('by', v_admin),
             p_amount > 0);
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'balance.adjust', 'user', p_user::text,
          jsonb_build_object('amount', p_amount, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'balance', v_new);
end;
$$;

-- --- User status ------------------------------------------------------------
create or replace function public.admin_set_user_status(p_user uuid, p_status user_status)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  update public.profiles set status = p_status where id = p_user;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'user.status', 'user', p_user::text, jsonb_build_object('status', p_status));
  return jsonb_build_object('ok', true);
end;
$$;

-- --- Settings ---------------------------------------------------------------
create or replace function public.admin_set_setting(p_key text, p_value jsonb, p_desc text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  insert into public.app_settings(key, value, description, updated_by, updated_at)
  values (p_key, p_value, p_desc, v_admin, now())
  on conflict (key) do update
    set value = excluded.value,
        description = coalesce(excluded.description, public.app_settings.description),
        updated_by = v_admin, updated_at = now();
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, 'setting.update', 'setting', p_key, jsonb_build_object('value', p_value));
  return jsonb_build_object('ok', true);
end;
$$;

-- --- Broadcast notification -------------------------------------------------
create or replace function public.admin_broadcast(p_title text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  insert into public.notifications(user_id, title, body, type)
  values (null, p_title, p_body, 'announcement');
  insert into public.audit_logs(actor_id, action, entity) values (v_admin, 'broadcast', 'notification');
  return jsonb_build_object('ok', true);
end;
$$;

-- --- Dashboard stats --------------------------------------------------------
create or replace function public.admin_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._assert_admin();
  return jsonb_build_object(
    'ok', true,
    'users', (select count(*) from public.profiles),
    'active_users', (select count(*) from public.profiles where status = 'active'),
    'total_balance', (select coalesce(sum(balance),0) from public.wallets),
    'total_earned', (select coalesce(sum(total_earned),0) from public.wallets),
    'pending_withdrawals', (select count(*) from public.withdrawals where status = 'pending'),
    'pending_withdrawal_amount', (select coalesce(sum(amount),0) from public.withdrawals where status = 'pending'),
    'pending_tasks', (select count(*) from public.task_completions where state = 'pending'),
    'active_mining', (select count(*) from public.mining_sessions where status = 'active')
  );
end;
$$;

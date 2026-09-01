-- ============================================================================
-- Admin content-management RPCs. All are SECURITY DEFINER and gate on
-- _assert_admin(); they never widen what a normal user can do. Every mutation
-- is written to audit_logs. No RLS policy is relaxed.
-- ============================================================================

-- ---- Tasks -----------------------------------------------------------------
create or replace function public.admin_save_task(
  p_id uuid,
  p_title text,
  p_description text,
  p_type task_type,
  p_reward bigint,
  p_action_url text,
  p_instructions text,
  p_auto_verify boolean,
  p_active boolean,
  p_position int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  if p_id is null then
    insert into public.tasks(title, description, type, reward, action_url,
                             instructions, auto_verify, active, position)
    values (p_title, p_description, p_type, p_reward, p_action_url,
            p_instructions, p_auto_verify, coalesce(p_active,true), coalesce(p_position,0))
    returning id into v_id;
  else
    update public.tasks set
      title = p_title, description = p_description, type = p_type,
      reward = p_reward, action_url = p_action_url, instructions = p_instructions,
      auto_verify = p_auto_verify, active = p_active, position = p_position
    where id = p_id returning id into v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, case when p_id is null then 'task.create' else 'task.update' end, 'task', v_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_delete_task(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.tasks where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'task.delete', 'task', p_id::text);
  return jsonb_build_object('ok', true);
end; $$;

-- ---- Quiz ------------------------------------------------------------------
create or replace function public.admin_create_quiz(
  p_quiz_date date, p_title text, p_reward bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  insert into public.quizzes(quiz_date, title, reward)
  values (p_quiz_date, p_title, p_reward)
  on conflict (quiz_date) do update set title = excluded.title, reward = excluded.reward
  returning id into v_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.upsert', 'quiz', v_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_add_quiz_question(
  p_quiz_id uuid, p_question text, p_options jsonb, p_correct_index int, p_position int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) < 2 then
    raise exception 'INVALID_OPTIONS';
  end if;
  if p_correct_index < 0 or p_correct_index >= jsonb_array_length(p_options) then
    raise exception 'INVALID_CORRECT_INDEX';
  end if;
  insert into public.quiz_questions(quiz_id, question, options, correct_index, position)
  values (p_quiz_id, p_question, p_options, p_correct_index, coalesce(p_position,0))
  returning id into v_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.question.add', 'quiz', p_quiz_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_delete_quiz_question(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.quiz_questions where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'quiz.question.delete', 'quiz_question', p_id::text);
  return jsonb_build_object('ok', true);
end; $$;

-- ---- Payment methods -------------------------------------------------------
create or replace function public.admin_save_payment_method(
  p_id uuid, p_key text, p_name text, p_fields jsonb,
  p_min_amount bigint, p_active boolean, p_position int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_id uuid;
begin
  perform public._assert_admin();
  if p_id is null then
    insert into public.payment_methods(key, name, fields, min_amount, active, position)
    values (p_key, p_name, coalesce(p_fields,'[]'::jsonb), coalesce(p_min_amount,0),
            coalesce(p_active,true), coalesce(p_position,0))
    returning id into v_id;
  else
    update public.payment_methods set
      key = p_key, name = p_name, fields = coalesce(p_fields,'[]'::jsonb),
      min_amount = p_min_amount, active = p_active, position = p_position
    where id = p_id returning id into v_id;
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'payment_method.save', 'payment_method', v_id::text);
  return jsonb_build_object('ok', true, 'id', v_id);
end; $$;

create or replace function public.admin_delete_payment_method(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid();
begin
  perform public._assert_admin();
  delete from public.payment_methods where id = p_id;
  insert into public.audit_logs(actor_id, action, entity, entity_id)
  values (v_admin, 'payment_method.delete', 'payment_method', p_id::text);
  return jsonb_build_object('ok', true);
end; $$;

-- ---- Admin role management -------------------------------------------------
-- Grant/revoke admin. Guard: never remove the last remaining admin.
create or replace function public.admin_set_admin(p_user uuid, p_grant boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_admin uuid := auth.uid(); v_admin_count int;
begin
  perform public._assert_admin();
  if p_grant then
    insert into public.user_roles(user_id, role) values (p_user, 'admin')
    on conflict do nothing;
  else
    select count(*) into v_admin_count from public.user_roles where role = 'admin';
    if v_admin_count <= 1 then raise exception 'CANNOT_REMOVE_LAST_ADMIN'; end if;
    delete from public.user_roles where user_id = p_user and role = 'admin';
  end if;
  insert into public.audit_logs(actor_id, action, entity, entity_id, meta)
  values (v_admin, case when p_grant then 'role.grant_admin' else 'role.revoke_admin' end,
          'user', p_user::text, jsonb_build_object('grant', p_grant));
  return jsonb_build_object('ok', true);
end; $$;

grant execute on function
  public.admin_save_task(uuid, text, text, task_type, bigint, text, text, boolean, boolean, int),
  public.admin_delete_task(uuid),
  public.admin_create_quiz(date, text, bigint),
  public.admin_add_quiz_question(uuid, text, jsonb, int, int),
  public.admin_delete_quiz_question(uuid),
  public.admin_save_payment_method(uuid, text, text, jsonb, bigint, boolean, int),
  public.admin_delete_payment_method(uuid),
  public.admin_set_admin(uuid, boolean)
  to authenticated;

-- ============================================================================
-- 0022  Push token unregister (sign-out / device change) + push audit helper
-- ----------------------------------------------------------------------------
-- Forward-only, non-destructive. Complements 0021's device_tokens table and
-- register_device_token(). The `push` edge function does invalid-token cleanup
-- automatically (FCM UNREGISTERED → delete); this RPC lets the client remove
-- its own token deliberately on sign-out, before the session ends.
-- ============================================================================

-- Redefine admin_send_notification to stamp a shared notification id into the
-- in-app rows' data and return it, so the push layer can use the SAME id for
-- de-duplication / collapsing (one logical notification, one banner).
create or replace function public.admin_send_notification(
  p_title text, p_body text,
  p_target text default 'all', p_user_ids uuid[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_count int := 0;
  v_id uuid := gen_random_uuid();
  v_data jsonb;
begin
  perform public._assert_admin();
  if coalesce(trim(p_title),'') = '' then raise exception 'TITLE_REQUIRED'; end if;

  v_data := jsonb_build_object('custom', true, 'id', v_id::text,
                               'route', '/notifications');

  if p_target = 'specific' then
    if p_user_ids is null or array_length(p_user_ids, 1) is null then
      raise exception 'NO_RECIPIENTS';
    end if;
    insert into public.notifications(user_id, title, body, type, data)
    select u, p_title, p_body, 'announcement', v_data
      from unnest(p_user_ids) as u
      where exists (select 1 from public.profiles p where p.id = u);
    get diagnostics v_count = row_count;
  else
    insert into public.notifications(user_id, title, body, type, data)
    values (null, p_title, p_body, 'announcement', v_data);
    v_count := (select count(*) from public.profiles where status = 'active');
  end if;

  insert into public.custom_notifications(id, title, body, target, recipients, sent_by)
  values (v_id, p_title, p_body,
          case when p_target = 'specific' then 'specific' else 'all' end,
          v_count, v_admin);

  insert into public.audit_logs(actor_id, action, entity, meta)
  values (v_admin, 'notification.send', 'custom_notification',
          jsonb_build_object('target', p_target, 'recipients', v_count));

  return jsonb_build_object('ok', true, 'recipients', v_count, 'id', v_id::text);
end;
$$;
grant execute on function public.admin_send_notification(text, text, text, uuid[]) to authenticated;

create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return; end if;
  if coalesce(p_token,'') = '' then
    -- No token given: clear all of this user's tokens (full sign-out cleanup).
    delete from public.device_tokens where user_id = v_uid;
  else
    delete from public.device_tokens where user_id = v_uid and token = p_token;
  end if;
end;
$$;
grant execute on function public.unregister_device_token(text) to authenticated;

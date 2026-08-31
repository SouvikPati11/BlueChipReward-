-- ============================================================================
-- Earning RPCs — every function is SECURITY DEFINER and server-authoritative.
-- The client sends intent only; amounts, eligibility and limits are decided here.
-- All return a jsonb envelope: { ok, ... } or raise a coded exception.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- DAILY REWARD
-- ---------------------------------------------------------------------------
create or replace function public.claim_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_last   record;
  v_streak int := 1;
  v_base   bigint;
  v_step   bigint;
  v_max    int;
  v_amount bigint;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- one claim per UTC day
  if exists (select 1 from public.daily_reward_claims where user_id = v_uid and claim_date = v_today) then
    raise exception 'ALREADY_CLAIMED';
  end if;

  select * into v_last from public.daily_reward_claims
    where user_id = v_uid order by claim_date desc limit 1;

  if found and v_last.claim_date = v_today - 1 then
    v_streak := v_last.streak + 1;
  end if;

  v_base := public.setting_num('daily_reward_base', 50)::bigint;
  v_step := public.setting_num('daily_reward_streak_step', 10)::bigint;
  v_max  := public.setting_num('daily_reward_streak_cap', 7)::int;
  if v_streak > v_max then v_streak := v_max; end if;

  v_amount := v_base + v_step * (v_streak - 1);

  insert into public.daily_reward_claims(user_id, claim_date, streak, amount)
  values (v_uid, v_today, v_streak, v_amount);

  v_new := public._apply_ledger(v_uid, v_amount, 'daily_reward', null,
             'Daily reward (day ' || v_streak || ')');

  insert into public.notifications(user_id, title, body, type)
  values (v_uid, 'Daily reward claimed', 'You earned ' || v_amount || ' BCP.', 'daily');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'streak', v_streak, 'balance', v_new);
end;
$$;

create or replace function public.daily_reward_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_last  record;
  v_claimed boolean;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  v_claimed := exists (select 1 from public.daily_reward_claims where user_id = v_uid and claim_date = v_today);
  select * into v_last from public.daily_reward_claims where user_id = v_uid order by claim_date desc limit 1;
  return jsonb_build_object(
    'ok', true,
    'claimed_today', v_claimed,
    'current_streak', coalesce(v_last.streak, 0),
    'next_available_utc', (v_today + 1)::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- MINING  (server-authoritative lazy accrual — survives app close/reopen)
-- ---------------------------------------------------------------------------

-- internal: recompute accrual for an active session, capped at ends_at
create or replace function public._mining_accrued(s public.mining_sessions)
returns bigint
language sql
stable
as $$
  select floor(
    extract(epoch from (least(now(), s.ends_at) - s.started_at)) / 3600.0 * s.rate_per_hour
  )::bigint;
$$;

create or replace function public.start_mining()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_rate     bigint;
  v_hours    numeric;
  v_id       uuid;
  v_ends     timestamptz;
  s          public.mining_sessions;
  v_acc      bigint;
  v_delta    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  -- Auto-settle a completed-but-still-active session (credit any unclaimed
  -- accrual) so the user never loses BCP and a fresh session can begin.
  for s in
    select * from public.mining_sessions
    where user_id = v_uid and status = 'active' and ends_at < now()
    for update
  loop
    v_acc := public._mining_accrued(s);
    v_delta := v_acc - s.claimed;
    if v_delta > 0 then
      perform public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward (auto-settled)');
    end if;
    update public.mining_sessions
       set accrued = v_acc, claimed = v_acc, status = 'settled', last_settled_at = now()
     where id = s.id;
  end loop;

  if exists (select 1 from public.mining_sessions where user_id = v_uid and status = 'active') then
    raise exception 'MINING_ALREADY_ACTIVE';
  end if;

  v_rate  := public.setting_num('mining_rate_per_hour', 20)::bigint;
  v_hours := public.setting_num('mining_session_hours', 8);
  v_ends  := now() + (v_hours || ' hours')::interval;

  insert into public.mining_sessions(user_id, ends_at, rate_per_hour)
  values (v_uid, v_ends, v_rate)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id, 'ends_at', v_ends, 'rate_per_hour', v_rate);
end;
$$;

create or replace function public.mining_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s     public.mining_sessions;
  v_acc bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active' order by started_at desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'active', false,
      'rate_per_hour', public.setting_num('mining_rate_per_hour', 20),
      'session_hours', public.setting_num('mining_session_hours', 8));
  end if;
  v_acc := public._mining_accrued(s);
  return jsonb_build_object(
    'ok', true, 'active', true, 'session_id', s.id,
    'started_at', s.started_at, 'ends_at', s.ends_at,
    'rate_per_hour', s.rate_per_hour,
    'accrued', v_acc, 'claimable', greatest(v_acc - s.claimed, 0),
    'completed', now() >= s.ends_at
  );
end;
$$;

-- claim (settle) accrued BCP; when the session is finished it is marked settled
create or replace function public.claim_mining()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  s        public.mining_sessions;
  v_acc    bigint;
  v_delta  bigint;
  v_new    bigint;
  v_done   boolean;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into s from public.mining_sessions
    where user_id = v_uid and status = 'active'
    order by started_at desc limit 1
    for update;
  if not found then raise exception 'NO_ACTIVE_MINING'; end if;

  v_acc   := public._mining_accrued(s);
  v_delta := v_acc - s.claimed;
  v_done  := now() >= s.ends_at;

  if v_delta <= 0 and not v_done then
    raise exception 'NOTHING_TO_CLAIM';
  end if;

  if v_delta > 0 then
    v_new := public._apply_ledger(v_uid, v_delta, 'mining', s.id, 'Mining reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  update public.mining_sessions
     set accrued = v_acc,
         claimed = v_acc,
         last_settled_at = now(),
         status = case when v_done then 'settled'::mining_status else 'active'::mining_status end
   where id = s.id;

  return jsonb_build_object('ok', true, 'claimed', greatest(v_delta,0),
                            'balance', v_new, 'session_closed', v_done);
end;
$$;

-- ---------------------------------------------------------------------------
-- SCRATCH CARD  (reward fixed server-side at issue; revealed on scratch)
-- ---------------------------------------------------------------------------

-- pick a weighted reward from settings: scratch_rewards = [{amount, weight}, ...]
create or replace function public._scratch_roll()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg  jsonb := public.setting_json('scratch_rewards');
  v_total numeric := 0;
  v_r     numeric;
  v_acc   numeric := 0;
  it      jsonb;
begin
  if v_cfg is null or jsonb_array_length(v_cfg) = 0 then
    return (10 + floor(random()*40))::bigint;  -- sane fallback 10..50
  end if;
  for it in select * from jsonb_array_elements(v_cfg) loop
    v_total := v_total + coalesce((it->>'weight')::numeric, 1);
  end loop;
  v_r := random() * v_total;
  for it in select * from jsonb_array_elements(v_cfg) loop
    v_acc := v_acc + coalesce((it->>'weight')::numeric, 1);
    if v_r <= v_acc then
      return (it->>'amount')::bigint;
    end if;
  end loop;
  return (v_cfg->0->>'amount')::bigint;
end;
$$;

-- ensure the user has a card available today (issues one if under the daily cap)
create or replace function public.scratch_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_cap   int;
  v_used  int;
  v_card  public.scratch_cards;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where user_id = v_uid and status = 'available' order by created_at limit 1;
  if found then
    return jsonb_build_object('ok', true, 'has_card', true, 'card_id', v_card.id);
  end if;

  v_cap  := public.setting_num('scratch_daily_cap', 3)::int;
  select count(*) into v_used from public.scratch_cards
    where user_id = v_uid and issued_date = v_today;
  if v_used >= v_cap then
    return jsonb_build_object('ok', true, 'has_card', false, 'remaining_today', 0);
  end if;

  insert into public.scratch_cards(user_id, reward_amount, source)
  values (v_uid, public._scratch_roll(), 'daily')
  returning * into v_card;

  return jsonb_build_object('ok', true, 'has_card', true, 'card_id', v_card.id,
                            'remaining_today', v_cap - v_used - 1);
end;
$$;

create or replace function public.scratch_reveal(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.scratch_cards;
  v_new  bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_card from public.scratch_cards
    where id = p_card_id and user_id = v_uid for update;
  if not found then raise exception 'CARD_NOT_FOUND'; end if;
  if v_card.status <> 'available' then raise exception 'CARD_ALREADY_USED'; end if;

  update public.scratch_cards
     set status = 'scratched', scratched_at = now()
   where id = v_card.id;

  v_new := public._apply_ledger(v_uid, v_card.reward_amount, 'scratch', v_card.id, 'Scratch card reward');

  return jsonb_build_object('ok', true, 'amount', v_card.reward_amount, 'balance', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- WATCH ADS  (server rate-limited; reward amount from settings, not client)
-- If AdMob SSV is configured, the edge function marks rows verified and this
-- RPC can be tightened to require verified=true.
-- ---------------------------------------------------------------------------
create or replace function public.reward_ad()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'utc')::date;
  v_cap    int;
  v_used   int;
  v_amount bigint;
  v_min_gap int;
  v_last   timestamptz;
  v_new    bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  v_cap := public.setting_num('ads_daily_cap', 20)::int;
  select count(*) into v_used from public.ad_rewards where user_id = v_uid and reward_date = v_today;
  if v_used >= v_cap then raise exception 'AD_DAILY_LIMIT'; end if;

  -- minimum seconds between two rewarded ads (anti-spam)
  v_min_gap := public.setting_num('ads_min_gap_seconds', 20)::int;
  select max(created_at) into v_last from public.ad_rewards where user_id = v_uid;
  if v_last is not null and now() - v_last < (v_min_gap || ' seconds')::interval then
    raise exception 'AD_TOO_SOON';
  end if;

  v_amount := public.setting_num('ads_reward', 15)::bigint;

  insert into public.ad_rewards(user_id, reward_amount, network, verified)
  values (v_uid, v_amount, 'admob', false);

  v_new := public._apply_ledger(v_uid, v_amount, 'ad', null, 'Rewarded ad');

  return jsonb_build_object('ok', true, 'amount', v_amount, 'balance', v_new,
                            'remaining_today', v_cap - v_used - 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- DAILY QUIZ  (correct answers never leave the server; graded here)
-- p_answers: [{ "question_id": "...", "answer_index": 2 }, ...]
-- ---------------------------------------------------------------------------
create or replace function public.quiz_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_quiz public.quizzes;
  v_qs   jsonb;
  v_attempt public.quiz_attempts;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_quiz from public.quizzes
    where active and quiz_date <= (now() at time zone 'utc')::date
    order by quiz_date desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'available', false);
  end if;

  select * into v_attempt from public.quiz_attempts where user_id = v_uid and quiz_id = v_quiz.id;

  -- questions WITHOUT correct_index
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'position', position, 'question', question, 'options', options
         ) order by position), '[]'::jsonb)
    into v_qs
    from public.quiz_questions where quiz_id = v_quiz.id;

  return jsonb_build_object(
    'ok', true, 'available', true, 'quiz_id', v_quiz.id, 'title', v_quiz.title,
    'reward', v_quiz.reward, 'questions', v_qs,
    'attempted', v_attempt.id is not null,
    'result', case when v_attempt.id is not null then
      jsonb_build_object('correct', v_attempt.correct_count, 'total', v_attempt.total_count, 'reward', v_attempt.reward)
      else null end
  );
end;
$$;

create or replace function public.submit_quiz(p_quiz_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_quiz    public.quizzes;
  v_total   int;
  v_correct int := 0;
  v_reward  bigint;
  v_new     bigint;
  ans       jsonb;
  v_ci      int;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_quiz from public.quizzes where id = p_quiz_id and active;
  if not found then raise exception 'QUIZ_NOT_FOUND'; end if;

  if exists (select 1 from public.quiz_attempts where user_id = v_uid and quiz_id = p_quiz_id) then
    raise exception 'ALREADY_ATTEMPTED';
  end if;

  select count(*) into v_total from public.quiz_questions where quiz_id = p_quiz_id;

  for ans in select * from jsonb_array_elements(coalesce(p_answers, '[]'::jsonb)) loop
    select correct_index into v_ci from public.quiz_questions
      where id = (ans->>'question_id')::uuid and quiz_id = p_quiz_id;
    if v_ci is not null and v_ci = (ans->>'answer_index')::int then
      v_correct := v_correct + 1;
    end if;
  end loop;

  -- reward is proportional to correctness, rounded down
  v_reward := case when v_total > 0 then floor(v_quiz.reward::numeric * v_correct / v_total)::bigint else 0 end;

  insert into public.quiz_attempts(user_id, quiz_id, correct_count, total_count, reward)
  values (v_uid, p_quiz_id, v_correct, v_total, v_reward);

  if v_reward > 0 then
    v_new := public._apply_ledger(v_uid, v_reward, 'quiz', p_quiz_id, 'Daily quiz reward');
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'correct', v_correct, 'total', v_total,
                            'reward', v_reward, 'balance', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- TASKS  (client submits proof; reward only on verified/auto_verify)
-- ---------------------------------------------------------------------------
create or replace function public.submit_task(p_task_id uuid, p_proof jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_task  public.tasks;
  v_comp  public.task_completions;
  v_state task_state;
  v_reward bigint := null;
  v_new   bigint;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);

  select * into v_task from public.tasks where id = p_task_id and active;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;

  select * into v_comp from public.task_completions where task_id = p_task_id and user_id = v_uid;
  if found and v_comp.state in ('verified','rewarded') then
    raise exception 'TASK_ALREADY_DONE';
  end if;

  -- auto_verify tasks (e.g. link visit) are rewarded immediately; others go pending
  if v_task.auto_verify then
    v_state := 'rewarded'; v_reward := v_task.reward;
  else
    v_state := 'pending';
  end if;

  insert into public.task_completions(task_id, user_id, state, proof, reward)
  values (p_task_id, v_uid, v_state, coalesce(p_proof,'{}'::jsonb), v_reward)
  on conflict (task_id, user_id)
    do update set state = excluded.state, proof = excluded.proof, reward = excluded.reward, created_at = now();

  if v_state = 'rewarded' then
    v_new := public._apply_ledger(v_uid, v_task.reward, 'task', p_task_id, 'Task: ' || v_task.title);
  else
    select balance into v_new from public.wallets where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'state', v_state, 'reward', coalesce(v_reward,0), 'balance', v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- WITHDRAWAL  (manual review; balance is held immediately)
-- ---------------------------------------------------------------------------
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
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED'; end if;
  perform public.assert_active_user(v_uid);
  if p_amount is null or p_amount <= 0 then raise exception 'INVALID_AMOUNT'; end if;

  select * into v_pm from public.payment_methods where key = p_method_key and active;
  if not found then raise exception 'METHOD_UNAVAILABLE'; end if;

  v_min := greatest(public.setting_num('withdrawal_min', 1000)::bigint, v_pm.min_amount);
  if p_amount < v_min then raise exception 'BELOW_MINIMUM'; end if;

  -- one pending withdrawal at a time
  if exists (select 1 from public.withdrawals where user_id = v_uid and status in ('pending','approved')) then
    raise exception 'WITHDRAWAL_IN_PROGRESS';
  end if;

  -- hold the balance atomically (debit; not counted against total_earned)
  perform public._apply_ledger(v_uid, -p_amount, 'withdrawal_hold', null,
            'Withdrawal request hold', jsonb_build_object('method', p_method_key), false);

  update public.wallets set pending_withdrawal = pending_withdrawal + p_amount where user_id = v_uid;

  insert into public.withdrawals(user_id, amount, method_key, details)
  values (v_uid, p_amount, p_method_key, coalesce(p_details,'{}'::jsonb))
  returning id into v_wd;

  insert into public.notifications(user_id, title, body, type, data)
  values (v_uid, 'Withdrawal submitted',
          'Your request for ' || p_amount || ' BCP is pending review.', 'withdrawal',
          jsonb_build_object('withdrawal_id', v_wd));

  return jsonb_build_object('ok', true, 'withdrawal_id', v_wd);
end;
$$;

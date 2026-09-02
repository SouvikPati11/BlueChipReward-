-- ============================================================================
-- READ-ONLY verification of objects created by migrations 0001–0008.
-- Reads only system catalogs (pg_*). Creates/alters/deletes NOTHING.
--
-- Columns:
--   migration        which migration file the object comes from
--   kind             extension | type | table | index | function | trigger | policy
--   object           object name
--   present          true = exists in this database, false = MISSING
--   reliable_signal  true  = presence/absence reliably indicates THIS migration
--                     false = also created/recreated by a LATER migration (0010–0012),
--                             so its presence does NOT prove 0001–0008 ran (see note)
--   note             interpretation hint
--   migration_verdict  per-migration rollup: are all *reliable* objects present?
-- ============================================================================
with expected(migration, kind, object, reliable_signal, note) as (
  values
    -- ---- 0001_schema: extension, enums, tables, indexes --------------------
    ('0001','extension','pgcrypto',                 true,  ''),
    ('0001','type','user_status',                   true,  ''),
    ('0001','type','app_role',                      true,  ''),
    ('0001','type','ledger_type',                   true,  'later ALTERed (0011 adds a value) but created here'),
    ('0001','type','mining_status',                 true,  ''),
    ('0001','type','scratch_status',                true,  ''),
    ('0001','type','task_type',                     true,  ''),
    ('0001','type','task_state',                    true,  ''),
    ('0001','type','withdrawal_status',             true,  ''),
    ('0001','type','notification_type',             true,  ''),
    ('0001','table','profiles',                     true,  '0010/0011/0012 FK-reference this, so it must exist'),
    ('0001','table','user_roles',                   true,  ''),
    ('0001','table','wallets',                      true,  ''),
    ('0001','table','wallet_transactions',          true,  ''),
    ('0001','table','app_settings',                 true,  '0013 INSERTs into this, so it must exist'),
    ('0001','table','daily_reward_claims',          true,  ''),
    ('0001','table','mining_sessions',              true,  '0012 ALTERs/UPDATEs this, so it must exist'),
    ('0001','table','scratch_cards',                true,  ''),
    ('0001','table','ad_rewards',                   true,  ''),
    ('0001','table','quizzes',                      true,  ''),
    ('0001','table','quiz_questions',               true,  ''),
    ('0001','table','quiz_attempts',                true,  ''),
    ('0001','table','tasks',                        true,  '0011 UPDATEs this, so it must exist'),
    ('0001','table','task_completions',             true,  ''),
    ('0001','table','referrals',                    true,  ''),
    ('0001','table','payment_methods',              true,  ''),
    ('0001','table','withdrawals',                  true,  ''),
    ('0001','table','notifications',                true,  ''),
    ('0001','table','audit_logs',                   true,  ''),
    ('0001','index','uniq_active_mining',           true,  ''),
    ('0001','index','idx_tx_user_created',          true,  ''),
    ('0001','index','idx_wd_status',                true,  ''),

    -- ---- 0002_core_functions: helpers, ledger, signup trigger -------------
    ('0002','function','setting_num',               true,  ''),
    ('0002','function','setting_json',              true,  ''),
    ('0002','function','is_admin',                  true,  ''),
    ('0002','function','assert_active_user',        true,  ''),
    ('0002','function','_apply_ledger',             true,  'THE ledger primitive; 0004/0010–0012 call it'),
    ('0002','function','_gen_referral_code',        true,  ''),
    ('0002','function','_touch_updated_at',         true,  ''),
    ('0002','function','handle_new_user',           false, 'recreated by 0010 — presence does not prove 0002'),
    ('0002','trigger','on_auth_user_created',       true,  'on auth.users'),
    ('0002','trigger','trg_profiles_touch',         true,  ''),

    -- ---- 0003_earning_functions ------------------------------------------
    ('0003','function','daily_reward_status',       true,  ''),
    ('0003','function','_scratch_roll',             true,  ''),
    ('0003','function','scratch_status',            true,  ''),
    ('0003','function','quiz_today',                true,  ''),
    ('0003','function','submit_task',               true,  ''),
    ('0003','function','request_withdrawal',        true,  ''),
    ('0003','function','claim_daily_reward',        false, 'dropped+recreated by 0012'),
    ('0003','function','scratch_reveal',            false, 'dropped+recreated by 0012'),
    ('0003','function','reward_ad',                 false, 'dropped+recreated by 0012'),
    ('0003','function','submit_quiz',               false, 'dropped+recreated by 0012'),
    ('0003','function','start_mining',              false, 'recreated by 0012'),
    ('0003','function','mining_status',             false, 'recreated by 0012'),
    ('0003','function','claim_mining',              false, 'recreated by 0012'),
    ('0003','function','_mining_accrued',           false, 'recreated by 0012'),

    -- ---- 0004_admin_functions --------------------------------------------
    ('0004','function','_assert_admin',             true,  ''),
    ('0004','function','admin_process_withdrawal',  true,  ''),
    ('0004','function','admin_review_task',         true,  ''),
    ('0004','function','admin_adjust_balance',      true,  ''),
    ('0004','function','admin_set_user_status',     true,  ''),
    ('0004','function','admin_set_setting',         true,  '0009–0013 call this indirectly; created here'),
    ('0004','function','admin_broadcast',           true,  ''),
    ('0004','function','admin_stats',               true,  ''),

    -- ---- 0005_rls: policies + profile-update guard -----------------------
    ('0005','function','_guard_profile_update',     true,  ''),
    ('0005','trigger','trg_guard_profile',          true,  ''),
    ('0005','policy','profiles_select',             true,  ''),
    ('0005','policy','profiles_update',             true,  ''),
    ('0005','policy','roles_select',                true,  ''),
    ('0005','policy','wallets_select',              true,  ''),
    ('0005','policy','tx_select',                   true,  ''),
    ('0005','policy','settings_select',             true,  ''),
    ('0005','policy','daily_select',                true,  ''),
    ('0005','policy','mining_select',               true,  ''),
    ('0005','policy','scratch_select',              true,  ''),
    ('0005','policy','ads_select',                  true,  ''),
    ('0005','policy','quizzes_select',              true,  ''),
    ('0005','policy','qq_select',                   true,  ''),
    ('0005','policy','qa_select',                   true,  ''),
    ('0005','policy','tasks_select',                true,  ''),
    ('0005','policy','taskcomp_select',             true,  ''),
    ('0005','policy','ref_select',                  true,  ''),
    ('0005','policy','pm_select',                   true,  ''),
    ('0005','policy','wd_select',                   true,  ''),
    ('0005','policy','notif_select',                true,  ''),
    ('0005','policy','notif_update',                true,  ''),
    ('0005','policy','audit_select',                true,  ''),

    -- ---- 0006_seed: DATA ONLY (no schema objects) ------------------------
    ('0006','seed','signup_bonus',                  true,  'app_settings seed key (data, admin may have removed)'),
    ('0006','seed','currency_symbol',               true,  'app_settings seed key (data)'),
    ('0006','seed','scratch_rewards',               true,  'app_settings seed key (data)'),

    -- ---- 0007_ssv_function -----------------------------------------------
    ('0007','function','credit_verified_ad',        true,  ''),
    ('0007','index','uniq_ad_ssv',                  true,  ''),

    -- ---- 0008_referral_apply ---------------------------------------------
    ('0008','function','apply_referral_code',       false, 'recreated by 0010 — 0008 is fully superseded; presence proves nothing about 0008')
),
checked as (
  select
    e.migration, e.kind, e.object, e.reliable_signal, e.note,
    case e.kind
      when 'extension' then exists (select 1 from pg_extension x where x.extname = e.object)
      when 'type'      then to_regtype('public.' || e.object) is not null
      when 'table'     then to_regclass('public.' || e.object) is not null
      when 'index'     then to_regclass('public.' || e.object) is not null
      when 'function'  then exists (
                             select 1 from pg_proc p
                             join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'public' and p.proname = e.object)
      when 'trigger'   then exists (
                             select 1 from pg_trigger t
                             where not t.tgisinternal and t.tgname = e.object)
      when 'policy'    then exists (select 1 from pg_policies pl where pl.policyname = e.object)
      -- app_settings is guaranteed to exist because 0013 INSERTs into it (and
      -- you confirmed 0013 applied). If it were missing, 0001 clearly did not run.
      when 'seed'      then exists (select 1 from public.app_settings s where s.key = e.object)
      else null
    end as present
  from expected e
)
select
  migration,
  kind,
  object,
  present,
  case when present then 'OK' else 'MISSING' end as status,
  reliable_signal,
  -- Per-migration verdict based only on RELIABLE signals:
  case
    when count(*) filter (where reliable_signal)
         over (partition by migration) = 0
    then 'INDETERMINATE (only superseded objects; a later migration recreated them)'
    when count(*) filter (where reliable_signal and not present)
         over (partition by migration) = 0
    then 'APPLIED (all reliable objects present)'
    when count(*) filter (where reliable_signal and present)
         over (partition by migration) = 0
    then 'NOT APPLIED (no reliable objects present)'
    else 'PARTIAL / SUSPECT — investigate'
  end as migration_verdict,
  note
from checked
order by migration, (kind = 'seed'), kind, object;

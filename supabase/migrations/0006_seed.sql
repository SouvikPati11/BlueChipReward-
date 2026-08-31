-- ============================================================================
-- Seed: default admin-configurable settings, payment methods, and demo content.
-- Values here are safe defaults; the admin can change everything at runtime via
-- admin_set_setting / the admin panel — no APK release required.
-- ============================================================================

insert into public.app_settings(key, value, description) values
  ('signup_bonus',             '100',  'One-time BCP credited on registration'),
  ('daily_reward_base',        '50',   'Base BCP for a daily reward claim'),
  ('daily_reward_streak_step', '10',   'Extra BCP per consecutive day'),
  ('daily_reward_streak_cap',  '7',    'Streak day at which the bonus caps'),
  ('mining_rate_per_hour',     '20',   'BCP accrued per hour while mining'),
  ('mining_session_hours',     '8',    'Length of one mining session in hours'),
  ('scratch_daily_cap',        '3',    'Scratch cards issuable per user per day'),
  ('scratch_rewards',          '[{"amount":10,"weight":40},{"amount":25,"weight":30},{"amount":50,"weight":20},{"amount":100,"weight":9},{"amount":500,"weight":1}]', 'Weighted scratch outcomes'),
  ('ads_reward',               '15',   'BCP per completed rewarded ad'),
  ('ads_daily_cap',            '20',   'Rewarded ads per user per day'),
  ('ads_min_gap_seconds',      '20',   'Minimum seconds between rewarded ads'),
  ('referral_reward_l1',       '200',  'BCP to referrer when a referral signs up'),
  ('withdrawal_min',           '1000', 'Minimum BCP per withdrawal request'),
  ('bcp_to_currency_rate',     '0.001','Display: 1 BCP = this much fiat (info only)'),
  ('currency_symbol',          '"₹"',  'Display currency symbol for wallet estimates'),
  ('maintenance_mode',         'false','When true, earning is paused (client hint)')
on conflict (key) do nothing;

insert into public.payment_methods(key, name, fields, min_amount, position) values
  ('upi',   'UPI',        '[{"key":"upi_id","label":"UPI ID","type":"text"}]', 1000, 0),
  ('paytm', 'Paytm',      '[{"key":"phone","label":"Paytm Number","type":"phone"}]', 1000, 1),
  ('bank',  'Bank Transfer', '[{"key":"account_name","label":"Account Holder","type":"text"},{"key":"account_number","label":"Account Number","type":"text"},{"key":"ifsc","label":"IFSC","type":"text"}]', 5000, 2),
  ('usdt',  'USDT (TRC20)', '[{"key":"wallet","label":"USDT Wallet Address","type":"text"}]', 10000, 3)
on conflict (key) do nothing;

insert into public.tasks(title, description, type, reward, action_url, instructions, auto_verify, position) values
  ('Join our Telegram', 'Join the official BlueChip Telegram channel for updates.', 'telegram', 150, 'https://t.me/bluechiprewards', 'Tap the link, join, then come back and claim.', true, 0),
  ('Follow us on X', 'Follow @BlueChipRewards for announcements.', 'social', 100, 'https://x.com/bluechiprewards', 'Follow, then claim your reward.', true, 1),
  ('Rate the app', 'Leave a review on the Play Store.', 'link_visit', 200, 'https://play.google.com/store', 'Open the store listing and rate us.', true, 2),
  ('Invite a friend', 'Share your referral link with a friend.', 'invite', 0, null, 'Use your referral link from the Referral tab.', false, 3)
on conflict do nothing;

-- A starter quiz for today (UTC)
do $$
declare v_qid uuid; v_date date := (now() at time zone 'utc')::date;
begin
  if not exists (select 1 from public.quizzes where quiz_date = v_date) then
    insert into public.quizzes(quiz_date, title, reward) values (v_date, 'Daily Brain Teaser', 100)
      returning id into v_qid;
    insert into public.quiz_questions(quiz_id, position, question, options, correct_index) values
      (v_qid, 0, 'What does BCP stand for in this app?',
        '["BlueChip Points","Basic Credit Points","Bonus Coin Pay","Blue Cash Prize"]', 0),
      (v_qid, 1, 'Which of these is an earning method here?',
        '["Mining","Trading stocks","Selling data","None"]', 0),
      (v_qid, 2, 'Withdrawals in BlueChip Rewards are…',
        '["Automatic instantly","Manually reviewed by admin","Not supported","Random"]', 1);
  end if;
end $$;

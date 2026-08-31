-- Grant yourself the admin role AFTER you have signed up in the app once.
-- Run this in the Supabase SQL editor. Replace the email with your own.
--
-- Admin is server-authorised (checked by is_admin() inside every admin RPC and
-- by RLS), so there is no hardcoded admin and no client-side admin flag.

insert into public.user_roles (user_id, role)
select id, 'admin'
from public.profiles
where email = 'you@example.com'
on conflict (user_id, role) do nothing;

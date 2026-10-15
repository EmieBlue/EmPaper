-- EmPaper: make YOUR login the owner. Run once, after the M1 migration, in Supabase -> SQL Editor.
--
-- 1) In the insert below, change the text between the quote marks to the email of the user you created
--    (Authentication -> Users). Keep the quote marks. Capital letters do not matter.
-- 2) Run it. The result table should show ONE row with your email.
--    If it shows no rows, no user has that email. Check the spelling in Authentication -> Users and run it again.
--    (Supabase says "Success" for an insert even when it added nothing, so look at the result table.)

insert into public.platform_admins (user_id)
select id from auth.users where lower(email) = lower('CHANGE-ME@example.com')
on conflict do nothing;

select u.email as owner_email, pa.require_mfa
from public.platform_admins pa
join auth.users u on u.id = pa.user_id;

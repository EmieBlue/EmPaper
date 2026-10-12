-- EmPaper: make YOUR login the owner. Run once, after the M1 migration, in Supabase -> SQL Editor.
--
-- 1) On the line near the bottom that says  where email = 'CHANGE-ME@example.com'
--    replace the text between the quote marks with the exact email address you used when you
--    created your user (Authentication -> Users -> Add user). Keep the quote marks.
-- 2) Run it. The result should say "Success. 1 row affected".
--    "0 rows affected" means no user has that email: check the spelling and run it again.

insert into public.platform_admins (user_id)
select id from auth.users where email = 'CHANGE-ME@example.com'
on conflict do nothing;

-- EmPaper M1b test: the logo / brand colour hints on demo requests. Rollback-safe.
-- Run in Supabase -> SQL Editor AFTER 20261016100000_add_lead_branding_hints.sql.
-- Expected result: one row saying "M1b ALL PASS".

begin;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

do $$
declare n int;
begin
  -- a visitor can send the new answers
  insert into public.leads (name, company_name, work_email, number_of_people, logo_status, brand_colours)
  values ('RLS_TEST_b1', 'RLS Co', 'b1@example.test', 3, 'unsure', 'navy and gold');

  -- and can still skip them
  insert into public.leads (name, company_name, work_email, number_of_people)
  values ('RLS_TEST_b2', 'RLS Co', 'b2@example.test', 3);

  begin
    insert into public.leads (name, company_name, work_email, number_of_people, logo_status)
    values ('RLS_TEST_b3', 'RLS Co', 'b3@example.test', 3, 'maybe');
    raise exception 'FAIL: an invalid logo answer was accepted';
  exception when check_violation then null; end;

  begin
    insert into public.leads (name, company_name, work_email, number_of_people, brand_colours)
    values ('RLS_TEST_b4', 'RLS Co', 'b4@example.test', 3, repeat('x', 101));
    raise exception 'FAIL: a 101-character brand colours text was accepted';
  exception when check_violation then null; end;

  -- the new columns did not open up reading
  begin
    select count(*) into n from public.leads;
    if n <> 0 then raise exception 'FAIL: a visitor can read % leads', n; end if;
  exception when insufficient_privilege then null; end;
end $$;

reset role;
delete from public.leads where starts_with(name, 'RLS_TEST_b');

rollback;

select 'M1b ALL PASS'::text as result;

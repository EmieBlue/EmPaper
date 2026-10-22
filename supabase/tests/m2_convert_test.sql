-- EmPaper M2 permission test: turning a demo request into a client company. Rollback-safe.
-- Run in Supabase -> SQL Editor AFTER 20261022100000_companies_branding_convert.sql (and the owner seed).
-- Expected result: one row saying "M2 ALL PASS".
-- If a check fails you get an error starting with "FAIL:" that says which one.

begin;

select set_config('empaper_test.owner',
  (select user_id::text from public.platform_admins order by created_at limit 1), true);
select set_config('empaper_test.orig_mfa',
  (select require_mfa::text from public.platform_admins order by created_at limit 1), true);
select set_config('empaper_test.rando', gen_random_uuid()::text, true);

do $$ begin
  if nullif(current_setting('empaper_test.owner', true), '') is null then
    raise exception 'FAIL: no owner found. Run supabase/seed/owner_seed.sql first with your email.';
  end if;
end $$;

delete from public.audit_log where entity_type in ('company', 'lead')
  and entity_id in (select id from public.leads where starts_with(name, 'RLS_TEST_'));
delete from public.leads where starts_with(name, 'RLS_TEST_');
delete from public.companies where starts_with(name, 'RLS_TEST_');

-- fixtures: two demo requests and one existing company
insert into public.leads (name, company_name, work_email, number_of_people)
values ('RLS_TEST_L1', 'RLS Co', 'l1@example.test', 5),
       ('RLS_TEST_L2', 'RLS Co', 'l2@example.test', 6);
select set_config('empaper_test.l1', (select id::text from public.leads where name = 'RLS_TEST_L1'), true);
select set_config('empaper_test.l2', (select id::text from public.leads where name = 'RLS_TEST_L2'), true);
insert into public.companies (name, slug) values ('RLS_TEST_ Fixture Co', 'rls-test-fixture-co');

-- 1) A visitor (anonymous)
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

do $$
declare n int;
begin
  begin
    perform public.convert_lead_to_company(current_setting('empaper_test.l1')::uuid, 'RLS_TEST_ Acme Ltd');
    raise exception 'FAIL: a visitor can convert a lead';
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.companies;
    if n <> 0 then raise exception 'FAIL: a visitor can read % companies', n; end if;
  exception when insufficient_privilege then null; end;
end $$;

-- 2) A signed-in user who is NOT the owner
reset role;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('empaper_test.rando'), 'role', 'authenticated', 'aal', 'aal1')::text, true);

do $$
declare n int;
begin
  begin
    perform public.convert_lead_to_company(current_setting('empaper_test.l1')::uuid, 'RLS_TEST_ Acme Ltd');
    raise exception 'FAIL: a non-owner can convert a lead';
  exception when insufficient_privilege then null; end;

  select count(*) into n from public.companies;
  if n <> 0 then raise exception 'FAIL: a non-owner can read % companies', n; end if;

  update public.companies set name = 'hacked' where starts_with(name, 'RLS_TEST_');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: a non-owner could rename % companies', n; end if;

  delete from public.companies where starts_with(name, 'RLS_TEST_');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: a non-owner could delete % companies', n; end if;

  begin
    insert into public.companies (name, slug) values ('RLS_TEST_ sneaky', 'rls-test-sneaky');
    raise exception 'FAIL: a non-owner could create a company directly';
  exception when insufficient_privilege then null; end;
end $$;

-- 3) The owner (single-step login)
reset role;
update public.platform_admins set require_mfa = false
  where user_id = current_setting('empaper_test.owner')::uuid;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('empaper_test.owner'), 'role', 'authenticated', 'aal', 'aal1')::text, true);

do $$
declare
  n int; c1 uuid; c2 uuid; l1 uuid := current_setting('empaper_test.l1')::uuid; l2 uuid := current_setting('empaper_test.l2')::uuid;
  r record; d jsonb;
begin
  c1 := public.convert_lead_to_company(l1, '  RLS_TEST_ Acme Ltd  ');
  if c1 is null then raise exception 'FAIL: converting returned no company'; end if;

  select * into r from public.companies where id = c1;
  if r.name <> 'RLS_TEST_ Acme Ltd' then raise exception 'FAIL: company name was not trimmed/stored, got %', r.name; end if;
  if r.slug <> 'rls-test-acme-ltd' then raise exception 'FAIL: unexpected slug %', r.slug; end if;
  if r.display_name <> r.name then raise exception 'FAIL: display name not set'; end if;
  if r.branding_status <> 'none' or not r.is_active then raise exception 'FAIL: new company has wrong defaults'; end if;

  select * into r from public.leads where id = l1;
  if r.status <> 'converted' or r.converted_company_id is distinct from c1 then
    raise exception 'FAIL: the lead was not marked converted and linked';
  end if;

  select details into d from public.audit_log where action = 'company.created' and entity_id = c1;
  if d is null then raise exception 'FAIL: no company.created audit row'; end if;
  if d ->> 'lead_id' <> l1::text then raise exception 'FAIL: audit row does not point at the lead'; end if;
  if d::text ilike '%acme%' or d::text ilike '%example.test%' then raise exception 'FAIL: audit details hold a name or email'; end if;

  select count(*) into n from public.audit_log where action = 'lead.status_changed' and entity_id = l1;
  if n <> 1 then raise exception 'FAIL: expected 1 status-change audit row, got %', n; end if;

  -- same name again: the web name gets a number instead of failing
  c2 := public.convert_lead_to_company(l2, 'RLS_TEST_ Acme Ltd');
  select slug into r from public.companies where id = c2;
  if r.slug <> 'rls-test-acme-ltd-2' then raise exception 'FAIL: duplicate name did not get -2, got %', r.slug; end if;

  begin
    perform public.convert_lead_to_company(l1, 'RLS_TEST_ Again');
    raise exception 'FAIL: the same lead could be converted twice';
  exception when unique_violation then null; end;

  begin
    perform public.convert_lead_to_company(gen_random_uuid(), 'RLS_TEST_ Nobody');
    raise exception 'FAIL: converting a lead that does not exist worked';
  exception when no_data_found then null; end;

  begin
    perform public.convert_lead_to_company(l1, '   ');
    raise exception 'FAIL: a blank company name was accepted';
  exception when invalid_parameter_value then null; end;

  select count(*) into n from public.companies where starts_with(name, 'RLS_TEST_');
  if n < 3 then raise exception 'FAIL: the owner sees only % test companies (expected 3)', n; end if;

  update public.companies set display_name = 'RLS_TEST_ Renamed' where id = c1;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: the owner could not rename a company'; end if;

  begin
    update public.companies set branding_status = 'bogus' where id = c1;
    raise exception 'FAIL: a bad branding status was accepted';
  exception when check_violation then null; end;
  begin
    update public.companies set primary_color = 'red' where id = c1;
    raise exception 'FAIL: a bad colour was accepted';
  exception when check_violation then null; end;
  begin
    update public.companies set slug = 'Bad Slug' where id = c1;
    raise exception 'FAIL: a bad web name was accepted';
  exception when check_violation then null; end;

  begin
    insert into public.companies (name, slug) values ('RLS_TEST_ direct', 'rls-test-direct');
    raise exception 'FAIL: the owner could create a company without the function';
  exception when insufficient_privilege then null; end;

  delete from public.companies where id = c1;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: the owner could delete a company from the browser'; end if;
end $$;

-- 4) 2-step login required: a single-step session cannot convert
reset role;
update public.platform_admins set require_mfa = true
  where user_id = current_setting('empaper_test.owner')::uuid;
insert into public.leads (name, company_name, work_email, number_of_people)
values ('RLS_TEST_L3', 'RLS Co', 'l3@example.test', 7);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('empaper_test.owner'), 'role', 'authenticated', 'aal', 'aal1')::text, true);

do $$
begin
  begin
    perform public.convert_lead_to_company((select id from public.leads where name = 'RLS_TEST_L3'), 'RLS_TEST_ Mfa Co');
    raise exception 'FAIL: with 2-step required, a single-step session could convert';
  exception when insufficient_privilege then null; end;
end $$;

-- 5) the staff policy must still be there (staff read their own company with it)
reset role;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'companies' and policyname = 'companies_select_own') then
    raise exception 'FAIL: companies_select_own policy is missing';
  end if;
end $$;

-- clean up (the ROLLBACK below would also do this)
update public.platform_admins
  set require_mfa = coalesce(nullif(current_setting('empaper_test.orig_mfa', true), '')::boolean, false)
  where user_id = current_setting('empaper_test.owner')::uuid;
delete from public.audit_log
  where entity_id in (select id from public.leads where starts_with(name, 'RLS_TEST_'))
     or entity_id in (select id from public.companies where starts_with(name, 'RLS_TEST_'));
delete from public.leads where starts_with(name, 'RLS_TEST_');
delete from public.companies where starts_with(name, 'RLS_TEST_');

rollback;

select 'M2 ALL PASS'::text as result;

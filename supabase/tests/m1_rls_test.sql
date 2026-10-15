-- EmPaper M1 permission test. Rollback-safe: it ends with ROLLBACK and also deletes its own test rows.
-- Run in Supabase -> SQL Editor AFTER the M1 migration and the owner seed.
-- Expected result: one row saying "M1 RLS: ALL PASS".
-- If a check fails you get an error starting with "FAIL:" that says which one.

begin;

select set_config('empaper_test.owner',
  (select user_id::text from public.platform_admins order by created_at limit 1), true);
select set_config('empaper_test.orig_mfa',
  (select require_mfa::text from public.platform_admins order by created_at limit 1), true);
select set_config('empaper_test.rando', gen_random_uuid()::text, true);

do $$ begin
  if nullif(current_setting('empaper_test.owner', true), '') is null then
    raise exception 'FAIL: no owner found. Run supabase/seed/owner_seed.sql first (with your email).';
  end if;
end $$;

delete from public.audit_log where action = 'rls_test';
delete from public.leads where starts_with(name, 'RLS_TEST_');
insert into public.leads (name, company_name, work_email, number_of_people)
values ('RLS_TEST_1', 'RLS Co', 'rls1@example.test', 5),
       ('RLS_TEST_2', 'RLS Co', 'rls2@example.test', 6);
-- one audit row to look for, so "a non-owner sees 0 rows" really proves something
insert into public.audit_log (action, entity_type) values ('rls_test', 'lead');

-- 1) A visitor using the public demo form (anonymous)
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

do $$
declare n int;
begin
  -- the same columns api/lead.ts sends: accepted
  insert into public.leads (name, company_name, work_email, number_of_people, interested_features, notes)
  values ('RLS_TEST_anon', 'RLS Co', 'anon@example.test', 1, array['pay_letters'], 'hello');

  begin
    insert into public.leads (name, company_name, work_email, number_of_people, status)
    values ('RLS_TEST_x', 'RLS Co', 'x@example.test', 1, 'converted');
    raise exception 'FAIL: a visitor could create a lead with status converted';
  exception when insufficient_privilege then null; end;

  begin
    insert into public.leads (name, company_name, work_email, number_of_people, owner_notes)
    values ('RLS_TEST_y', 'RLS Co', 'y@example.test', 1, 'sneaky');
    raise exception 'FAIL: a visitor could write owner notes';
  exception when insufficient_privilege then null; end;

  begin
    select count(*) into n from public.leads;
    if n <> 0 then raise exception 'FAIL: a visitor can read % leads', n; end if;
  exception when insufficient_privilege then null; end;

  begin
    update public.leads set owner_notes = 'hack' where starts_with(name, 'RLS_TEST_');
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: a visitor could update % leads', n; end if;
  exception when insufficient_privilege then null; end;

  begin
    delete from public.leads where starts_with(name, 'RLS_TEST_');
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'FAIL: a visitor could delete % leads', n; end if;
  exception when insufficient_privilege then null; end;

  begin
    perform public.is_platform_admin();
    raise exception 'FAIL: a visitor can run is_platform_admin()';
  exception when insufficient_privilege then null; end;
end $$;

-- 2) A signed-in user who is NOT the owner (random id)
reset role;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('empaper_test.rando'), 'role', 'authenticated', 'aal', 'aal1')::text, true);

do $$
declare n int;
begin
  select count(*) into n from public.leads;
  if n <> 0 then raise exception 'FAIL: a non-owner can read % leads', n; end if;

  update public.leads set owner_notes = 'hack' where starts_with(name, 'RLS_TEST_');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: a non-owner could update % leads', n; end if;

  delete from public.leads where starts_with(name, 'RLS_TEST_');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: a non-owner could delete % leads', n; end if;

  select count(*) into n from public.audit_log where action = 'rls_test';
  if n <> 0 then raise exception 'FAIL: a non-owner can read the audit log'; end if;

  select count(*) into n from public.platform_admins;
  if n <> 0 then raise exception 'FAIL: a non-owner can read platform_admins'; end if;

  if public.is_platform_admin() then raise exception 'FAIL: a non-owner is treated as owner'; end if;

  begin
    insert into public.audit_log (action, entity_type) values ('hack', 'lead');
    raise exception 'FAIL: a non-owner could write to the audit log';
  exception when insufficient_privilege then null; end;

  begin
    insert into public.platform_admins (user_id) values (current_setting('empaper_test.rando')::uuid);
    raise exception 'FAIL: a non-owner could make themselves an owner';
  exception when insufficient_privilege then null; end;

  begin
    perform public.write_audit('hack', 'lead', null, '{}'::jsonb);
    raise exception 'FAIL: a non-owner can call write_audit()';
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
declare n int; v_id uuid; v_contacted timestamptz;
begin
  if not public.is_platform_admin() then raise exception 'FAIL: the owner is not recognised as owner'; end if;

  select count(*) into n from public.leads where starts_with(name, 'RLS_TEST_');
  if n < 3 then raise exception 'FAIL: the owner sees only % test leads (expected 3)', n; end if;

  update public.leads set status = 'contacted', owner_notes = 'a note' where name = 'RLS_TEST_1';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: the owner could not update a lead'; end if;

  select id, contacted_at into v_id, v_contacted from public.leads where name = 'RLS_TEST_1';
  if v_contacted is null then raise exception 'FAIL: contacted_at was not stamped'; end if;

  select count(*) into n from public.audit_log
    where action = 'lead.status_changed' and entity_id = v_id;
  if n <> 1 then raise exception 'FAIL: expected 1 audit row for the status change, got %', n; end if;

  begin
    update public.leads set status = 'bogus' where name = 'RLS_TEST_1';
    raise exception 'FAIL: an invalid status was accepted';
  exception when check_violation then null; end;

  delete from public.leads where name = 'RLS_TEST_2';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: the owner could not delete a lead'; end if;

  begin
    insert into public.audit_log (action, entity_type) values ('direct', 'lead');
    raise exception 'FAIL: the owner could insert into the audit log directly';
  exception when insufficient_privilege then null; end;

  select count(*) into n from public.platform_admins;
  if n <> 0 then raise exception 'FAIL: platform_admins is readable by the browser'; end if;

  select count(*) into n from public.audit_log where action = 'rls_test';
  if n <> 1 then raise exception 'FAIL: the owner cannot read the audit log'; end if;
end $$;

-- 4) 2-step login required for the owner
reset role;
update public.platform_admins set require_mfa = true
  where user_id = current_setting('empaper_test.owner')::uuid;
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('empaper_test.owner'), 'role', 'authenticated', 'aal', 'aal1')::text, true);

do $$
declare n int;
begin
  if public.is_platform_admin() then raise exception 'FAIL: with 2-step required, a single-step session is accepted'; end if;
  select count(*) into n from public.leads where starts_with(name, 'RLS_TEST_');
  if n <> 0 then raise exception 'FAIL: with 2-step required, a single-step session can read leads'; end if;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('empaper_test.owner'), 'role', 'authenticated', 'aal', 'aal2')::text, true);

do $$
declare n int;
begin
  if not public.is_platform_admin() then raise exception 'FAIL: a 2-step session is not accepted'; end if;
  select count(*) into n from public.leads where starts_with(name, 'RLS_TEST_');
  if n < 1 then raise exception 'FAIL: a 2-step session cannot read leads'; end if;
end $$;

-- clean up (the ROLLBACK below would also do this)
reset role;
update public.platform_admins
  set require_mfa = coalesce(nullif(current_setting('empaper_test.orig_mfa', true), '')::boolean, false)
  where user_id = current_setting('empaper_test.owner')::uuid;
delete from public.audit_log
  where action = 'rls_test'
     or (entity_type = 'lead' and entity_id in (select id from public.leads where starts_with(name, 'RLS_TEST_')));
delete from public.leads where starts_with(name, 'RLS_TEST_');

rollback;

select 'M1 RLS: ALL PASS'::text as result;

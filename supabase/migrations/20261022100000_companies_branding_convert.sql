-- EmPaper M2: client companies for the owner console.
--   1) companies get a web name (slug), a display name and the branding fields (filled in by a later phase).
--   2) only the owner can see/rename companies from the console (staff still read their own company as before).
--   3) convert_lead_to_company(): one safe step that turns a demo request into a client company.
-- Safe to run more than once. Run the matching test (supabase/tests/m2_convert_test.sql) right after.

alter table public.companies
  add column if not exists slug text,
  add column if not exists display_name text,
  add column if not exists logo_path text,
  add column if not exists primary_color text,
  add column if not exists accent_color text,
  add column if not exists branding_status text not null default 'none';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'companies_branding_status_check') then
    alter table public.companies add constraint companies_branding_status_check
      check (branding_status in ('none', 'requested', 'pending_review', 'approved'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'companies_slug_check') then
    alter table public.companies add constraint companies_slug_check
      check (slug is null or slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'companies_primary_color_check') then
    alter table public.companies add constraint companies_primary_color_check
      check (primary_color is null or primary_color ~ '^#[0-9a-fA-F]{6}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'companies_accent_color_check') then
    alter table public.companies add constraint companies_accent_color_check
      check (accent_color is null or accent_color ~ '^#[0-9a-fA-F]{6}$');
  end if;
end $$;

create unique index if not exists companies_slug_lower_idx on public.companies (lower(slug));

-- Owner-only access from the console. The existing companies_select_own policy (staff read their own company) stays.
-- There is deliberately NO insert or delete policy: companies are created only by convert_lead_to_company() below,
-- and deleting one would wipe its staff, letters and files.
drop policy if exists companies_platform_select on public.companies;
create policy companies_platform_select on public.companies for select to authenticated
  using ((select public.is_platform_admin()));

drop policy if exists companies_platform_update on public.companies;
create policy companies_platform_update on public.companies for update to authenticated
  using ((select public.is_platform_admin())) with check ((select public.is_platform_admin()));

-- Turns a demo request into a client company. Everything happens in one transaction: either all of it or none.
create or replace function public.convert_lead_to_company(p_lead_id uuid, p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name    text := btrim(coalesce(p_name, ''));
  v_base    text;
  v_slug    text;
  v_n       int := 1;
  v_company uuid;
  v_lead    public.leads%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 160 then
    raise exception 'invalid name' using errcode = '22023';
  end if;

  select * into v_lead from public.leads where id = p_lead_id for update;
  if not found then
    raise exception 'lead not found' using errcode = 'P0002';
  end if;
  if v_lead.converted_company_id is not null then
    raise exception 'already converted' using errcode = '23505';
  end if;

  v_base := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
  if v_base = '' then v_base := 'company'; end if;
  v_base := left(v_base, 60);
  v_base := trim(both '-' from v_base);
  v_slug := v_base;

  loop
    begin
      insert into public.companies (name, display_name, slug)
      values (v_name, v_name, v_slug)
      returning id into v_company;
      exit;
    exception when unique_violation then
      v_n := v_n + 1;
      v_slug := v_base || '-' || v_n;
    end;
  end loop;

  update public.leads
     set status = 'converted', converted_company_id = v_company
   where id = p_lead_id;

  -- ids only: the audit log never holds names or emails
  perform public.write_audit('company.created', 'company', v_company, jsonb_build_object('lead_id', p_lead_id));
  return v_company;
end;
$$;

revoke execute on function public.convert_lead_to_company(uuid, text) from public, anon;
grant execute on function public.convert_lead_to_company(uuid, text) to authenticated;

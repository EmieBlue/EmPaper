-- EmPaper initial schema
-- Run once in Supabase Studio -> SQL Editor (Project -> SQL Editor -> New query -> paste -> Run).
-- Not idempotent by design (plain CREATE TABLE, no IF NOT EXISTS) -- it should fail loudly on a
-- second run rather than silently no-op. Drop tables manually first if you need to re-apply in dev.

create extension if not exists pgcrypto;

-- ─────────────────────────────────────────────────────────────────────────
-- companies (tenants)
-- ─────────────────────────────────────────────────────────────────────────
create table public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────────────
-- employees -- id == auth.users.id; one row per portal user (employee or admin)
-- ─────────────────────────────────────────────────────────────────────────
create table public.employees (
  id                   uuid primary key references auth.users (id) on delete cascade,
  company_id           uuid not null references public.companies (id) on delete cascade,
  role                 text not null default 'employee' check (role in ('employee', 'admin')),
  full_name            text not null,
  email                text not null,
  job_title            text,
  phone                text,
  address              text,
  bank_name            text,
  bank_account_name    text,
  bank_account_number  text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index employees_company_id_idx on public.employees (company_id);

-- ─────────────────────────────────────────────────────────────────────────
-- payslips -- one row per employee per period; file itself lives in Storage later
-- ─────────────────────────────────────────────────────────────────────────
create table public.payslips (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references public.employees (id) on delete cascade,
  company_id    uuid not null references public.companies (id) on delete cascade,
  period_month  date not null, -- convention: first-of-month, e.g. 2026-09-01
  storage_path  text,          -- Supabase Storage object path; null until the file lands
  created_at    timestamptz not null default now(),
  unique (employee_id, period_month)
);

create index payslips_employee_id_idx on public.payslips (employee_id);
create index payslips_company_id_idx on public.payslips (company_id);

-- ─────────────────────────────────────────────────────────────────────────
-- letters -- introductory / employment letter requests
-- ─────────────────────────────────────────────────────────────────────────
create table public.letters (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references public.employees (id) on delete cascade,
  company_id    uuid not null references public.companies (id) on delete cascade,
  type          text not null check (type in ('introductory', 'employment')),
  status        text not null default 'requested' check (status in ('requested', 'ready')),
  storage_path  text,
  requested_at  timestamptz not null default now(),
  ready_at      timestamptz,
  created_at    timestamptz not null default now()
);

create index letters_employee_id_idx on public.letters (employee_id);
create index letters_company_id_idx on public.letters (company_id);

-- ─────────────────────────────────────────────────────────────────────────
-- leads -- public /demo page submissions; no auth, not tied to a real company yet
-- ─────────────────────────────────────────────────────────────────────────
create table public.leads (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  company_name      text not null,
  work_email        text not null,
  number_of_people  integer not null check (number_of_people > 0),
  created_at        timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────────────
-- helper functions -- SECURITY DEFINER so the lookup bypasses RLS itself and
-- never triggers recursive policy evaluation when used inside policies below
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.current_employee_company_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select company_id from public.employees where id = auth.uid();
$$;

create or replace function public.is_company_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.employees
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- updated_at maintenance
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_companies_set_updated_at
before update on public.companies
for each row
execute function public.set_updated_at();

create trigger trg_employees_set_updated_at
before update on public.employees
for each row
execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────
-- guard: an employee can never move themselves to another company_id, or
-- grant themselves 'admin', via a self-service UPDATE. This pins both
-- columns back to their OLD value on every UPDATE unless a session-local
-- flag is explicitly set first. There is no code that sets that flag yet --
-- a future admin-only RPC (e.g. public.set_employee_role(...)) is the only
-- intended way to legitimately change these two columns, and it is not
-- built in this pass.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.protect_employee_privileged_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('empaper.bypass_privileged_guard', true), 'false') = 'true' then
    return new;
  end if;

  new.company_id := old.company_id;
  new.role := old.role;
  return new;
end;
$$;

create trigger trg_protect_employee_privileged_columns
before update on public.employees
for each row
execute function public.protect_employee_privileged_columns();

-- ─────────────────────────────────────────────────────────────────────────
-- keep payslips.company_id / letters.company_id in sync with the employee's
-- actual company, regardless of what a client sends -- simplifies admin RLS
-- (no join needed) and removes any chance of a mismatched tenant tag
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.sync_company_id_from_employee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select company_id into new.company_id
  from public.employees
  where id = new.employee_id;

  if new.company_id is null then
    raise exception 'employee % not found or has no company_id', new.employee_id;
  end if;

  return new;
end;
$$;

create trigger trg_payslips_sync_company_id
before insert or update on public.payslips
for each row
execute function public.sync_company_id_from_employee();

create trigger trg_letters_sync_company_id
before insert or update on public.letters
for each row
execute function public.sync_company_id_from_employee();

-- ─────────────────────────────────────────────────────────────────────────
-- row level security
-- ─────────────────────────────────────────────────────────────────────────
alter table public.companies enable row level security;
alter table public.employees enable row level security;
alter table public.payslips  enable row level security;
alter table public.letters   enable row level security;
alter table public.leads     enable row level security;

-- companies: any portal user may read their own company row
create policy companies_select_own
on public.companies
for select
to authenticated
using (id = public.current_employee_company_id());

-- employees: self select, self update, admin select scoped to own company
create policy employees_select_own
on public.employees
for select
to authenticated
using (id = auth.uid());

create policy employees_select_company_admin
on public.employees
for select
to authenticated
using (
  public.is_company_admin()
  and company_id = public.current_employee_company_id()
);

create policy employees_update_own
on public.employees
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- payslips: self select, admin select scoped to own company (no insert/update --
-- payslips are created by a future backend/payroll process using service_role,
-- which bypasses RLS entirely)
create policy payslips_select_own
on public.payslips
for select
to authenticated
using (employee_id = auth.uid());

create policy payslips_select_company_admin
on public.payslips
for select
to authenticated
using (
  public.is_company_admin()
  and company_id = public.current_employee_company_id()
);

-- letters: self select, self insert (request only, must start 'requested'),
-- admin select scoped to own company. No update policy: the 'requested' ->
-- 'ready' transition is backend/service_role-only in this pass.
create policy letters_select_own
on public.letters
for select
to authenticated
using (employee_id = auth.uid());

create policy letters_select_company_admin
on public.letters
for select
to authenticated
using (
  public.is_company_admin()
  and company_id = public.current_employee_company_id()
);

create policy letters_insert_own
on public.letters
for insert
to authenticated
with check (employee_id = auth.uid() and status = 'requested');

-- leads: public insert-only, no select policy for anyone (view via Supabase
-- Studio's table editor, which runs as service_role and bypasses RLS)
create policy leads_insert_public
on public.leads
for insert
to anon, authenticated
with check (true);

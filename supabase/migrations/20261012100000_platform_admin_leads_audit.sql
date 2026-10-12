-- EmPaper M1: owner (platform admin) role, leads pipeline, audit log.
-- Run in Supabase Studio -> SQL Editor -> New query -> paste -> Run. Safe to run again.
-- After it succeeds: run supabase/seed/owner_seed.sql once (with your email), then supabase/tests/m1_rls_test.sql.

-- platform_admins: no policies on purpose (only the definer function and the service role read it)
create table if not exists public.platform_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  require_mfa boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table public.platform_admins enable row level security;

create or replace function public.is_platform_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.platform_admins pa
    where pa.user_id = auth.uid()
      and (not pa.require_mfa or coalesce(auth.jwt()->>'aal','aal1') = 'aal2')
  );
$$;
-- Supabase's default privileges also grant EXECUTE to anon, so "from public" alone is not enough.
revoke execute on function public.is_platform_admin() from public, anon;
grant  execute on function public.is_platform_admin() to authenticated;

-- leads pipeline
alter table public.leads
  add column if not exists status text not null default 'new',
  add column if not exists owner_notes text,
  add column if not exists contacted_at timestamptz,
  add column if not exists converted_company_id uuid references public.companies(id) on delete set null,
  add column if not exists updated_at timestamptz not null default now();

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'leads_status_check') then
    alter table public.leads add constraint leads_status_check
      check (status in ('new','contacted','qualified','converted','lost'));
  end if;
end $$;

create index if not exists leads_status_created_idx on public.leads (status, created_at desc);

drop trigger if exists trg_leads_set_updated_at on public.leads;
create trigger trg_leads_set_updated_at before update on public.leads
  for each row execute function public.set_updated_at();

-- Public demo form: still insert-only, and only as a brand-new lead.
-- api/lead.ts and the demo.astro fallback never send the pipeline columns, so the defaults pass this check.
drop policy if exists leads_insert_public on public.leads;
create policy leads_insert_public on public.leads for insert to anon, authenticated
  with check (status = 'new' and owner_notes is null and contacted_at is null
              and converted_company_id is null);

drop policy if exists leads_platform_select on public.leads;
create policy leads_platform_select on public.leads for select to authenticated
  using (public.is_platform_admin());
drop policy if exists leads_platform_update on public.leads;
create policy leads_platform_update on public.leads for update to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists leads_platform_delete on public.leads;
create policy leads_platform_delete on public.leads for delete to authenticated
  using (public.is_platform_admin());

-- audit_log: written only by definer functions/triggers; readable by the owner only
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor_id    uuid,
  action      text not null,
  entity_type text not null,
  entity_id   uuid,
  details     jsonb not null default '{}'   -- ids and enums only, never emails or names
);
alter table public.audit_log enable row level security;
drop policy if exists audit_platform_select on public.audit_log;
create policy audit_platform_select on public.audit_log for select to authenticated
  using (public.is_platform_admin());

create or replace function public.write_audit(p_action text, p_type text, p_id uuid, p_details jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_log(actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), p_action, p_type, p_id, coalesce(p_details, '{}'::jsonb));
$$;
revoke execute on function public.write_audit(text, text, uuid, jsonb) from public, anon, authenticated;

-- When a lead's status changes: stamp contacted_at the first time it becomes 'contacted', and write the audit row.
-- security definer, because write_audit is not executable by the signed-in user.
create or replace function public.leads_on_status_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'contacted' and new.contacted_at is null then
      new.contacted_at := now();
    end if;
    perform public.write_audit('lead.status_changed', 'lead', new.id,
      jsonb_build_object('from', old.status, 'to', new.status));
  end if;
  return new;
end;
$$;
revoke execute on function public.leads_on_status_change() from public, anon, authenticated;

drop trigger if exists trg_leads_status_change on public.leads;
create trigger trg_leads_status_change before update on public.leads
  for each row execute function public.leads_on_status_change();

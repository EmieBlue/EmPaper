-- Adds optional lead-qualification fields to public.leads: which feature
-- areas a prospect is most interested in, and free-text notes. Both are
-- optional on the /demo form, so interested_features defaults to an empty
-- array and notes is nullable.
--
-- Apply manually via Supabase Studio -> SQL Editor, same as the init
-- migration (no CLI-managed migration pipeline in this project yet).

alter table public.leads
  add column interested_features text[] not null default '{}',
  add column notes text;

-- EmPaper: two optional hints from the /demo form about the company's look.
-- logo_status: did they say they have a logo (yes / no / unsure). brand_colours: free text, e.g. "navy and gold" or "#12304A".
-- Both are optional and nullable, so existing rows and requests that skip the questions are unaffected.
-- Safe to run more than once. Run this BEFORE the website change that sends these fields goes live.

alter table public.leads
  add column if not exists logo_status text,
  add column if not exists brand_colours text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'leads_logo_status_check') then
    alter table public.leads add constraint leads_logo_status_check
      check (logo_status is null or logo_status in ('yes', 'no', 'unsure'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'leads_brand_colours_len_check') then
    alter table public.leads add constraint leads_brand_colours_len_check
      check (brand_colours is null or char_length(brand_colours) <= 100);
  end if;
end $$;

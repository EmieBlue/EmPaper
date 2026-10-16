# EmPaper handoff

Read this first in any new Claude session or on a new computer. It carries the project state, the decisions and the way of working. It contains no secrets and must never gain any (this repository is public).

Last updated: 2026-10-16.

## What EmPaper is

An HR self-service product for companies in Ghana and across Africa: pay letters, time off and holidays, people directory, "My Info", company files and announcements, and an inbox with instant answers. The public marketing site is live. The back-office (the owner console, "a WordPress for EmPaper") is being built in small steps.

The founder is one non-technical person. Explain things in short, plain English with exact click paths, and confirm risky actions before doing them. They say "push" or "go" when they want an action.

## Where things live

- Code: GitHub `EmieBlue/EmPaper`. `main` is protected: changes go through a pull request, CI ("CI") and Vercel must pass, and the founder clicks **Squash and merge** themselves.
- Website: Astro static site on Vercel at `https://em-paper.vercel.app`. Server functions are in `api/` (Vercel Functions). Only `api/lead.ts` exists today: it saves a demo request to Supabase and emails an alert through Gmail.
- Database and logins: Supabase (Postgres, Auth, Storage). Migrations are in `supabase/migrations/`. There is no Supabase CLI: the founder pastes each SQL file into Supabase, SQL Editor, New query, Run. Every migration has a rollback-safe permission test in `supabase/tests/` that must answer "ALL PASS".
- Plans and issues: GitHub issues, milestone "Owner console" (#13 to #20), plus roadmap issues #2 to #12.

## What is done

- Marketing site: home, features, for-companies, demo, pricing placeholder. Rebrand (tagline "Your Digital Workplace, All in One.", navy/teal/blue palette) is in `src/styles/tokens.css`.
- Demo form with interest checkboxes and notes; every request is saved and emailed to the founder.
- GitHub workflow, automatic checks and protected `main`.
- **Phase 1 (merged, #21):** `platform_admins` (who is the owner), `is_platform_admin()`, leads pipeline columns (status, owner notes, contacted time), `audit_log`, tightened public insert rule. Tested locally in CI with PGlite and in the real Supabase ("M1 RLS: ALL PASS").
- **Demo form branding hints (merged, #24):** two optional text questions on /demo, "Does your company have a logo?" (`leads.logo_status`: yes / no / unsure) and "Brand colours" (`leads.brand_colours`, max 100 characters). Shown in the alert email and in /admin/leads. Deliberately NO file upload on the public form (spam, storage cost, unsafe files, fewer completions). Migration `20261016100000_add_lead_branding_hints.sql` and test `m1b_lead_branding_test.sql` were applied in Supabase ("M1b ALL PASS"). Also `docs/EmPaper-how-it-works.pdf`, a 2-page plain-English overview for the founder.
- **Phase 2 (merged, #22):** owner console at `/admin` (sign-in, overview counts, demo requests list with status and private notes). Verified by the founder against the real database.

## What is next (one pull request each)

- **Phase 0 leftovers (founder, no code):** turn off public sign-ups in Supabase; set Auth Site URL to `https://em-paper.vercel.app` and redirects `https://*-haulio-cargo.vercel.app/**` and `http://localhost:4321/**`; add `SUPABASE_SERVICE_ROLE_KEY` in Vercel as Sensitive (Production and Preview, never pasted in chat); 2-step login on Supabase, Vercel and GitHub; delete the test lead in Supabase; buy a domain. Ask the founder which are still open.
- **P3:** convert a lead to a client company (migration M2: company branding columns and a `convert_lead_to_company` function, plus Companies pages).
- **P4:** branding link the founder sends to a client; the client uploads a logo and picks colours; founder approves (migration M3, `api/brand.ts`). The page also offers **"We don't have a logo"**: then `branding_submissions.logo_path` is nullable with `no_logo boolean not null default false` (a submission needs a logo, or no_logo, or at least colours), and the portal shows a text wordmark (the company display name in the brand colour) instead of an image.
- **P5:** "Invite HR admin" produces a copy-and-send link (no automatic email until a domain exists) (migration M4, `api/invite-hr.ts`, accept-invite and welcome pages).
- **P6 (optional):** 2-step login for the owner inside the app. **P7 (optional):** audit page.
- Later: pricing page (#2, show both GHS and USD), privacy page (#3), domain and email (#4), HR portal and employee portal (#11).

## Decisions the founder made

1. First version is the owner console only.
2. Clients give logo and colours through a link the founder sends.
3. No client is waiting, so build it properly, in small steps.
4. No domain yet, so nothing emails clients or HR automatically.
5. Pricing waits until the console is done.

## Design rules to keep

- Static site. Private pages are static shells that run `supabase-js` in the browser. **The database rules (RLS) are the real lock**, the page guard is only convenience.
- Owner identity = a row in `platform_admins`, checked by `is_platform_admin()`. Never trust `user_metadata` for permissions.
- Server functions (service-role key) verify the caller first, never log emails, names, tokens or request bodies, and return `Cache-Control: no-store`.
- Vercel type-checks `api/` without strict null checks: return `T | string` and narrow with `typeof`, not `{ok:true}|{ok:false}`. Run `npm run check:api`.
- Show lead data with `textContent`, never `innerHTML` (it comes from a public form).
- Do not use `<section>` or `BaseLayout` in app pages; use `AppLayout` and styles scoped under `.app` / `.auth` in `src/styles/app.css`.
- New policies: write `using ((select public.is_platform_admin()))` so it is evaluated once per query.
- Branding link design: random token in the URL fragment (`/brand#token`), only its SHA-256 hash stored, expiry plus revoke, upload caps, PNG/JPEG/WebP only (no SVG), file type decided by magic bytes, hex colours only, WCAG contrast check with a computed on-accent text colour.
- HR invite design: `auth.admin.generateLink({type:'invite'})` returns a `hashed_token`; the browser builds `/accept-invite#token_hash=...&type=invite`. Do not hand out the raw `action_link`.

## Before the first paying client (track as issues)

- Vercel Hobby forbids commercial use: move to Vercel Pro.
- Supabase Free pauses when idle and has no backups: move to Supabase Pro before real payroll data.
- Email to 1,000+ staff needs an owned domain, a transactional email service (SPF/DKIM/DMARC) and Supabase custom SMTP.
- Ghana Data Protection Act 2012: lawyer, data processing agreement per client, privacy policy and terms, breach plan.

## How to work (every phase)

1. New branch from up-to-date `main`.
2. Build, then run `npm run ci` (type-check `api/`, tests, build). Test in a real browser with faked database answers where it helps.
3. Push and open a pull request with a plain-English description (what changes for visitors, why, how it was checked, what the owner must do). End the description with the Claude Code attribution line.
4. Wait for CI and Vercel to turn green, then the founder squash-merges.
5. Database changes: the founder pastes the migration, then the permission test, and reports the result.

Git on the work laptop pushed with a one-command override of the stored credential (`git -c credential.helper= -c "credential.helper=!gh auth git-credential" push ...`) after `gh auth login`. Do not change the user's git config.

## Setting up a new computer

1. Install Git, Node 24, GitHub CLI and Claude Code.
2. `gh auth login` (GitHub.com, HTTPS, sign in with the browser).
3. `git clone https://github.com/EmieBlue/EmPaper.git`, then `cd EmPaper` and `npm ci`.
4. Create `.env.local` from the names in `.env.example` (`PUBLIC_SUPABASE_URL`, `PUBLIC_SUPABASE_ANON_KEY`). Get the values from the Supabase dashboard under Project Settings, API. Never paste keys into chat and never commit this file. The service-role key and Gmail app password live only in Vercel's Environment Variables.
5. Start Claude Code in the project folder and send the first message below.

First message for the new computer:

> This is the EmPaper project. Read docs/HANDOFF.md and CLAUDE.md, check `git log` and the open GitHub issues and pull requests, then tell me in plain English where we are and what the next step is. Remember I am not technical: short steps, exact click paths, never ask me for passwords or keys.

// Vercel Function for the /demo form: validate, save the lead to Supabase, then email the owner via Resend.
// The demo page treats a 404 from this route as "function not deployed" and falls back to a direct insert,
// so this handler must never return 404.

declare const process: { env: Record<string, string | undefined> };

const INTEREST_LABELS: Record<string, string> = {
  pay_letters: 'Pay & Letters',
  time_off_holidays: 'Time Off & Holidays',
  people_directory: 'People Directory',
  my_info: 'My Info',
  company_files_announcements: 'Company Files & Announcements',
  inbox_instant_answers: 'Inbox & Instant Answers',
};

const MAX_BODY_BYTES = 20_000;
const UPSTREAM_TIMEOUT_MS = 8000;
const EMAIL_RE = /^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]{2,}$/;
const SUBMISSION_ID_RE = /^[\w-]{8,100}$/;
const GENERIC_ERROR = "We couldn't save your request. Please try again.";

type Lead = {
  name: string;
  company: string;
  email: string;
  people: number;
  interests: string[];
  notes: string;
};

type Validation = { ok: true; lead: Lead } | { ok: false; message: string };

function json(status: number, body: Record<string, unknown>, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...extraHeaders },
  });
}

function cleanLine(value: unknown): string {
  if (typeof value !== 'string') return '';
  return value.replace(/[\u0000-\u001F\u007F]+/g, ' ').replace(/\s+/g, ' ').trim();
}

function cleanMultiline(value: unknown): string {
  if (typeof value !== 'string') return '';
  return value
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, '')
    .trim();
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function validate(raw: Record<string, unknown>): Validation {
  const name = cleanLine(raw.name);
  if (!name) return { ok: false, message: 'Please enter your name.' };
  if (name.length > 120) return { ok: false, message: 'Name is too long (120 characters max).' };

  const company = cleanLine(raw.company);
  if (!company) return { ok: false, message: 'Please enter your company name.' };
  if (company.length > 160) return { ok: false, message: 'Company name is too long (160 characters max).' };

  const email = cleanLine(raw.email);
  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return { ok: false, message: 'Please enter a valid work email.' };
  }

  const peopleRaw = typeof raw.people === 'string' ? raw.people.trim() : raw.people;
  const people =
    typeof peopleRaw === 'number' ? peopleRaw : /^\d+$/.test(String(peopleRaw)) ? Number(peopleRaw) : NaN;
  if (!Number.isInteger(people) || people < 1 || people > 100000) {
    return { ok: false, message: 'Team size must be a whole number of at least 1.' };
  }

  const notes = cleanMultiline(raw.notes);
  if (notes.length > 2000) return { ok: false, message: 'Notes are too long (2000 characters max).' };

  const interests = Array.isArray(raw.interests)
    ? [...new Set(raw.interests)].filter(
        (slug): slug is string =>
          typeof slug === 'string' && Object.prototype.hasOwnProperty.call(INTEREST_LABELS, slug),
      )
    : [];

  return { ok: true, lead: { name, company, email, people, interests, notes } };
}

function buildEmail(lead: Lead): { subject: string; html: string; text: string } {
  const interests = lead.interests.length
    ? lead.interests.map((slug) => INTEREST_LABELS[slug]).join(', ')
    : 'None selected';
  const submittedAt = `${new Date().toISOString().replace('T', ' ').slice(0, 19)} UTC`;

  const rows: Array<[string, string]> = [
    ['Name', lead.name],
    ['Company', lead.company],
    ['Work email', lead.email],
    ['Team size', String(lead.people)],
    ['Interested in', interests],
    ['Notes', lead.notes || '—'],
    ['Submitted', submittedAt],
  ];

  // name and company went through cleanLine(), so the subject is guaranteed single-line.
  const subject = `New demo request — ${lead.company} (${lead.people} people)`.slice(0, 120);

  const html =
    `<div style="font-family:Arial,Helvetica,sans-serif;color:#172b3a;max-width:560px">` +
    `<h2 style="margin:0 0 12px;font-size:18px">New demo request</h2>` +
    `<table style="border-collapse:collapse;width:100%">` +
    rows
      .map(
        ([label, value]) =>
          `<tr><td style="padding:8px 12px 8px 0;color:#64748b;vertical-align:top;white-space:nowrap">${escapeHtml(label)}</td>` +
          `<td style="padding:8px 0;white-space:pre-wrap">${escapeHtml(value)}</td></tr>`,
      )
      .join('') +
    `</table>` +
    `<p style="margin:16px 0 0;color:#64748b;font-size:13px">Reply to this email to answer ${escapeHtml(lead.name)} directly.</p>` +
    `</div>`;

  const text =
    rows.map(([label, value]) => `${label}: ${value}`).join('\n') +
    `\n\nReply to this email to answer ${lead.name} directly.`;

  return { subject, html, text };
}

function redact(message: string, lead: Lead): string {
  let out = message;
  for (const value of [lead.email, lead.name, lead.company]) {
    if (value.length >= 3) out = out.split(value).join('[redacted]');
  }
  return out.slice(0, 200);
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : 'unknown';
}

async function insertLead(lead: Lead, supabaseUrl: string, anonKey: string): Promise<number> {
  const response = await fetch(`${supabaseUrl.replace(/\/+$/, '')}/rest/v1/leads`, {
    method: 'POST',
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${anonKey}`,
      'Content-Type': 'application/json',
      // return=minimal is required: the anon role has no SELECT policy on leads, so the row can't be read back.
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({
      name: lead.name,
      company_name: lead.company,
      work_email: lead.email,
      number_of_people: lead.people,
      interested_features: lead.interests,
      notes: lead.notes,
    }),
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
  return response.status;
}

async function notifyOwner(lead: Lead, submissionId: string): Promise<void> {
  const apiKey = process.env.RESEND_API_KEY;
  const to = process.env.LEAD_NOTIFY_EMAIL;
  if (!apiKey || !to) {
    console.warn('NOTIFY_SKIPPED: RESEND_API_KEY or LEAD_NOTIFY_EMAIL is not set');
    return;
  }

  const { subject, html, text } = buildEmail(lead);
  const headers: Record<string, string> = {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
  };
  if (SUBMISSION_ID_RE.test(submissionId)) headers['Idempotency-Key'] = submissionId;

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers,
    body: JSON.stringify({
      from: process.env.LEAD_FROM_EMAIL || 'EmPaper Leads <onboarding@resend.dev>',
      to: [to],
      reply_to: lead.email,
      subject,
      html,
      text,
    }),
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    console.error(`NOTIFY_FAILED status=${response.status} ${redact(detail, lead)}`);
  }
}

export default {
  async fetch(request: Request): Promise<Response> {
    if (request.method !== 'POST') {
      return json(405, { ok: false, message: 'Method not allowed.' }, { Allow: 'POST' });
    }

    const bodyText = await request.text();
    if (new TextEncoder().encode(bodyText).length > MAX_BODY_BYTES) {
      return json(413, { ok: false, message: 'Request too large.' });
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(bodyText);
    } catch {
      return json(400, { ok: false, message: 'Invalid request.' });
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return json(400, { ok: false, message: 'Invalid request.' });
    }
    const body = parsed as Record<string, unknown>;

    // Bots fill the hidden "website" field; pretend success so they don't retry.
    if (typeof body.website === 'string' && body.website.trim() !== '') {
      return json(200, { ok: true });
    }

    const result = validate(body);
    if (!result.ok) return json(400, { ok: false, message: result.message });
    const { lead } = result;

    const supabaseUrl = process.env.PUBLIC_SUPABASE_URL;
    const anonKey = process.env.PUBLIC_SUPABASE_ANON_KEY;
    if (!supabaseUrl || !anonKey) {
      console.error(`CONFIG_MISSING: ${!supabaseUrl ? 'PUBLIC_SUPABASE_URL' : 'PUBLIC_SUPABASE_ANON_KEY'}`);
      return json(500, { ok: false, message: GENERIC_ERROR });
    }

    try {
      const status = await insertLead(lead, supabaseUrl, anonKey);
      if (status < 200 || status >= 300) {
        console.error(`INSERT_FAILED status=${status}`);
        return json(500, { ok: false, message: GENERIC_ERROR });
      }
    } catch (err) {
      console.error(`INSERT_FAILED error=${errorName(err)}`);
      return json(502, { ok: false, message: GENERIC_ERROR });
    }

    const submissionId = typeof body.submissionId === 'string' ? body.submissionId : '';
    try {
      await notifyOwner(lead, submissionId);
    } catch (err) {
      console.error(`NOTIFY_FAILED error=${errorName(err)}`);
    }

    return json(200, { ok: true });
  },
};

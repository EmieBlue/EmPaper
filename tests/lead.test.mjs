import assert from 'node:assert/strict';
import nodemailer from 'nodemailer';
import handler from '../api/lead.ts';

// Exercises api/lead.ts against stubbed Supabase and SMTP, so it needs no network or credentials. Run: npm test

const PII = { name: 'Ada Obi', company: 'Riverstone Ltd', email: 'ada@riverstone.test', notes: 'secret-note-123' };
const APP_PASSWORD = 'abcd efgh ijkl mnop';
const validBody = (over = {}) => ({
  name: PII.name,
  company: PII.company,
  email: PII.email,
  people: 25,
  interests: ['pay_letters', 'time_off_holidays'],
  notes: PII.notes,
  website: '',
  ...over,
});

const logs = [];
const statuses = [];
for (const level of ['log', 'warn', 'error']) {
  console[level] = (...args) => logs.push(`${level}: ${args.join(' ')}`);
}
const report = (line) => process.stdout.write(line + '\n');

let fetchCalls = [];
let sentMail = [];
let transports = [];
let closedCount = 0;
let supabaseResponder;
let sendMailResponder;

globalThis.fetch = async (url, init = {}) => {
  fetchCalls.push({ url: String(url), init });
  assert.ok(String(url).includes('supabase'), `unexpected fetch to ${url} (email must go through SMTP only)`);
  return supabaseResponder(init);
};
nodemailer.createTransport = (options) => {
  transports.push(options);
  return {
    sendMail: async (message) => {
      sentMail.push(message);
      return sendMailResponder(message);
    },
    close: () => {
      closedCount += 1;
    },
  };
};

function resetEnv() {
  process.env.PUBLIC_SUPABASE_URL = 'https://example.supabase.co';
  process.env.PUBLIC_SUPABASE_ANON_KEY = 'anon-key-test';
  process.env.GMAIL_USER = 'sender@gmail.test';
  process.env.GMAIL_APP_PASSWORD = APP_PASSWORD;
  process.env.LEAD_NOTIFY_EMAIL = 'owner@example.com';
  supabaseResponder = () => new Response(null, { status: 201 });
  sendMailResponder = async () => ({ accepted: ['owner@example.com'] });
  fetchCalls = [];
  sentMail = [];
  transports = [];
  closedCount = 0;
}

async function post(body, { raw, method = 'POST' } = {}) {
  const payload = raw !== undefined ? raw : JSON.stringify(body);
  const req = new Request('https://example.com/api/lead', {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: method === 'GET' || method === 'HEAD' ? undefined : payload,
  });
  const res = await handler.fetch(req);
  statuses.push(res.status);
  return res;
}

const results = [];
async function test(name, fn) {
  resetEnv();
  try {
    await fn();
    results.push([true, name]);
  } catch (err) {
    results.push([false, `${name}\n      ${String(err.message).split('\n').join('\n      ')}`]);
  }
}

const insertBody = () => JSON.parse(fetchCalls.find((c) => c.url.includes('supabase')).init.body);

await test('valid lead: insert, then one email with the right envelope and transport', async () => {
  const res = await post(validBody());
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
  assert.equal(fetchCalls.length, 1);
  assert.ok(fetchCalls[0].url.startsWith('https://example.supabase.co/rest/v1/leads'));
  const h = fetchCalls[0].init.headers;
  assert.equal(h.apikey, 'anon-key-test');
  assert.equal(h.Authorization, 'Bearer anon-key-test');
  assert.equal(h.Prefer, 'return=minimal');
  assert.deepEqual(Object.keys(insertBody()).sort(), ['company_name', 'interested_features', 'name', 'notes', 'number_of_people', 'work_email']);
  assert.deepEqual(insertBody().interested_features, ['pay_letters', 'time_off_holidays']);
  assert.equal(insertBody().number_of_people, 25);

  assert.equal(transports.length, 1);
  assert.equal(transports[0].host, 'smtp.gmail.com');
  assert.equal(transports[0].port, 465);
  assert.equal(transports[0].secure, true);
  assert.equal(transports[0].auth.user, 'sender@gmail.test');
  assert.equal(sentMail.length, 1);
  const m = sentMail[0];
  assert.equal(m.from, '"EmPaper Leads" <sender@gmail.test>');
  assert.equal(m.to, 'owner@example.com');
  assert.equal(m.replyTo, PII.email);
  assert.ok(m.subject.includes('Riverstone Ltd') && m.subject.includes('25 people'));
  assert.ok(m.html.includes('Pay &amp; Letters') && m.html.includes('Time Off &amp; Holidays'));
  assert.ok(m.text.includes('Time Off & Holidays') && m.text.includes(PII.email) && m.text.includes(PII.notes));
  assert.equal(closedCount, 1, 'transport must be closed after sending');
  assert.equal(res.headers.get('Content-Type'), 'application/json');
  assert.equal(res.headers.get('Cache-Control'), 'no-store');
});

await test('app password: spaces from Google\'s display format are stripped', async () => {
  await post(validBody());
  assert.equal(transports[0].auth.pass, 'abcdefghijklmnop');
});

await test('honeypot filled: silent 200, nothing saved or sent', async () => {
  const res = await post(validBody({ website: 'http://spam.example' }));
  assert.equal(res.status, 200);
  assert.equal(fetchCalls.length + sentMail.length + transports.length, 0);
});

await test('malformed bodies rejected, nothing saved or sent', async () => {
  assert.equal((await post(null, { raw: '{not json' })).status, 400);
  assert.equal((await post(null, { raw: '' })).status, 400);
  assert.equal((await post(null, { raw: '[]' })).status, 400);
  assert.equal((await post(null, { raw: 'null' })).status, 400);
  assert.equal((await post(validBody({ notes: 'x'.repeat(25000) }))).status, 413);
  assert.equal(fetchCalls.length + sentMail.length, 0);
});

await test('validation failures return 400 with a message, nothing saved or sent', async () => {
  const bad = [
    validBody({ name: '' }),
    validBody({ name: '   ' }),
    validBody({ company: '' }),
    validBody({ email: '' }),
    validBody({ email: 'nope' }),
    validBody({ email: 'a@b.com,c@d.com' }),
    validBody({ email: 'a b@c.com' }),
    validBody({ email: 'a@b' }),
    validBody({ email: '<x@y.com>' }),
    validBody({ people: 0 }),
    validBody({ people: -1 }),
    validBody({ people: 1.5 }),
    validBody({ people: 'abc' }),
    validBody({ people: '1.5' }),
    validBody({ people: 100001 }),
    validBody({ people: undefined }),
    validBody({ name: 'n'.repeat(121) }),
    validBody({ company: 'c'.repeat(161) }),
    validBody({ notes: 'z'.repeat(2001) }),
  ];
  for (const body of bad) {
    const res = await post(body);
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 80));
    const j = await res.json();
    assert.equal(j.ok, false);
    assert.ok(typeof j.message === 'string' && j.message.length > 0);
  }
  assert.equal(fetchCalls.length + sentMail.length, 0);
});

await test('numeric-string people and boundary values accepted', async () => {
  assert.equal((await post(validBody({ people: '12' }))).status, 200);
  assert.equal(insertBody().number_of_people, 12);
  assert.equal((await post(validBody({ people: 1 }))).status, 200);
  assert.equal((await post(validBody({ people: 100000 }))).status, 200);
  assert.equal((await post(validBody({ name: 'n'.repeat(120), company: 'c'.repeat(160), notes: 'z'.repeat(2000) }))).status, 200);
});

await test('unknown / duplicate / prototype interest slugs are dropped', async () => {
  const res = await post(validBody({ interests: ['pay_letters', 'pay_letters', '__proto__', 'constructor', 'toString', 'evil', 5, null] }));
  assert.equal(res.status, 200);
  assert.deepEqual(insertBody().interested_features, ['pay_letters']);
  fetchCalls = [];
  assert.equal((await post(validBody({ interests: 'pay_letters' }))).status, 200);
  assert.deepEqual(insertBody().interested_features, []);
});

await test('HTML in name/company/notes is escaped in the email html', async () => {
  await post(validBody({ name: '<script>alert(1)</script>', company: '<img src=x onerror=1>', notes: '"><b>x</b>' }));
  const { html, text } = sentMail[0];
  assert.ok(!html.includes('<script>') && !html.includes('<img') && !html.includes('<b>x</b>'));
  assert.ok(html.includes('&lt;script&gt;') && html.includes('&lt;img'));
  assert.ok(text.includes('<script>alert(1)</script>'));
});

await test('CR/LF in company cannot break the subject line', async () => {
  await post(validBody({ company: 'Acme\r\nBcc: evil@x.com' }));
  assert.ok(!/[\r\n]/.test(sentMail[0].subject));
  assert.ok(sentMail[0].subject.includes('Acme'));
});

await test('empty notes stored as empty string and shown as a dash', async () => {
  await post(validBody({ notes: '' }));
  assert.equal(insertBody().notes, '');
  assert.ok(sentMail[0].text.includes('Notes: —'));
});

await test('multiple recipients in LEAD_NOTIFY_EMAIL pass through unchanged', async () => {
  process.env.LEAD_NOTIFY_EMAIL = 'a@example.com, b@example.com';
  await post(validBody());
  assert.equal(sentMail[0].to, 'a@example.com, b@example.com');
});

await test('Supabase non-2xx: 500, no email attempted', async () => {
  for (const status of [401, 403, 500]) {
    sentMail = [];
    transports = [];
    supabaseResponder = () => new Response('{"message":"nope"}', { status });
    const res = await post(validBody());
    assert.equal(res.status, 500);
    assert.equal((await res.json()).ok, false);
    assert.equal(sentMail.length + transports.length, 0);
  }
});

await test('Supabase throws/times out: 502, no email attempted', async () => {
  supabaseResponder = () => {
    throw new DOMException('timed out', 'TimeoutError');
  };
  const res = await post(validBody());
  assert.equal(res.status, 502);
  assert.equal(sentMail.length + transports.length, 0);
});

await test('rejected Gmail login: still 200, lead saved, error logged without PII, transport closed', async () => {
  sendMailResponder = async () => {
    const err = new Error(`Invalid login: 535-5.7.8 Username and Password not accepted for ${PII.email} (${PII.name})`);
    err.code = 'EAUTH';
    err.responseCode = 535;
    throw err;
  };
  const res = await post(validBody());
  assert.equal(res.status, 200);
  assert.equal(fetchCalls.length, 1);
  assert.equal(closedCount, 1, 'transport must close even when sending fails');
  const line = logs.filter((l) => l.includes('NOTIFY_FAILED')).at(-1);
  assert.ok(line.includes('code=EAUTH') && line.includes('smtp=535'), line);
  assert.ok(line.includes('[redacted]'), line);
  assert.ok(!line.includes(PII.email) && !line.includes(PII.name), line);
});

await test('SMTP server that never answers: request still completes (~8s) with 200', async () => {
  sendMailResponder = () => new Promise(() => {});
  const started = Date.now();
  const res = await post(validBody());
  const elapsed = Date.now() - started;
  assert.equal(res.status, 200);
  assert.ok(elapsed >= 7500 && elapsed < 12000, `expected ~8s, took ${elapsed}ms`);
  assert.equal(closedCount, 1);
  assert.ok(logs.some((l) => l.includes('NOTIFY_FAILED') && l.includes('Timed out')));
});

await test('missing Gmail/notify config: 200, lead saved, warning, no transport created', async () => {
  for (const key of ['GMAIL_USER', 'GMAIL_APP_PASSWORD', 'LEAD_NOTIFY_EMAIL']) {
    resetEnv();
    delete process.env[key];
    const res = await post(validBody());
    assert.equal(res.status, 200, key);
    assert.equal(fetchCalls.length, 1, key);
    assert.equal(transports.length, 0, key);
  }
  assert.ok(logs.some((l) => l.includes('NOTIFY_SKIPPED')));
});

await test('missing Supabase config: 500, CONFIG_MISSING names the variable, nothing sent', async () => {
  delete process.env.PUBLIC_SUPABASE_ANON_KEY;
  assert.equal((await post(validBody())).status, 500);
  assert.ok(logs.some((l) => l.includes('CONFIG_MISSING: PUBLIC_SUPABASE_ANON_KEY')));
  process.env.PUBLIC_SUPABASE_ANON_KEY = 'anon-key-test';
  delete process.env.PUBLIC_SUPABASE_URL;
  assert.equal((await post(validBody())).status, 500);
  assert.ok(logs.some((l) => l.includes('CONFIG_MISSING: PUBLIC_SUPABASE_URL')));
  assert.equal(fetchCalls.length + sentMail.length, 0);
});

await test('non-POST methods: 405 with Allow: POST', async () => {
  for (const method of ['GET', 'PUT', 'DELETE', 'PATCH']) {
    const res = await post(validBody(), { method });
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.get('Allow'), 'POST');
  }
  assert.equal(fetchCalls.length + sentMail.length, 0);
});

await test('Supabase URL with trailing slash is normalised', async () => {
  process.env.PUBLIC_SUPABASE_URL = 'https://example.supabase.co/';
  await post(validBody());
  assert.ok(fetchCalls[0].url.startsWith('https://example.supabase.co/rest/v1/leads'));
  assert.ok(!fetchCalls[0].url.includes('.co//rest'));
});

await test('logs never contain lead PII or credentials (whole run)', async () => {
  const joined = logs.join('\n');
  for (const secret of [PII.email, PII.name, PII.company, PII.notes, 'anon-key-test', 'abcdefghijklmnop', APP_PASSWORD]) {
    assert.ok(!joined.includes(secret), `log leaked: ${secret}`);
  }
});

await test('no response was ever a 404', async () => {
  assert.ok(statuses.length > 30);
  assert.ok(!statuses.includes(404));
});

let failed = 0;
for (const [ok, name] of results) {
  if (!ok) failed++;
  report(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
}
report(`\n${results.length - failed}/${results.length} passed; ${statuses.length} responses checked; ${logs.length} log lines captured`);
process.exitCode = failed ? 1 : 0;

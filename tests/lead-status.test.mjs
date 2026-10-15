import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';

// Loads src/lib/lead-status.ts the same way the other tests load TypeScript: transpile, then import.
const src = readFileSync(new URL('../src/lib/lead-status.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
const mod = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

const results = [];
function test(name, fn) {
  try {
    fn();
    results.push([true, name]);
  } catch (err) {
    results.push([false, `${name}\n      ${String(err.message).split('\n')[0]}`]);
  }
}

test('every status the database allows has a plain-English label', () => {
  assert.deepEqual([...mod.LEAD_STATUSES], ['new', 'contacted', 'qualified', 'converted', 'lost']);
  for (const s of mod.LEAD_STATUSES) assert.ok(mod.STATUS_LABELS[s]);
});

test('the database check constraint and the app list agree', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20261012100000_platform_admin_leads_audit.sql', import.meta.url), 'utf8');
  const m = sql.match(/status in \(([^)]*)\)/);
  assert.ok(m, 'status check not found in migration');
  const fromSql = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  assert.deepEqual(fromSql, [...mod.LEAD_STATUSES]);
});

test('isLeadStatus rejects unknown values', () => {
  assert.equal(mod.isLeadStatus('new'), true);
  assert.equal(mod.isLeadStatus('bogus'), false);
  assert.equal(mod.isLeadStatus(undefined), false);
});

test('statusLabel falls back safely', () => {
  assert.equal(mod.statusLabel('lost'), 'Not going ahead');
  assert.equal(mod.statusLabel('???'), 'Unknown');
});

test('interestLabel shows unknown keys as they are', () => {
  assert.equal(mod.interestLabel('pay_letters'), 'Pay & Letters');
  assert.equal(mod.interestLabel('future_thing'), 'future_thing');
});

test('countByStatus counts and ignores bad rows', () => {
  const c = mod.countByStatus([{ status: 'new' }, { status: 'new' }, { status: 'lost' }, { status: 'bogus' }, {}]);
  assert.deepEqual(c, { new: 2, contacted: 0, qualified: 0, converted: 0, lost: 1 });
});

let failed = 0;
for (const [ok, name] of results) {
  if (!ok) failed++;
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'}  ${name}\n`);
}
process.stdout.write(`\n${results.length - failed}/${results.length} passed\n`);
process.exitCode = failed ? 1 : 0;

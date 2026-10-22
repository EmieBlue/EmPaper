import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';

// Loads src/lib/company.ts the same way the other tests load TypeScript: transpile, then import.
const src = readFileSync(new URL('../src/lib/company.ts', import.meta.url), 'utf8');
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

test('every branding status has a plain-English label', () => {
  for (const s of mod.BRANDING_STATUSES) assert.ok(mod.BRANDING_LABELS[s]);
  assert.equal(mod.brandingLabel('pending_review'), 'Waiting for your review');
});

test('the database check and the app agree on branding statuses', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20261022100000_companies_branding_convert.sql', import.meta.url), 'utf8');
  const m = sql.match(/branding_status in \(([^)]*)\)/);
  assert.ok(m, 'branding check not found in migration');
  const fromSql = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
  assert.deepEqual(fromSql, [...mod.BRANDING_STATUSES]);
});

test('unknown branding values are shown safely', () => {
  assert.equal(mod.brandingLabel('bogus'), 'Unknown');
  assert.equal(mod.brandingLabel('__proto__'), 'Unknown');
  assert.equal(mod.brandingLabel(undefined), 'Unknown');
});

test('activeLabel', () => {
  assert.equal(mod.activeLabel(true), 'Active');
  assert.equal(mod.activeLabel(false), 'Paused');
});

let failed = 0;
for (const [ok, name] of results) {
  if (!ok) failed++;
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'}  ${name}\n`);
}
process.stdout.write(`\n${results.length - failed}/${results.length} passed\n`);
process.exitCode = failed ? 1 : 0;

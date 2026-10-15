import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

// Runs every migration, the owner seed and every permission test in supabase/tests on a local Postgres.
// No network or credentials. Run: npm test

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const sqlFiles = (dir) => readdirSync(new URL(`../${dir}`, import.meta.url)).filter((f) => f.endsWith('.sql')).sort();

const results = [];
async function test(name, fn) {
  try {
    await fn();
    results.push([true, name]);
  } catch (err) {
    results.push([false, `${name}\n      ${String(err.message).split('\n')[0]}`]);
  }
}

const db = new PGlite();
await db.exec(read('tests/support/supabase-shim.sql'));

const migrations = sqlFiles('supabase/migrations');
for (const file of migrations) {
  await test(`migration ${file} applies`, async () => {
    // pgcrypto is only needed on real Supabase (gen_random_uuid is built into Postgres itself)
    await db.exec(read(`supabase/migrations/${file}`).replace('create extension if not exists pgcrypto;', ''));
  });
}

await test(`newest migration ${migrations.at(-1)} is safe to run a second time`, async () => {
  await db.exec(read(`supabase/migrations/${migrations.at(-1)}`));
});

await test('owner seed makes exactly one owner and shows their email', async () => {
  await db.exec(`insert into auth.users (email) values ('Owner@Example.test'), ('other@example.test');`);
  // typed in a different case on purpose: the seed must still match
  const out = await db.exec(read('supabase/seed/owner_seed.sql').replaceAll('CHANGE-ME@example.com', 'OWNER@example.TEST'));
  const shown = out.at(-1)?.rows ?? [];
  assert.equal(shown.length, 1, 'the seed must end by showing exactly one owner row');
  assert.equal(shown[0].owner_email, 'Owner@Example.test');
  const { rows } = await db.query('select count(*)::int as n from public.platform_admins');
  assert.equal(rows[0].n, 1);
});

await test('owner seed with a wrong email adds nobody and shows no rows', async () => {
  const other = new PGlite();
  await other.exec(read('tests/support/supabase-shim.sql'));
  for (const file of migrations) {
    await other.exec(read(`supabase/migrations/${file}`).replace('create extension if not exists pgcrypto;', ''));
  }
  await other.exec(`insert into auth.users (email) values ('real@example.test');`);
  const out = await other.exec(read('supabase/seed/owner_seed.sql').replaceAll('CHANGE-ME@example.com', 'typo@example.test'));
  assert.equal((out.at(-1)?.rows ?? []).length, 0);
});

for (const file of sqlFiles('supabase/tests')) {
  await test(`permission test ${file} passes`, async () => {
    const out = await db.exec(read(`supabase/tests/${file}`));
    const last = out.at(-1)?.rows?.[0]?.result;
    assert.match(String(last), /ALL PASS$/, `last result was: ${last}`);
  });
}

await test('the permission tests leave no test data behind', async () => {
  const { rows } = await db.query(
    `select (select count(*) from public.leads where starts_with(name, 'RLS_TEST_'))::int as leads,
            (select count(*) from public.audit_log)::int as audit`,
  );
  assert.deepEqual(rows[0], { leads: 0, audit: 0 });
});

let failed = 0;
for (const [ok, name] of results) {
  if (!ok) failed++;
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'}  ${name}\n`);
}
process.stdout.write(`\n${results.length - failed}/${results.length} passed\n`);
process.exitCode = failed ? 1 : 0;

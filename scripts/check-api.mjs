import { existsSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

// Type-checks every server function (api/ and server/) the way Vercel does (without strictNullChecks),
// and again strictly. Listing the files here avoids shell wildcards, which differ between Windows and Linux.
const tsc = createRequire(import.meta.url).resolve('typescript/bin/tsc');

const files = ['api', 'server']
  .filter((dir) => existsSync(dir))
  .flatMap((dir) => readdirSync(dir).filter((f) => f.endsWith('.ts')).map((f) => `${dir}/${f}`));

if (files.length === 0) {
  console.error('check-api: no .ts files found in api/ or server/');
  process.exit(1);
}

const base = ['--noEmit', '--skipLibCheck', '--target', 'es2022', '--module', 'esnext', '--moduleResolution', 'bundler', '--lib', 'es2023,dom', '--types', 'node'];
let failed = false;
for (const [label, flags] of [['loose (what Vercel uses)', ['--strict', 'false']], ['strict', ['--strict']]]) {
  console.log(`check-api: ${files.length} file(s), ${label}`);
  const result = spawnSync(process.execPath, [tsc, ...base, ...flags, ...files], { stdio: 'inherit' });
  if (result.status !== 0) {
    failed = true;
    console.error(`check-api: FAILED in ${label} mode`);
  }
}
process.exit(failed ? 1 : 0);

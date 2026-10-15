import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// Runs every tests/*.test.mjs file in its own process, so a new test file is picked up automatically.
const files = readdirSync('tests').filter((f) => f.endsWith('.test.mjs')).sort();
let failed = 0;
for (const file of files) {
  console.log(`\n=== tests/${file} ===`);
  const result = spawnSync(process.execPath, [`tests/${file}`], { stdio: 'inherit' });
  if (result.status !== 0) {
    failed++;
    console.error(`FAILED: tests/${file}`);
  }
}
console.log(`\n${files.length - failed}/${files.length} test files passed`);
process.exit(failed ? 1 : 0);

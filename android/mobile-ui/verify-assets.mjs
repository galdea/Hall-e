// Rebuilds the Órbita bundle from source and fails if it differs from the committed
// android/app/src/main/assets/orbita. Run after `npm ci` with the Node version in .nvmrc.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const pinned = readFileSync(new URL('.nvmrc', import.meta.url), 'utf8').trim();
if (process.version !== `v${pinned}`) {
  console.error(`verify-assets: Node ${process.version} does not match the pinned v${pinned} (.nvmrc).`);
  process.exit(1);
}
execFileSync(process.execPath, ['build.mjs'], { stdio: 'inherit' });
const assets = '../app/src/main/assets/orbita';
const changed = execFileSync('git', ['status', '--porcelain', '--', assets], { encoding: 'utf8' }).trim();
if (changed) {
  console.error('verify-assets: the rebuilt bundle differs from the committed assets:\n' + changed);
  execFileSync('git', ['--no-pager', 'diff', '--stat', '--', assets], { stdio: 'inherit' });
  process.exit(1);
}
console.log(`verify-assets: ${assets} matches a clean rebuild with Node v${pinned}.`);

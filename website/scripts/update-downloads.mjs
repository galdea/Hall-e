import { readFile, writeFile, rename, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { updateDownloadMarkup, verifyPublishedDownloads } from './downloads.mjs';

const args = process.argv.slice(2);
const checkOnly = args.length === 1 && args[0] === '--check';
if (!checkOnly && args.length !== 2) {
  throw new Error('Usage: node scripts/update-downloads.mjs MAC_VERSION WINDOWS_VERSION | --check');
}
const filename = fileURLToPath(new URL('../public/index.html', import.meta.url));
const current = await readFile(filename, 'utf8');
const updated = checkOnly ? current : updateDownloadMarkup(current, ...args);
// Validate every public installer and checksum before changing any native link.
// A failed/unfinished release leaves the previous working downloads untouched.
const targets = await verifyPublishedDownloads(updated);
if (!checkOnly && updated !== current) {
  const temporary = `${filename}.${process.pid}.tmp`;
  try {
    await writeFile(temporary, updated);
    await rename(temporary, filename);
  } finally {
    await rm(temporary, { force: true });
  }
}
console.log(`${checkOnly ? 'Verified' : 'Updated'} published downloads: ${targets.map((target) => target.name).join(', ')}`);

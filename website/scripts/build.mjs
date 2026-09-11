import { cp, readFile, rm, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { validateDownloads } from './downloads.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path.join(root, 'public');
const output = path.join(root, 'dist');
const html = await readFile(path.join(source, 'index.html'), 'utf8');
validateDownloads(html);
const assetPattern = /(?:src|href)="(\/[^"\s]*)"/g;
const assets = new Set([...html.matchAll(assetPattern)]
  .map((match) => new URL(match[1], 'https://hall-e.pages.dev').pathname)
  .filter((url) => url !== '/'));
for (const asset of assets) {
  const info = await stat(path.join(source, asset));
  if (!info.isFile()) throw new Error(`Missing public asset: ${asset}`);
}
await rm(output, { recursive: true, force: true });
await cp(source, output, { recursive: true });
console.log(`Built Hall-e download site with ${assets.size} verified local assets: ${output}`);

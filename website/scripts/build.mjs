import { cp, readFile, rm, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path.join(root, 'public');
const output = path.join(root, 'dist');
const html = await readFile(path.join(source, 'index.html'), 'utf8');
const releaseVersionMatch = html.match(/<span data-version>v([^<]+)<\/span>/);
if (!releaseVersionMatch) throw new Error('Missing release version label.');
const releaseVersion = releaseVersionMatch[1];
const assetPattern = /(?:src|href)="(\/[^"\s]*)"/g;
const assets = new Set([...html.matchAll(assetPattern)]
  .map((match) => new URL(match[1], 'https://hall-e.pages.dev').pathname)
  .filter((url) => url !== '/'));
for (const asset of assets) {
  const info = await stat(path.join(source, asset));
  if (!info.isFile()) throw new Error(`Missing public asset: ${asset}`);
}
for (const architecture of ['arm64', 'x86_64']) {
  const anchorMatch = html.match(new RegExp(`<a[^>]*data-download="${architecture}"[^>]*href="([^"]+)"`, 'i'));
  if (!anchorMatch) {
    throw new Error(`Missing ${architecture} download link.`);
  }
  const expectedURL = `https://github.com/galdea/Hall-e/releases/download/v${releaseVersion}/Hall-e-${releaseVersion}-macOS14-${architecture}-adhoc.dmg`;
  if (anchorMatch[1] !== expectedURL) {
    throw new Error(`${architecture} download link does not match release v${releaseVersion}: ${anchorMatch[1]}`);
  }
}
const windowsVersion = html.match(/<span data-windows-version>([^<]+)<\/span>/)?.[1];
if (!windowsVersion || !/^\d+\.\d+\.\d+$/.test(windowsVersion)) throw new Error('Missing valid Windows preview version.');
const windowsURL = html.match(/<a[^>]*data-download="windows-x64"[^>]*href="([^"]+)"/i)?.[1];
const expectedWindowsURL = `https://github.com/galdea/Hall-e/releases/download/win-v${windowsVersion}/Hall-e-${windowsVersion}-windows-x64-setup.exe`;
if (windowsURL !== expectedWindowsURL) throw new Error('Windows installer link does not match the displayed version.');
await rm(output, { recursive: true, force: true });
await cp(source, output, { recursive: true });
console.log(`Built Hall-e download site with ${assets.size} verified local assets: ${output}`);

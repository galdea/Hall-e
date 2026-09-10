import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateDownloads, updateDownloadMarkup, verifyPublishedDownloads } from './downloads.mjs';

const html = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
const updated = updateDownloadMarkup(html, '1.2.3', '2.3.4');

function publishedRequest(change = () => {}) {
  const { targets } = validateDownloads(updated);
  return async (url, options) => {
    if (options.method === 'HEAD') return new Response(null, { headers: { 'content-type': 'application/octet-stream' } });
    const tag = url.split('/').at(-1);
    const release = {
      tag_name: tag, draft: false, published_at: '2026-09-10T00:00:00Z',
      assets: targets.filter((target) => target.tag === tag).flatMap((target) => ['', '.sha256'].map((suffix) => ({
        name: `${target.name}${suffix}`, browser_download_url: `${target.url}${suffix}`, size: 100, state: 'uploaded',
      }))),
    };
    change(release);
    return Response.json(release);
  };
}

test('updates both platform versions, all native links, labels, and Windows help together', () => {
  const result = validateDownloads(updated);
  assert.equal(result.mac, '1.2.3');
  assert.equal(result.windows, '2.3.4');
  assert.equal(result.targets.length, 3);
  assert.match(updated, /aria-label="Download Hall-e 1\.2\.3 for Intel/);
  assert.match(updated, /blob\/win-v2\.3\.4\/windows\/README\.md/);
  assert.equal(updateDownloadMarkup(updated, '1.2.3', '2.3.4'), updated);
});

test('rejects malformed versions and mixed installer, label, or help versions', () => {
  assert.throws(() => updateDownloadMarkup(html, '../latest', '2.3.4'), /X.Y.Z/);
  assert.throws(() => validateDownloads(updated.replace('Hall-e-1.2.3-macOS14-arm64', 'Hall-e-1.2.2-macOS14-arm64')), /download link/);
  assert.throws(() => validateDownloads(updated.replace('Download Hall-e 1.2.3 for Intel', 'Download Hall-e 1.2.2 for Intel')), /accessible label/);
  assert.throws(() => validateDownloads(updated.replace('/blob/win-v2.3.4/', '/blob/win-v2.3.3/')), /help links/);
});

test('verifies public installers and accompanying checksums', async () => {
  assert.equal((await verifyPublishedDownloads(updated, publishedRequest())).length, 3);
});

test('rejects unfinished releases and releases with a missing Intel installer or checksum', async () => {
  await assert.rejects(verifyPublishedDownloads(updated, publishedRequest((release) => { release.draft = true; })), /not a published release/);
  await assert.rejects(verifyPublishedDownloads(updated, publishedRequest((release) => {
    release.assets = release.assets.filter((asset) => !asset.name.includes('x86_64'));
  })), /Missing published asset/);
  await assert.rejects(verifyPublishedDownloads(updated, publishedRequest((release) => {
    release.assets = release.assets.filter((asset) => !asset.name.endsWith('.sha256'));
  })), /Missing published asset/);
});

test('rejects GitHub failures and missing public download responses', async () => {
  await assert.rejects(verifyPublishedDownloads(updated, async () => new Response(null, { status: 403 })), /HTTP 403/);
  const request = publishedRequest();
  await assert.rejects(verifyPublishedDownloads(updated, (url, options) => options.method === 'HEAD'
    ? new Response(null, { status: 404 }) : request(url, options)), /Public download is unavailable/);
});

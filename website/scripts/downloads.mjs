const repository = 'https://github.com/galdea/Hall-e';
const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

export function downloadTargets(mac, windows) {
  if (!versionPattern.test(mac) || !versionPattern.test(windows)) {
    throw new Error('Both release versions must be X.Y.Z.');
  }
  return [
    ...['arm64', 'x86_64'].map((architecture) => ({
      architecture, version: mac, tag: `v${mac}`,
      name: `Hall-e-${mac}-macOS14-${architecture}-adhoc.dmg`,
    })),
    { architecture: 'windows-x64', version: windows, tag: `win-v${windows}`, name: `Hall-e-${windows}-windows-x64-setup.exe` },
  ].map((target) => ({ ...target, url: `${repository}/releases/download/${target.tag}/${target.name}` }));
}

function anchor(html, architecture) {
  const matches = [...html.matchAll(new RegExp(`<a\\b[^>]*\\bdata-download="${architecture}"[^>]*>`, 'g'))];
  if (matches.length !== 1) throw new Error(`Expected exactly one ${architecture} download link.`);
  return matches[0][0];
}

export function validateDownloads(html) {
  const mac = html.match(/<span data-version>v([^<]+)<\/span>/)?.[1];
  const windows = html.match(/<span data-windows-version>([^<]+)<\/span>/)?.[1];
  const targets = downloadTargets(mac, windows);
  for (const target of targets) {
    const tag = anchor(html, target.architecture);
    if (tag.match(/\bhref="([^"]+)"/)?.[1] !== target.url) {
      throw new Error(`${target.architecture} download link does not match ${target.tag}.`);
    }
    const label = tag.match(/\baria-label="([^"]+)"/)?.[1];
    if (!label?.includes(` ${target.version} `) && !label?.includes(` ${target.version},`)) {
      throw new Error(`${target.architecture} accessible label does not match ${target.tag}.`);
    }
  }
  for (const url of [`${repository}/blob/win-v${windows}/windows/README.md`, `${repository}/releases/tag/win-v${windows}`]) {
    if (!html.includes(`href="${url}"`)) throw new Error('Windows help links do not match the installer version.');
  }
  return { mac, windows, targets };
}

export function updateDownloadMarkup(html, mac, windows) {
  const previous = validateDownloads(html);
  const targets = downloadTargets(mac, windows);
  let updated = html;
  for (const target of targets) {
    const oldTarget = previous.targets.find((item) => item.architecture === target.architecture);
    const oldAnchor = anchor(updated, target.architecture);
    const newAnchor = oldAnchor.replace(oldTarget.url, target.url)
      .replace(/aria-label="([^"]+)"/, (_, label) => `aria-label="${label.replace(oldTarget.version, target.version)}"`);
    updated = updated.replace(oldAnchor, newAnchor);
  }
  updated = updated.replace(`<span data-version>v${previous.mac}</span>`, `<span data-version>v${mac}</span>`)
    .replace(`<span data-windows-version>${previous.windows}</span>`, `<span data-windows-version>${windows}</span>`)
    .replaceAll(`/blob/win-v${previous.windows}/`, `/blob/win-v${windows}/`)
    .replaceAll(`/releases/tag/win-v${previous.windows}"`, `/releases/tag/win-v${windows}"`);
  validateDownloads(updated);
  return updated;
}

export async function verifyPublishedDownloads(html, request = globalThis.fetch) {
  const { targets } = validateDownloads(html);
  const releases = new Map();
  for (const tag of new Set(targets.map((target) => target.tag))) {
    const response = await request(`https://api.github.com/repos/galdea/Hall-e/releases/tags/${tag}`, {
      headers: { Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`Cannot verify release ${tag}: HTTP ${response.status}.`);
    const release = await response.json();
    if (release.tag_name !== tag || release.draft || !release.published_at || !Array.isArray(release.assets)) {
      throw new Error(`${tag} is not a published release.`);
    }
    releases.set(tag, release);
  }
  for (const target of targets) {
    const release = releases.get(target.tag);
    for (const suffix of ['', '.sha256']) {
      const url = `${target.url}${suffix}`;
      const asset = release.assets.find((item) => item.name === `${target.name}${suffix}`);
      if (!asset || asset.state !== 'uploaded' || !(asset.size > 0) || asset.browser_download_url !== url) {
        throw new Error(`Missing published asset: ${target.name}${suffix}`);
      }
      const response = await request(url, { method: 'HEAD', redirect: 'follow', signal: AbortSignal.timeout(30_000) });
      if (!response.ok || response.headers.get('content-type')?.includes('text/html')) {
        throw new Error(`Public download is unavailable: ${target.name}${suffix} (HTTP ${response.status}).`);
      }
    }
  }
  return targets;
}

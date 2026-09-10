# Hall-e download site

A single-viewport, dependency-free download page for `https://hall-e.pages.dev`.
The mechanical SVG separates detailed WALL-E and HAL artwork into 18 masked
components, reconfigures them edge-on, and seats them into a friendly
industrial/cyberpunk Hall-e portrait over 10.6 seconds. The matching navbar mark and
original IMBA logo are bundled in `public/assets/`. Download links are native
anchors and work without JavaScript. Motion can be paused or replayed;
reduced-motion preferences show the final composition. A single animation clock
pauses on manual pause or a hidden tab, and replay resets every component. The intro
starts only after all three character images decode, with a static fallback if
decoding fails. Component masks reuse the three existing images; no additional
image downloads, animation libraries, or video files are required. The final
assembled crop exactly matches the static Hall-e portrait. Responsive framing
keeps the detached parts inside narrow screens and eases back to the original
portrait scale before the final handoff. Resizing also updates a paused frame.

```sh
cd website
npm run check
npm run dev
```

The preview defaults to `http://127.0.0.1:4173`. If that port is in use, run
`PORT=4175 npm run dev` and open `http://127.0.0.1:4175`. Build validates local
assets and all three installer links, then copies only `public/` to `dist/`. No app
code, credentials, or recordings are part of the public deployment.

## Cloudflare Pages

This site targets the existing Cloudflare Pages project, `hall-e`, with the
production branch `main` and public address `https://hall-e.pages.dev/`.
Authenticate Wrangler in the Cloudflare account that owns the project, then
publish the validated build. The deploy script pins Wrangler 4.130.0 so the
direct-upload command is reproducible:

```sh
npm run deploy
```

Project creation is a one-time operation and has already been completed. When
setting up a replacement project, Wrangler 4.130.0 requires `--force` on
`pages project create` to create it directly on Pages rather than Workers:

```sh
npx wrangler@4.130.0 pages project create hall-e --production-branch main --force
```

Do not add `--force` to deployment commands. After publishing, verify the public
page, its stylesheet and script, and all three installer links. A successful project
creation alone does not mean the site has been deployed.

No GitHub Actions run is needed for this static-site deployment.

## Releases

The current native links and version labels in `public/index.html` identify the
published downloads. After a new release is public, use the updater rather than
editing individual links:

```sh
npm run update:downloads -- 0.3.2 0.1.1
npm run deploy
```

The first version is macOS and the second is Windows. The updater checks GitHub
release metadata and anonymous availability of both DMGs, the Windows installer,
and all corresponding checksum files before atomically updating the page. Missing
or unfinished releases leave every old link intact. It updates native links,
accessible labels, displayed versions, and Windows help links together. Deployment
rechecks public downloads; offline `npm run check` checks consistency and regression
tests without requiring network access. Review the signing notice and minimum OS
requirements separately when these change. Versioned links keep
working even if the GitHub API is rate-limited or JavaScript is unavailable.

The separate Windows 11 x64 preview uses `win-vX.Y.Z` tags. Publish its verified
installer before deploying its website link. Windows preview releases do not
replace the macOS latest release. The Windows guide explains the unsigned
installer and security-policy limitations alongside the download button.

Installation instructions reflect the repository's README and release guide.
Apple's first-launch guidance: https://support.apple.com/en-us/102445.
Deployment reference: https://developers.cloudflare.com/pages/get-started/direct-upload/.

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
assets and both installer links, then copies only `public/` to `dist/`. No app
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
page, its stylesheet and script, and both installer links. A successful project
creation alone does not mean the site has been deployed.

No GitHub Actions run is needed for this static-site deployment. The existing
Swift release workflow is unchanged.

## Releases

The page targets the `v0.3.1` DMGs for `arm64` and `x86_64`. Deploy only after both
release assets are public. For a new release, verify both public assets and update the native links,
accessible labels, release version, signing notice, and minimum macOS requirement
in `public/index.html`, then run the checks and deploy. Versioned links keep
working even if the GitHub API is rate-limited or JavaScript is unavailable.

Installation instructions reflect the repository's README and release guide.
Apple's first-launch guidance: https://support.apple.com/en-us/102445.
Deployment reference: https://developers.cloudflare.com/pages/get-started/direct-upload/.

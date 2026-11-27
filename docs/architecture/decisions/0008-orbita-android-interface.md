# 0008 — Orbita as the Android interface

Date: 2026-11-27. Status: **Accepted by the owner, with the conditions below.** An independent architecture review was done on 2026-11-27 (read-only). A cross-provider review of the implementation is still due under `AGENTS.md`.

## Context

The owner uses "Orbita" daily: an Android interface built on branch `codex/hall-e-orbita` (`f5eb12a`, 20 commits from `d5950c4`, never merged). It is an Imba web app compiled into `android/app/src/main/assets/orbita/`, hosted by a locked-down WebView with a small native bridge. The owner's installed build (0.3.1) adds one "Agenda privada" button on the Calendario page. `main` meanwhile gained the private account calendar, staging builds and device-QA fixes, all in native screens with a plainer look. The owner asked that the whole Android app have Orbita's interface and experience.

Verified facts:
- Orbita's WebView disables file and content access, storage and pop-ups, refuses all navigation, and serves only an exact list of assets.
- The bridge is absent in preview mode and caps input size.
- The page's security policy allows no network connections.

Unknowns:
- TalkBack behaviour.
- Cold-start time.
- Tablet and foldable layout.
- Which coordinator Worker version production runs.

## Options

| Option | Summary | Assessment |
| --- | --- | --- |
| A. Keep native screens | Restyle the existing native UI | No new toolchain. High effort to match Orbita's calendar grid and animations; does not reuse the owner's approved design. |
| B. Orbita WebView shell | Port Orbita's UI onto `main`; keep native for recording, permissions, notes, pairing and the account calendar | Reuses the design the owner uses; adds an Imba/Node build step, mitigated by committed compiled assets and a reproducibility check. |
| C. Merge the Orbita branch | Merge all 20 commits | Rejected: it would replace `main`'s newer native screen with an older one and bring in the unreviewed phone→Mac audio relay, which deletes audio on both devices. |
| D. Postpone | Keep Orbita as a personal build | Leaves the public app on the plainer interface. |

## Decision

Option B, landed as slices on `main`:
1. **The Orbita shell and its UI features:** calendar, projects, notes, trash, artwork, recording reminders. All of `main`'s behaviour stays, expressed in Orbita's design and Spanish wording. "Agenda privada" opens the native account calendar.
2. **The account calendar stays native, restyled with Orbita's tokens and copy.** Session tokens and sign-in never reach JavaScript.
3. **The encrypted phone→Mac relay is not part of this decision.** It needs its own ADR before it lands, covering:
   - one destination per recording;
   - an opt-in or delayed deletion policy;
   - coordinator TTL, caps and revocation purge;
   - authentication before reading upload bodies;
   - privacy notice and Play data-safety updates;
   - a known production Worker version.

## Conditions

- `android/mobile-ui` pins its Node version, and `npm ci && npm run build` must reproduce the committed `assets/orbita` exactly.
- The WebView respects the system font size. Bridge actions do no disk work on the UI thread.
- `PhoneRecordingPolicy` stays the single source of the recording rules, with its tests.
- Manual checks of TalkBack, large fonts and a large screen are recorded before a public release.

## Consequences

The Android build gains a Node/Imba step for UI changes only; the compiled output is committed. The interface is Spanish-first, like Orbita. The bridge is a security boundary: every new action must validate its input natively and must never return credentials.

## Rollback and reconsideration

Roll back by reverting the shell slice. The native screens remain in history and the data formats are unchanged. Reconsider if:
- Imba alpha builds break;
- the bridge grows beyond about 20 actions;
- TalkBack or startup measurements fail;
- tablets become a requirement.

A plain-JavaScript rewrite of the small `app.imba` is the fallback.

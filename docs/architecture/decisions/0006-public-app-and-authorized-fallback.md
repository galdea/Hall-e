# 0006 — Public app and authorized provider fallback

Date: 2026-09-08. Supersedes the explicit-only routing decision in ADR 0005.

The public workflow is record → transcribe → organize. Calendar, Obsidian, linked developer conversations, and AI reports are optional. A fresh workspace has no developer projects. Onboarding accepts Deepgram or Speechmatics keys directly; community links never perform a star or payment automatically.

Automatic mode prefers a ready Deepgram account, or a ready Speechmatics account when Deepgram is not configured/consented. After a definite Deepgram credit-exhaustion rejection, it may switch to separately configured/consented Speechmatics. Authentication errors, ambiguous uploads, and the shared spend guard do not trigger a switch. Explicit engines remain explicit. Durable provider jobs take precedence over routing changes.

The app shows anonymous, 1-based speaker labels without identifying attendees from voice clusters. The cloud schema retains original 0-based speaker IDs. Display/copy/export includes timestamps; model input can still use plain text.

Melia 1 is multilingual, available in US/EU only, and does not need hardcoded Spanish/English hints. Existing AU1 settings still decode but cannot authorize a Melia upload.

Distribution includes MIT licensing, notices, an original generated icon, installation guidance, architecture-specific archives, checksums, and tag-triggered draft releases. No private repository is made public by the build workflow. Ad-hoc and notarized archives are clearly distinguished.

Verification: routing tests cover missing setup, consent, credit exhaustion, unsafe errors, and durable remote checkpoints; transcript tests cover speaker preservation; workspace tests cover empty defaults and unreadable-file preservation. Live billing behavior and fresh-Mac permission UX require separate validation.

References: [Deepgram diarization](https://developers.deepgram.com/docs/diarization), [Speechmatics models and regions](https://docs.speechmatics.com/speech-to-text/models).

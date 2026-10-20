# Google Play screenshot provenance

Both candidates are mechanical crops and canvas resizes of real Android QA
captures. The phone UI was not redrawn, retouched, or annotated. Content is
synthetic QA data; no transcript, invitation, workspace key, or personal meeting
details appear.

These two candidates replace stale screenshot 01 for the current Play listing.
Both are saved in the listing. They are real QA screenshots and are not
AI-generated or labeled as AI-generated. The app icon and feature graphic are
marked AI-generated in Play Console. English and Spanish listing text and these
screenshots are saved for the 0.2.0/code 3 candidate. The owner explicitly
confirmed sending 15 changes. The Publishing overview says: “Your changes are
now in review. We may find additional issues when reviewing your app.” Quick
checks completed successfully. Closed testing release 1 is configured for Chile
only with the unchanged owner-only tester list (one user); it is not active or
public.

| Candidate | QA capture and build | Crop and result |
| --- | --- | --- |
| `03-shared-sessions.png` | `/private/tmp/hall-e-release-evidence/android-code3-paired.png` — Hall-e 0.2.0, version code 3; paired shared-sessions view. | Source 758×1700. Cropped to `(0, 57)–(758, 1700)` to remove only the outer Mac window title strip; retained the entire phone screen, status bar, and navigation bar. Fitted at 886×1920 (1.1686×) and centered on a 1080×1920 `#EFF3F0` canvas. |
| `04-local-recording.png` | `/private/tmp/hall-e-release-evidence/android-quick-meeting-recorded.png` — Hall-e 0.2.0, version code 2; local meeting marked Recorded (0:15). | Source 758×1700. Cropped to `(0, 57)–(758, 1700)` to remove only the outer Mac window title strip; retained the entire phone screen, status bar, and navigation bar. Fitted at 886×1920 (1.1686×) and centered on a 1080×1920 `#EFF3F0` canvas. |

The local meeting-card and recording layout shown in the code 2 capture remains
valid in code 3; code 3 changes the shared-workspace handoff-state refresh, not
that local recording screen. The shared-sessions capture is from code 3. The
source's cursor overlay remains visible over the Play button in the local
recording image; it was left untouched as required by the no-retouch constraint.

## Foreground-service microphone video

The public Play declaration video is
[`android-microphone-demo.mp4`](https://hall-e.pages.dev/review/android-microphone-demo.mp4).
It is 1,340,583 bytes, 720×1560, and 50.041667 seconds long; SHA-256:
`d3bb9a94e7cb8d7e8049ee090f9b8b7e41422a6ee430648c644ef7faa853090b`. Captured
from the actual Pixel running code 3, it shows the user-initiated Save and
Record action, the in-app microphone disclosure, the one-time Android
microphone permission, and the visible recording timer and Stop control. The
video ends before Stop is pressed; do not claim it shows the stop action or a
completed recording. Separately, local verification confirmed a 23-second
recording stopped, with a screenshot documenting that result. No audio was
uploaded.

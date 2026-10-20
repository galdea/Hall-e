# Mac App Store screenshot provenance

`01-projects.png` is a genuine, unedited capture of the running Hall-e Store QA
macOS app, build `2026102011`. It shows the synthetic **Launch planning**
project in the Projects view; its visible counts are zero and no meeting,
attendee, transcript, audio, invitation, or workspace key appears. The project
section controls remain on one line at the captured width.

- **App:** `/Applications/Hall-e Store QA.app`, executable PID `84438` at
  capture time.
- **Window:** Quartz window ID `58064`, title `Projects`, owned by PID `84438`.
- **Window bounds:** `{X: 88, Y: 62, Width: 1280, Height: 800}` points.
- **Capture:** `screencapture -x -o -l 58064`; `-o` omits the window shadow.
- **Output:** 2560 × 1600 PNG, matching the captured Retina window dimensions.
- **Image processing:** None. The saved file is the direct window-only capture.

The build 2011 Store QA app was installed after preserving its signed bundle;
the prior build 2010 bundle remains preserved separately. No production app
was captured. No recording or AI job was started.

This image is uploaded to the English (U.S.) App Store Connect listing. The
Spanish (Mexico) listing displays it through “Using Existing Assets”; it does
not have a separate localized screenshot. The app build itself is not uploaded.

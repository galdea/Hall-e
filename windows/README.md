# Hall-e for Windows — preview 0.1.1

An initial native Windows edition for **Windows 11 on Intel/AMD x64 computers**. The installer includes the .NET runtime: no developer tools, terminal commands, or administrator password are needed for a normal per-user installation. Windows on ARM is not supported by this installer.

## Install

Download **Hall-e-0.1.1-windows-x64-setup.exe** from the [Windows release](https://github.com/galdea/Hall-e/releases/tag/win-v0.1.1). Open the file, choose Install, then launch Hall-e from the Start menu or desktop shortcut. Use the same installer to update. Windows Settings → Apps → Installed apps can uninstall Hall-e; your meeting library is retained.

This preview is **not Authenticode-signed**. If Microsoft Defender SmartScreen displays “Windows protected your PC”, first check that the file came from the Hall-e release above, then choose **More info → Run anyway**, if Windows offers that option. Do not disable antivirus, SmartScreen, or Smart App Control. Smart App Control, S mode, or organizational policy can block unsigned software without an individual override; this preview cannot guarantee installation on those computers. Ask your IT administrator on a managed computer.

The portable ZIP is an alternative: extract the whole folder first, then open Hall-e.exe. Keep its neighboring files together. It uses the same local meeting library as the installed app.

## First meeting

1. Choose a microphone, meeting title, and language. Microphone-only is the default.
2. For calls, explicitly enable computer audio. This records **all sound playing through the Windows output device**, not just one selected meeting app. Tell participants before recording.
3. Start recording, write notes, then stop. Notes save automatically. Choose a transcription provider and Transcribe when you are ready.

Offline transcription uses an installed **Windows SAPI recognizer for the exact meeting language**. Availability varies by Windows installation; if no compatible recognizer is present, Hall-e explains that limitation and never silently sends audio to a cloud provider. Optional Deepgram/Speechmatics use your own paid provider account, a validated API key, and separate consent. Speechmatics also requires a processing region and confirmation that account-level model training is disabled. Its submitted jobs can be resumed without another upload.

## Included in this edition

Microphone and optional computer-audio recording; local meeting library and projects; notes with autosave; search; audio playback; local or optional cloud transcription; Markdown export; audio deletion that keeps notes/transcripts. Credentials are protected with Windows DPAPI for the current user. Library: `%LOCALAPPDATA%\Hall-e`. Deleting audio removes local WAV/PCM files, not audio already sent to a cloud provider.

This is a Windows preview, with a separate version from macOS. The advanced macOS calendar/meeting integrations, app-specific audio capture, and optional AI integrations are not included. Offline SAPI recognition is not the same engine or quality as the macOS recognizer.

## Build and verify

Install the .NET 10 SDK and Inno Setup 6 on Windows. From the repository root:

```powershell
dotnet run --project windows/HallE.Core.Tests/HallE.Core.Tests.csproj -c Release
dotnet run --project windows/HallE.Windows.Tests/HallE.Windows.Tests.csproj -c Release
./windows/scripts/package.ps1
```

The package version defaults to `Directory.Build.props`. Packaging starts with a clean application payload so removed dependencies cannot leak into an update. The Windows workflow verifies storage, a self-contained installer, update/uninstall, the extracted portable ZIP, and the real WPF window in isolated temporary storage. Installation smoke checks run only on disposable GitHub-hosted Windows runners because installing and uninstalling the real product changes its installer registration. Startup checks never record sound or submit cloud jobs. Physical microphones, live-call synchronization, recognition accuracy, and paid cloud transcription still need an interactive Windows test. Checksums accompany each release artifact.

Publishing a `win-vX.Y.Z` tag matching `Directory.Build.props` runs these checks and publishes a Windows prerelease only after they pass. Windows releases preserve the macOS latest release. Existing published assets are never overwritten; fixes receive a new version.

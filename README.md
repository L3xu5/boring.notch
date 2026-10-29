<h1 align="center">🎵 Boring Notch — Yandex Music Edition</h1>

<p align="center">
  A fork of <a href="https://github.com/TheBoredTeam/boring.notch">boring.notch</a> with native Yandex Music controls, synced lyrics and a configurable MacBook notch.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon%20%2B%20Intel-blue" alt="Universal macOS app">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

Version 3 keeps the existing features while rebuilding application, window and service ownership. Each display has its own notch window and presentation state; shared media, shelf, calendar, camera and hardware services have explicit lifetimes.

The UI and platform adapters remain native SwiftUI/AppKit. Two local packages separate reusable strict Swift 6 logic in [`BoringCore`](Packages/BoringCore) from the shared Objective-C XPC schema in [`BoringRPC`](Packages/BoringRPC). See [the contributor architecture guide](CONTRIBUTING.md#architecture-and-ownership) for the service boundaries.

## Features

- **Music:** Yandex Music, Apple Music, Spotify, the YouTube Music desktop API client and generic macOS Now Playing; artwork, transport, source-dependent favorite/dislike controls and configurable shortcuts.
- **Lyrics:** optional Yandex account connection, LRCLIB fallback, timing adjustment and a karaoke view with click-to-seek where the source supports seeking.
- **Shelf:** file and clipboard imports, previews, Quick Look, drag-and-drop, sharing and AirDrop.
- **Everyday tools:** calendar, camera preview, battery/charging activities, volume and brightness HUDs, menu-bar controls and launch-at-login settings.
- **Multiple displays:** independent windows, keyboard focus, screen selection, fullscreen handling and sleep/lock cleanup.

## Install

Download **`boringNotch.zip`** from [this fork's latest release](https://github.com/L3xu5/boring.notch/releases/latest), unzip it and move **boringNotch.app** to `/Applications`. Releases are universal binaries for **Apple Silicon and Intel**, with **macOS 14 or later** as the runtime minimum.

Releases use a stable self-signed certificate and are not notarized by Apple. If macOS quarantines the downloaded app, remove that flag once after checking the download source:

```bash
xattr -dr com.apple.quarantine /Applications/boringNotch.app
```

Homebrew installation is also available:

```bash
brew install --cask l3xu5/boring-notch/boring-notch-yandex
```

Release builds update through this fork's Sparkle feed using **Check for Updates…**. Existing application and signing identities are retained across updates.

## Setup and privacy

Choose a music source during onboarding. A fresh installation waits for that choice before starting its player integration. Camera, calendar and account connections remain optional; permissions can be configured later in Settings.

| Access | Used for |
| --- | --- |
| Accessibility | Yandex playback/like/dislike controls, its metadata fallback and enabled system-key integrations. |
| Automation | Apple Music or Spotify AppleScript controls when those sources are used. |
| Camera | A visible camera preview; closing the final preview releases capture. |
| Calendar | Reading the calendars selected for the calendar feature. |
| Selected files | Shelf imports, previews and sharing actions. |

The official **Yandex Music desktop app** (`ru.yandex.desktop.music`) needs no modification. In Settings, select **Yandex Music**, grant Accessibility and start playback in that app. Connecting a Yandex account inside the notch is optional: playback controls work independently of it.

With lyrics enabled, track metadata is sent to LRCLIB or, when connected, Yandex's lyrics API. Yandex OAuth credentials are kept in **macOS Keychain**. Older preference-based tokens are removed only after a successful Keychain save; **Disconnect** removes the stored credential. Lyrics use a bounded, account-separated cache. Camera/calendar permissions and account credentials are not required to use the other features.

Generated files dragged to an external app keep a durable copy so recipients can read the exported URL later. Removing the Shelf row does not delete these copies, and there is no automatic expiry. To review them in Finder, choose **Go → Go to Folder** and enter `~/Library/Application Support/boringNotch/Shelf/OwnedAssets`. Remove only copies you no longer need; deleting a retained copy can break links in the receiving app. Original user files are never deleted by Shelf cleanup.

## Yandex playback and media keys

The integration reads the system Now Playing stream through the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter). Full snapshots and incremental updates share one owner-aware reducer, including explicit field removals.

Playback, like and dislike commands target Yandex's own accessible player buttons. If Safari or another app owns the system media session, Accessibility supplies Yandex's title and artist; artwork can be loaded using the exact track link. This does not claim the system session or send playback commands to that other app.

The animation reads playback independently of track metadata and likes. With a closed window, Yandex desktop 5.124.1 exposes its playback-owned Electron sleep assertion; a pause requires two seconds of consistent absence. This read-only check does not open the window, capture audio or change assertions. An unknown or failed query does not imply a pause.

A confirmed pause freezes the current track's position even if the system still reports an advancing playing session. Explicit seeks remain available while Yandex owns Now Playing; the progress control reconciles their preview even while paused.

Dragging the progress bar keeps the notch open until the pointer is released, including outside the panel. The release position determines the seek, and the notch's own gestures leave the slider interaction in control.

Artwork is associated with the current track. A changed title clears the preceding cover while the replacement is decoded; shared covers remain in place. A bounded, read-only adapter snapshot can verify delayed artwork against the current source and track.

Physical media keys always retain native macOS handling. Play/Pause recovery is limited to a proven unresponsive, paused foreign session, followed by fresh Yandex evidence and a final check before an AX action. Active or focused foreign players keep their native behavior. Configurable media shortcuts explicitly control the selected source.

**Position remains a limitation:** when another app owns Now Playing, Yandex's precise live position is unavailable. Seeking, shuffle and repeat depend on Yandex owning the system session, and karaoke timing can drift otherwise. For accurate synced lyrics, keep Yandex as the active Now Playing source. Accessibility matching also depends on the desktop player's UI and may need updates when that UI changes.

## Build and check

Development is tested with **Xcode 26.6**; macOS CI runs on **macOS 26**. The runtime deployment target remains macOS 14. Clone this fork and open the Xcode project:

```bash
git clone https://github.com/L3xu5/boring.notch.git
cd boring.notch
open boringNotch.xcodeproj
```

Select the shared **boringNotch** scheme and run it. Local Debug builds use ad-hoc signing with App Sandbox disabled, matching the native integration model of Release; no Apple Developer team is required. Local builds have their own permission identity. Debug does not start the automatic updater, so a development build is not automatically replaced by a release.

The canonical checks are:

```bash
python3 .github/scripts/check_project.py                # Both groups, on macOS
python3 .github/scripts/check_project.py --python-only  # Release/tooling tests; also Linux
python3 .github/scripts/check_project.py --native-only  # Swift Core and native integration suites
```

Native checks build the actual Swift 6 Core package once, then reuse fingerprint-verified artifacts for platform fixtures. Tests use injected player/network/storage/camera boundaries instead of controlling real players or changing permissions. See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture, Debug UI snapshots and review guidance.

## Maintaining this fork

**Build latest** runs quality checks before building, signing or publishing a `main` commit. The project supplies the marketing version; the complete commit count supplies the monotonic build number. A v3 release therefore has a tag such as `v3.0.0-yandex.N`. Keep published `main` history intact.

Each build publishes a versioned release with `boringNotch.zip` and its appcast. The fixed **`latest`** release and rolling ZIP URL remain for existing Sparkle clients and Homebrew. Sparkle appcasts reference immutable, build-specific archives uploaded before the feed; keep those archives available for clients holding older feeds. Published version tags continue to identify their original source commits. Branch builds cannot publish fork releases.

Required Actions secrets:

| Secret | Purpose |
| --- | --- |
| `SIGNING_CERT_P12` | Base64-encoded stable self-signed certificate and private key. |
| `SIGNING_CERT_PASSWORD` | Password for that P12. |
| `SIGNING_IDENTITY` | Identity contained in the P12. |
| `SPARKLE_PRIVATE_KEY` | Ed25519 key matching `SUPublicEDKey` in `boringNotch/Info.plist`. |
| `SYNC_SSH_KEY` | Private key for this repository's write-enabled deploy key. |

Keep the existing signing certificate, Sparkle key, bundle IDs and helper IDs during routine maintenance. Xcode produces **Boring Notch.app**; publication stages it as **boringNotch.app** for installation compatibility.

The repository-scoped sync deploy key is configured for this fork. **Sync with upstream** merges `TheBoredTeam/boring.notch`'s `main` daily at **06:00 UTC**. Its deploy-key push can update workflow files and trigger **Build latest**. For a new fork, install a dedicated write-enabled deploy key and set `SYNC_SSH_KEY`; the default `GITHUB_TOKEN` cannot provide those push/trigger semantics. Conflicts leave `main` untouched and create a conflict issue.

If scheduled runs stop, check that **Sync with upstream** is enabled in Actions, then dispatch it manually to inspect its result.

For local upstream merges, enable the README preservation driver once:

```bash
git config merge.ours.driver true
```

Review fork-specific behavior, signing and update configuration when resolving upstream changes. Upstream release/nightly/Pages and branch-policy jobs are restricted to the upstream repository; this fork uses its own validation, sync and release workflows and does not run Crowdin synchronization.

## Credits and license

This project is a fork of **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** by **[The Bored Team](https://github.com/TheBoredTeam)**. Their application provides the foundation for the notch, calendar, shelf, HUDs and other features; this fork adds and maintains the Yandex integration and its own changes.

Licensed under **GNU GPLv3**: [LICENSE](LICENSE). Dependency and bundled-component notices remain in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

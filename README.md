<h1 align="center">
  <br>
  🎵 Boring Notch — <span>Yandex Music Edition</span>
  <br>
</h1>

<p align="center">
  <b>A fork of <a href="https://github.com/TheBoredTeam/boring.notch">boring.notch</a> that turns your MacBook notch into a music control center — now with first-class <b>Yandex Music</b> support.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
  <img src="https://img.shields.io/badge/Yandex%20Music-native-yellow" alt="Yandex Music">
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/2d5f69c1-6e7b-4bc2-a6f1-bb9e27cf88a8" alt="Demo GIF" />
</p>

---

## ✨ What this fork adds

The upstream app already controls Apple Music, Spotify, YouTube Music and the generic "Now Playing" source. **This fork adds the official Yandex Music desktop app as a native media source** — pick it in onboarding or **Settings → Media Source**.

| Capability | Status |
| --- | :---: |
| 🎼 Now playing — title / artist / album | ✅ |
| 🖼️ Album artwork | ✅ |
| ⏱️ Progress bar & synced lyrics | ✅ |
| ⏯️ Play / Pause / Next / Previous | ✅ |
| ❤️ Like (*«Мне нравится»*) | ✅ *best-effort* |
| 👎 Dislike · configurable media hotkeys | ✅ |
| 🎤 Full-window karaoke lyrics · click to seek | ✅ *seeking depends on the source* |
| 🔀 Shuffle · 🔁 Repeat | ✅ |

Works with the **official Yandex Music app** (`ru.yandex.desktop.music`) — no modified client is needed. Playback controls do not require a Yandex account connection in the notch. Connecting an account is optional and enables lyrics from Yandex's own API; otherwise the app uses LRCLIB.

## 🔧 How it works

Yandex Music is an Electron app with **no AppleScript dictionary**, so the scripting approach used for Spotify / Apple Music isn't available. The integration uses **two channels**:

1. **Reading "now playing" — via MediaRemote.**
   Chromium publishes the track's metadata, artwork and position to the macOS *Now Playing* session. We read that stream (through the bundled [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)) filtered to Yandex's bundle id. Diff updates arrive without an owner id, so the session owner is tracked from full snapshots and diffs are applied to it.

2. **Controlling playback & likes — via the Accessibility API.**
   Transport commands **press Yandex's own on-screen buttons** instead of sending MediaRemote commands, so they always target Yandex — even when a browser tab currently owns the system media session. The controls are located on the persistent bottom player bar (anchored via the unique *Next / Previous song* buttons), and Chromium's web accessibility tree is enabled with `AXManualAccessibility`. *Like* is the bar's `Like` checkbox; its state is read from `AXValue`.

Playback integration lives in [`YandexMusicController.swift`](boringNotch/MediaControllers/YandexMusicController.swift). Lyrics fetching and caching live in [`MusicManager.swift`](boringNotch/managers/MusicManager.swift); account connection and Accessibility setup are in [`SettingsView.swift`](boringNotch/components/Settings/SettingsView.swift).

## 🚀 Install

1. Download **`boringNotch.zip`** from the [latest release](../../releases/latest) and unzip it.
2. Move **boringNotch.app** to `/Applications`.
3. Releases use a stable **self-signed certificate**, without Apple notarization. Clear the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/boringNotch.app
   ```
4. Launch it.

## ▶️ Enable Yandex Music

1. In the notch settings (menu-bar star → **Settings → Media Source**) choose **Yandex Music**.
2. Grant **Accessibility** permission — **System Settings → Privacy & Security → Accessibility** → enable **boringNotch**.
   *Required for transport and likes. Metadata & artwork work without it.*
3. Play something in the Yandex Music app 🎧
4. Optionally use **Connect…** in the Yandex Music settings to enable lyrics from your account. Lyrics timing can be adjusted with **Lyrics offset**.

Connected account tokens are stored in macOS Keychain. Existing tokens from older builds are migrated automatically; the old preference is removed after a successful Keychain write.

Updates are delivered from this fork through **Check for Updates…**. You can also install with Homebrew:

```bash
brew install --cask l3xu5/boring-notch/boring-notch-yandex
```

## ⚠️ Known limitation

macOS exposes a **single** system *Now Playing* session. If another app (e.g. a video in Safari) is actively playing and owns that session, Yandex's live position can't be read from the system, so synced lyrics may drift. Yandex Music also doesn't expose a playback slider through Accessibility, so there's no fallback. **For accurate lyrics, keep Yandex Music as the active media session.**

## 🛠️ Building from source

- **macOS 15.6+** and **Xcode 26+**
- Clone, then:
  ```bash
  open boringNotch.xcodeproj
  ```
  Select the **boringNotch** scheme and press **⌘R**.

Upstream names the built product **Boring Notch.app**. Fork releases package it as **boringNotch.app** to preserve existing installations and Homebrew compatibility.

The Xcode project enables App Sandbox, while fork releases are signed without it so Accessibility can control Yandex Music. For a local build with the same Accessibility behavior:

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
codesign --force --deep --timestamp=none --sign - \
  "build/Build/Products/Release/Boring Notch.app"
```

Grant Accessibility to that local app separately. An ad-hoc signature does not preserve the release certificate's identity.

## Maintaining this fork

**Build latest** publishes every push to `main`, using the full commit count as `CFBundleVersion`. The marketing version is derived from the project and stamped into both the app and Sparkle feed. Keep `main` history intact so update build numbers continue to increase.

Each build creates a new versioned release such as `v2.7.3-yandex.1353`, with `boringNotch.zip` and `appcast.xml`, and marks it as GitHub's latest release. Reruns preserve the assets and notes of an already published version. A version tag must continue to point to the original built commit.

The separate rolling release retains the fixed `latest` tag and `boringNotch.zip` URL for existing Sparkle clients and Homebrew. Its title shows the current build, while the latest-release badge belongs to the versioned release. Sparkle uses an archive unique to each build, uploaded before `appcast.xml`, so clients with an older feed can still download the matching signed archive. Old build archives must remain available. The rolling `latest` tag moves to the built source commit. Manually dispatched builds from other branches cannot publish.

Configure these repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Purpose |
| --- | --- |
| `SIGNING_CERT_P12` | Base64-encoded stable self-signed code-signing certificate and private key. |
| `SIGNING_CERT_PASSWORD` | Password for that P12 file. |
| `SIGNING_IDENTITY` | Code-signing identity contained in the P12 file. |
| `SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private key matching `SUPublicEDKey` in `boringNotch/Info.plist`. |
| `SYNC_SSH_KEY` | Private SSH key for a write-enabled deploy key installed on this repository. Its pushes can update workflows and trigger the release build. |

Keep the existing signing certificate and Sparkle key across updates. Do not replace them as part of routine maintenance.

**Sync with upstream** merges `TheBoredTeam/boring.notch`'s `main` daily at 06:00 UTC. Set up a dedicated SSH key pair for this repository: add its public key in **Settings → Deploy keys** with **Allow write access**, and save its private key as the `SYNC_SSH_KEY` Actions secret. The key grants access only to this repository and can push workflow changes; its pushes trigger **Build latest**. No personal access token is needed.

GitHub's standard `GITHUB_TOKEN` cannot push workflow changes and its pushes do not trigger the release build. Without `SYNC_SSH_KEY`, sync stops with a setup error. Conflicts leave `main` untouched and create an issue. For local merges, enable the README preservation rule once with `git config merge.ours.driver true`.

If GitHub disables the schedule after repository inactivity, enable **Sync with upstream** in Actions and run it manually once after configuring the deploy key. Upstream-only release, nightly, Pages, manual-build and PR branch-policy jobs are restricted to the upstream repository; this fork uses **Build latest**.

Run release-script checks with:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/scripts/tests -v
python3 .github/scripts/run_yandex_auth_tests.py  # macOS; uses fake storage
python3 .github/scripts/test_lyrics.py           # macOS; uses fixture responses
```

## 🙏 Credits & License

This is a fork of **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** by [The Bored Team](https://github.com/TheBoredTeam) — all credit for the app itself goes to them. See the upstream README for the full feature set (calendar, shelf/AirDrop, HUD replacement, and more).

Licensed under **GNU GPLv3** (see [LICENSE](LICENSE)); this fork keeps the same license. Third-party attributions are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

> The Yandex Music integration was added on top of The Bored Team's excellent work.

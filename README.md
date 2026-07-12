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
| 🔀 Shuffle · 🔁 Repeat | ✅ |

Works with the **official Yandex Music app** (`ru.yandex.desktop.music`) — nothing extra to install, no modified client, no login inside the notch.

## 🔧 How it works

Yandex Music is an Electron app with **no AppleScript dictionary**, so the scripting approach used for Spotify / Apple Music isn't available. The integration uses **two channels**:

1. **Reading "now playing" — via MediaRemote.**
   Chromium publishes the track's metadata, artwork and position to the macOS *Now Playing* session. We read that stream (through the bundled [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)) filtered to Yandex's bundle id. Diff updates arrive without an owner id, so the session owner is tracked from full snapshots and diffs are applied to it.

2. **Controlling playback & likes — via the Accessibility API.**
   Transport commands **press Yandex's own on-screen buttons** instead of sending MediaRemote commands, so they always target Yandex — even when a browser tab currently owns the system media session. The controls are located on the persistent bottom player bar (anchored via the unique *Next / Previous song* buttons), and Chromium's web accessibility tree is enabled with `AXManualAccessibility`. *Like* is the bar's `Like` checkbox; its state is read from `AXValue`.

The whole integration lives in one file: [`YandexMusicController.swift`](boringNotch/MediaControllers/YandexMusicController.swift).

## 🚀 Install

1. Download **`boringNotch.zip`** from the [latest release](../../releases/latest) and unzip it.
2. Move **boringNotch.app** to `/Applications`.
3. This build is **unsigned**, so clear the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/boringNotch.app
   ```
4. Launch it.

## ▶️ Enable Yandex Music

1. In the notch settings (menu-bar star → **Settings → Media Source**) choose **Yandex Music**.
2. Grant **Accessibility** permission — **System Settings → Privacy & Security → Accessibility** → enable **boringNotch**.
   *Required for transport and likes. Metadata & artwork work without it.*
3. Play something in the Yandex Music app 🎧

## ⚠️ Known limitation

macOS exposes a **single** system *Now Playing* session. If another app (e.g. a video in Safari) is actively playing and owns that session, Yandex's live position can't be read from the system, so synced lyrics may drift. Yandex Music also doesn't expose a playback slider through Accessibility, so there's no fallback. **For accurate lyrics, keep Yandex Music as the active media session.**

## 🛠️ Building from source

- **macOS 15.6+** and **Xcode 26+**
- Clone, then:
  ```bash
  open boringNotch.xcodeproj
  ```
  Select the **boringNotch** scheme and press **⌘R**.

## 🙏 Credits & License

This is a fork of **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** by [The Bored Team](https://github.com/TheBoredTeam) — all credit for the app itself goes to them. See the upstream README for the full feature set (calendar, shelf/AirDrop, HUD replacement, and more).

Licensed under **GNU GPLv3** (see [LICENSE](LICENSE)); this fork keeps the same license. Third-party attributions are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

> The Yandex Music integration was added on top of The Bored Team's excellent work.

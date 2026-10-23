# Contributing to this fork

Target **`L3xu5/boring.notch`'s `main` branch** for code, documentation and pull requests. This fork has its own release workflow and contribution policy; upstream's `dev` branch and Crowdin process do not apply here. For a separate upstream contribution, follow upstream's instructions.

## Development setup

Use **Xcode 26.6**, the toolchain tested by this repository's macOS 26 CI. The app supports macOS 14 and later; releases include Apple Silicon and Intel architectures.

```bash
git clone https://github.com/L3xu5/boring.notch.git
cd boring.notch
git switch -c feature/describe-the-change
open boringNotch.xcodeproj
```

Run the shared **boringNotch** scheme. The project uses filesystem-synchronized source groups, and both local packages resolve from `Packages/`. Add app Swift files to their feature directory; keep the shared scheme, local package references, resources and XPC embedding intact.

A command-line Debug build is available without a personal development team:

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath build -disableAutomaticPackageResolution build
```

Debug uses ad-hoc signing and disables App Sandbox, as required by the same native integrations used in Release. Grant local builds permissions separately when testing those integrations. Debug does not automatically start Sparkle updates. Release uses the fork's stable signing identity and signed update feed; do not change those identities to make a local build work.

## Architecture and ownership

| Area | Responsibility |
| --- | --- |
| `boringNotch/App/` | Application runtime, onboarding, per-display window ownership and shutdown. |
| `boringNotch/components/` | Feature views and presentation state; settings pages remain separated by feature. |
| `boringNotch/MediaControllers/` | Native player adapters, supervised media streams, AX/API clients, lyrics, artwork and recovery services. |
| `boringNotch/managers/MusicManager.swift` | MainActor media facade consumed by the UI. |
| `Packages/BoringCore/` | Strict Swift 6 value models, reducers, policies, bounded stores and testable service state machines. |
| `Packages/BoringRPC/` | Shared Objective-C XPC protocol/schema used by the app and helper. |
| `BoringNotchXPCHelper/` and `boringNotch/XPCHelperClient/` | Platform helper implementation and client connection/authorization lifetimes. |
| `Tests/` and `.github/scripts/` | Native integration fixtures, release tests and canonical validation tools. |

Put value-level logic in `BoringCore` and inject operating-system/network/storage boundaries. Native UI and OS integration stay in SwiftUI/AppKit adapters. Keep the XPC schema shared through `BoringRPC`, including its Objective-C runtime name; do not reintroduce copied app/helper protocols.

Every source, observer, process, socket, camera consumer and async operation needs a clear owner and stop path. Stop must cancel pending reads/reconnects and invalidate late replies. Keep AX IPC and expensive image work off the UI executor. Apply artwork to its current item/revision rather than restoring a captured playback snapshot.

Preserve these behavioral boundaries:

- Physical media keys always pass to macOS. Yandex recovery requires fresh, unchanged evidence and an accepted action receipt; it must not take control from Safari or another active/focused player.
- Yandex commands target its own accessible controls. A missing control must not fall back to a global command for another media-session owner.
- Display-local UI state belongs to its window. Shared capture/resources use explicit consumers; closing one display must not stop another display's camera preview.
- First-run player initialization follows the user's source confirmation. Camera, calendar and account setup remain optional.
- Persistent work uses app-owned paths and serialized atomic writes. Respect leases, current revisions and existing data when cleaning up or migrating.

Keep bundle/helper IDs, raw preference/source/shortcut identifiers, Keychain service/account, signing identity and Sparkle keys compatible with installed releases. Versioned caches may migrate existing data; retain recoverable originals until a new save succeeds.

## Checks

From the repository root:

```bash
python3 .github/scripts/check_project.py
```

The default runs release/tooling Python tests, native `BoringCore` SwiftPM tests and every native platform suite. Native checks compile the real Swift 6 package once and verify source, package, compiler/SDK and archive/module fingerprints before reusing it in fixtures.

```bash
python3 .github/scripts/check_project.py --python-only  # Linux or macOS
python3 .github/scripts/check_project.py --native-only  # macOS with Xcode
```

The current test count is printed by the command. Add regressions to the real module/service boundary: fake HTTP sessions, process/AX providers, clocks, credentials and device state instead of copying algorithms into tests. Keep existing lifecycle, metadata ordering, native-key, migration and publication scenarios. Standalone native scripts still work when diagnosing one boundary.

Automated checks must not issue commands to real players, read real account credentials, install event taps or request camera/calendar/Accessibility permissions. Live integration checks are a separate, intentional manual step. Check the Debug build too, and compile Release/universal when changing project settings, packaging or platform interfaces.

## Debug UI snapshots

Use a **Debug build** to render settings, onboarding and notch fixtures:

```bash
python3 .github/scripts/preview_ui.py \
  --app "build/Build/Products/Debug/Boring Notch.app" \
  --output /tmp/boring-notch-ui
```

The script creates and ad-hoc signs an isolated copy with the preview bundle ID. Debug snapshot mode uses stopped application services, empty in-memory credentials and isolated in-memory Shelf state; it does not migrate the real token or start playback/capture. The installed app and its identity are not replaced. Use `--help` for page and appearance options. Release binaries do not enable developer snapshot mode.

## Language boundary and Rust assessment

Version 3 retains SwiftUI/AppKit UI, native Swift adapters and a strict Swift 6 Core. A full Rust rewrite was not selected: the required work was ownership, cancellation and OS integration, and changing languages would still require those platform lifetimes to be designed and verified.

An isolated Swift–Rust prototype scanned LRC timestamp statistics. It did not allocate the production lyric/state models or exercise async services, UI, device ownership or end-to-end application performance. Its timings are not an app benchmark. A future engine could use the replaceable value/event boundary after representative measurements and lifecycle tests. The [official UniFFI cancellation guide](https://mozilla.github.io/uniffi-rs/latest/futures.html#cancelling-async-code) describes library-specific cancellation channels; bindings alone do not replace the app's cancellation and revision guards. Rust is not required to build or run this version.

## Pull requests, translations and reports

Keep a change reviewable: describe the concrete problem, resulting behavior, relevant tests and any manual platform verification. Include snapshots for visible UI changes. Avoid rebasing published `main`, because release build numbers derive from its full commit count.

Edit translations in `boringNotch/Localizable.xcstrings`; this fork does not run Crowdin synchronization. Preserve existing keys and placeholders when updating strings.

Use [this fork's issues](https://github.com/L3xu5/boring.notch/issues) for reproducible bugs and feature requests. Include macOS/app version, selected player, relevant permission state and reproduction steps. Remove tokens and private file/account information from logs and screenshots. Report security findings privately through [SECURITY.md](SECURITY.md).

Keep upstream credits, GPLv3 terms and third-party notices when contributing code or assets.

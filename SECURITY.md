# Security policy

This policy covers **[L3xu5/boring.notch](https://github.com/L3xu5/boring.notch)**, including its Yandex Music integration and fork-specific build/update workflows.

## Report privately

Report vulnerabilities through this fork's GitHub [Report a vulnerability](https://github.com/L3xu5/boring.notch/security/advisories/new) form. Include affected versions, reproduction steps, impact and a minimal example with secrets removed. Do not put exploit details, OAuth tokens, signing material or personal files in a public issue.

Identify an upstream or dependency component when relevant so the report can be routed appropriately. This policy does not promise a response timeline on behalf of The Bored Team or dependency maintainers.

## Credentials, permissions and data

- Yandex OAuth tokens are stored in macOS Keychain. Legacy preference-based tokens are removed only after a successful secure save; disconnect removes the credential. Tokens must not enter logs, screenshots, cache keys or bug reports.
- Lyrics are optional and use remote Yandex/LRCLIB services with track metadata. Cache partitions use an account fingerprint, not the credential. Yandex API credentials are not attached to artwork CDN or LRCLIB requests.
- Accessibility, Automation, camera, calendar and selected-file access belong to their enabled features. The app runs outside App Sandbox for native integrations; users can choose which optional permissions to grant.
- First-run media integration waits for the source choice. Debug snapshot rendering uses a separate preview identity, stopped services and memory-only credentials. Automated tests use injected credentials/devices/player state.

Security-sensitive changes should preserve source/track/transport revision checks, native-first media-key behavior, XPC schema/authorization boundaries, owned-path/lease boundaries and migration recovery. Late callbacks must not revive a stopped source, press another track's controls, or launch an app/request permissions after the originating action was canceled.

## Releases and signing

Install releases from [this fork's releases](https://github.com/L3xu5/boring.notch/releases). The app uses a stable self-signed certificate and signed Sparkle updates; it is not Apple-notarized. Local ad-hoc builds have a different permission/signing identity.

Signing certificates, P12 passwords, Sparkle private keys and the repository-scoped sync deploy key belong in protected Actions secrets. Never commit or attach them to reports. Routine maintenance must retain the existing signing identity, bundle/helper identifiers and Sparkle verification key so installed clients keep their trust and update path.

Quality checks run before fork release signing/publication. Keep published version tags bound to their source commits and immutable update archives available for older signed appcasts. Upstream sync uses the repository's dedicated deploy key; it does not require a personal access token.

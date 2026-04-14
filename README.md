# zen-Babel

zen-Babel is a local-first translation app for Apple platforms (macOS / iOS).
It is designed for on-device translation workflows where privacy, low latency, and offline-friendly behavior matter.
In version 0.8.1, the app name changed from Pre-Babel Lens to zen-Babel (Japanese name: zenバベル).

Repository: https://github.com/ttrace/pre-babel-lens

![zen-Babel Screenshot](docs/images/screenshot.png)

## Current Direction

- Swift + SwiftUI based app architecture
- Backend-swappable translation engines
- Deterministic preprocessing + observable translation pipeline
- iOS default runtime focuses on Apple Translation framework stability
- Foundation Models path is capability-gated and used for quality improvements when available

## Key Features

- On-device translation workflow (no mandatory cloud round-trip)
- Clutch mode (iOS / macOS): bidirectional segment highlighting between Source and Output
- Auto-scroll to corresponding segment when target is out of view
- macOS View controls: compact/column layout and text-size actions
- Import support:
  - macOS: drag & drop / file import (`.txt`, `.md`, `.pdf`, `.docx`, etc.)
  - iOS Share Panel: document import (`.pdf`, `.docx`)
  - Image OCR via Vision framework
- Quick Launch on macOS via double copy (`Cmd+C`, `Cmd+C`)

## macOS Quick Launch by Double Copy

1. Select text in any app.
2. Press `Command + C` twice quickly (about 1 second).
3. zen-Babel comes to front and starts translation with the selected text.

Notes:
- macOS only.
- Empty clipboard content is ignored.
- Duplicate requests are suppressed.

## Automator Integration (macOS)

You can launch translation from selected text via Automator Quick Action.

1. Create a new `Quick Action` in Automator.
2. Set:
   - `Workflow receives current`: `text`
   - `in`: `any application`
3. Add `Run Shell Script` (`/bin/zsh`, pass input `to stdin`).
4. Use this script:

```bash
#!/bin/zsh

text="$(cat)"
if [ -z "$text" ]; then
  text="$*"
fi

if [ -z "$text" ]; then
  exit 0
fi

encoded="$(printf '%s' "$text" | /usr/bin/python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
open "prebabellens://translate?text=${encoded}"
```

5. Save (for example: `Translate with zen-Babel`).
6. Assign a keyboard shortcut in `System Settings > Keyboard > Keyboard Shortcuts > Services`.

## Reliability and Fallback Behavior

The app prioritizes completion and visibility of failures:

- Per-segment fallback to source text when translation is unavailable/unsafe
- Retry guards for recoverable engine errors
- Explicit propagation of cancellation (no hidden fallback on user stop)
- Observable diagnostics in Developer Console

## Project Structure

- `Sources/App/`: app entry points and lifecycle
- `Sources/Features/Translation/`: translation UI and state
- `Sources/Domain/`: core models and protocols
- `Sources/Engines/Preprocess/`: preprocessing engines
- `Sources/Engines/Translation/`: translation backends
- `Sources/Services/`: orchestration, policy, diagnostics
- `Tests/`: unit/integration tests

## Build

`swift build` is for core/development verification (SwiftPM build), not a distributable `.app` bundle build.

```bash
swift build
```

## Test

```bash
swift test
```

## Localization

UI strings are managed in `Localizable.strings` under:

- `Sources/Resources/en.lproj/Localizable.strings`
- `Sources/Resources/ja.lproj/Localizable.strings`
- `Sources/Resources/ko.lproj/Localizable.strings`
- `Sources/Resources/zh-Hans.lproj/Localizable.strings`
- `Sources/Resources/zh-Hant.lproj/Localizable.strings`

How to add/update localized text:

1. Add a key in code via `localized("your.key", defaultValue: "...")` (or `NSLocalizedString` with the same key).
2. Add/update the same key in `en.lproj/Localizable.strings` first (source of truth).
3. Add/update the key in each supported locale file.
4. Keep key names stable; do not rename existing keys unless necessary.
5. Build and verify labels in app menus and translation screens.

Notes:
- `defaultValue` should be clear fallback English text.
- Prefer adding new keys instead of overloading old keys with different meaning.

## Local Signing and Notarization

Official artifacts are built and signed locally on macOS, then notarized and stapled locally.
Do not treat GitHub-hosted CI build artifacts as official distributables.

Preferred script:

```bash
scripts/build_notarized_release.sh
```

Notarization credentials:
- Recommended: `NOTARY_PROFILE` (Keychain profile from `xcrun notarytool store-credentials`)
- Fallback: `APPLE_ID` + app-specific password + `APPLE_TEAM_ID`

Typical flow:
1. Local release build
2. Developer ID codesign
3. Notarization submit/wait
4. Staple + validate

## License

This project is licensed under the MIT License. See `LICENSE`.

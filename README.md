# Pre-Babel Lens

Pre-Babel Lenz is a local translation application using Apple's In Device Foundation Models. Translation using LLM is possible even in places without an internet connection. Additionally, since the translated text is not sent to an external server, it can be used safely when dealing with privacy or confidential information.
* Please enable Apple Intelligence.

If you set up the Automator workflow as described in the README, you can translate text selected in Mac applications. You can also translate from shortcuts set in the workflow.

Repository: https://github.com/ttrace/pre-babel-lens

![Pre-Babel Lens Screenshot](docs/images/screenshot.png)

## Quick Launch by Double Copy (macOS)

You can launch translation quickly with a DeepL-like flow:

1. Select text in any app.
2. Press `Command + C` twice quickly (`Cmd+C`, `Cmd+C` within about 1 second).
3. Pre-Babel Lens comes to front and starts translation with the selected text.

Notes:
- This feature watches clipboard changes on macOS only.
- It ignores empty text and applies the same duplicate suppression logic used by URL launch.

## Automator Integration (macOS)

You can launch translation from selected text via Automator.

1. Open Automator and create a new `Quick Action`.
2. Set:
   - `Workflow receives current`: `text`
   - `in`: `any application`
3. Add `Run Shell Script`.
4. Set:
   - `Shell`: `/bin/zsh`
   - `Pass input`: `to stdin`
5. Paste this script:

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

6. Save (for example: `Translate with Pre-Babel Lens`).
7. Assign a keyboard shortcut from `System Settings > Keyboard > Keyboard Shortcuts > Services`.

Notes:
- The app keeps your current target language and updates the existing window content.
- If Automator sends the same `text + target language` again, duplicate translation is skipped.

## Unsafe Content Handling

If Apple Intelligence blocks a segment as unsafe, Pre-Babel Lens stops retrying that segment and shows a clear fallback instead.

Current behavior:
- The blocked segment falls back to the original source text.
- Unsafe-source fallback is marked with a leading `⛔`.
- Other segments can continue translating when possible.

## Translation Failure Handling

When a segment cannot be translated cleanly, the Foundation Models engine applies the following recovery flow:

1. Normal segment translation:
   - Each segment is translated with structured output (`targetLanguage`, `translation`).
2. Context window overflow:
   - If an error contains `Exceeded model context window size`, the engine recreates `LanguageModelSession` and retries that segment once.
   - If retry succeeds, translation continues.
   - If retry fails, the segment falls back to source text.
3. Sentence-drop safeguard:
   - After translation, sentence counts are compared (`input` vs `output`).
   - If `output < input/2`, the segment is retried once with a fresh session.
   - Exception: `2 -> 1` is explicitly allowed.
   - If retry fails, the first translation result is kept.
   - Unsafe-content failures skip this retry path and return source text immediately.
4. Structured-output mismatch:
   - If structured output validation fails (for example target language mismatch / empty / placeholder), the segment falls back to source text.
5. Unsafe content:
   - If Foundation Models reports a safety or policy restriction, the segment falls back to source text with a leading `⛔`.
   - This path is treated as no-retry to avoid repeated blocked generations.
6. Cancellation handling:
   - Cancellation is propagated immediately (not converted to source fallback), so stopped jobs can drain cleanly.

## Developer Notes

### Developer Console Diagnostics

Developer Console diagnostics include:
- `context-window-exceeded-refresh-session-and-retry`
- `resumed-after-session-refresh`
- `retry-after-session-refresh-failed-source-returned`
- `sentence-count-drop-detected retry-once`
- `sentence-count-retry-finished`
- `sentence-count-retry-failed-keep-first`
- `structured-output-no-retry-source-returned`
- `unsafe-no-retry-source-returned`

## Project Structure

- `Sources/App/`: app entry point
- `Sources/Features/Translation/`: translation UI and view model
- `Sources/Domain/`: core models and protocols
- `Sources/Engines/Preprocess/`: deterministic preprocessing
- `Sources/Engines/Translation/`: translation engine stubs
- `Sources/Services/`: orchestration and engine policy
- `Tests/`: unit tests

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Release (Local Signing + Notarization)

This project's official release artifacts are built locally, signed locally, and notarized locally.
Do not use GitHub-hosted CI build artifacts as official distributables.

Preferred release script:

```bash
scripts/build_notarized_release.sh
```

Credential options:
- Recommended: `NOTARY_PROFILE` (Keychain profile created by `xcrun notarytool store-credentials`)
- Legacy fallback: `APPLE_ID` + app-specific password + `APPLE_TEAM_ID`

The script performs:
1. local release build
2. Developer ID code signing
3. notarization submission/wait
4. stapling and validation

## Translation Failure Handling

When a segment cannot be translated cleanly, the Foundation Models engine applies the following recovery flow:

1. Normal segment translation:
   - Each segment is translated with structured output (`targetLanguage`, `translation`).
2. Context window overflow:
   - If an error contains `Exceeded model context window size`, the engine recreates `LanguageModelSession` and retries that segment once.
   - If retry succeeds, translation continues.
   - If retry fails, the segment falls back to source text.
3. Sentence-drop safeguard:
   - After translation, sentence counts are compared (`input` vs `output`).
   - If `output < input/2`, the segment is retried once with a fresh session.
   - Exception: `2 -> 1` is explicitly allowed.
   - If retry fails, the first translation result is kept.
4. Structured-output mismatch:
   - If structured output validation fails (for example target language mismatch / empty / placeholder), the segment falls back to source text.
5. Cancellation handling:
   - Cancellation is propagated immediately (not converted to source fallback), so stopped jobs can drain cleanly.

Developer Console diagnostics include:
- `context-window-exceeded-refresh-session-and-retry`
- `resumed-after-session-refresh`
- `retry-after-session-refresh-failed-source-returned`
- `sentence-count-drop-detected retry-once`
- `sentence-count-retry-finished`
- `sentence-count-retry-failed-keep-first`
- `structured-output-no-retry-source-returned`

## License

This project is licensed under the MIT License. See `LICENSE`.

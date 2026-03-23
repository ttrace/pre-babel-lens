# Pre-Babel Lens

Pre-Babel Lenz is a local translation application using Apple's In Device Foundation Models. Translation using LLM is possible even in places without an internet connection. Additionally, since the translated text is not sent to an external server, it can be used safely when dealing with privacy or confidential information.
* Please enable Apple Intelligence.

If you set up the Automator workflow as described in the README, you can translate text selected in Mac applications. You can also translate from shortcuts set in the workflow.

Repository: https://github.com/ttrace/pre-babel-lens

![Pre-Babel Lens Screenshot](docs/images/screenshot.png)

Current focus:
- macOS-first implementation with Swift + SwiftUI
- deterministic preprocessing before translation
- engine-swappable design (Foundation Models / Core ML backends)

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

## Analysis Parameters

The Translation screen can show the following analysis values:

- `Engine`: Translation engine name currently used. `(none)` means no translation has run yet.
- `Mode`: Active preprocessing experiment mode.
- `Detected language`: Language code detected from input text before translation.
- `AI language support`: Whether detected language is supported by Apple Intelligence.
- `Protected tokens`: Count of extracted protected items (URLs, code snippets, numbers, etc.).
- `Glossary matches`: Count of glossary hits found in input text.
- `Ambiguity hints`: Count of ambiguity warnings detected in preprocessing.
- `Trace steps`: Number of preprocessing trace entries recorded for the request.

## License

This project is licensed under the MIT License. See `LICENSE`.

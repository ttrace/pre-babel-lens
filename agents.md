# AGENTS.md

## Project Overview
This repository is a local translation app for Apple platforms.

Primary goals:
- Build a practical local translation app for macOS and iOS
- Keep translation architecture portable across Apple platforms
- Improve translation quality through structured preprocessing and observability
- Learn practical strengths and weaknesses of local LLM-assisted translation

Current product direction:
- App language: Swift
- UI: SwiftUI (iOS-first for current feature work)
- Preprocessing: deterministic guardrails + heuristic/model-assisted analysis
- Translation engine abstraction: interchangeable backends
- Engine strategy:
  - iOS default runtime: Apple Translation framework (TF)
  - iOS enhancement path: Foundation Models (FM) only on FM-capable devices
  - macOS path: continue backend-swappable design (FM / Core ML evolution)
- Current iOS deployment target scope: all iOS 26 devices that support Apple Translation framework (TF)

## Strategic Direction
- Keep iOS startup and baseline translation stable by defaulting to TF.
- Enable FM only when runtime/device capability checks pass.
- Use FM primarily for quality improvements (heuristics, nuanced translation), not for baseline app availability.
- Keep deterministic logic minimal, explainable, and safety-oriented.
- Prefer typed/structured Foundation Models generation (`@Generable`, `@Guide`) over prompt-defined JSON where FM is used.
- Preserve explicit and observable fallback paths; avoid hidden engine switching.

## Core Design Principles
1. Keep Foundation Models, Translation framework, and Core ML decoupled.
   - Treat each as a separate engine behind shared protocols.
   - Do not implement one engine through another.
   - Preserve backend replaceability.

2. Keep preprocessing independent from translation.
   - Preprocessing should be reusable across engines.
   - Translation engines should receive structured inputs, not UI state.

3. Prefer model-assisted heuristics where they improve quality.
   - Use deterministic rules as guardrails and safety constraints.
   - Avoid dictionary-heavy handcrafted exceptions unless required for reliability.

4. Optimize for observability.
   - Preserve intermediate analysis and decision logs.
   - Make engine selection and fallback reasons inspectable.
   - Support output comparison across preprocessing/engine modes.

## iOS Engine Policy (Authoritative)
Default iOS behavior:
- Primary engine: TF
- FM is optional and must be capability-gated

FM activation conditions:
- Device/OS supports required FM features
- FM runtime availability checks pass
- Policy/settings do not force TF

Fallback ordering:
1. If TF is selected as primary: TF result is returned directly (normal path).
2. If FM is selected and succeeds safely: FM result is returned.
3. If FM is selected but output is unsafe/unavailable: retry via TF.
4. If TF recovery also fails: return original source text with UI indication.

Policy constraints:
- Keep engine selection logic in policy/facade/orchestrator layer.
- Do not scatter engine branching in SwiftUI views.
- Log `selectedEngine` and `reason` on each request.

## Architecture Requirements
Prefer the following conceptual layers:
- UI layer
- Application / orchestration layer
- Preprocess layer
- Translation engine layer
- Evaluation / logging layer

Expected abstractions:
- `PreprocessEngine`
- `TranslationEngine`
- `TranslationInput`
- `TranslationOutput`
- `TranslationAnalysis`

## Coding Rules
- Use Swift for app code.
- Use SwiftUI for UI unless there is a strong reason not to.
- Favor small, testable types.
- Prefer value types (`struct`) unless reference semantics are necessary.
- Keep files focused; avoid giant manager classes.
- Avoid premature generalization, but preserve backend-swappability.
- Do not add heavy dependencies unless clearly justified.

## Translation-Specific Requirements
Always preserve and/or explicitly handle:
- proper nouns
- glossary terms
- numbers
- dates
- units
- URLs
- file paths
- code snippets
- UI labels
- punctuation structure where relevant

When implementing preprocessing, prioritize:
1. sentence segmentation
2. protected token extraction
3. glossary application
4. style/domain classification
5. ambiguity hinting
6. formatting preservation

Preprocessing should be conservative:
- prefer marking/protecting over destructive rewriting
- prefer candidate labeling over hard assumptions
- avoid irreversible normalization unless necessary

## PDF Import Line-Break Normalization Spec
Applies to both:
- macOS Source file import path
- iOS Share Extension file import path

Definitions:
- `line-end marker`: `.。!?！？` and closing brackets.
- closing brackets set: `) ] } ） ］ ｝ 〉 》 」 』 】 〙 〗`

Rules:
1. PDF text is extracted page-by-page and normalized before page-join.
2. A line whose original line-head is one of `・ ＊ ー -`, or matches `^[0-9]+[.:;]`, is treated as bullet/list.
3. Bullet/list lines always keep their line break (their line end is not soft-joined).
4. Vertical-writing heuristic:
   - If single-character CJK (excluding Hangul) lines continue for 3+ lines, treat as vertical text.
   - In that region, concatenate lines with no spaces.
   - Continue until a line-end marker appears.
5. CJK no-space join rule:
   - When soft-joining, if the character before the removed line break is CJK (excluding Hangul), join without inserting a space.
   - Otherwise, insert one ASCII space.
6. Numeric-only data line rule:
   - A line matching `^[0-9/:\\s]+$` is treated as data row and is not soft-joined.
7. Intro-line short heading/data rule:
   - Compute max line length from the first 30 lines (after trim).
   - Any non-empty line with length `<= floor(max/2)` is treated as heading/data and is not soft-joined.
   - This rule applies to that line's outgoing edge only:
     previous line may still join into the short line,
     but the short line does not soft-join into the next line.
8. Empty lines are preserved as paragraph separators.

## Observability and Diagnostics
- Append warnings/errors to the in-app Developer Console when available.
- Prefer structured error details (`type`, `domain`, `code`, `userInfo`) over only localized messages.
- For engine policy, log at least:
  - selected engine (`tf` / `fm`)
  - selection reason (`fm_ready`, `device_unsupported`, `fm_unavailable`, `forced_tf`, etc.)
  - fallback transitions (`fm_unsafe -> tf`, `tf_failed -> source`)

## Experimentation Rules
This repository is also for learning. When changing translation quality behavior:
- make effects measurable
- preserve before/after comparisons when practical
- avoid magic behavior without logs/traceability

Where practical, support comparison modes such as:
- raw input
- segmented input
- segmented + glossary
- segmented + glossary + protected terms
- same input across different engine backends

## File / Folder Expectations
If these folders exist, keep responsibilities clear:
- `App/` UI entry points and app lifecycle
- `Features/Translation/` feature-specific UI and state
- `Domain/` core models and protocols
- `Engines/Preprocess/` preprocessing engines
- `Engines/Translation/` translation backends
- `Services/` persistence, settings, logging
- `Tests/` unit and integration tests

Do not move responsibilities across layers casually.

## Testing Expectations
Before finishing substantial work:
- build successfully
- run relevant tests
- add tests for deterministic preprocessing logic
- add regression tests for previously identified failures when possible

Prefer tests for:
- sentence splitting
- glossary application
- protected-term handling
- formatting preservation
- engine selection policy
- iOS policy gating (TF default, FM capability checks, fallback ordering)

## iOS UI and Share Extension Policy
- Keep iOS UI SwiftUI-first.
- Preserve established full-screen translation layout behavior.
- Do not regress Source/Output usability while working on share ingestion.
- Keep Share Extension lightweight and reliability-focused.
- Keep share import paths explicit and observable:
  - App Group storage
  - URL scheme handoff (`prebabellens://import-shared`)
  - shared pasteboard fallback

## Clutch and Scroll-Resize Policy
Clutch interaction requirements:
- In Clutch mode, tapping/cursoring in one field highlights the corresponding segment in the other field.
- When the highlighted target segment is out of view, auto-scroll should bring it into view with platform-consistent touch-and-feel.
- Keep Source and Output behavior symmetric where possible, while allowing platform-specific implementation details.

Compact stacked layout resize requirements (current direction):
- Prefer scroll-driven field resizing over grabber-driven mode switching.
- Reader mode transition should be two-stage:
  1. First downward gesture from compact reader state restores default field heights.
  2. Next gesture performs normal content scrolling.
- After default heights are restored, Source/Output scroll must behave normally in both directions.

Implementation principles for this area:
- Avoid ad-hoc “observe and snap back” patterns whenever possible.
- Prefer structural state transitions that prevent invalid movement up front (for example, explicit mode/lock state gates) over reactive correction.
- Keep gesture ownership clear and minimal to avoid competing recognizers and jitter.
- Keep layout changes decoupled from text-selection/clutch updates to reduce interaction side effects.

## Release Policy
- Official release artifacts must be built on local macOS using the project owner's Xcode toolchain.
- Official release artifacts must be signed with local Developer ID credentials, notarized, and stapled locally.
- GitHub-hosted build artifacts must not be treated as official distributables.
- Preferred command for official release packaging: `scripts/build_notarized_release.sh`.
- Use `NOTARY_PROFILE` keychain profile for notarization credentials when available.

### macOS Release Runbook (v0.8.0 memo)
- Standard flow:
  1. `NOTARY_PROFILE=NOTARY_PROFILE scripts/build_notarized_release.sh`
  2. Confirm outputs exist in `dist/releases/v<version>/`:
     - `zen-Babel.app`
     - `zen-Babel-v<version>.zip`
     - `zen-Babel-v<version>.dmg`
- If script fails only at DMG creation (`hdiutil create failed`), continue with manual completion:
  1. Create DMG manually:
     - `hdiutil create -volname "zen-Babel" -srcfolder "dist/releases/v<version>/zen-Babel-dmg" -anyowners -ov -format UDZO "dist/releases/v<version>/zen-Babel-v<version>.dmg"`
  2. Notarize DMG:
     - `xcrun notarytool submit "dist/releases/v<version>/zen-Babel-v<version>.dmg" --keychain-profile NOTARY_PROFILE --wait`
  3. Staple and validate DMG:
     - `xcrun stapler staple "dist/releases/v<version>/zen-Babel-v<version>.dmg"`
     - `xcrun stapler validate "dist/releases/v<version>/zen-Babel-v<version>.dmg"`
- Permission troubleshooting (important):
  - If VS Code terminal shows `could not access /Volumes/zen-Babel/zen-Babel.app`:
    - Prefer running `hdiutil create ...` from `Terminal.app`.
    - VS Code may not expose/retain `Removable Volumes` permission reliably in some sessions.
  - `...` in docs/commands is placeholder text; replace with a real file path before running `notarytool submit`.
- Final verification checklist:
  - `xcrun notarytool submit ... --wait` returns `status: Accepted`.
  - `xcrun stapler validate` reports success for both `.app` (if re-stapled) and `.dmg`.
  - `spctl --assess --type execute --verbose=4 dist/releases/v<version>/zen-Babel.app` returns accepted.

## iOS Release Branch Policy
- Dedicated iOS release branch: `release/ios`
- Xcode Cloud iOS release workflows should target `release/ios`.
- Keep `release/ios` close to `main` unless temporary hotfix divergence is required.
- Before iOS release:
  1. Sync latest stable changes into `release/ios`.
  2. Confirm version/build metadata on `release/ios`.
  3. Trigger and verify Xcode Cloud from `release/ios`.

## Branch Naming and Version-Line Workflow
Because App Store review can overlap with ongoing development, keep version lines separated by branch.

Branch naming rules:
- Next-release integration branch: `release/ios-<major>.<minor>.x` (example: `release/ios-0.8.x`)
- App Store review / maintenance line: `release/ios-<major>.<minor>.x` for the submitted version line (example: `release/ios-0.7.x`)
- Feature branches: `feature/<short-feature-name>` (example: `feature/clutch-bidirectional-highlighting`)
- Hotfix branches: `hotfix/<short-fix-name>`

Workflow rules:
1. Base all new feature work on the current next-release branch (for example, `release/ios-0.8.x`).
2. Keep App Store pending/maintenance fixes on the submitted version line branch (for example, `release/ios-0.7.x`).
3. Merge feature branches into the next-release branch, not directly into the maintenance branch.
4. For fixes needed in both lines, commit on the maintenance line first, then forward-port to the next-release line (`cherry-pick -x` preferred for traceability).
5. Keep one concern per branch/PR to minimize cross-version merge risk.

## Implementation Guidance for Codex
When making changes:
1. read surrounding code first
2. preserve existing architecture
3. propose minimal, coherent changes
4. avoid unrelated refactors
5. explain tradeoffs clearly in summaries
6. call out uncertainty instead of guessing
7. before creating any commit, ask the user for explicit confirmation

If introducing a new abstraction:
- explain why it is needed
- keep naming simple
- match existing project terminology

If a task is ambiguous, prefer the solution that:
- preserves engine replaceability
- improves observability
- keeps preprocessing deterministic where appropriate
- avoids hidden LLM coupling
- keeps TF/FM integration isolated to engine/policy layers, not views

## Output Style for Agent Work
When returning implementation summaries:
- briefly state what changed
- list impacted files
- mention risks or follow-up items
- mention tests run or not run

Do not claim tests passed unless they were actually run.

## Non-Goals
Unless explicitly requested, do not:
- add cloud dependencies
- redesign the whole app
- collapse preprocessing and translation into one opaque pipeline
- hardwire the app to a single model backend
- introduce large frameworks for simple tasks

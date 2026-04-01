# AGENTS.md

## Project Overview
This repository is a local translation app for Apple platforms.

Primary goals:
- Build a practical local translation app for macOS first
- Keep the architecture portable to iPhone later
- Use heuristics and structured preprocessing to improve translation quality
- Reduce model burden instead of relying only on larger models
- Learn the strengths and weaknesses of LLM-based translation through implementation

Current product direction:
- App language: Swift
- UI: SwiftUI
- Preprocessing: deterministic / heuristic analysis, with optional Foundation Models assistance
- Translation engine abstraction: interchangeable backends
- Initial Apple-platform path:
  - iPhone / early stage: Foundation Models-centered implementation
  - macOS / later stage: custom translation model via Core ML

Strategic direction update:
- Maximize Apple Intelligence (Foundation Models) usage for heuristic preprocessing.
- Prioritize practical local MT quality through model-assisted heuristics over handcrafted rules.
- Avoid dictionary-heavy or purpose-specific deterministic algorithms unless strictly required for reliability/safety.
- Foundation Models structured generation must prefer `@Generable` and `@Guide` schemas over prompt-defined JSON formats.
- Minimize prompt engineering for structure; use prompts mainly for task intent/context while enforcing output shape via typed generation.
- For iOS unsafe fallback recovery, prefer Apple OS Translation framework as a secondary translation engine before falling back to raw source text.
- Treat Translation framework as a fast, stability-oriented recovery path for unsafe segments only; do not replace the main Foundation Models pipeline with it by default.

## Core Design Principles
1. Do not tightly couple Foundation Models and Core ML.
   - Treat them as separate engines behind a shared interface.
   - Do not implement Foundation Models “through” Core ML.
   - Prefer protocol-based abstraction and engine replacement.

2. Keep preprocessing independent from translation.
   - Preprocessing should be reusable across engines.
   - Translation engines should receive structured input, not raw UI state.

3. Prefer heuristic preprocessing backed by Apple Intelligence when quality benefits are expected.
   - Use deterministic logic mainly as guardrails, fallback behavior, and safety-critical constraints.
   - Avoid overfitting segmentation/normalization to specific terms or handcrafted exception dictionaries.
   - Keep deterministic rules minimal, explainable, and easy to remove when model-driven heuristics perform better.

4. Use Foundation Models as the primary heuristic layer.
   - Preferred for analysis, classification, hint generation, ambiguity detection, and adaptive preprocessing.
   - Keep deterministic fallbacks for resilience when model output is unavailable or unsafe.
   - When Foundation Models output is unsafe, allow a secondary translation attempt through Apple Translation framework before source-text fallback.

5. Optimize for observability.
   - Preserve intermediate analysis results
   - Make preprocessing steps inspectable
   - Make it easy to compare outputs across engines

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

Suggested rule:
- keep engine selection in a policy/facade layer
- do not scatter engine-specific branching across views
- fallback ordering for iOS translation should remain explicit and observable:
  - primary: Foundation Models
  - secondary for unsafe segments: Translation framework
  - final fallback: original source text with UI indication

## Coding Rules
- Use Swift for app code
- Use SwiftUI for UI unless there is a strong reason not to
- Favor small, testable types
- Prefer value types (`struct`) unless reference semantics are necessary
- Keep files focused; avoid giant “manager” classes
- Avoid premature generalization, but preserve backend-swappability
- Do not add heavy dependencies unless clearly justified

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

Preprocessing should be mostly conservative:
- prefer marking/protecting over destructive rewriting
- prefer candidate labeling over hard assumptions
- avoid irreversible normalization unless necessary

## Experimentation Rules
This repository is also for learning.
When implementing changes related to translation quality:
- make the effect measurable
- preserve before/after comparison when practical
- avoid “magic” behavior without logs or traceability

Where practical, support comparison modes such as:
- raw input
- segmented input
- segmented + glossary
- segmented + glossary + protected terms
- different engine backends on the same input

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

## Release Policy
- Official release artifacts must be built on local macOS using the project owner's Xcode toolchain.
- Official release artifacts must be signed with local Developer ID credentials, notarized, and stapled locally.
- GitHub-hosted build artifacts must not be treated as official distributables for this project.
- Preferred command for official release packaging: `scripts/build_notarized_release.sh`.
- Use `NOTARY_PROFILE` keychain profile for notarization credentials when available.

## Implementation Guidance for Codex
When making changes:
1. read surrounding code first
2. preserve existing architecture
3. propose minimal, coherent changes
4. avoid unrelated refactors
5. explain tradeoffs clearly in summaries
6. call out uncertainty instead of guessing

For debugging and observability:
- append warnings and errors to the in-app Developer Console when available
- prefer structured error details (type/domain/code/userInfo) over only localized messages

If introducing a new abstraction:
- explain why it is needed
- keep naming simple
- match existing project terminology

If a task is ambiguous, prefer the solution that:
- preserves engine replaceability
- improves observability
- keeps preprocessing deterministic
- avoids hidden LLM coupling
- keeps Translation framework integration isolated to an engine/policy layer rather than embedding direct framework calls in views or view models

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

## Session Handoff (2026-03-23)
Current branch:
- `main`

Working tree status:
- Uncommitted changes exist in:
  - `Sources/Domain/TranslationModels.swift`
  - `Sources/Domain/TranslationProtocols.swift`
  - `Sources/Engines/Translation/FoundationModelsTranslationEngine.swift`
  - `Sources/Features/Translation/TranslationViewModel.swift`
  - `Sources/Services/TranslationOrchestrator.swift`

Implemented in this session (not yet committed):
- Added `SegmentKind` enum and attached `kind` to `TextSegment` (default `.general`).
- Switched Foundation Models translation output to structured JSON with:
  - `targetLanguage`
  - `kind`
  - `translation`
- Added structured-output validation for:
  - target language mismatch
  - kind mismatch
  - empty translation
- Added retry/fallback diagnostic events and routed them to ViewModel console.
- Updated translation console logs to session-scoped format (`[Sx] ...`).
- Added session-start kind summary logging (e.g. `kinds={general=...}`).
- Updated prompt example text to use `"<translated text>"` (no ellipsis placeholder).

Important behavior notes:
- Current segmentation still defaults to `kind = .general` unless explicitly assigned.
- Console now includes timing indexes and diagnostic retry/fallback events per session.

Known verification gap:
- Build/test not executed successfully in this environment due local toolchain/SDK mismatch.
- Next session should run local build/tests in user’s normal Xcode toolchain before release.

Suggested next steps:
1. Build and run app in Xcode toolchain.
2. Verify structured output stability with multiple target languages.
3. Confirm session logs include kind and session prefix for retry cases.
4. Optionally implement deterministic kind classifier in preprocess layer.

## Session Handoff (2026-03-26)
Current branch:
- `feature/ios-support`

Current product policy (important):
- iPhone UI development is now SwiftUI-first.
- iOS layout tuning is considered complete for current baseline.
- Current focus is Share Panel (iOS Share Extension) integration and stabilization.
- Keep macOS and iOS architecture aligned through shared domain/service layers.

iOS UI policy:
- Use full-screen layout.
- Keep compact spacing and practical controls.
- Preserve dark/light theme parity with macOS design direction.
- Do not regress the finalized Source/Output split layout while implementing share features.

Share Extension scope (current):
- Extension target exists: `PreBabelLensShare`.
- Goal: accept shared text/URL/file text and bring it into app Source field.
- URL scheme route is already confirmed to work:
  - `prebabellens://translate?text=...`
  - `prebabellens://import-shared?text=...`
- Remaining issue: Share Panel flow does not always deliver content into app Source after tapping post.

Technical requirements for Share Panel work:
- Keep extension lightweight; avoid heavy UI and avoid unrelated refactors.
- Use App Group for shared storage:
  - `group.com.ttrace.prebabellens`
- Keep URL scheme handoff enabled:
  - `prebabellens://import-shared`
- Maintain fallback paths to maximize delivery reliability:
  - App Group storage
  - URL query handoff
  - shared pasteboard fallback
- Ensure Swift Concurrency safety:
  - avoid non-Sendable crossing actor boundaries
  - handle `SLComposeServiceViewController` main actor isolation correctly
- Prefer observable failure paths (clear logs/error reporting) for share ingestion.

Files currently central to Share Panel debugging:
- `iOSShareExtension/ShareViewController.swift`
- `iOSApp/Shared/SharedImportStore.swift`
- `iOSApp/SceneDelegate.swift`
- `iOSApp/TranslationViewController.swift`
- `iOSApp/Info.plist`
- `PreBabelLensiOS.xcodeproj/project.pbxproj`

Near-term implementation priorities:
1. Make Share Panel ingest reliable for Files/Safari/selected text workflows.
2. Add visible diagnostics for successful/failed import path selection.
3. Keep existing iOS SwiftUI layout behavior unchanged while fixing share intake.
4. Verify signing/capabilities alignment for App + Extension (same team, App Group enabled).

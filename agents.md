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

## Release Policy
- Official release artifacts must be built on local macOS using the project owner's Xcode toolchain.
- Official release artifacts must be signed with local Developer ID credentials, notarized, and stapled locally.
- GitHub-hosted build artifacts must not be treated as official distributables.
- Preferred command for official release packaging: `scripts/build_notarized_release.sh`.
- Use `NOTARY_PROFILE` keychain profile for notarization credentials when available.

## iOS Release Branch Policy
- Dedicated iOS release branch: `release/ios`
- Xcode Cloud iOS release workflows should target `release/ios`.
- Keep `release/ios` close to `main` unless temporary hotfix divergence is required.
- Before iOS release:
  1. Sync latest stable changes into `release/ios`.
  2. Confirm version/build metadata on `release/ios`.
  3. Trigger and verify Xcode Cloud from `release/ios`.

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

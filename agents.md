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

## Core Design Principles
1. Do not tightly couple Foundation Models and Core ML.
   - Treat them as separate engines behind a shared interface.
   - Do not implement Foundation Models “through” Core ML.
   - Prefer protocol-based abstraction and engine replacement.

2. Keep preprocessing independent from translation.
   - Preprocessing should be reusable across engines.
   - Translation engines should receive structured input, not raw UI state.

3. Prefer deterministic logic where possible.
   - Sentence splitting
   - glossary matching
   - protected-term extraction
   - formatting preservation
   - symbol / punctuation normalization
   These should be implemented as ordinary program logic first, not delegated blindly to an LLM.

4. Use Foundation Models conservatively.
   - Good for soft analysis, classification, hint generation, ambiguity detection
   - Avoid making app-critical behavior depend entirely on nondeterministic model output

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

## Implementation Guidance for Codex
When making changes:
1. read surrounding code first
2. preserve existing architecture
3. propose minimal, coherent changes
4. avoid unrelated refactors
5. explain tradeoffs clearly in summaries
6. call out uncertainty instead of guessing

If introducing a new abstraction:
- explain why it is needed
- keep naming simple
- match existing project terminology

If a task is ambiguous, prefer the solution that:
- preserves engine replaceability
- improves observability
- keeps preprocessing deterministic
- avoids hidden LLM coupling

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

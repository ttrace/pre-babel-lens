import Foundation

enum TranslationExperimentMode: String, CaseIterable, Equatable, Sendable, Identifiable {
    case rawInput
    case segmented
    case segmentedGlossary
    case segmentedGlossaryProtected

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rawInput:
            return "Raw Input"
        case .segmented:
            return "Segmented"
        case .segmentedGlossary:
            return "Segmented + Glossary"
        case .segmentedGlossaryProtected:
            return "Segmented + Glossary + Protected"
        }
    }

    var usesSegmentation: Bool {
        self != .rawInput
    }

    var usesGlossary: Bool {
        self == .segmentedGlossary || self == .segmentedGlossaryProtected
    }

    var usesProtectedTokens: Bool {
        self == .segmentedGlossaryProtected
    }
}

struct TranslationRequest: Equatable {
    var sourceLanguage: String
    var targetLanguage: String
    var text: String
    var glossary: [GlossaryEntry]
    var preferredLanguages: [String] = []
    var experimentMode: TranslationExperimentMode = .segmentedGlossaryProtected
    var usesAITranslation: Bool = false
}

struct GlossaryEntry: Hashable, Equatable {
    var source: String
    var target: String
}

struct TranslationInput: Equatable {
    var sourceLanguage: String
    var targetLanguage: String
    var originalText: String
    var preferredLanguages: [String] = []
    var detectedLanguageCode: String? = nil
    var isDetectedLanguageSupportedByAppleIntelligence: Bool = true
    var segments: [TextSegment]
    // Joiner text after each segment (same count as `segments`), used to preserve punctuation/newlines.
    var segmentJoinersAfter: [String] = []
    var protectedTokens: [ProtectedToken]
    var glossaryMatches: [GlossaryMatch]
    var ambiguityHints: [AmbiguityHint]
    var formatting: FormattingProfile
}

struct TranslationOutput: Equatable {
    var translatedText: String
    var containsUnsafeFallback: Bool
    var segmentOutputs: [SegmentOutput]
    var analysis: TranslationAnalysis
}

enum SegmentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case heading
    case general
    case dialogue
    case uiLabels = "ui-labels"
    case lists
    case codesOrPath = "codes_or_path"
}

enum SegmentRole: String, CaseIterable, Codable, Hashable, Sendable {
    case leading
    case regular
}

struct TextSegment: Hashable, Equatable, Identifiable {
    let id: UUID
    var index: Int
    var text: String
    var kind: SegmentKind
    var role: SegmentRole

    init(
        id: UUID = UUID(),
        index: Int,
        text: String,
        kind: SegmentKind = .general,
        role: SegmentRole? = nil
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.kind = kind
        self.role = role ?? (index == 0 ? .leading : .regular)
    }
}

struct SegmentOutput: Hashable, Equatable, Identifiable {
    let id: UUID
    var segmentIndex: Int
    var sourceText: String
    var translatedText: String
    var isUnsafeFallback: Bool
    var isUnsafeRecoveredByTranslationFramework: Bool

    init(
        id: UUID = UUID(),
        segmentIndex: Int,
        sourceText: String,
        translatedText: String,
        isUnsafeFallback: Bool = false,
        isUnsafeRecoveredByTranslationFramework: Bool = false
    ) {
        self.id = id
        self.segmentIndex = segmentIndex
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.isUnsafeFallback = isUnsafeFallback
        self.isUnsafeRecoveredByTranslationFramework = isUnsafeRecoveredByTranslationFramework
    }
}

struct ProtectedToken: Hashable, Equatable, Identifiable {
    enum Kind: String {
        case url
        case filePath
        case codeSnippet
        case properNounCandidate
        case number
    }

    let id: UUID
    var kind: Kind
    var value: String
    var range: Range<String.Index>

    init(id: UUID = UUID(), kind: Kind, value: String, range: Range<String.Index>) {
        self.id = id
        self.kind = kind
        self.value = value
        self.range = range
    }
}

struct GlossaryMatch: Hashable, Equatable, Identifiable {
    let id: UUID
    var source: String
    var target: String
    var range: Range<String.Index>

    init(id: UUID = UUID(), source: String, target: String, range: Range<String.Index>) {
        self.id = id
        self.source = source
        self.target = target
        self.range = range
    }
}

struct AmbiguityHint: Hashable, Equatable, Identifiable {
    let id: UUID
    var category: String
    var message: String

    init(id: UUID = UUID(), category: String, message: String) {
        self.id = id
        self.category = category
        self.message = message
    }
}

struct FormattingProfile: Equatable {
    var leadingWhitespace: String
    var trailingWhitespace: String
    var newlineCount: Int
}

struct PreprocessTrace: Hashable, Equatable, Identifiable {
    let id: UUID
    var step: String
    var summary: String

    init(id: UUID = UUID(), step: String, summary: String) {
        self.id = id
        self.step = step
        self.summary = summary
    }
}

struct TranslationAnalysis: Equatable {
    var request: TranslationRequest
    var traces: [PreprocessTrace]
    var input: TranslationInput
    var engineName: String
}

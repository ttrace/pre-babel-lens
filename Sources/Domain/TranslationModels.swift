import Foundation

struct TranslationRequest: Equatable {
    var sourceLanguage: String
    var targetLanguage: String
    var text: String
    var glossary: [GlossaryEntry]
}

struct GlossaryEntry: Hashable, Equatable {
    var source: String
    var target: String
}

struct TranslationInput: Equatable {
    var sourceLanguage: String
    var targetLanguage: String
    var originalText: String
    var segments: [TextSegment]
    var protectedTokens: [ProtectedToken]
    var glossaryMatches: [GlossaryMatch]
    var ambiguityHints: [AmbiguityHint]
    var formatting: FormattingProfile
}

struct TranslationOutput: Equatable {
    var translatedText: String
    var segmentOutputs: [SegmentOutput]
    var analysis: TranslationAnalysis
}

struct TextSegment: Hashable, Equatable, Identifiable {
    let id: UUID
    var index: Int
    var text: String

    init(id: UUID = UUID(), index: Int, text: String) {
        self.id = id
        self.index = index
        self.text = text
    }
}

struct SegmentOutput: Hashable, Equatable, Identifiable {
    let id: UUID
    var segmentIndex: Int
    var sourceText: String
    var translatedText: String

    init(id: UUID = UUID(), segmentIndex: Int, sourceText: String, translatedText: String) {
        self.id = id
        self.segmentIndex = segmentIndex
        self.sourceText = sourceText
        self.translatedText = translatedText
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

import Foundation

public enum SpokenRequestRoute: Equatable, Sendable {
    case agent(prompt: String)
    case agentFollowUp(prompt: String)
    case agentStatus
    case invalidAgentTrigger
    case screenAwareComposition
    case companion
}

public enum SpokenAgentConversationContext: Equatable, Sendable {
    case none
    case selected
    case soleRunning
    case ambiguous

    fileprivate var hasPotentialFollowUpTarget: Bool {
        self != .none
    }
}

public enum SpokenIntentRouter {
    public static func route(
        _ transcript: String,
        hasScreenAwareDestination: Bool = false,
        agentConversationContext: SpokenAgentConversationContext = .none
    ) -> SpokenRequestRoute {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return .companion }
        if requestsHardNoAgent(trimmedTranscript) { return .companion }

        for wakePhraseWords in spokenWakePhraseWords {
            guard let prompt = promptAfterWakePhrase(
                wakePhraseWords,
                in: trimmedTranscript
            ) else { continue }
            guard !prompt.isEmpty else { return .invalidAgentTrigger }
            return .agent(prompt: prompt)
        }

        for followUpWakePhraseWords in spokenFollowUpWakePhraseWords {
            guard let prompt = promptAfterWakePhrase(
                followUpWakePhraseWords,
                in: trimmedTranscript
            ) else { continue }
            guard !prompt.isEmpty else { return .invalidAgentTrigger }
            return .agentFollowUp(prompt: prompt)
        }

        if trimmedTranscript.range(
            of: "agent:",
            options: [.anchored, .caseInsensitive]
        ) != nil {
            let promptStartIndex = trimmedTranscript.index(
                trimmedTranscript.startIndex,
                offsetBy: "agent:".count
            )
            let prompt = promptAfterRemovingLeadingTriggerSeparators(
                from: trimmedTranscript[promptStartIndex...]
            )
            guard !prompt.isEmpty else { return .invalidAgentTrigger }
            return .agent(prompt: prompt)
        }

        if requestsSoftNoAgent(trimmedTranscript) {
            return .companion
        }
        if isAgentStatusQuery(trimmedTranscript) { return .agentStatus }

        // High-confidence NEW work must win over follow-up steering in every
        // context, not just .ambiguous: an unrelated multi-step request
        // spoken while some task happens to be open would otherwise be
        // silently steered into the wrong existing thread.
        if agentConversationContext.hasPotentialFollowUpTarget,
           isLikelyAgentFollowUp(trimmedTranscript),
           !isHighConfidenceAgentTask(trimmedTranscript) {
            return .agentFollowUp(prompt: trimmedTranscript)
        }

        if isQuestionOrTeachingRequest(trimmedTranscript) {
            return hasScreenAwareDestination ? .screenAwareComposition : .companion
        }

        if isHighConfidenceAgentTask(trimmedTranscript) {
            return .agent(prompt: trimmedTranscript)
        }

        return hasScreenAwareDestination ? .screenAwareComposition : .companion
    }

    private static let spokenWakePhraseWords = [
        ["hey", "clicky", "agent"],
        ["clicky", "agent"]
    ]

    private static let spokenFollowUpWakePhraseWords = [
        ["hey", "clicky", "continue", "agent"],
        ["hey", "clicky", "tell", "agent"],
        ["clicky", "continue", "agent"]
    ]

    private static let strongAgentTaskPhrases = [
        "run tests",
        "run the tests",
        "prepare a pr",
        "open a pr",
        "create a pr",
        "pull request",
        "build a website",
        "make a website",
        "create a website",
        "build an app",
        "create an app",
        "edit the code",
        "modify the code",
        "audit the codebase",
        "audit this codebase",
        "clean up these screenshots",
        "create a csv",
        "create a reminder",
        "create a report",
        "create a ticket",
        "upload this folder"
    ]

    private static let durableAgentTaskVerbs = [
        "audit",
        "build",
        "clean",
        "create",
        "debug",
        "fix",
        "implement",
        "investigate",
        "make",
        "refactor",
        "research",
        "schedule",
        "send",
        "transcribe",
        "upload"
    ]

    private static let agentScopeWords = [
        "codebase",
        "csv",
        "database",
        "files",
        "folder",
        "invite",
        "message",
        "note",
        "reminder",
        "report",
        "repo",
        "repository",
        "spreadsheet",
        "ticket",
        "website",
        "app"
    ]

    // Prefixes are matched against normalizedWords(in:) output, so each one
    // is normalized the same way; the trailing space is re-appended after
    // normalizing because it is the word boundary that stops a prefix like
    // "make " from matching a longer word like "makeshift".
    private static let directFollowUpPrefixes = [
        "also ",
        "do not ",
        "don't ",
        "instead ",
        "only "
    ].map { normalizedWords(in: $0) + " " }

    private static let continuedActionPrefixes = [
        "now add ",
        "now change ",
        "now create ",
        "now fix ",
        "now implement ",
        "now run ",
        "now test ",
        "now update "
    ].map { normalizedWords(in: $0) + " " }

    private static let refinementActionPrefixes = [
        "add ",
        "adjust ",
        "change ",
        "keep ",
        "make ",
        "remove ",
        "replace ",
        "use ",
        "can you add ",
        "can you change ",
        "can you make ",
        "can you remove ",
        "could you add ",
        "could you change ",
        "could you make ",
        "could you remove "
    ].map { normalizedWords(in: $0) + " " }

    // These are matched against normalizedWords(in:) output, which strips
    // punctuation, so the phrases must be normalized the same way — otherwise
    // contracted forms like "don't" (normalized to "don t") can never match
    // and the hard no-agent guard is silently dead for them.
    private static let hardNoAgentPhrases = [
        "do not start an agent",
        "don't start an agent",
        "do not use an agent",
        "don't use an agent"
    ].map { normalizedWords(in: $0) }

    private static let softNoAgentPhrases = [
        "just explain"
    ]

    private static let agentStatusPhrases = [
        "are my agents done",
        "show my agents",
        "what are my agents doing",
        "what are the agents doing"
    ]

    private static let triggerBoundaryCharacters = CharacterSet
        .whitespacesAndNewlines
        .union(.punctuationCharacters)

    // The boundary AFTER the trigger word must be whitespace or an explicit
    // phrase separator — never the full punctuation set, because that set
    // includes word-internal characters like apostrophes and hyphens, and
    // ordinary words such as "agent's" or "agent-based" would misroute the
    // whole sentence into the agent lane with a mangled prompt.
    private static let promptSeparatorCharacters = CharacterSet
        .whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",:;.?!"))

    private static func isTriggerBoundary(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(from: triggerBoundaryCharacters) != nil
    }

    private static func isPromptSeparator(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(from: promptSeparatorCharacters) != nil
    }

    private static func promptAfterWakePhrase(
        _ wakePhraseWords: [String],
        in transcript: String
    ) -> String? {
        var currentIndex = transcript.startIndex

        for (wordIndex, wakePhraseWord) in wakePhraseWords.enumerated() {
            let remainingTranscript = transcript[currentIndex...]
            guard remainingTranscript.range(
                of: wakePhraseWord,
                options: [.anchored, .caseInsensitive]
            ) != nil else {
                return nil
            }
            currentIndex = transcript.index(
                currentIndex,
                offsetBy: wakePhraseWord.count
            )

            guard wordIndex < wakePhraseWords.count - 1 else { break }
            guard currentIndex < transcript.endIndex,
                  isTriggerBoundary(transcript[currentIndex]) else {
                return nil
            }
            while currentIndex < transcript.endIndex,
                  isTriggerBoundary(transcript[currentIndex]) {
                currentIndex = transcript.index(after: currentIndex)
            }
        }

        let remainingTranscript = transcript[currentIndex...]
        guard remainingTranscript.isEmpty
                || remainingTranscript.first.map(isPromptSeparator) == true else {
            return nil
        }
        return promptAfterRemovingLeadingTriggerSeparators(from: remainingTranscript)
    }

    private static func promptAfterRemovingLeadingTriggerSeparators(
        from remainingTranscript: Substring
    ) -> String {
        guard let promptStartIndex = remainingTranscript.firstIndex(
            where: { !isPromptSeparator($0) }
        ) else {
            return ""
        }
        return remainingTranscript[promptStartIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyAgentFollowUp(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedWords(in: transcript)
        return directFollowUpPrefixes.contains {
            normalizedTranscript.hasPrefix($0)
        } || continuedActionPrefixes.contains {
            normalizedTranscript.hasPrefix($0)
        } || refinementActionPrefixes.contains {
            normalizedTranscript.hasPrefix($0)
        }
    }

    private static func isHighConfidenceAgentTask(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedWords(in: transcript)
        var confidenceScore = 0

        if strongAgentTaskPhrases.contains(where: normalizedTranscript.contains) {
            confidenceScore += 2
        }
        if durableAgentTaskVerbs.contains(where: { durableAgentTaskVerb in
            normalizedTranscript == durableAgentTaskVerb
                || normalizedTranscript.hasPrefix(durableAgentTaskVerb + " ")
        }) {
            confidenceScore += 1
        }
        if normalizedTranscript.contains(" and ")
            || normalizedTranscript.contains(" then ") {
            confidenceScore += 1
        }
        if agentScopeWords.contains(where: { agentScopeWord in
            normalizedTranscript.split(separator: " ").contains(Substring(agentScopeWord))
        }) {
            confidenceScore += 1
        }

        return confidenceScore >= 3
    }

    private static func normalizedWords(in transcript: String) -> String {
        transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func requestsHardNoAgent(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedWords(in: transcript)
        return hardNoAgentPhrases.contains(where: normalizedTranscript.contains)
    }

    private static func requestsSoftNoAgent(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedWords(in: transcript)
        return softNoAgentPhrases.contains(where: normalizedTranscript.contains)
    }

    private static func isAgentStatusQuery(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedWords(in: transcript)
        return agentStatusPhrases.contains(where: normalizedTranscript.contains)
    }

    private static func isQuestionOrTeachingRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = normalizedWords(in: transcript)
        let questionPrefixes = [
            "explain ",
            "how ",
            "show me ",
            "tell me ",
            "what ",
            "why "
        ]
        return questionPrefixes.contains(where: normalizedTranscript.hasPrefix)
            || normalizedTranscript.contains("explain how ")
            || normalizedTranscript.contains("explain why ")
            || normalizedTranscript.contains("show me how ")
            || normalizedTranscript.contains("show me why ")
            || normalizedTranscript.contains("tell me how ")
            || normalizedTranscript.contains("tell me why ")
    }
}

public enum SpokenAgentFollowUpTargetResolution: Equatable, Sendable {
    case target(threadID: String)
    case requiresSelection
    case missing
}

public enum SpokenAgentFollowUpTargetResolver {
    public static func resolve(
        selectedThreadID: String?,
        runningThreadIDs: [String]
    ) -> SpokenAgentFollowUpTargetResolution {
        if let selectedThreadID {
            return .target(threadID: selectedThreadID)
        }
        if runningThreadIDs.count == 1, let runningThreadID = runningThreadIDs.first {
            return .target(threadID: runningThreadID)
        }
        return runningThreadIDs.isEmpty ? .missing : .requiresSelection
    }
}

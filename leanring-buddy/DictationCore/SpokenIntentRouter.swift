import Foundation

public enum SpokenRequestRoute: Equatable, Sendable {
    case agent(prompt: String)
    case invalidAgentTrigger
    case screenAwareComposition
    case companion
}

public enum SpokenIntentRouter {
    public static func route(
        _ transcript: String,
        hasScreenAwareDestination: Bool = false
    ) -> SpokenRequestRoute {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return .companion }

        for wakePhraseWords in spokenWakePhraseWords {
            guard let prompt = promptAfterWakePhrase(
                wakePhraseWords,
                in: trimmedTranscript
            ) else { continue }
            guard !prompt.isEmpty else { return .invalidAgentTrigger }
            return .agent(prompt: prompt)
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

        return hasScreenAwareDestination ? .screenAwareComposition : .companion
    }

    private static let spokenWakePhraseWords = [
        ["hey", "clicky", "agent"],
        ["clicky", "agent"]
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
}

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
            let prompt = trimmedTranscript[promptStartIndex...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func isTriggerBoundary(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(from: triggerBoundaryCharacters) != nil
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
                || remainingTranscript.first.map(isTriggerBoundary) == true else {
            return nil
        }
        return promptAfterRemovingLeadingTriggerSeparators(from: remainingTranscript)
    }

    private static func promptAfterRemovingLeadingTriggerSeparators(
        from remainingTranscript: Substring
    ) -> String {
        guard let promptStartIndex = remainingTranscript.firstIndex(
            where: { !isTriggerBoundary($0) }
        ) else {
            return ""
        }
        return remainingTranscript[promptStartIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

//
//  CodexAppServerProcessTransport.swift
//  leanring-buddy
//
//  Launches the local Codex app-server and frames JSONL messages over stdio.
//

import Foundation

struct CodexJSONLineFramer {
    private var bufferedData = Data()

    mutating func append(_ incomingData: Data) -> [Data] {
        bufferedData.append(incomingData)
        var completeLines: [Data] = []

        while let newlineIndex = bufferedData.firstIndex(of: 0x0A) {
            var lineData = Data(bufferedData[..<newlineIndex])
            bufferedData.removeSubrange(bufferedData.startIndex...newlineIndex)

            if lineData.last == 0x0D {
                lineData.removeLast()
            }

            if !lineData.isEmpty {
                completeLines.append(lineData)
            }
        }

        return completeLines
    }

    mutating func finish() -> Data? {
        var finalLineData = bufferedData
        bufferedData.removeAll(keepingCapacity: true)

        if finalLineData.last == 0x0D {
            finalLineData.removeLast()
        }

        return finalLineData.isEmpty ? nil : finalLineData
    }
}

enum CodexChildProcessEnvironment {
    private static let standardExecutableDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin"
    ]

    static func augmentingPath(
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> [String: String] {
        var augmentedEnvironment = environment
        var executableDirectories = environment["PATH"]?
            .components(separatedBy: ":") ?? []

        executableDirectories.append(contentsOf: standardExecutableDirectories)
        executableDirectories.append(
            homeDirectoryURL.appendingPathComponent(".npm-global/bin").path
        )

        var seenExecutableDirectories = Set<String>()
        augmentedEnvironment["PATH"] = executableDirectories
            .filter { seenExecutableDirectories.insert($0).inserted }
            .joined(separator: ":")
        return augmentedEnvironment
    }
}

enum CodexProcessStandardError {
    static let maximumCapturedByteCount = 4_096

    static func appendingTail(
        _ incomingData: Data,
        to existingData: Data,
        maximumByteCount: Int = maximumCapturedByteCount
    ) -> Data {
        guard maximumByteCount > 0 else { return Data() }
        if incomingData.count >= maximumByteCount {
            return Data(incomingData.suffix(maximumByteCount))
        }

        var capturedData = existingData
        let overflowByteCount = capturedData.count + incomingData.count - maximumByteCount
        if overflowByteCount > 0 {
            capturedData.removeFirst(overflowByteCount)
        }
        capturedData.append(incomingData)
        return capturedData
    }

    static func sanitizedText(from capturedData: Data) -> String {
        let decodedText = String(decoding: capturedData, as: UTF8.self)
        let unicodeScalars = Array(decodedText.unicodeScalars)
        var sanitizedScalars = String.UnicodeScalarView()
        var scalarIndex = 0

        while scalarIndex < unicodeScalars.count {
            let scalarValue = unicodeScalars[scalarIndex].value

            if scalarValue == 0x1B {
                scalarIndex = indexAfterEscapeSequence(
                    in: unicodeScalars,
                    startingAt: scalarIndex
                )
                continue
            }

            let isAllowedWhitespace = scalarValue == 0x09
                || scalarValue == 0x0A
                || scalarValue == 0x0D
            if isAllowedWhitespace || (scalarValue >= 0x20 && scalarValue != 0x7F) {
                sanitizedScalars.append(unicodeScalars[scalarIndex])
            }
            scalarIndex += 1
        }

        return String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func indexAfterEscapeSequence(
        in unicodeScalars: [UnicodeScalar],
        startingAt escapeIndex: Int
    ) -> Int {
        let introducerIndex = escapeIndex + 1
        guard introducerIndex < unicodeScalars.count else {
            return introducerIndex
        }

        switch unicodeScalars[introducerIndex].value {
        case 0x5B: // Control Sequence Introducer: ESC [ ... final-byte
            var scalarIndex = introducerIndex + 1
            while scalarIndex < unicodeScalars.count {
                let scalarValue = unicodeScalars[scalarIndex].value
                scalarIndex += 1
                if (0x40...0x7E).contains(scalarValue) {
                    break
                }
            }
            return scalarIndex

        case 0x5D: // Operating System Command: ESC ] ... BEL or ESC \
            var scalarIndex = introducerIndex + 1
            while scalarIndex < unicodeScalars.count {
                let scalarValue = unicodeScalars[scalarIndex].value
                if scalarValue == 0x07 {
                    return scalarIndex + 1
                }
                if scalarValue == 0x1B,
                   scalarIndex + 1 < unicodeScalars.count,
                   unicodeScalars[scalarIndex + 1].value == 0x5C {
                    return scalarIndex + 2
                }
                scalarIndex += 1
            }
            return scalarIndex

        default:
            return introducerIndex + 1
        }
    }
}

enum CodexExecutableLocator {
    static let executableOverrideEnvironmentKey = "CLICKY_CODEX_EXECUTABLE"

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> URL? {
        candidateURLs(
            environment: environment,
            bundleResourceURL: bundleResourceURL
        ).first { candidateURL in
            fileManager.isExecutableFile(atPath: candidateURL.path)
        }
    }

    static func candidateURLs(
        environment: [String: String],
        bundleResourceURL: URL?
    ) -> [URL] {
        var candidateURLs: [URL] = []

        if let overriddenExecutablePath = environment[executableOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overriddenExecutablePath.isEmpty {
            candidateURLs.append(URL(fileURLWithPath: overriddenExecutablePath))
        }

        if let bundleResourceURL {
            candidateURLs.append(bundleResourceURL.appendingPathComponent("codex"))
        }

        candidateURLs.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ])

        var seenPaths = Set<String>()
        return candidateURLs.filter { candidateURL in
            seenPaths.insert(candidateURL.standardizedFileURL.path).inserted
        }
    }
}

final class CodexAppServerProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    private let executableURL: URL
    private let extraArguments: [String]
    private let stateLock = NSLock()

    private var process: Process?
    private var standardInputPipe: Pipe?
    private var standardOutputPipe: Pipe?
    private var standardErrorPipe: Pipe?
    private var standardErrorData = Data()
    private var jsonLineFramer = CodexJSONLineFramer()
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onTermination: (@Sendable (CodexAppServerError) -> Void)?
    private var isStoppingIntentionally = false
    private var isFinalizingProcessTermination = false

    init(
        executableURL: URL,
        extraArguments: [String] = []
    ) {
        self.executableURL = executableURL
        self.extraArguments = extraArguments
    }

    static func processArguments(
        extraArguments: [String] = []
    ) -> [String] {
        extraArguments + ["app-server", "--stdio"]
    }

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (CodexAppServerError) -> Void
    ) throws {
        stateLock.lock()
        guard process == nil else {
            stateLock.unlock()
            throw CodexAppServerError.alreadyConnected
        }

        let process = Process()
        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = Self.processArguments(extraArguments: extraArguments)
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.environment = CodexChildProcessEnvironment.augmentingPath(
            environment: ProcessInfo.processInfo.environment,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )

        // If the app-server dies between send()'s liveness check and the actual
        // stdin write, writing to a pipe with no reader raises SIGPIPE, which
        // kills the whole app rather than throwing. F_SETNOSIGPIPE converts that
        // into an EPIPE error that FileHandle.write(contentsOf:) throws normally.
        _ = fcntl(
            standardInputPipe.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        )

        self.process = process
        self.standardInputPipe = standardInputPipe
        self.standardOutputPipe = standardOutputPipe
        self.standardErrorPipe = standardErrorPipe
        self.standardErrorData = Data()
        self.jsonLineFramer = CodexJSONLineFramer()
        self.onMessage = onMessage
        self.onTermination = onTermination
        self.isStoppingIntentionally = false
        self.isFinalizingProcessTermination = false
        stateLock.unlock()

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            self?.receiveAvailableStandardOutput(from: fileHandle)
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            self?.receiveAvailableStandardError(from: fileHandle)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.processDidTerminate(terminatedProcess)
        }

        do {
            try process.run()
        } catch {
            resetAfterFailedStart()
            throw error
        }
    }

    func send(_ messageData: Data) throws {
        stateLock.lock()
        guard let standardInputHandle = standardInputPipe?.fileHandleForWriting,
              process?.isRunning == true else {
            stateLock.unlock()
            throw CodexAppServerError.notConnected
        }
        stateLock.unlock()

        var jsonLineData = messageData
        jsonLineData.append(0x0A)
        try standardInputHandle.write(contentsOf: jsonLineData)
    }

    func stop() {
        stateLock.lock()
        isStoppingIntentionally = true
        let runningProcess = process
        let inputHandle = standardInputPipe?.fileHandleForWriting
        let outputHandle = standardOutputPipe?.fileHandleForReading
        let errorHandle = standardErrorPipe?.fileHandleForReading
        onMessage = nil
        onTermination = nil
        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe = nil
        stateLock.unlock()

        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    private func receiveAvailableStandardOutput(from fileHandle: FileHandle) {
        stateLock.lock()
        guard !isFinalizingProcessTermination,
              standardOutputPipe?.fileHandleForReading === fileHandle else {
            stateLock.unlock()
            return
        }

        let incomingData = fileHandle.availableData
        guard !incomingData.isEmpty else {
            stateLock.unlock()
            return
        }

        let completeMessages = jsonLineFramer.append(incomingData)
        let messageHandler = onMessage
        for completeMessage in completeMessages {
            messageHandler?(completeMessage)
        }
        stateLock.unlock()
    }

    private func receiveAvailableStandardError(from fileHandle: FileHandle) {
        stateLock.lock()
        guard !isFinalizingProcessTermination,
              standardErrorPipe?.fileHandleForReading === fileHandle else {
            stateLock.unlock()
            return
        }

        let incomingData = fileHandle.availableData
        guard !incomingData.isEmpty else {
            stateLock.unlock()
            return
        }

        appendStandardError(incomingData)
        stateLock.unlock()
    }

    private func appendStandardError(_ incomingData: Data) {
        standardErrorData = CodexProcessStandardError.appendingTail(
            incomingData,
            to: standardErrorData
        )
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        stateLock.lock()
        guard process === terminatedProcess else {
            stateLock.unlock()
            return
        }

        // Stop readability callbacks from consuming bytes while this method drains EOF.
        // Any callback already handling data holds stateLock and completes before this phase.
        isFinalizingProcessTermination = true
        let outputHandle = standardOutputPipe?.fileHandleForReading
        let errorHandle = standardErrorPipe?.fileHandleForReading
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        stateLock.unlock()

        let finalStandardOutputData = (try? outputHandle?.readToEnd()) ?? nil
        let finalStandardErrorData = (try? errorHandle?.readToEnd()) ?? nil

        stateLock.lock()
        guard process === terminatedProcess else {
            stateLock.unlock()
            return
        }

        var finalMessages: [Data] = []
        if let finalStandardOutputData, !finalStandardOutputData.isEmpty {
            finalMessages.append(contentsOf: jsonLineFramer.append(finalStandardOutputData))
        }
        if let unterminatedFinalMessage = jsonLineFramer.finish() {
            finalMessages.append(unterminatedFinalMessage)
        }
        if let finalStandardErrorData, !finalStandardErrorData.isEmpty {
            appendStandardError(finalStandardErrorData)
        }

        let shouldReportTermination = !isStoppingIntentionally
        let messageHandler = onMessage
        let terminationHandler = onTermination
        let capturedStandardError = CodexProcessStandardError.sanitizedText(
            from: standardErrorData
        )
        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe = nil
        onMessage = nil
        onTermination = nil
        stateLock.unlock()

        for finalMessage in finalMessages {
            messageHandler?(finalMessage)
        }

        if shouldReportTermination {
            terminationHandler?(
                .processTerminated(
                    exitCode: terminatedProcess.terminationStatus,
                    standardError: capturedStandardError
                )
            )
        }
    }

    private func resetAfterFailedStart() {
        stateLock.lock()
        let outputHandle = standardOutputPipe?.fileHandleForReading
        let errorHandle = standardErrorPipe?.fileHandleForReading
        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe = nil
        onMessage = nil
        onTermination = nil
        isFinalizingProcessTermination = false
        stateLock.unlock()

        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
    }
}

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
    private static let maximumCapturedStandardErrorBytes = 65_536

    private let executableURL: URL
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

    init(executableURL: URL) {
        self.executableURL = executableURL
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
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        self.process = process
        self.standardInputPipe = standardInputPipe
        self.standardOutputPipe = standardOutputPipe
        self.standardErrorPipe = standardErrorPipe
        self.standardErrorData = Data()
        self.jsonLineFramer = CodexJSONLineFramer()
        self.onMessage = onMessage
        self.onTermination = onTermination
        self.isStoppingIntentionally = false
        stateLock.unlock()

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            self?.receiveStandardOutput(availableData)
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            self?.receiveStandardError(availableData)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.processDidTerminate(exitCode: terminatedProcess.terminationStatus)
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

    private func receiveStandardOutput(_ incomingData: Data) {
        stateLock.lock()
        let completeMessages = jsonLineFramer.append(incomingData)
        let messageHandler = onMessage
        stateLock.unlock()

        for completeMessage in completeMessages {
            messageHandler?(completeMessage)
        }
    }

    private func receiveStandardError(_ incomingData: Data) {
        stateLock.lock()
        let availableByteCount = Self.maximumCapturedStandardErrorBytes - standardErrorData.count
        if availableByteCount > 0 {
            standardErrorData.append(incomingData.prefix(availableByteCount))
        }
        stateLock.unlock()
    }

    private func processDidTerminate(exitCode: Int32) {
        stateLock.lock()
        let shouldReportTermination = !isStoppingIntentionally
        let terminationHandler = onTermination
        let capturedStandardError = String(data: standardErrorData, encoding: .utf8) ?? ""
        let outputHandle = standardOutputPipe?.fileHandleForReading
        let errorHandle = standardErrorPipe?.fileHandleForReading
        process = nil
        standardInputPipe = nil
        standardOutputPipe = nil
        standardErrorPipe = nil
        onMessage = nil
        onTermination = nil
        stateLock.unlock()

        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil

        if shouldReportTermination {
            terminationHandler?(
                .processTerminated(
                    exitCode: exitCode,
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
        stateLock.unlock()

        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
    }
}

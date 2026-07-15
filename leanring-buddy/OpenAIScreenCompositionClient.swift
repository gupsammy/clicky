//
//  OpenAIScreenCompositionClient.swift
//  leanring-buddy
//
//  Sends bounded screen-aware dictation context through the Clicky Worker.
//

import Foundation

struct OpenAIScreenCompositionClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class OpenAIScreenCompositionClient {
    private let urlSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        urlSession = Foundation.URLSession(configuration: configuration)
    }

    var isConfigured: Bool {
        compositionProxyURL != nil && ClickyProxyAuthorization.isConfigured
    }

    func compose(
        request screenAwareCompositionRequest: ScreenAwareCompositionRequest
    ) async throws -> ScreenAwareCompositionResponse {
        guard let compositionProxyURL else {
            throw OpenAIScreenCompositionClientError(
                message: "Screen-aware dictation is not configured. Set ClickyAPIProxyBaseURL in Info.plist."
            )
        }
        guard ClickyProxyAuthorization.isConfigured else {
            throw OpenAIScreenCompositionClientError(
                message: "Screen-aware dictation requires a Worker access token in the macOS Keychain."
            )
        }

        var urlRequest = Foundation.URLRequest(url: compositionProxyURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        try ClickyProxyAuthorization.authorize(&urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(screenAwareCompositionRequest)

        let (responseData, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenAIScreenCompositionClientError(
                message: "Screen-aware composition failed with HTTP \(statusCode)."
            )
        }

        return try ScreenAwareCompositionResponse.decode(data: responseData)
    }

    private var compositionProxyURL: URL? {
        if let configuredURL = AppBundleConfiguration
            .stringValue(forKey: "OpenAIScreenCompositionProxyURL"),
           !configuredURL.contains("your-worker-name"),
           let proxyURL = URL(string: configuredURL) {
            return proxyURL
        }

        guard let configuredWorkerBaseURL = AppBundleConfiguration
            .stringValue(forKey: "ClickyAPIProxyBaseURL"),
              !configuredWorkerBaseURL.contains("your-worker-name"),
              let workerBaseURL = URL(string: configuredWorkerBaseURL) else {
            return nil
        }

        return workerBaseURL.appendingPathComponent("openai-screen-compose")
    }
}

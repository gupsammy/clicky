//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation
import PostHog

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        PostHogSDK.shared.capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        PostHogSDK.shared.capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        PostHogSDK.shared.capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        PostHogSDK.shared.capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        PostHogSDK.shared.capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        PostHogSDK.shared.capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        PostHogSDK.shared.capture("push_to_talk_released")
    }

    static func trackFastDictationStarted() {
        PostHogSDK.shared.capture("fast_dictation_started")
    }

    static func trackFastDictationReleased() {
        PostHogSDK.shared.capture("fast_dictation_released")
    }

    static func trackFastDictationCompleted(
        characterCount: Int,
        insertionMethod: FocusedTextInsertionMethod,
        latencyMilliseconds: Int?
    ) {
        var properties: [String: Any] = [
            "character_count": characterCount,
            "insertion_method": insertionMethod.rawValue
        ]
        if let latencyMilliseconds {
            properties["latency_ms"] = latencyMilliseconds
        }
        PostHogSDK.shared.capture("fast_dictation_completed", properties: properties)
    }

    static func trackFastDictationFailed() {
        PostHogSDK.shared.capture("fast_dictation_failed")
    }

    static func trackScreenAwareDictationStarted() {
        PostHogSDK.shared.capture("screen_aware_dictation_started")
    }

    static func trackScreenAwareDictationReleased() {
        PostHogSDK.shared.capture("screen_aware_dictation_released")
    }

    static func trackScreenAwareDictationCompleted(
        characterCount: Int,
        insertionMethod: FocusedTextInsertionMethod,
        latencyMilliseconds: Int?
    ) {
        var properties: [String: Any] = [
            "character_count": characterCount,
            "insertion_method": insertionMethod.rawValue
        ]
        if let latencyMilliseconds {
            properties["latency_ms"] = latencyMilliseconds
        }
        PostHogSDK.shared.capture(
            "screen_aware_dictation_completed",
            properties: properties
        )
    }

    static func trackScreenAwareDictationFailed() {
        PostHogSDK.shared.capture("screen_aware_dictation_failed")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "character_count": transcript.count
        ])
    }

    /// Claude responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "character_count": response.count
        ])
    }

    /// Claude's response included a coordinate tag, so the buddy is flying to
    /// point at a UI element. The label is screen-derived content and must not
    /// leave the device.
    static func trackElementPointed() {
        PostHogSDK.shared.capture("element_pointed")
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: Error) {
        PostHogSDK.shared.capture(
            "response_error",
            properties: privacyPreservingErrorProperties(for: error)
        )
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: Error) {
        PostHogSDK.shared.capture(
            "tts_error",
            properties: privacyPreservingErrorProperties(for: error)
        )
    }

    /// Converts arbitrary upstream errors into a small, enumerable analytics
    /// vocabulary. Never include localized descriptions because upstream
    /// response bodies can contain user or screen-derived content.
    private static func privacyPreservingErrorProperties(for error: Error) -> [String: Any] {
        let nsError = error as NSError
        var properties: [String: Any] = [
            "category": errorCategory(for: nsError)
        ]

        if (100...599).contains(nsError.code),
           ["ClaudeAPI", "OpenAIAPI", "ElevenLabsTTS"].contains(nsError.domain) {
            properties["http_status_code"] = nsError.code
        }

        return properties
    }

    private static func errorCategory(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled:
                return "cancelled"
            case NSURLErrorTimedOut:
                return "timeout"
            default:
                return "network"
            }
        }

        if (100...599).contains(error.code) {
            switch error.code {
            case 401, 403:
                return "authentication"
            case 408:
                return "timeout"
            case 429:
                return "rate_limit"
            case 400...499:
                return "request"
            case 500...599:
                return "upstream"
            default:
                break
            }
        }

        switch error.code {
        case -1:
            return "invalid_response"
        default:
            return "other"
        }
    }
}

# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it through OpenAI Realtime when configured, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming. This fork routes `/chat` through Google Vertex AI (`us-east5`) using a GCP service account, rather than the upstream Anthropic direct path.
- **Speech-to-Text**: OpenAI Realtime streaming (`gpt-realtime-whisper`) via websocket and a Worker-minted ephemeral client secret. Apple Speech is the no-API fallback; AssemblyAI remains available as an explicitly selected legacy provider.
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Codex Agents**: The UI-independent foundation launches a local Codex app-server over JSONL stdio, performs the required initialization handshake, reads ChatGPT subscription authentication, correlates requests, and streams notifications plus server-initiated approval requests. Agent threads and UI are not wired yet.
- **Concurrency**: UI state uses `@MainActor`; the Codex app-server client is an actor and process I/O is lock-protected before crossing into async streams.
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `{region}-aiplatform.googleapis.com` (Vertex AI) | Claude vision + streaming chat via `streamRawPredict`. Worker signs a service-account JWT, exchanges it for an OAuth access token (cached in module scope), and forwards the SSE stream unchanged. |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token. Unused when `VoiceTranscriptionProvider=apple` in Info.plist. |
| `POST /openai-realtime-token` | `api.openai.com/v1/realtime/client_secrets` | Fetches a short-lived OpenAI transcription-session client secret. |

Worker secrets: `GCP_SERVICE_ACCOUNT_KEY` (full JSON key for the Vertex proxy service account), `ELEVENLABS_API_KEY`, `OPENAI_API_KEY`, `CLICKY_PROXY_ACCESS_TOKEN` (matching per-install token stored in the macOS Keychain), `ASSEMBLYAI_API_KEY` (optional — only needed if the app uses AssemblyAI transcription).
Worker vars: `ELEVENLABS_VOICE_ID`, `VERTEX_PROJECT_ID`, `VERTEX_REGION`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**OpenAI Realtime Dictation**: The app never stores a standard OpenAI API key. It asks the Worker for a one-minute client secret, opens one authenticated websocket per push-to-talk session, converts microphone audio to 24 kHz mono PCM16, streams base64 audio append events, and manually commits the buffer on key-up. The provider reconciles delta and completed events by `item_id`. GA `gpt-realtime-whisper` does not accept prompt steering, so contextual vocabulary stays at the dictation-manager seam for a later screen-aware cleanup pass.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Local Codex App-Server**: Agent work uses the local Codex executable and its existing authentication instead of shipping a second agent credential. Clicky checks an explicit `CLICKY_CODEX_EXECUTABLE` override, a bundled executable, the ChatGPT/Codex app bundles, and common Homebrew locations. The stable connection sequence is `initialize` → `initialized` → `account/read`. Notifications and server-initiated requests use separate streams so approval requests retain their request IDs and cannot be silently dropped.

**Safe Agent Workspace**: Every thread start/resume and turn start requires an existing Agent Folder. Clicky reasserts `on-request`, user-reviewed approvals, and `workspace-write`; turns also send an explicit writable-root list containing only the selected folder and disable network access. Thread history is listed by exact `cwd`. The agent API supports start, resume, list, read, turn start, steer, and interrupt without exposing unrestricted defaults to callers.

**Agent Task State**: `CodexAgentTaskStore` reduces the notification and server-request streams into concurrent snapshots keyed by thread. It assembles agent message deltas, tracks current and recent command/file/tool activities, preserves pending approvals by request ID, handles waiting-for-input and terminal states, and publishes newest-first HUD-ready snapshots. Per-turn presentation state resets when a durable thread starts another turn. Approval presence is authoritative across the two independently consumed streams, so out-of-order delivery cannot hide or resurrect an approval.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIRealtimeTranscriptionProvider.swift` | ~418 | OpenAI-first streaming provider. Fetches an ephemeral client secret from the Worker, streams 24 kHz PCM16 to Realtime, commits on key-up, and delivers partial/final transcripts without embedding an API key. |
| `ClickyProxyAuthorization.swift` | ~64 | Reads the deployment-specific Worker bearer token from the macOS Keychain and authorizes proxy requests without embedding it in the app. |
| `DictationCore/OpenAIRealtimeTranscriptionProtocol.swift` | ~188 | UI-independent session/client event encoding, server event parsing, and item-aware transcript accumulation for OpenAI Realtime. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `AgentCore/CodexAppServerProtocol.swift` | ~275 | Minimal stable Codex JSON-RPC types, initialization/account contracts, dynamic JSON values, server notifications, server-initiated requests, and typed errors. |
| `AgentCore/CodexAppServerProcessTransport.swift` | ~259 | Locates and launches the local Codex executable, frames JSONL stdout, writes requests to stdin, captures bounded stderr, and handles process lifecycle. |
| `AgentCore/CodexAppServerClient.swift` | ~320 | Actor that performs initialization and account discovery, correlates requests with timeouts, streams notifications and approval requests, and sends typed responses. |
| `AgentCore/CodexAgentModels.swift` | ~254 | Validated Agent Folder, safe approval/sandbox settings, durable thread and turn models, request contracts, and typed lifecycle notifications. |
| `AgentCore/CodexAgentClient.swift` | ~153 | Safe app-server thread and turn operations: start, resume, list, read, start turn, steer, and interrupt. |
| `AgentCore/CodexAgentTaskModels.swift` | ~120 | HUD-independent task, activity, approval, and event models for concurrent agent progress. |
| `AgentCore/CodexAgentTaskStore.swift` | ~582 | Actor reducer and stream monitor that converts Codex notifications and approval requests into bounded, concurrent task snapshots. |
| `Package.swift` | ~42 | UI-independent Swift package harness for compiling and testing agent and dictation protocol cores without invoking Xcode or touching TCC permissions. |
| `AgentCoreTests/CodexAppServerCoreTests.swift` | ~320 | Deterministic transport/protocol tests plus an opt-in live handshake against an installed, authenticated Codex app-server. |
| `AgentCoreTests/CodexAgentThreadTests.swift` | ~510 | Wire-level safety tests for workspace scoping and durable thread/turn operations plus an opt-in ephemeral live thread test. |
| `AgentCoreTests/CodexAgentTaskStoreTests.swift` | ~525 | Reducer tests for concurrency, deltas, activities, approvals, terminal states, multi-turn reset, ordering, and memory bounds. |
| `DictationCoreTests/OpenAIRealtimeTranscriptionProtocolTests.swift` | ~69 | Deterministic tests for Realtime session configuration, audio encoding, event parsing, and transcript reconciliation. |
| `.github/workflows/agent-core-tests.yml` | ~19 | Runs the UI-independent agent and dictation suites with warnings treated as errors on macOS pull requests and main pushes. |
| `worker/src/index.ts` | ~224 | Cloudflare Worker proxy for Claude chat, ElevenLabs TTS, AssemblyAI tokens, and ephemeral OpenAI Realtime transcription secrets. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Compile and run the UI-independent agent and dictation protocol tests
swift test

# Opt into the local ChatGPT-subscription handshake test
CLICKY_RUN_CODEX_INTEGRATION_TESTS=1 \
CLICKY_CODEX_EXECUTABLE=/Applications/ChatGPT.app/Contents/Resources/codex \
swift test --filter CodexAppServerLiveTests/testAuthenticatedChatGPTCodexHandshake

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put OPENAI_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

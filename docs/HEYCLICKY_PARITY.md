# HeyClicky parity and architecture plan

Status: research complete.
Research date: July 15, 2026.
Target: bring this open-source fork toward current HeyClicky behavior with an OpenAI-first stack, prioritizing dictation and Codex app-server agents. External SaaS integrations are intentionally deferred.

## Implementation status

As of July 16, 2026, this is a late parity implementation and native QA effort, not a completed full-parity clone. The highest-value product spine exists: subscription-backed Codex app-server agents, concurrent durable threads, the line-based notch HUD, approvals and structured input, same-thread spoken continuation, conservative voice routing, literal and screen-aware dictation foundations, companion vision, cursor grounding, static annotations, and one-step TARGET/HOVER walkthroughs.

The remaining work is split between native acceptance and intentionally deferred scope:

```text
IMPLEMENTED, NOW UNDER QA
  app-server agents + resume + attention delivery
  spoken start/follow-up router
  dictation and screen-aware composition paths
  cursor trace, POINT/SHAPE, TARGET/HOVER
  line-based notch, task history, persistent tokens

PARTIAL OR NOT YET RELEASE-GREEN
  cross-app physical dictation matrix
  automatic spoken routing acceptance
  live model-authored spatial alignment
  long streaming CPU and 30-minute resilience soak
  display hot-plug, VoiceOver, and complete TCC recovery matrix

DEFERRED FROM THIS MILESTONE
  full-duplex app-server/API Realtime voice
  first-class computer-use automation
  local memory and skill-management UI
  MCP/SaaS integrations, proactive monitoring, billing, remote tasks
```

Therefore, current work is both feature completion and QA-driven bug fixing. The app is not yet at literal full HeyClicky v10 parity, and the active goal must remain open until the release-gate scenarios in the manual QA document are either verified or explicitly accepted as deferred.

## Executive conclusion

The public repository is not merely an older UI. It contains the first product architecture: a voice-triggered screen-aware tutor whose response is rendered beside a blue cursor. Current HeyClicky has evolved into a two-lane macOS assistant shell:

```text
                              HEYCLICKY SHELL
                                    |
                  +-----------------+-----------------+
                  |                                   |
          FAST INTERACTION LANE                DURABLE WORK LANE
          dictation / realtime voice           Codex app-server agents
          screen-aware drafting                persisted threads
          teaching / annotations               tools, commands, file edits
          sub-second visible feedback          minutes-long background work
                  |                                   |
                  +-----------------+-----------------+
                                    |
                           NOTCH + CURSOR UX
                   progress, follow-up, artifacts,
                     history, settings, completion
```

The best path is not to clone the private app file-for-file. It is a clean-room evolution of this repo that keeps the proven microphone, shortcut, ScreenCaptureKit, and overlay code while replacing the one-shot Claude response path with two explicit OpenAI lanes:

1. `gpt-realtime-whisper` or `gpt-4o-transcribe` for low-latency text dictation, with Apple Speech retained as an offline fallback.
2. `gpt-5.6-luna` through the Responses API for slower screen-aware focused-field composition, with the focused app, bounded field text, and only the relevant display as context.
3. The locally authenticated Codex app-server for durable agent work, using the user's ChatGPT subscription when available.
4. A later Realtime voice lane for duplex conversation, barge-in, and voice routing to Codex threads. API-backed Realtime use requires an API credential; ChatGPT subscription authentication covers Codex app-server, not general OpenAI API calls.

This ordering produces the highest user value without first rebuilding integrations, billing, proactive monitoring, or the commercial backend.

## Evidence standard

The feature inventory uses three confidence levels.

`Verified` means the behavior or architecture is present in the official current notarized app bundle, its readable shipped resources, its symbols, or the current public repository. `Demonstrated` means Farza visibly showed and narrated it in a dated product video. `Inferred` means the behavior is the most likely explanation of the evidence but the private Swift body is not available.

The official current artifact inspected was HeyClicky `1.0.38 (47)`, released July 14, signed and notarized by Farzain Majeed. The DMG SHA-256 was `0512e793b5a5515ed73df94237cff5ef11a595281f928ba335e55d1841d4213e`. The bundle reports private build commit `61a9a3d2` and contains a universal native Swift executable, Codex `0.132.0`, `ClickyModelInstructions.md`, an `AGENTS.md`, bundled skills, integration instructions, audio assets, and build metadata. It does not contain Swift source, JavaScript source, source maps, or a dSYM. Swift source filenames, type names, protocol strings, endpoints, and user-visible labels remain in the compiled binary and are useful for architectural confirmation, not source recovery.

No private implementation code is copied into this plan. Shipped instructions and skills are summarized as product behavior contracts.

## Product evolution

### April 7: cursor tutor, the public-repo generation

The [original demo](https://x.com/FarzaTV/status/2041314633978659092) shows the product represented by this repository: a blue companion follows the pointer, listens on a hotkey, captures screen context, answers aloud, and points to exact UI targets. The stated value is learning inside the application instead of moving between a tutorial and the work.

### April 23: product foundation livestream

The [one-hour livestream](https://x.com/FarzaTV/status/2047389920474644732) is the long-form baseline source. It confirms that the agent pivot was driven by seeing nontechnical users struggle to get meaningful work from Codex and Claude Code. At 15:31 Farza states the goal: the simplest interface for people to interact with models. At 18:13 he demonstrates the legacy cursor tutor; at 21:41 he introduces the new voice-spawned agent.

The live agent sequence establishes the base product contract in unusually concrete form:

```text
21:41  voice agent concept; any kind of agent
22:00  clean 90 desktop screenshots; visible local/background execution
22:52  create native Reminders without opening the app
24:22  build and launch a browser game while other agents run
25:55  follow up on the same work thread from visible result
26:54  screen-aware competitor research delivered into Apple Notes
28:34  micro-influencer research in parallel
30:14  download/transcribe/analyze a reel and write a matching script
31:31  inspect completed agent results
33:04  turn research into a personalized outreach DM
38:48  expose a wrong-channel messaging failure and the need to stop safely
39:14  frame voice as the nontechnical agent interface
40:52  build and launch a native Spotify Mac app
42:02  explain that durable work runs in the background, not as computer use
46:50  state that the agent runs a local fork of Codex
50:00  point the agent at an existing codebase and build Clicky with Clicky
55:20  discuss progressive permissions and the need for user confidence
56:32  verify an agent-authored feature after restart and permission handling
59:33  demonstrate typed chat and typed agent spawning as a voice alternative
```

This stream resolves several architectural questions that the short demos leave ambiguous. Agents are local Codex processes, not long-running calls inside the screen-chat provider. They work concurrently in the background, operate on local files and codebases, preserve follow-up threads, can use current-screen context, and deliver results into the user's existing apps or as local artifacts. The cursor tutor remains a separate fast interaction mode rather than being replaced by agents.

### April 26: voice-spawned background agents

The [agent demo](https://x.com/FarzaTV/status/2048203459976188261) introduces the most important architectural shift. Voice requests spawn background workers; each worker has a visible representation, live hover status, independent completion, and a follow-up thread. Demonstrated work includes desktop cleanup, a Reminder, web research to a CSV, and building and launching a native Spotify controller. Multiple agents run concurrently.

### May 5: automatic routing, memory, computer use, and text insertion

The [v1.0.12 announcement](https://x.com/FarzaTV/status/2051454940326097220) shows several features that later become core rather than add-ons: Clicky decides when work requires an agent without a special wake phrase, keeps a structured personal wiki for agent memory, inserts generated text into the focused field, and uses visible computer control as a fallback. The screen-aware email-reply example is the direct precursor of July's dictation feature.

### May 16: notch home and proactive assistance

The [notch UX demo](https://x.com/FarzaTV/status/2055774393243230387) moves Clicky's home from a cursor follower to the MacBook notch. The notch shows compact current work, history, and connector identity. The assistant detects the current app and offers a small proactive suggestion. Users speak naturally; the router, not the user, decides whether to spawn an agent.

### May 30: always-on realtime voice

The [hands-free demo](https://x.com/FarzaTV/status/2060865350036750847) demonstrates application opening, media control, status queries, calendar questions, reminder creation, and conversational response without holding a key. A follow-up states that triple-Control enables the experiment and headphones are required, consistent with an early echo/barge-in constraint.

### June 16: model-to-user spatial teaching

The [drawing demo](https://x.com/FarzaTV/status/2066983088035656086) expands one point tag into a visual instruction grammar. The model draws labelled polygons, arrows, curves, and sequential targets over any app while narrating. Examples teach the Pythagorean theorem over a paused video and build a beat directly in FL Studio.

### July 8: user-to-model spatial context

The [spatial-context demo](https://x.com/FarzaTV/status/2074973272463310905) reverses the direction. While holding the hotkey, the user circles or hovers over a region; that trace is attached to the screenshot so a question or agent request is grounded in the exact intended area.

### July 14: fast and screen-aware dictation

The [dictation demo](https://x.com/FarzaTV/status/2077130366230639022) establishes two separate shortcuts and latency expectations. `Fn + Control` is fast, literal streaming dictation into the focused text field. `Control + Option` is slower screen-aware composition: it reads the visible email, technical terminal output, slide, or other context and writes an appropriate result in the user's voice. The fast lane visibly streams into Notes. The screen-aware lane shows `Listening` or `Speaking`, then `Thinking deeper`, and atomically inserts into Gmail, a Claude Code prompt, or a selected Slides text box without auto-sending. Skills and memory can shape the composition. An adjacent founder post reports roughly 450 ms for the fast lane, but does not define whether that measures interim or final text; the Gmail screen-aware example takes about five seconds after speech.

## Current public-repo baseline

```text
Control + Option key-down
        |
GlobalPushToTalkShortcutMonitor (listen-only CGEvent tap)
        |
BuddyDictationManager + AVAudioEngine
        |
Apple Speech (configured default)
AssemblyAI streaming or OpenAI upload (available alternatives)
        |
final transcript
        |
CompanionManager captures every display with ScreenCaptureKit
        |
ClaudeAPI -> Cloudflare Worker -> Vertex Claude
        |
streamed text + optional [POINT:x,y:label:screenN]
        |
ElevenLabs voice + blue cursor overlay
```

The repo already has a credible reusable microphone pipeline, provider abstraction, permission flow, partial-transcript plumbing, system-wide modifier shortcut, screen capture, multi-monitor coordinate conversion, transparent overlays, interruption behavior, and state-driven cursor animation. The decisive integration seam is the finalized transcript callback in `CompanionManager.swift`: today it immediately calls the Claude-with-screenshot path.

The repo has no agent runtime. There is no `Process` owner, app-server transport, JSON-RPC model, thread persistence, turn reducer, tool activity, approval response, diff model, artifact surface, agent history, working-directory selection, or concurrent task model.

The current worktree also has two operational facts that must be preserved. The user's Xcode signing-team edit is uncommitted, and Xcode user data is untracked. Local `main` is one commit ahead and one behind `origin/main`. The remote-side commit removes a raw Anthropic credential that remains in local `HEAD`; the credential should be considered compromised and rotated. Future work should be isolated in worktrees or a new branch so those local changes are not overwritten.

## Current commercial architecture

The current native app's compiled source inventory is unusually informative. Relevant filenames include `CodexRuntimeBridge.swift`, `CodexProtocolClient.swift`, `CodexAgentSession.swift`, `CompanionManager+CodexAgent.swift`, `CompanionManager+CodexAgentTurn.swift`, `CodexHUDWindow.swift`, `CompanionManager+Dictation.swift`, `DictationDeepgramTranscriber.swift`, `DictationFocusContext.swift`, `DictationInsertion.swift`, `DictationCorrectionLearner.swift`, `CompanionManager+RealtimeVoice.swift`, `RealtimeVoiceClient.swift`, `RealtimeDuplexAudioEngine.swift`, `ScreenAnnotationManager.swift`, `AnnotationOverlay.swift`, `NotchWindowManager.swift`, and separate Home, Agents, History, Threads, Settings, and text-input notch views.

That inventory, the shipped agent contract, and protocol strings support this architecture:

```text
macOS process: HeyClicky.app (SwiftUI + AppKit)
|
+-- Input and routing
|   +-- global shortcut monitor
|   +-- fast dictation controller
|   +-- realtime duplex voice controller
|   +-- focused-field and Accessibility context
|   +-- screen capture and user annotation trace
|   `-- intent router: companion response vs agent start/steer
|
+-- Fast companion lane
|   +-- /agent/realtime/session -> OpenAI Realtime ephemeral session
|   +-- /v2/chat -> screen reasoning provider
|   +-- audio response, barge-in, VAD, truncation
|   `-- cursor/annotation overlay and short response history
|
+-- Dictation lane
|   +-- streaming STT session
|   +-- final tail/batch fallback
|   +-- /v2/dictation/cleanup
|   +-- verify captured field is still focused
|   +-- Accessibility text insertion
|   `-- clipboard fallback + learned corrections/dictionary
|
+-- Durable agent lane
|   +-- CodexRuntimeBridge
|   |   `-- bundled codex app-server child process
|   +-- CodexProtocolClient (JSONL JSON-RPC over stdio)
|   +-- CodexAgentSession (thread/turn ownership)
|   +-- concurrent CodexTaskViewModels
|   +-- file diffs, artifacts, commands, notifications
|   `-- stop, steer, resume, list, read, hide/history
|
+-- Presentation
|   +-- notch Home / Agents / Threads / History / Settings
|   +-- compact live-event surface in collapsed notch
|   +-- per-screen Codex HUD and cursor-flight animation
|   +-- text composer, attachments, follow-up suggestions
|   `-- launch/completion sounds and Quick Look thumbnails
|
+-- Context and customization
|   +-- user memory profile
|   +-- active skills + bundled workflow skills
|   +-- selected Agent Folder / working directory
|   +-- optional activity timeline for proactive suggestions
|   `-- permissions and per-capability settings
|
`-- Backend services
    +-- auth, plan, usage, memory, history
    +-- ephemeral Realtime and dictation tokens
    +-- screen-chat proxy
    +-- skills and integrations
    `-- PostHog, Sentry, Sparkle
```

### Agent runtime details

Current HeyClicky bundles Codex and starts `codex app-server` with an isolated `CODEX_HOME`. Static configuration shows a custom Worker-backed Responses provider, saved history, high reasoning effort, `approval_policy = "never"`, and `sandbox_mode = "danger-full-access"`. Those last two settings describe the inspected commercial build; they are not a safe default for this fork.

Confirmed calls include `initialize`, `thread/start`, `thread/resume`, `thread/list`, `thread/read`, `turn/start`, `turn/steer`, and `turn/interrupt`. Confirmed events include assistant/reasoning deltas, command execution, file changes, MCP startup and tool activity, errors, and turn completion. The current official app-server schema also supports model listing, account status/login, permissions, granular approval requests, thread naming/archive/delete/fork, local images, and skill inputs.

The target fork should use the stable app-server surface first. It should start with `workspace-write` and `on-request`, render command/file-change approvals, and let users deliberately choose a more autonomous permission profile later. Using the user's normal Codex state allows ChatGPT subscription authentication and automatic token refresh. An isolated Clicky-specific `CODEX_HOME` is a later distribution decision because it requires an explicit sign-in flow and credential lifecycle.

### Fast voice and dictation details

The inspected build separates literal dictation from full duplex voice. Its fast dictation implementation has streaming deltas, a final tail, batch fallback, model cleanup, captured-focus validation, Accessibility insertion, clipboard fallback, language settings, a custom dictionary, and learned corrections. The realtime lane has ephemeral sessions, server VAD, barge-in, assistant-audio truncation, echo-cancellation topology checks, route-change recovery, voice selection, and tools that can spawn or steer Codex sessions.

For this OpenAI-first fork, the equivalent stack should be:

```text
Fn + Control                    Control + Option / voice mode
fast literal dictation          contextual or agent request
        |                                  |
gpt-realtime-whisper            screenshot + focused app/field context
or gpt-4o-transcribe                       |
        |                         gpt-5.6-luna composition
focused-field validation                   |
        |                       verified atomic field insertion
Accessibility insertion
```

Apple Speech should remain a no-key fallback. General OpenAI transcription and Realtime calls use Platform API credentials and billing; they do not inherit ChatGPT subscription credits from Codex login.

## Ranked parity backlog

### P0: trust and a runnable foundation

1. Rebase the working baseline safely without touching the user's signing changes. Bring in the remote credential-removal commit and rotate the exposed key.
2. Stop sending full transcripts and full model responses to PostHog. Agent prompts, terminal output, code, and file paths must never be added to analytics events by default.
3. Add a Foundation-only protocol/test target that can be verified without microphone, Screen Recording, Accessibility, or terminal `xcodebuild`.
4. Define explicit `VoiceState`, `DictationState`, and `AgentTaskState` models instead of overloading the current four-state companion enum.

### P1: fast dictation

1. Add a distinct configurable `Fn + Control` literal-dictation shortcut while retaining `Control + Option` for screen-aware work.
2. Render partial transcription in a small non-activating overlay and stream it into the focused field only after focus capture is validated.
3. Capture the focused Accessibility element, surrounding text, selection/range, app bundle ID, and window title at shortcut-down. Refuse to inject if focus changed before completion.
4. Add Accessibility insertion with pasteboard fallback and a visible fallback notice.
5. Add language selection/automatic detection, custom vocabulary, and correction learning after the core flow is stable.
6. Target the founder-stated visible latency: first useful text around 450 ms on a warm streaming session, measured rather than assumed.

### P1: Codex app-server agents

1. Discover and launch a compatible local Codex runtime. For the first build, prefer the installed ChatGPT/Codex runtime and the user's existing ChatGPT login; provide clear setup if neither exists.
2. Implement newline-delimited JSON-RPC over stdio with request IDs, initialization, crash detection, restart, and bounded event buffering.
3. Implement thread start/resume/list/read, turn start/steer/interrupt, and stable per-thread working directories.
4. Route explicit agent requests and substantial tasks from the existing finalized-transcript seam into Codex. Attach a screenshot only when screen context materially helps.
5. Reduce streamed items into user-facing activity: thinking, command, file change, web/tool call, approval, reconnecting, failed, interrupted, and done.
6. Implement concurrent tasks, persistent thread IDs, voice/text follow-up, interrupt, and relaunch recovery.
7. Render command and file-change approvals. Default to `workspace-write` plus `on-request`; never silently copy the inspected commercial `danger-full-access`/`never` combination.
8. Surface changed files, artifact paths, Quick Look previews, and the final result. Do not speak verbose logs; speak only a concise completion summary.

### P2: agent and notch UX

1. Replace the large menu dropdown as the primary surface with a notch/top-center shell, while retaining a menu-bar fallback for Macs without a useful notch layout.
2. Collapsed state: show only the current phase, waveform/typing/thinking animation, connected tool mark, or completion pulse.
3. Expanded state: Home, Agents, History/Threads, and Settings. The Agents view must show concurrent running tasks, recently completed threads, live activity, artifacts, and follow-up.
4. Support typed prompts, file/image drag-and-drop, attachment chips, suggested follow-ups, copy, dismiss, stop, and hide-with-undo.
5. Preserve the companion's personality through cursor-to-notch launch flights, restrained sound design, and short spoken completion summaries.

The proposed layout must be approved in text before implementation, per repository instructions.

### P2: screen-aware dictation and spatial context

1. Capture the active display, focused app, focused field, surrounding text, and user request.
2. Generate text specifically for the destination rather than returning a general answer: email reply, terminal follow-up, slide copy, form field, or note.
3. Let the user draw a short hover/circle trace while holding the hotkey. Normalize the trace against the captured display and attach both screenshot and coordinates to the request.
4. Add the output grammar `POINT`, `HIGHLIGHT`, and `SHAPE` with line, arrow, circle, curve, and polygon.
5. Add interactive `TARGET`/`HOVER` walkthrough steps only after static annotation is reliable. Each step must observe user action, recapture, and avoid repeating a completed target.

### P3: realtime voice

1. Add `gpt-realtime-2.1` as the duplex conversation/router lane behind an explicit API-key configuration.
2. Implement server VAD, push-to-talk and always-on modes, barge-in, assistant audio truncation, route-change recovery, and headphone guidance where echo cancellation is insufficient.
3. Expose a small voice picker and warm-session management.
4. Give Realtime tools only the narrow authority to answer, spawn a Codex thread, steer the owning thread, report status, or stop work. Codex remains the durable tool-execution authority.

### P3: memory and skills

1. Start with local user memory stored in Application Support and explicitly injected into companion/agent prompts.
2. Add active skills as files that shape task behavior. Begin with repository work, research report, artifacts, build preview, documents, PDFs, and spreadsheets.
3. Keep skill names as implementation details; route from user intent.
4. Do not build a skill marketplace or remote skill-generation backend until the local contract and lifecycle are stable.

### Deferred

Google Workspace, Notion, Linear, Slack, Spotify, and other integrations are not required for the first parity milestone. Also deferred are proactive activity monitoring, remote scheduled tasks, billing/paywall, commercial auth, computer-use automation, and Windows support. The agent contract in v1.0.38 explicitly says remote tasks are not shipped even though gated binary surfaces exist, so they are not a parity blocker.

## Target architecture for this fork

```text
ClickyApp / AppDelegate
|
+-- CompanionManager (@MainActor presentation coordinator)
|   +-- VoiceInteractionRouter
|   +-- ScreenContextProvider
|   +-- OverlayWindowManager
|   `-- NotchWindowManager
|
+-- DictationController
|   +-- AudioCaptureSession
|   +-- OpenAIStreamingTranscriber
|   +-- AppleSpeechFallback
|   +-- FocusContextCapture
|   `-- TextInsertionService
|
+-- AgentSessionManager (@MainActor observable state)
|   +-- CodexRuntimeLocator
|   +-- CodexAppServerProcess
|   +-- CodexProtocolClient
|   +-- CodexEventReducer
|   +-- AgentThreadStore
|   `-- ApprovalCoordinator
|
+-- ScreenAnnotationManager
|   +-- UserTraceCapture
|   +-- AnnotationProtocolParser
|   `-- PerDisplayAnnotationOverlay
|
`-- Local stores
    +-- UserDefaults: lightweight preferences and shortcuts
    +-- Application Support: thread mapping, memory, skills, corrections
    `-- Codex state: existing user CODEX_HOME for subscription-backed MVP
```

`CompanionManager` should remain the main-actor presentation coordinator, but it should no longer own protocol parsing, process lifecycle, audio transport, and all business state. This is a separation by independently testable responsibility, not a broad rewrite.

## Implementation approaches

### Approach A: staged evolution of this fork (recommended)

Keep the current app target and reuse its dictation, screen-capture, overlay, permission, and shortcut code. Add app-server as isolated Foundation components, then replace the menu panel with the notch shell after the agent state is real.

This is the lowest-risk path, preserves the parts already working on this Mac, and supports small reviewable PRs. The main tradeoff is a temporary mixed UX while the old panel and new agent surfaces coexist.

### Approach B: architecture-first backport

Reshape the repo immediately around the module boundaries visible in current HeyClicky: split `CompanionManager`, add notch views, introduce all state models, then wire behavior into the new structure.

This reaches a cleaner end-state sooner, but it creates a large refactor before app-server and dictation have proven integration tests. Review and regression risk are materially higher.

### Approach C: new target beside the legacy app

Create a second macOS target implementing the new shell and migrate reusable files selectively.

This provides the cleanest architecture and makes A/B comparison possible, but duplicates signing, entitlements, assets, permissions, release configuration, and app lifecycle. It is the slowest route to a reliable daily-use build.

Approach A is recommended.

## PR and turn plan

The refined estimate is 20-28 autonomous goal turns across nine reviewable PRs. A turn is one meaningful implementation/verification/review-follow-up cycle, not every shell command. The original seven-PR outline was split after the app-server investigation exposed two independently valuable seams: safe thread control before presentation state, and Realtime transport before focused-field insertion. Review latency and unexpected TCC/runtime behavior can increase the total.

```text
PR 1  Baseline safety, privacy, parity document, test seam             1-2 turns
PR 2  Codex runtime + JSONL app-server client                          2-3 turns
PR 3  Safe durable agent threads and turn controls                     2-3 turns
PR 4  Concurrent task/event/approval reducer                           2-3 turns
PR 5  OpenAI Realtime dictation transport + ephemeral secrets         2-3 turns
PR 6  Fast shortcut, focus capture, insertion, latency instrumentation 2-3 turns
PR 7  Screen-aware dictation + user/model annotation grammar          2-3 turns
PR 8  Agent HUD/history/attachments/artifacts/notch UX                 3-4 turns
PR 9  Realtime voice router + local memory/skills                      3-4 turns
```

As of July 16, 2026, PRs 1-10 and 12 are merged into `main`. They establish the clean-room research baseline, subscription-backed Codex process protocol, safe workspace-scoped durable threads, concurrent task state and line-based HUD, OpenAI Realtime transcription with Worker-minted ephemeral credentials, safe focused-field fast dictation, screen-aware composition, explicit and automatic spoken routing, and reviewed static spatial annotations. PR 13 is the active final implementation slice for app-server-first companion vision/composition, concise attention delivery, cursor-trace grounding, and one-step TARGET/HOVER walkthroughs. Its Foundation suite passes with 124 XCTest cases, 3 opt-in live skips, and 34 Swift Testing cases. Both dictation modes, spoken routing, and the live spatial paths still need the Xcode-run acceptance matrix before release.

Each PR should be developed in an isolated worktree, verified independently, opened as draft, and watched for both review comments and CI. Actionable feedback should be pulled, fixed, and re-verified until checks are green. Nothing should be merged without explicit user instruction.

## Verification strategy

Terminal `xcodebuild` is prohibited by this repository because it invalidates TCC permissions. Verification therefore has three layers.

First, JSON framing, request correlation, event reduction, state transitions, interruption, persistence, focus validation, annotation parsing, and coordinate transforms should be implemented as Foundation-only units with deterministic fixtures. These tests must not require microphone, Accessibility, screen recording, or a running UI.

Second, app-server contract tests should launch a local Codex child process against a temporary working directory using `read-only` or `workspace-write`, initialize it, start and interrupt a harmless turn, and assert streamed lifecycle events. The installed Codex on this Mac is currently authenticated through ChatGPT, so subscription-backed local testing is available.

Third, Xcode GUI/manual acceptance runs must verify the real macOS surfaces: global shortcuts while another app is focused, microphone start/stop, focused-field insertion and replacement, stale-field refusal, ScreenCaptureKit exclusion, relevant-display selection, multi-display overlays, notch expansion, concurrent agent status, approval prompts, interruption, relaunch/resume, and spoken completion. Xcode-driven verification must preserve the user's TCC grants.

Before the first PR, the repository needs at least one CI lane for non-TCC protocol/state tests. Full signed macOS UI automation is not a prerequisite for each PR, but every UI-bearing PR needs a documented manual acceptance recording or screenshot set.

## Security and privacy decisions

The inspected commercial app's full-access defaults should not be copied. A consumer agent that can execute commands and edit files needs visible scope, interruption, and approval behavior even if the user can opt into broader autonomy.

The fork should default to an explicit Agent Folder, `workspace-write`, and `on-request`. It should show the exact command, working directory, and file changes when Codex requests approval. Full-disk or protected-folder access should remain a deliberate macOS permission event. Agent logs, prompts, transcripts, code, filenames, screenshots, and command output should remain local unless needed for the selected model call, and analytics should carry only coarse operational metadata. Paid Worker routes must require an access token held in the Keychain and a Worker secret, plus route-specific Cloudflare rate limits. This is suitable for a self-hosted install; a distributed multi-user release still needs an authenticated backend that issues short-lived per-user or per-install sessions.

The raw Anthropic credential currently present in local `HEAD` must be revoked even though `origin/main` already contains a removal commit. Deleting it from the current file does not invalidate copies in Git history.

## Source ledger

Primary product sources:

- [Original cursor tutor, April 7](https://x.com/FarzaTV/status/2041314633978659092)
- [Product livestream, April 23](https://x.com/FarzaTV/status/2047389920474644732)
- [Voice agents, April 26](https://x.com/FarzaTV/status/2048203459976188261)
- [v1.0.12, memory/text insertion/computer use, May 5](https://x.com/FarzaTV/status/2051454940326097220)
- [Notch and proactive agents, May 16](https://x.com/FarzaTV/status/2055774393243230387)
- [Always-on voice, May 30](https://x.com/FarzaTV/status/2060865350036750847)
- [Screen drawing/teaching, June 16](https://x.com/FarzaTV/status/2066983088035656086)
- [Spatial context, July 8](https://x.com/FarzaTV/status/2074973272463310905)
- [Screen-aware dictation, July 14](https://x.com/FarzaTV/status/2077130366230639022)
- [Open-source repository](https://github.com/farzaa/clicky)
- [Official v1.0.38 release](https://github.com/farzaa/clicky-releases/releases/tag/v1.0.38)
- [Sparkle appcast](https://github.com/farzaa/clicky-releases/blob/main/appcast.xml)
- [HeyClicky homepage](https://www.heyclicky.com/)
- [Privacy policy](https://www.heyclicky.com/privacy)

OpenAI architecture sources:

- [Codex app-server](https://learn.chatgpt.com/docs/app-server.md)
- [Codex authentication](https://learn.chatgpt.com/docs/auth.md)
- [Codex open-source app-server implementation](https://github.com/openai/codex/tree/main/codex-rs/app-server)
- [GPT-Realtime models](https://developers.openai.com/api/docs/models/all)
- [GPT-4o Transcribe](https://developers.openai.com/api/docs/models/gpt-4o-transcribe)
- [GPT-Realtime-Whisper](https://developers.openai.com/api/docs/models/gpt-realtime-whisper)
- [Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [Latest-model selection guide](https://developers.openai.com/api/docs/guides/latest-model)
- [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [Images and vision inputs](https://developers.openai.com/api/docs/guides/images-vision)
- [Responses text generation](https://developers.openai.com/api/docs/guides/text)
- [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data)
- [Cloudflare Workers rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)

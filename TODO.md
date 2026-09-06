# TODO — Future Work

Read [AGENTS.md](AGENTS.md), [USER_STORIES.md](USER_STORIES.md), and [README.md](README.md) before accepting an implementation task. This file owns outstanding work, user decisions, and task boundaries. AGENTS owns working policy; README owns current architecture and operating instructions; USER_STORIES owns product behavior.

This plan replaces the former phase sequence and phase-closure fences. Dependencies below govern execution. A recorded finding is not permission to combine unrelated changes or redesign the app. Accept a bounded assignment, re-read its code, and implement one independent change per commit. Expand a compact backlog entry into a full boundary before implementing it.

## Maintaining this plan

This section owns how TODO is updated. General working principles belong in AGENTS; the review skill owns the review procedure. Keep this file focused on decisions and work that still matter.

1. Give each finding a stable ID, severity, evidence status, relevant paths, expected outcome, validation criteria, and dependencies. Keep hypotheses distinguishable from validated defects; preserve reviewer classifications and record user dispositions. Do not recycle IDs.
2. Keep unassigned work compact. Before implementation, expand the assigned task into a full boundary: intent, dependencies, implementation direction, non-goals, validation, and done criteria. Link that boundary from the finding instead of duplicating it.
3. Record accepted decisions with their rationale and affected tasks. Keep unresolved choices explicit. When a decision changes, record its supersession and update affected boundaries and dependencies before the implementation commit.
4. Use explicit dependencies and readiness to guide execution. Do not rebuild phase-closure fences or imply that every non-blocking issue must land before unrelated work can proceed.
5. In each implementation commit, remove the completed task's full active entry and execution boundary. Update references, dependencies, legacy mappings, and any affected counts or indexes. Keep at most a concise disposition or governing-document/commit link needed for remaining work or traceability. Put implementation history in the commit and current operations in README.
6. Record deferral or acceptance without change explicitly, with the reason and any revisit trigger. Do not silently drop inherited work or treat a documentation rewrite as an implementation fix.
7. Keep evidence tied to its revision and provenance. Remove obsolete status inventories; historical review results do not certify an executor's current gates. Check local links and ID/dependency consistency after restructuring this file.

## Evidence provenance

The findings come from the 2026-09-06 full-project review of cf39ce5a9777a9acf150bab0a4b93dade6798d4e, using Xcode 26.6 (17F113) and SwiftLint 0.65.1. Commands and bounded scratch probes are recorded in that review conversation; scratch artifacts were removed. Probe descriptions below are reproduction recipes, not checked-in tests or reusable gate certificates. Revalidate affected claims and remedies against the execution revision.

The review did not exercise live providers, physical device switching, macOS 13, or Thread Sanitizer. Device-change evidence used an owned engine and a simulated notification. The inherited Task 42 whole-suite mutant result was not rerun. N5 records the relevant toolchain warnings.

**Validated** means source inspection and/or the stated review probe supported the finding. **Not independently validated** identifies inherited evidence still needing verification. Architectural benefits are design judgments, even when the underlying structure is validated.

## Decisions and constraints

### Accepted user decisions — 2026-09-06

| ID | Decision | Applies to |
|---|---|---|
| D1 | Introduce one speech-session coordinator incrementally before fixing underruns. It owns start/cancel, the selected audio format, and ordered completion. | NB19, B2, NB9 |
| D2 | Applying a changed live PCM format clears the buffer and cancels its paired network request. Do not defer the change until the next session. | NB9 |
| D3 | Discard a trailing partial PCM byte silently when complete frames exist. Empty and single-byte responses still fail. | NB2 |
| D4 | OpenAI-compatible endpoints may omit Content-Type or use a generic type; reject explicitly unsupported formats. Validate Gemini's native PCM declaration. | NB1 |
| D5 | Refuse cross-origin credential-bearing redirects. Preserve credentials deliberately only on permitted same-origin redirects, subject to the transport rule. | NB4 |
| D6 | Use an explicit ephemeral policy with no persistent cache, shared cookie store, or credential store. | NB5 |
| D7 | Expand the 85% aggregate coverage gate to application logic outside Managers, with narrow documented platform UI/integration exceptions. | NB16 |
| D8 | Remove the unused clipboard-presence console messages. | NB24 |
| D9 | Keep AGENTS concise and principle-based, the review skill procedural, and TODO focused on future work with its own maintenance rules. This separates stable working policy from review operations and evolving plans. | Documentation ownership |

These choices do not need to be asked again. Validate exact implementation details against the repository and version-appropriate APIs. Raise a newly discovered material trade-off before changing the boundary; do not reinterpret an accepted decision silently.

### Constraints that remain in force

- Preserve USER_STORIES: the fixed menu icon, Settings-only voice selection, two-click Clear Buffer/Speak behavior, and the clipboard-only OpenAI input-length refusal.
- Preserve README's immutable request snapshots, ordered generation-authorized callbacks, synchronous cancellation authority, and single bounded Gemini HTTP 500 retry. Completion cannot overtake accepted PCM; published isStreaming is not an end-of-stream signal.
- Preserve the 0.1-second initial prebuffer, 0.2-second deferred clipboard policy, exact-end seek/replay, and finite Custom sample rates from 8000 through 48000, including fractions.
- Tests state settings through storage they own (`makeOwnedDefaults`), never the developer's preferences. Do not reintroduce snapshot/clear/restore of the app's own domain, and do not seed real preferences to prove that tests avoid them; a scratch checkout alone does not isolate macOS preferences.

### Investigation gates

NB6 must establish a defensible event-size bound from provider evidence before choosing a limit. NB20/NB21 must inventory unique behavior before proposing removals. NB25 must revalidate its metadata test gap. These investigations can expose new decisions; they do not authorize guessing compatibility limits or removing coverage.

## Active backlog

Finding IDs preserve the full-project review's numbering. NB22 is completed by this documentation change and appears under dispositions. NB25 preserves inherited Task 42. Severity and readiness are separate: needing a decision does not make a defect non-blocking.

### Blocking

#### B2 — Streaming underrun permanently pauses playback

**Validated — audio probe; legacy Task 52, promoted to Blocking.** The timer pauses at the received buffer end, and one-shot automatic playback never resumes later PCM. A 0.3-second buffer grew to 0.6 seconds while playback stayed paused at 0.3. **Paths:** [AudioPlayerManager](Sources/Managers/AudioPlayerManager.swift), [network completion](Sources/Managers/TTSNetworkManager+Failures.swift), focused audio/network tests. **Depends on:** NB19's ordered terminal-event interface (D1). **Acceptance:** distinguish open-stream underrun, manual pause, and finished playback. Later PCM resumes only underrun, at the current position, without replay or another prebuffer. Completion follows accepted PCM; stale terminal events cannot affect a replacement. Inject deterministic render-progress input and cover manual pause, genuine end, delayed final PCM, and cancellation. Document the state transitions.

#### B3 — Pending automatic playback overrides Pause

**Validated — controllable-prebuffer probe.** Play then Pause before the automatic callback runs leaves it authorized; releasing it sets isPlaying back to true. **Paths:** [AudioPlayerManager](Sources/Managers/AudioPlayerManager.swift), [automatic playback tests](Tests/AudioPlayerManagerAutomaticPlaybackTests.swift). **Boundary/acceptance:** [B3 execution boundary](#b3-execution-boundary). **Readiness:** independent local fix.

#### B4 — A queued progress tick applies old render time after seeking

**Validated — original timer-body probe with scratch-only access to fire it.** A pre-seek tick later advanced a seek from 1.8 to 2.0 seconds and paused a two-second buffer. **Paths:** [AudioPlayerManager](Sources/Managers/AudioPlayerManager.swift), [audio tests](Tests/AudioPlayerManagerTests.swift). **Boundary/acceptance:** [B4 execution boundary](#b4-execution-boundary). **Readiness:** independent local fix; preserve B2's separate state-machine boundary.

### Non-blocking

#### NB1 — Declared non-audio success responses reach the PCM player

**Validated — delegate probes; legacy Task 44.** HTTP 200 application/json containing two bytes was delivered as PCM without failure; Gemini accepted an application/pdf inline payload. **Paths:** [response delegate](Sources/Managers/TTSNetworkManager.swift), [Gemini decoder](Sources/Managers/TTSNetworkManager+GeminiStreaming.swift), failure/streaming tests. **Direction:** implement D4; verify exact accepted MIME types and format parameters against official provider documentation. **Acceptance:** unsupported declarations never reach the player; valid PCM and agreed OpenAI-compatible missing/generic headers still work. Keep errors sanitized, preserve callback ordering, and coordinate NB2/NB3 without combining independent fixes.

#### NB2 — A trailing partial PCM byte causes a false no-audio failure

**Validated — both transport probes; legacy Task 38, revised to Non-blocking.** Complete frames survive; the even-length completion predicate misreports that no playable audio arrived. **Paths:** [failure classifier](Sources/Managers/TTSNetworkManager+Failures.swift), [AudioPlayerManager](Sources/Managers/AudioPlayerManager.swift), failure/streaming tests, README. **Direction:** implement D3; never drop complete frames to satisfy the stricter predicate. **Acceptance:** network and player agree for empty, one-byte, odd, and even responses. Preserve HTTP, transport, malformed-event, redirect, and explicitly declared Gemini truncation precedence.

#### NB3 — Gemini ignores additional audio parts in one event

**Validated — multipart probe.** Parts [0,1] and [2,3] delivered only [0,1] without failure; a malformed second part was ignored. **Paths:** [Gemini decoder](Sources/Managers/TTSNetworkManager+GeminiStreaming.swift), [streaming tests](Tests/TTSNetworkManagerGeminiStreamingTests.swift). **Direction:** inspect all relevant parts of the selected candidate in order; preserve candidate selection and metadata behavior. **Acceptance:** valid parts contribute ordered PCM, fragments join correctly, malformed later parts cannot silently succeed, and fatal-event revocation remains. **Reference:** [Google Content schema](https://ai.google.dev/api/generate-content#Content).

#### NB4 — Redirect handling does not enforce credential origin

**Validated — current-toolchain loopback probe; legacy Task 40.** x-goog-api-key followed a cross-origin redirect; Authorization disappeared on a same-origin redirect. **Paths:** [redirect delegate](Sources/Managers/TTSNetworkManager.swift), [transport policy](Sources/Managers/EndpointTransportPolicy.swift), [endpoint tests](Tests/TTSNetworkManagerEndpointTransportTests.swift), README. **Direction:** D5; compare normalized scheme, host, and effective port with the request-owned origin. Restore only the appropriate request-owned credential on permitted same-origin redirects. **Acceptance:** test both header shapes and speech/discovery. Cross-origin refusal forwards neither key nor text; same-origin authentication works. Retain transport refusal precedence, sanitized errors, request snapshots, retry identity, and cancellation.

#### NB5 — Session persistence differs between production and tests

**Validated — configuration inspection; legacy Task 45.** Production uses default configuration; the test factory uses ephemeral. This identifies an untested policy, not proof a response was cached. **Paths:** [network initialization](Sources/Managers/TTSNetworkManager.swift), [test factory](Tests/TestNetworkSupport.swift), network tests, README. **Direction:** implement D6 through one explicit production policy, tested before mock routing. **Acceptance:** no persistent cache or shared cookie/credential store; inspect effective configuration and a mocked request while retaining test routing/teardown. Ephemeral does not itself imply no in-memory caching; document the exact selected configuration.

#### NB6 — SSE parsing rescans unbounded unfinished input

**Validated — source and bounded probes.** Each packet rescans the accumulated unfinished line; there is no event-size bound, and parsing holds request-state ownership. **Paths:** [GeminiSSEEventParser](Sources/Managers/TTSNetworkManager+GeminiStreaming.swift), parser/streaming tests. **Direction:** maintain incremental scan position and establish an evidence-backed maximum unfinished event size. Record its compatibility rationale; raise material trade-offs before selecting a cap. **Acceptance:** fragmented LF/CRLF and multiline events work; retained prefixes are not repeatedly rescanned; oversized incomplete input fails safely. Verify work/buffer bounds and valid near-boundary events rather than machine-speed assertions.

#### NB7 — Provider dispatch still infers identity from endpoints

**Validated — source; legacy Task 55.** Speech and model discovery inspect endpoint substrings; voice selection uses a provider string; updateSettings accepts arbitrary identities. **Paths:** [network settings](Sources/Managers/TTSNetworkManager.swift), [metadata](Sources/Managers/TTSNetworkManager+Metadata.swift), authentication/provider tests, README. **Direction:** use one canonical typed identity across configuration, snapshots, and metadata; reuse APIKeyProvider normalization, with unknown values falling back to OpenAI. **Acceptance:** Custom hosts containing Google's hostname remain OpenAI-compatible for speech and discovery; canonical Gemini stays native; malformed direct identities normalize safely. Preserve freshness guards/request shapes and correct README's premature no-inference claim.

#### NB8 — Reentrant cancellation is overwritten by outer publication

**Validated — synchronous observer probes.** Stop during isStreaming publication removed the task but left isStreaming true; a failure-publication observer similarly left an old error after Stop. An equivalent ordinary production sink was not demonstrated. **Paths:** [publication helpers](Sources/Managers/TTSNetworkManager.swift), [lifecycle](Sources/Managers/TTSNetworkManager+RequestLifecycle.swift), lifecycle/concurrency tests. **Direction:** make publication transitions coherent under reentrant cancellation as well as starts. **Acceptance:** state describes the surviving generation after observer stop/replacement; exercise isStreaming, lastError, objectWillChange, and nested lifecycle order without weakening synchronous callback revocation.

#### NB9 — Live format changes revoke audio without cancelling its request

**Validated — Settings-to-player trace.** Custom 48 kHz to fixed 24 kHz clears the audio generation while the old request continues delivering PCM that is dropped. **Paths:** [Settings synchronization](Sources/Views/SettingsView.swift), [audio format application](Sources/Managers/AudioPlayerManager.swift), integration tests. **Depends on:** NB19. **Direction:** implement D2 through the shared owner. **Acceptance:** a changed format cancels the paired request and clears audio together; stale PCM is refused. An unchanged format does not cancel playback. Invalid drafts do not replace saved good values; graph failure/retry behavior remains explicit.

#### NB10 — Opening Settings rounds and persists a fractional rate

**Validated — hosted form probe with owned defaults/inert managers.** Mounting Settings changed 24000.4 to 24000.0 via integer formatting followed by synchronization. **Paths:** [SettingsView](Sources/Views/SettingsView.swift), settings tests, README. **Direction/acceptance:** round-trip valid finite fractional rates exactly; mounting/reopening changes neither precision nor graph rate. Invalid values still block new speech, and corrected drafts persist only after successful application.

#### NB11 — Engine interruption and recovery leave inconsistent state

**Validated — owned-engine probes; physical switching untested.** Simulated configuration change left readiness false without guidance. Failed play followed by successful retry left the engine running/isPlaying true but readiness false and the old error visible. **Paths:** [AudioPlayerManager](Sources/Managers/AudioPlayerManager.swift), audio tests, README. **Direction:** centralize consistent start/recovery state updates; handle configuration notifications through the main-thread owner. Split interruption handling and stale-error recovery if independent. **Acceptance:** successful starts reconcile readiness/errors, failures stay actionable, and an explicit configuration-change recovery policy preserves manual pause/generation ownership. Add safe notification tests and record a physical-device smoke test. **Reference:** [Apple engine configuration changes](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).

#### NB12 — Startup rereads a key migration already secured

**Validated — scripted-store probe.** Migration saved the key and removed plaintext; a second-read failure left the startup credential empty because securedSecrets was discarded. **Paths:** [APIKeyStartupState](Sources/SecretStore.swift), secret/startup tests, README. **Direction/acceptance:** consume the selected provider's secured value directly; read only when the outcome lacks it. A successful migration remains usable if another read would fail. Preserve Keychain-over-legacy precedence, pending-provider guidance, and non-migration reads.

#### NB13 — Existing saved-key read failures have no explicit retry

**Validated — secret-state probe.** Restored store availability without a legacy key left the form credential empty; migration retry performed no reread. **Paths:** [SettingsSecretState](Sources/Views/SettingsSecretState.swift), [SettingsView](Sources/Views/SettingsView.swift), secret/hosted recovery tests. **Direction:** provide user-triggered retry for unreadable saved keys and update future-request credentials after recovery. Define the UI boundary first; automatic reload must not overwrite edits. **Acceptance:** no key re-entry/relaunch needed; retry unresolved reads, clear only relevant guidance, and preserve newer edits and speech errors.

#### NB14 — One Settings edit duplicates synchronization and discovery

**Validated — hosted field probe and call trace.** TextField and Picker observe the same binding; one edit produced two sync callbacks. Every sync also fetches model metadata. **Paths:** [ModelVoiceConfigurationView](Sources/Views/ModelVoiceConfigurationView.swift), [SettingsView](Sources/Views/SettingsView.swift), settings/metadata tests. **Direction:** observe each binding once; separate configuration application, static voice selection, and model discovery. **Acceptance:** one edit applies once; voice-only changes do not refetch models; provider/endpoint/relevant credential changes still refresh. Preserve off-catalog selections. Coordinate with NB20; duplicate-observer removal can be a separate commit.

#### NB15 — Coverage passes when its measured manager population is absent

**Validated — synthetic report probe.** An app target with no files passed as Managers 100%, 0/0. **Paths:** [check-coverage.sh](check-coverage.sh), bounded script-verification fixtures if needed. **Direction:** fail closed on missing gated coverage or zero executable lines, independently of NB16. **Acceptance:** missing target, empty/missing gated files, zero executable lines, and insufficient coverage fail; a valid measured report passes. Explain deliberately zero-line non-gated files.

#### NB16 — Coverage exemptions follow directories rather than logic

**Validated — gate/source inspection.** SettingsSecretState is exempt under Views; migration/startup logic falls under Other. Declarative-body rationale does not explain those exclusions. **Paths:** [check-coverage.sh](check-coverage.sh), affected source/tests, AGENTS, README. **Direction:** implement D7 after inventorying logic and genuine platform adapters. The script owns the executable threshold and inclusion/exclusion policy. **Acceptance:** 85% aggregate application-logic coverage is enforced regardless of folder; moving a logic file cannot evade it. Narrow exclusions have rationales and end-to-end smoke strategies. Reconcile docs with actual measurement and preserve NB15's fail-closed property.

#### NB17 — Test teardown does not own every queued audio action

**Validated — ownership trace.** Fixed waits remain in Services/audio/metadata tests. Draining a network delivery queue does not drain the player buffer queue, publications, or pending automatic start. This is a missing guarantee, not a claim the baseline observed an escaping callback. **Paths:** [Services tests](Tests/ServicesCoordinatorTests.swift), [audio tests](Tests/AudioPlayerManagerTests.swift), [test factory](Tests/TestNetworkSupport.swift), [audio owner](Sources/Managers/AudioPlayerManager.swift), metadata tests. **Direction/acceptance:** test-owned audio lifecycle, explicit processing/publication completion, cancelled scheduled work, unconditional teardown, and locally counted late work. Forced delayed callbacks cannot escape even after assertion timeouts. Preserve network scope accounting.

#### NB18 — Pure tests inherit heavyweight integration dependencies

**Validated — construction trace.** Secret/state tests inherit the global network lifecycle; an About test creates audio/network managers solely to forward metadata. **Paths:** [SecretStoreTests](Tests/SecretStoreTests.swift), [SettingsSecretStateTests](Tests/SettingsSecretStateTests.swift), [SettingsAboutTests](Tests/SettingsAboutTests.swift), test support. **Direction/acceptance:** test pure units with owned memory dependencies and no audio/session resources; retain a small hosted wiring suite. Meaningful mutants must still detect protected behavior. Improved preferences ownership alone does not justify removing shared asynchronous safeguards.

#### NB19 — Speech-session orchestration is duplicated across entry points

**Validated — architectural observation; D1 accepted.** Menu, Services, and Test Voice each coordinate cancellation, player reset, generation capture, and forwarding. **Paths:** [MenuBarView](Sources/Views/MenuBarView.swift), [ServicesCoordinator](Sources/Managers/ServicesCoordinator.swift), [SettingsView](Sources/Views/SettingsView.swift), startup, network/audio managers and tests. **Boundary/acceptance:** [NB19 execution boundary](#nb19-execution-boundary). **Order:** establish the shared owner/interface before the independent B2 and NB9 behavior fixes.

#### NB20 — Network responsibilities remain coupled across extensions

**Validated — architectural observation.** Loading configuration, migration, transport, decoding, retry, metadata, and UI publication share one mutable manager surface. **Paths:** [TTSNetworkManager](Sources/Managers/TTSNetworkManager.swift), its extensions, [SecretStore](Sources/SecretStore.swift), startup/settings code and tests. **Direction:** investigate pure provider catalogs/codecs and resolved configuration supplied outside transport. Prefer focused extraction over a framework or blanket actor rewrite. **Acceptance:** each extraction reduces shared state and owns a real responsibility; preserve snapshots, failure copy/precedence, callback authority, retry, and freshness. Static catalogs may become synchronous if stale-provider protection moves with them. Define independent boundaries against the final NB7/NB14/NB19 state; account for NB25's properties before removing guards.

#### NB21 — Production layers accommodate windowless test-harness limitations

**Validated — architectural observation.** SettingsActionButton exposes AppKit controls to the host; About uses three protocols plus metadata/routing adapters for a small operation. **Paths:** [SettingsActionButton](Sources/Views/SettingsActionButton.swift), [AboutAction](Sources/AboutAction.swift), [HostedSettings](Tests/HostedSettings.swift), related tests. **Direction:** assess command-level tests plus a small wiring suite before removing wrappers. **Acceptance:** preserve appearance, actionable controls, accessibility, metadata fallbacks, license credits/link, and main-thread presentation. Give unique behavior a replacement owner first. A new UI-test target or changed interaction needs its own agreed boundary; do not delete coverage merely to simplify the production tree.

#### NB24 — Clipboard-presence console messages have no release purpose

**Validated — print calls; legacy Task 46.** They disclose clipboard presence, not copied text. **Paths:** [TextExtractionManager](Sources/Managers/TextExtractionManager.swift), [text tests](Tests/TextExtractionManagerTests.swift), README if a diagnostic description changes. **Direction/acceptance:** implement D8 by removing the prints. Preserve populated/empty injected clipboard returns; introduce no new error or alternative logging; never use the shared pasteboard.

#### NB25 — Provider-only metadata invalidation needs current falsification evidence

**Not independently validated — inherited Task 42 mutation claim.** The check still compares endpoint and provider. OpenAI and Custom can share a default endpoint; provider-only invalidation remains meaningful. The prior whole-suite surviving mutant is historical. **Paths:** [updateSettings](Sources/Managers/TTSNetworkManager.swift), [metadata source tests](Tests/TTSNetworkManagerMetadataSourceTests.swift), README. **Direction/acceptance:** verify pending model cancellation and prompt list clearing on a provider-only switch; independently falsify provider change, endpoint change, and needless invalidation when neither changes. Do not remove the guard because an old mutant survived. If NB20 supersedes a property, identify its replacement owner and retained coverage.

### Nits

#### N1 — Confinement documentation has the wrong rule count

**Validated — source.** [TTSNetworkManager](Sources/Managers/TTSNetworkManager.swift) says three rules and lists four. Correct or omit the count, preserving the rules. Documentation-only scope.

#### N2 — Lint configuration explains an obsolete inline request builder

**Validated — source.** [.swiftlint.yml](.swiftlint.yml) justifies function length using body construction that moved out of streamTTS. Correct the comment without changing lint behavior. A threshold change needs a separate configuration boundary.

#### N3 — Provider-change forwarding has an unused parameter

**Validated — source.** [SettingsView](Sources/Views/SettingsView.swift) forwards providerDidChange to syncSettings without using the value. Remove the argument or forwarding layer while preserving notification/synchronization behavior. Coordinate with NB14 to avoid redundant edits.

#### N4 — Metadata test names describe operations rather than behavior

**Validated — source.** [Metadata provider tests](Tests/TTSNetworkManagerMetadataProviderTests.swift) use names such as testFetchAvailableModels. Name the expected provider/catalog behavior; retain assertions and test discovery.

#### N5 — Test deployment and toolchain warnings need explicit treatment

**Validated — review output.** [project.yml](project.yml) targets macOS 13 for tests while this Xcode's XCTest libraries reported macOS 14; destination ambiguity and AppIntents messages occurred. Reconcile the runner minimum with the toolchain, preserving the app's macOS 13 requirement. **Acceptance:** regenerate and inspect a clean build/test run and effective deployment settings. Choose an explicit destination where useful; explain benign metadata output. Do not raise the app minimum or suppress source warnings merely to silence tooling.

## Ready for implementation

These initial full boundaries are referenced from the backlog rather than duplicated there. Suggested order: local B3/B4 fixes; NB19; B2 and NB9; response/credential work; settings/catalog simplification. This is priority guidance, not a phase fence. Every change needs its assigned scope.

### B3 execution boundary

**Intent:** Pause revokes the pending automatic start for its stream. **Dependencies:** none. **Implementation:** inspect automaticPlaybackSuppressedGeneration and make Pause's intent survive prebuffer delivery using the smallest coherent state change. **Non-goals:** prebuffer duration, underrun/end redesign, loss of explicit Resume, exact-end replay, replacement, or generation guards. **Validation:** queue a controlled start, manually play/pause, release it, and remain paused. Also prove a fresh stream starts, explicit Resume works, and stale generations cannot start. Falsify lost pause intent and over-restriction of legitimate playback. **Done:** callback cannot override Pause; focused regressions, gates, docs, and review pass.

### B4 execution boundary

**Intent:** progress uses render time and seek offset from one coherent main-thread turn. **Dependencies:** none. **Implementation:** enforce the documented main-owned timer contract and remove the asynchronous split between reading render time and applying progress, or establish an equally small coherent update if the affected code has changed. **Non-goals:** new concurrency framework, timer cadence/seek semantics change, or B2 repair. **Validation:** deterministic captured pre-seek tick followed by near-end seek; playback remains at the intended position. Preserve ordinary progress, Pause/Stop, real-end behavior, and timer teardown. Use completion/ownership evidence, not sleeping as a drain. **Done:** stale ticks cannot apply a new offset; regression, gates, docs, and review pass.

### NB19 execution boundary

**Intent:** implement D1's shared owner and the ordered terminal interface B2 needs, preserving entry-point product policy. **Dependencies:** build on the landed B1 test-ownership contract and re-read final B3/B4 code if landed; introduce the owner before B2.

**Implementation:**

1. Document a small main-owned coordinator API and session ownership model before coding. It coordinates start/cancel, format, audio generation, and delivery; it does not own catalogs, persistence, clipboard reads, or modal presentation.
2. Route Menu, Services, and Test Voice through it. Keep menu delay/idle revalidation and OpenAI length refusal at the menu boundary; preserve Services/Test Voice replacement behavior.
3. Deliver explicit request-owned terminal events after accepted PCM through the same ordered, revocable handoff. Carry success/failure and session identity; do not infer completion from isStreaming or reread mutable settings.
4. Preserve synchronous cancellation authority, snapshots, callback reentrancy, retry identity, and Services availability from launch. Never invoke clients under the request-state lock.
5. Document ownership/order in README. B2 adds underrun recovery and NB9 paired live-format cancellation as separate behavior changes.

**Non-goals:** general event framework, blanket actor migration, new providers, catalog extraction, or changed two-click menu behavior. Do not merge generations without relocating every unique retry/cancellation/rendering guarantee. **Validation:** all three entries, deferred clipboard races, Clear Buffer, replacement, first-audio ordering, stale completion, and retry. Hold final PCM and prove the terminal event cannot overtake it or affect a replacement. Use owned settings/audio lifecycles. **Done:** one orchestration owner, testable/documented terminal order, preserved entry behavior, and passing gates/review before the independent B2/NB9 changes.

## Deferred, accepted, and completed dispositions

- **B1 — Fixed.** Tests own the settings storage they state; `SettingsView` binds every `@AppStorage` to the domain it is handed, and the mock-network lifecycle no longer snapshots, clears, or restores the app's own domain. Two isolation tests name the domain by identity, but no runtime test observes which domain an ordinary call site was handed, so that guarantee is held by the compiler (no settings API in `Sources` defaults to `.standard`), by `InMemoryDefaults` owning its inherited surface, and by the `process_default_settings_store` and `test_owned_settings_storage` lint rules over the named routes in `Sources` and `Tests`. README owns the current contract. NB17 and NB18 build on this ownership rather than reopening it.
- **Accepted without change — `InMemoryDefaults`' inert domain mutators (2026-09-06).** Registration, named-domain, suite, and volatile-domain mutators succeed while doing nothing, so a future production path invoking one through an injected store would look correct under test while production mutated real state. Accepted because no production path calls them, the behavior is fail-closed for B1's isolation goal, and the lint rule refuses those calls from `Tests/`. **Revisit if** production code ever calls a domain-level `UserDefaults` member through an injected store.
- **NB22 — Completed by this TODO rewrite:** the active backlog/decision register replaces the stale phase handoff. No implementation finding is marked fixed by this documentation change.
- No other implementation finding has been deferred or accepted without change.
- Legacy Tasks 14 and 36 remain withdrawn; [USER_STORIES](USER_STORIES.md) governs the fixed icon and Settings-only voice selection. This plan reinstates neither feature.

### Legacy task mapping

| Old task | Current owner | Disposition |
|---|---|---|
| 38 | NB2 / D3 | Retained; Non-blocking, tolerate trailing partial byte |
| 40 | NB4 / D5 | Retained; same-origin redirects only |
| 42 | NB25 | Retained validation question; historical mutant is not current proof |
| 44 | NB1 / D4 | Retained; supported audio plus compatibility allowance |
| 45 | NB5 / D6 | Retained; explicit ephemeral policy |
| 46 | NB24 / D8 | Retained; remove prints |
| 48 | NB22 | Missing-rationale premise corrected: both audio files explain their exceptions; cohesion policy belongs in AGENTS, not a forced split task |
| 52 | B2 / D1 | Promoted to Blocking; shared owner precedes repair |
| 55 | NB7 | Retained; canonical identity |

## Integration acceptance

Review integrated changes against accepted decisions and current USER_STORIES/README. Do not require every non-blocking task to land first: record explicit defer/accept dispositions and reasons.

Use AGENTS for required gates/review. Supplement integration changes with cross-entry playback, cancellation, provider/format switching, failure/recovery, and settings-isolation checks. Inspect warnings and the complete gated population. Static analysis and, when relevant and supported, Thread Sanitizer provide additional evidence; clean output is not proof of race freedom.

Keep hardware and live-provider smoke tests separate from automated test dependencies. Physical switching and macOS 13 compatibility remain unverified by this baseline. Live-provider tests need explicit authorization and credentials; record no keys, copied text, or returned audio. Record evidence at its actual revision. Remove completed full entries in their implementation commits, retaining only concise dispositions/links needed by remaining work.

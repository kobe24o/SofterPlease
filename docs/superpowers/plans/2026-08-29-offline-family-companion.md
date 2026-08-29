# Offline Family Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mobile server-dependent experience with a local-only
conversation companion that performs speech/emotion/speaker analysis on device
and sends daily advice only to the user's configured model provider.

**Architecture:** Keep model installation and signed update verification, but
replace mobile backend state with local conversation and speaker repositories.
The analyzer returns individual utterances and the local repository assigns or
updates persistent speaker centroids.  Flutter's three-tab shell consumes the
local repository; a direct OpenAI-compatible client is isolated behind the
optional advice action.

**Tech Stack:** Flutter/Dart, sherpa_onnx, SharedPreferences,
FlutterSecureStorage, Dio, record, GitHub Actions Android signing.

**Spec:** `docs/superpowers/specs/2026-08-29-offline-family-companion-design.md`

## Global Constraints

- Android is the first release target and model assets remain CI-downloaded.
- The mobile app must not contain or call SofterPlease backend endpoints.
- Local audio, transcripts, embeddings, corrections, and advice history stay
  on the device.
- A network call is permitted only after explicit daily-advice action using a
  user-owned OpenAI-compatible key.
- The saved key belongs in secure storage and must never be rendered.
- Release version is `2.3.0+15` and tag is `v2.3.0`.

---

### Task 1: Local conversation and speaker domain

**Files:**
- Create: `mobile/flutter_app/lib/local/conversation_models.dart`
- Modify: `mobile/flutter_app/lib/local/local_session_store.dart`
- Create: `mobile/flutter_app/test/local/conversation_models_test.dart`

**Interfaces:**
- Produces `LocalConversation`, `LocalUtterance`, `SpeakerProfile`, and
  `SpeakerMatcher` for analysis and UI.
- `SpeakerMatcher.assign(embedding, profiles)` returns a local speaker match
  at the configured threshold.
- `SpeakerProfile.withSample(embedding, at)` produces a weighted local
  centroid update.

- [ ] Write tests that assert a near centroid is matched, a far centroid is
  unknown, correcting an utterance updates the profile sample count/centroid,
  and JSON round trips preserve transcript and embeddings.
- [ ] Run the local domain test and confirm it fails because the domain types
  do not yet exist.
- [ ] Implement small immutable domain types and JSON/base64 serialization.
- [ ] Extend the local store to save/load conversations and profiles without
  backend fields.
- [ ] Re-run the local domain test and commit the isolated domain change.

### Task 2: Per-utterance local inference

**Files:**
- Modify: `mobile/flutter_app/lib/local/local_speech_analysis.dart`
- Modify: `mobile/flutter_app/test/local/conversation_models_test.dart`

**Interfaces:**
- Consumes `LocalModelPack` and returns `LocalSpeechAnalysis` containing
  `List<AnalyzedUtterance>` rather than only an aggregate summary.
- `AnalyzedUtterance` carries timing, text, emotion, session cluster, and an
  optional Float32 speaker embedding.

- [ ] Write a pure result-conversion test that asserts ordered utterances are
  retained and the summary is derived from them.
- [ ] Run it and confirm it fails against the aggregate-only analyzer result.
- [ ] Add typed utterance output and retain VAD segment timing, ASR emotion,
  and speaker embedding in the result while keeping resource cleanup.
- [ ] Re-run focused tests and commit the analyzer change.

### Task 3: Explicit direct-advice client and settings

**Files:**
- Create: `mobile/flutter_app/lib/local/daily_advice.dart`
- Create: `mobile/flutter_app/test/local/daily_advice_test.dart`

**Interfaces:**
- `DailyAdviceRequest.forDay(day, conversations)` constructs only that day's
  speaker-attributed text.
- `OpenAiCompatibleAdviceClient.generate(request, settings, apiKey)` performs
  `POST /chat/completions` with the supplied provider settings.
- `AdviceSettingsStore` persists base URL/model locally and uses secure storage
  for the key.

- [ ] Write tests for same-day filtering, empty transcript handling, and
  OpenAI-compatible content extraction using a fake Dio adapter.
- [ ] Run tests and observe the expected missing-type failure.
- [ ] Implement request building, response extraction, error messages, and
  settings/key separation.
- [ ] Re-run focused tests and commit the advice subsystem.

### Task 4: Local-first mobile shell and correction UX

**Files:**
- Rewrite: `mobile/flutter_app/lib/main.dart`
- Modify: `mobile/flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes local conversations/profiles, local analyzer, model installer, and
  optional daily-advice client only.
- Produces three tabs labelled `记录`, `对话`, and `家庭`.

- [ ] Write a widget test for the local shell, no-login startup, and all three
  tabs.
- [ ] Run it to verify the old server-oriented shell fails the expected UI
  assertion.
- [ ] Replace backend authentication, family reports, server session calls,
  and remote speaker flows with the compact local-only shell.
- [ ] Add recording, local analysis, conversation detail, correction/create
  speaker sheet, local profile list, direct-advice settings/action, about, and
  update panel.
- [ ] Re-run widget and local tests; commit the local-first mobile UI.

### Task 5: Versioning, CI, and release verification

**Files:**
- Modify: `mobile/flutter_app/pubspec.yaml`
- Modify: `.github/workflows/mobile-build.yml` only if verification reveals a
  missing local model asset or release behavior.

- [ ] Update the version to `2.3.0+15`.
- [ ] Run formatting, static analysis, and the complete Flutter test suite
  with test-only placeholder model assets as needed.
- [ ] Inspect the mobile source to confirm no SofterPlease backend endpoint or
  backend token remains.
- [ ] Commit, push, tag `v2.3.0`, and let GitHub Actions build/sign/release.
- [ ] Verify the Actions conclusion, release APK SHA-256/certificate, bundled
  model entries, and the signed remote update manifest.

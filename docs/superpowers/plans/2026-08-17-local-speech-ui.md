# Local Speech UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for inline implementation task-by-task.

**Goal:** Make the Android client local-first for recording, VAD/ASR-ready analysis, emotion metadata, and speaker identity, leaving only optional family advice as a network feature.

**Architecture:** A small Dart domain layer owns model-pack availability and local speech-result data. `MonitorPage` reads that state and presents a local session workflow; it no longer renders or controls backend model preloading, backend model status, or the server-only monitoring panels. Existing secure LLM advice settings remain a separately labelled optional feature.

**Tech Stack:** Flutter/Dart, `sherpa_onnx`, `record`, `SharedPreferences`, app-private storage.

## Global Constraints

- Android is the first runtime target; new domain classes remain Dart-only and platform-neutral.
- Raw recordings and local results remain in the app-private directory and are never uploaded automatically.
- The application must not claim recognition is complete until a verified model pack is installed.
- Do not add model weights, tokens, credentials, or license-gated files to Git.

---

### Task 1: Persist local analysis status

**Files:**
- Modify: `mobile/flutter_app/lib/local/local_session_store.dart`
- Modify: `mobile/flutter_app/tool/local_session_store_tdd.dart`

- [ ] Extend `LocalSessionSummary` with `analysisState`, `emotionLabel`, and `speakerLabel`, retaining backward-compatible defaults for existing stored JSON.
- [ ] Save and reload a completed local analysis record in the tool regression test.
- [ ] Run `dart tool/local_session_store_tdd.dart` and `dart analyze` for the local directory.

### Task 2: Add a model-pack contract

**Files:**
- Create: `mobile/flutter_app/lib/local/model_pack.dart`
- Create: `mobile/flutter_app/tool/model_pack_tdd.dart`

- [ ] Define `LocalModelPack` with an installed/absent state, model directory and an actionable message.
- [ ] Resolve the pack only when `sensevoice/model.int8.onnx`, `vad/ten-vad.int8.onnx`, and `speaker/model.onnx` are present in the app documents directory.
- [ ] Run the pure-Dart model-pack regression test and analysis.

### Task 3: Simplify the Android UI to local-first

**Files:**
- Modify: `mobile/flutter_app/lib/main.dart`

- [ ] Replace server model status and preload controls with a local-model readiness card.
- [ ] Change the start action to always create a local recording session; keep backend endpoints out of the default recording path.
- [ ] Show saved local sessions with recorded/awaiting-model state and remove backend-only model/segment controls from the primary monitor page.
- [ ] Keep profile About and update checking; label LLM advice as optional and network-based.

### Task 4: Validate and document

**Files:**
- Modify: `mobile/flutter_app/README.md`

- [ ] Document the required locally installed model-pack layout and privacy boundary.
- [ ] Run local tool tests, focused Dart analysis, `git diff --check`, and inspect the final diff.

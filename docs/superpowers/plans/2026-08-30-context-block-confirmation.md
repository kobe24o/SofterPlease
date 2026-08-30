# Context Block Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-utterance confirmation and LLM requests with sentence-safe context blocks, batch speaker confirmation, and one serialized model request per confirmed block.

**Architecture:** Persist `ConversationContextBlock` separately from `LocalSessionSummary`, with ordered utterance IDs and a block-level review. A deterministic builder joins adjacent utterances across recordings in the same recording group, preserving a block while its final text lacks a natural sentence ending. UI selection writes speaker changes for all selected utterances; the queue only picks fully confirmed, closed blocks.

**Tech Stack:** Flutter/Dart, SharedPreferences JSON persistence, sherpa-onnx VAD/ASR outputs, Dio/OpenAI-compatible API, flutter_test.

**Spec:** `docs/superpowers/specs/2026-08-30-context-block-confirmation-design.md`

## Global Constraints

- Keep physical PCM/WAV segments local; logical blocks may span files in one `recordingGroupId`.
- Join only gaps <= 3 seconds, up to 45 seconds and 180 Chinese characters.
- Do not close a block without VAD closure or `。！？…`, except when recording stops.
- Model requests are globally serial, one per complete confirmed block, with existing retry backoff.
- Do not resend after a speaker-only correction; reattribute existing sentence scores locally.

---

### Task 1: Persist and build sentence-safe context blocks

**Files:**
- Create: `mobile/flutter_app/lib/local/context_blocks.dart`
- Modify: `mobile/flutter_app/lib/local/local_session_store.dart`
- Test: `mobile/flutter_app/test/local/context_blocks_test.dart`

**Interfaces:**
- Produces `ConversationContextBlock(id, recordingGroupId, utteranceIds, startMilliseconds, endMilliseconds, state, review)`.
- Produces `ContextBlockBuilder.build(Iterable<LocalSessionSummary>, {required bool recordingStopped})`.

- [ ] **Step 1: Write failing tests** for a <=3-second same-group join, a 4-second split, a 45-second split, and a no-punctuation tail joined to the next WAV.
- [ ] **Step 2: Run** `flutter test test/local/context_blocks_test.dart`; expect missing builder/types.
- [ ] **Step 3: Implement** JSON round-trip and deterministic grouping. Use `RegExp(r'[。！？…][”』]?$')` to close a textual sentence; retain an `awaitingContinuation` tail unless `recordingStopped`.
- [ ] **Step 4: Run** the targeted test; expect all pass.
- [ ] **Step 5: Commit** `feat: persist sentence-safe context blocks`.

### Task 2: Convert the model contract and queue to block tasks

**Files:**
- Modify: `mobile/flutter_app/lib/local/daily_advice.dart`
- Modify: `mobile/flutter_app/lib/local/llm_review_queue.dart`
- Test: `mobile/flutter_app/test/local/llm_review_queue_test.dart`

**Interfaces:**
- `ContextBlockScoreRequest.forBlock(block, utterances)` sends ordered `speaker: transcript` turns.
- `ContextBlockScoreResponse` returns `markdown` plus `{utteranceId: {score, markdown}}`.
- Queue candidate requires a closed block whose nonempty utterances all have a nonempty `speakerId`.

- [ ] **Step 1: Write failing tests** that one confirmed 3-utterance block starts one request, an unconfirmed block starts none, and response scores map to all referenced utterances.
- [ ] **Step 2: Run** `flutter test test/local/llm_review_queue_test.dart`; expect the per-utterance queue assertions to fail.
- [ ] **Step 3: Implement** block-level queue states/retry persistence and JSON validation; leave missing result entries unscored rather than inventing a value.
- [ ] **Step 4: Run** targeted tests; expect pass.
- [ ] **Step 5: Commit** `feat: score confirmed context blocks serially`.

### Task 3: Add batch confirmation and block presentation

**Files:**
- Modify: `mobile/flutter_app/lib/main.dart`
- Create: `mobile/flutter_app/lib/widgets/context_block_card.dart`
- Test: `mobile/flutter_app/test/widget_test.dart`

**Interfaces:**
- `ContextBlockCard(block, utterances, selectedIds, onSelectionChanged, onConfirmRole)`.
- `confirmSelectedSpeaker(conversationIds, utteranceIds, SpeakerProfile)` updates every selected embedding and label, then rebuilds blocks.

- [ ] **Step 1: Write failing widget/state tests** for multi-select visibility, one role action updating two selected utterances, and no queue enqueue while one block utterance remains unconfirmed.
- [ ] **Step 2: Run** `flutter test test/widget_test.dart`; expect missing card/actions.
- [ ] **Step 3: Implement** collapsible block cards, per-sentence checkboxes, select-all, and a bottom confirmation bar. Display block Markdown and sentence-level red/green scores after completion.
- [ ] **Step 4: Run** widget and local model tests; expect pass.
- [ ] **Step 5: Commit** `feat: batch confirm context block speakers`.

### Task 4: Integrate streaming analysis and regressions

**Files:**
- Modify: `mobile/flutter_app/lib/main.dart`
- Modify: `mobile/flutter_app/test/local/score_trends_test.dart`
- Test: `mobile/flutter_app/test/local/context_blocks_test.dart`

- [ ] **Step 1: Write failing integration test** for two consecutive physical segments whose trailing/leading utterances form one logical block, and for a speaker correction reattributing trend scores without enqueueing another model request.
- [ ] **Step 2: Run** targeted tests; expect failure.
- [ ] **Step 3: Rebuild blocks after each completed PCM analysis, enqueue only closed confirmed blocks, and retain prior sentence score objects during speaker correction.
- [ ] **Step 4: Run** `flutter analyze` and `flutter test`; expect zero analysis issues and all tests passing.
- [ ] **Step 5: Commit** `feat: integrate context blocks with streaming analysis`.

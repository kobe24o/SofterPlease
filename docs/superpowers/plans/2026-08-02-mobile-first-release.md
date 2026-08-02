# Mobile-first Android Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline execution selected by the user).

**Goal:** Deliver an Android-first, local-first SofterPlease build with secure in-app updates and a GitHub Actions release pipeline.

**Architecture:** Flutter owns UI, local recordings, session metadata and update orchestration. Sherpa ONNX provides the Android-native inference runtime; models are installed as a separately verified, user-visible model pack. GitHub Actions builds with an immutable Android signing certificate, signs an update manifest with a separate Ed25519 key, then publishes APK and manifest only after artifact validation.

**Tech Stack:** Flutter/Dart, sherpa_onnx, Android Kotlin/FileProvider, SharedPreferences interim local store, GitHub Actions, GitHub Releases, Ed25519, SHA-256.

## Global Constraints

- First production target is Android; shared Dart domain code must remain iOS/desktop compatible.
- Voice recordings remain in the app-private directory and are not uploaded in offline sessions.
- Accelerated Git download URLs are untrusted transports; signed manifest, SHA-256, package name, version and certificate checks remain mandatory.
- Release APKs must use one persistent non-debug Android certificate.
- No secret, private key, keystore, token, or model license credential may enter Git.

---

### Task 1: Make the release signing contract real

**Files:**
- Modify: `mobile/flutter_app/android/app/build.gradle.kts`
- Modify: `mobile/flutter_app/android/.gitignore`
- Modify: `.github/workflows/mobile-build.yml`
- Test: CI build and `apksigner verify --print-certs`

- [ ] Add Gradle `key.properties` loading that fails a release build without the configured keystore.
- [ ] Decode `ANDROID_KEYSTORE_BASE64` in Actions, write a temporary `key.properties`, and pass signing values only through environment variables.
- [ ] Validate application ID, version code and certificate SHA-256 after building.
- [ ] Commit the release-signing contract separately.

### Task 2: Publish authenticated updates

**Files:**
- Modify: `.github/workflows/mobile-build.yml`
- Create: `tool/release/sign_update_manifest.dart`
- Modify: `docs/UPDATE_RELEASE.md`
- Test: `dart run tool/release/sign_update_manifest.dart --verify`

- [ ] Build a protocol-1 update envelope from the APK hash, package data, certificate and release notes.
- [ ] Sign payload bytes using `UPDATE_MANIFEST_PRIVATE_KEY_BASE64`; reject malformed keys and unsigned output.
- [ ] Publish the APK to the tag release and envelope to `update-feed/updates/latest.json`.
- [ ] Add Git acceleration then GitHub direct URL to the signed payload.
- [ ] Commit Actions publishing changes separately.

### Task 3: Turn offline recordings into model-ready input

**Files:**
- Modify: `mobile/flutter_app/lib/local/local_session_store.dart`
- Create: `mobile/flutter_app/lib/local/local_speech_engine.dart`
- Modify: `mobile/flutter_app/lib/main.dart`
- Test: `mobile/flutter_app/tool/local_session_store_tdd.dart`

- [ ] Persist session source, duration and model status with bounded local history.
- [ ] Define a platform-neutral recognizer interface returning transcript, language, emotion tag and inference error.
- [ ] Update offline session UI to distinguish saved recordings from successful on-device analysis.
- [ ] Commit the local data contract separately.

### Task 4: Integrate Sherpa ONNX safely

**Files:**
- Create: `mobile/flutter_app/lib/local/sherpa_sensevoice_engine.dart`
- Create: `mobile/flutter_app/lib/local/model_pack.dart`
- Modify: `mobile/flutter_app/pubspec.yaml`
- Modify: `mobile/flutter_app/lib/main.dart`
- Test: `mobile/flutter_app/tool/model_pack_tdd.dart`

- [ ] Require a manifest-declared SHA-256 model pack before constructing the recognizer.
- [ ] Run SenseVoice against only 16 kHz mono WAV input and return structured results.
- [ ] Keep VAD/ASR model paths outside source control and show an actionable “model not installed” state.
- [ ] Validate on a physical Android device before calling this feature delivered.

### Task 5: Release gate

**Files:**
- Modify: `README.md`
- Modify: `docs/UPDATE_RELEASE.md`
- Test: `flutter test`, `flutter analyze`, release APK build, `apksigner verify --print-certs`, device installation, GitHub Actions run.

- [ ] Run secret scan and inspect all staged files.
- [ ] Verify local and CI APK package/version/certificate match the signed update manifest.
- [ ] Commit, push, tag `v2.2.2`, wait for the GitHub Actions release workflow, and inspect its logs and published asset.

# SofterPlease Android App

Flutter Android client for long-form family conversations, VAD segmentation, speaker confirmation, emotion analysis and family guidance.

The app opens directly into the main monitoring shell. Users can browse the monitor and statistics screens before signing in. The **My** page connects to the server, registers users through the backend `/v1/users` endpoint, stores the returned token locally, syncs profile/family data through `/v1/users/me`, and shows the same family/report statistics used by the web dashboard.

## Build

1. Install Flutter and Android Studio.
2. From this folder, create the local Android SDK binding if it is missing:

   ```powershell
   flutter create --platforms android .
   ```

3. Start the backend API.
4. Build an APK:

   ```powershell
   flutter pub get
   flutter build apk --dart-define=API_BASE_URL=http://192.168.1.10:8000
   ```

Use `10.0.2.2` only for the Android emulator. Use your computer's LAN IP when testing on a physical phone on the same WiFi network. The app also exposes the backend URL on the login screen, so you can change it without rebuilding when the LAN IP changes.

## Conversation workflow

1. Start a session and record naturally for up to 10 minutes.
2. Android first saves a 16 kHz mono WAV locally. When the on-device model pack is installed, VAD, transcription, coarse emotion tags and speaker embedding run locally; the recording is never uploaded automatically.
3. Play any saved utterance and use the person button to confirm which family member spoke it.
4. Confirming a role updates that member's voice embedding and reclassifies similar utterances in the same recording.
5. Rename a detected speaker in Statistics. Its stable `spk_xxx` identity is reused for future matching and historical grouping.
6. Tap a date to review positive/neutral/negative counts, the integer emotion score, exact timestamps, audio, transcripts and model output.
7. Tap **Get advice** to receive separate Markdown-rendered guidance for every speaker and compare the current seven days with the previous seven days.

Configure an OpenAI-compatible Base URL, model and API key under **My > Family advice model**. The key is stored with `flutter_secure_storage`; it is sent only for the active advice request and is never stored by the backend.

The launcher and app bar use the new SofterPlease conversation-home-heart brand mark from `assets/branding/softerplease-logo.png`.

## On-device model pack

The app intentionally does not bundle model weights into the APK. Install the verified model pack under the app documents directory using this layout:

```text
models/
  sensevoice/model.int8.onnx
  vad/ten-vad.int8.onnx
  speaker/model.onnx
```

Until all three files are present, the app records and stores sessions locally but marks them as awaiting on-device analysis. This prevents a partial or missing pack from silently falling back to server-side audio processing.

Family advice remains optional and network-based. Send only the user-selected transcript or summary to that model; do not upload raw recordings or speaker embeddings.

For Xunfei MaaS, set the Base URL to `https://maas-api.cn-huabei-1.xf-yun.com/v2` and enter the model ID assigned by MaaS. Use **Test connection** before generating advice. The backend does not inherit desktop proxy variables and allows up to 180 seconds for a full report response.

# SofterPlease Android App

Flutter Android client for recording short WAV voice segments and sending them to the SofterPlease backend.

The app registers users through the backend `/v1/users` endpoint, stores the returned token locally, syncs profile/family data through `/v1/users/me`, and shows the same family/report statistics used by the web dashboard.

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

# SofterPlease Android App

Flutter Android client for recording short WAV voice segments and sending them to the SofterPlease backend.

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
   flutter build apk --dart-define=API_BASE_URL=http://10.0.2.2:8000
   ```

Use `10.0.2.2` for the Android emulator. Use your computer's LAN IP when testing on a physical phone.

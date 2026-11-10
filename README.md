# myzeptotracker

Flutter Android app + laptop-hosted Python backend for configurable, location-by-location inventory monitoring, high-priority Android notifications, and direct product/search links.

## Important: what works immediately vs. live inventory

- **Demo mode works immediately**: the app can connect to the laptop backend, import the included Excel workbook, show status, and send a clearly labelled test notification.
- **Live Zepto inventory is not pre-enabled.** There is no official Zepto stock API credential or approved endpoint included with this project. `CHECK_MODE=demo` is the default and does not pretend demo events are real stock. To run live checks, configure an endpoint you are authorised to use in `backend/.env` using the JSON contract in `docs/LIVE_CONNECTOR.md`.
- The backend does **not** spoof browsers, rotate IPs, solve challenges, or bypass Akamai/anti-bot controls. A `403` or `429` opens a circuit breaker and pauses scanning. No system can promise a permanent no-block result.
- Android heads-up notifications are controlled by Android, user settings, device vendor, and Do Not Disturb. The app requests notification permission and sets a high-importance channel, but cannot force itself above every app or override system settings. Android 15+ also limits `dataSync` foreground services; this is not an unlimited 24/7 guarantee, and battery/vendor policies may still stop background work.

## Workbook coverage

Included workbook: `backend/data/locations.xlsx`.

The `Zepto Store Locations` sheet contains **228 mapped records across Delhi (117), Gurugram (59), Noida (36), Faridabad (16)**. They correspond to **102 distinct six-digit PIN codes**, not 228 distinct PIN codes. Multiple area records can share a PIN. These records are public mapped listings, not official proof of an operating Zepto dark store or serviceability. The backend keeps all mapped records as separate targets so that locality/address context is not silently lost. It does not use the `Route Checkpoints` sheet as store targets.

## Quick start on Windows 11

1. Install Python 3.11+ (3.12 recommended).
2. Extract this ZIP.
3. Open `backend` in File Explorer, copy `.env.example` to `.env`.
4. Double-click `start_backend_windows.bat`. It creates a virtual environment, installs dependencies and starts the API on `http://0.0.0.0:8765`.
5. Find your laptop's private LAN IPv4 address with `ipconfig`. On your phone and laptop, connect to the same trusted Wi-Fi.
6. Open `mobile` in Android Studio. Ensure Flutter SDK (3.44+), Android SDK, and Android Studio's Flutter/Dart plugins are installed. Open `mobile/pubspec.yaml`, run `flutter pub get`, then run/build the app.
7. In the app, enter `http://<LAPTOP-LAN-IP>:8765` (not `localhost` on a physical phone), set the same API key as `API_KEY` in `backend/.env`, and tap **Connect**.
8. Tap **Test notification** to test the app notification. Tap **Start monitoring** only after reading the live-connector section below.

Android emulator note: `http://10.0.2.2:8765` generally reaches the host computer from the standard Android emulator. A physical phone should use the laptop's LAN IP.

## Quick start on Linux / Arch

From the extracted folder, run `backend/start_backend_linux.sh`. Install Flutter/Dart and Android SDK separately, then open `mobile` in Android Studio and run `flutter pub get`.

## Backend safety defaults

- `CHECK_MODE=demo` by default; no remote Zepto requests are made.
- Live mode (`http_json`) needs a configured authorised `CHECK_API_URL`.
- One request per mapped location per scan, containing the enabled products together.
- Bounded concurrency (`MAX_CONCURRENCY`, default 6), minimum scan interval (`SCAN_INTERVAL_SECONDS`, default 180), network timeout, and immediate pause on HTTP 403/429.
- The backend never retries a 403/429 in a tight loop, rotates IPs, or tries to defeat an anti-bot challenge.
- The API key is required for backend control endpoints. Change it in `.env` and enter the same value in the app.

## Build an APK

From a terminal in `mobile`:

```bash
flutter pub get
flutter analyze
flutter build apk --release
```

APK output: `mobile/build/app/outputs/flutter-apk/app-release.apk`.

This environment did not contain Flutter/Android SDK, so this ZIP includes the project source, not a prebuilt APK. Android Studio/Flutter downloads the packages and performs the build on your machine.

## Troubleshooting

- **App cannot connect:** ensure phone and laptop are on the same Wi-Fi; check the laptop LAN IP, backend console, Windows Firewall, and matching API key. Do not expose port 8765 to the public internet.
- **No heads-up pop-up:** enable myzeptotracker notifications and allow its high-priority channel; disable Do Not Disturb for testing. Android/vendor policies may still suppress heads-up alerts.
- **Monitoring paused:** inspect `/api/status` or the app banner. If an endpoint returns 403/429, the backend pauses automatically; respect the endpoint's rules and use only an authorised integration.
- **Location count:** all mapped rows are attempted separately; the PIN count is deduplicated for display only.

See `docs/LIVE_CONNECTOR.md` and `docs/ARCHITECTURE.md`.

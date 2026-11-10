# Architecture

- **Flutter Android client**: product toggles, API connection settings, Excel upload, scanner controls, recent event feed, heads-up local notifications, tap-to-open product/search URL.
- **Python FastAPI backend on laptop**: reads the workbook, stores product configuration, orchestrates bounded concurrent scans, deduplicates availability transitions, exposes status and events to the phone.
- **Location model**: all rows from the preferred location sheet are retained; route checkpoint sheets are not mixed into the primary location list when a preferred sheet exists. Unique PIN counts are reported separately.
- **Rate-limit circuit breaker**: HTTP 403/429 pauses the scanner for `BLOCK_COOLDOWN_SECONDS`, preventing immediate repeated requests. Requests are bounded by semaphore, and the app surfaces the pause reason.
- **Data integrity**: the backend only creates a live event when the configured connector positively returns `available: true`. Test-event payloads are tagged `is_demo: true` and the app labels them as demo.
- **Network**: phone and laptop should use one trusted LAN; port 8765 must not be exposed to the public internet. The API key is required for control endpoints.

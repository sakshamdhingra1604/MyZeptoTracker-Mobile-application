# Backend

FastAPI server, location workbook importer, product configuration, scan orchestrator and events API.

- `start_backend_windows.bat`: Windows 11 one-click bootstrap.
- `start_backend_linux.sh`: Linux/Arch bootstrap.
- `data/locations.xlsx`: default workbook; 228 mapped targets, 102 unique PIN codes.
- `config/products.json`: editable product identities and fallback search links.
- `.env.example`: copy to `.env`; change `API_KEY` and use `CHECK_MODE=demo` unless a permitted live connector is configured.

Interactive API docs are available at `http://127.0.0.1:8765/docs` while the server runs. All `/api/*` routes require `X-API-Key`; `/health` is open for connection diagnostics.

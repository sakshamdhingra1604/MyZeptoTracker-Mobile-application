from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import shutil
import time
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from openpyxl import load_workbook
from pydantic import BaseModel, Field

# Optional zepto_client – only required when CHECK_MODE=zepto_direct
try:
    from . import zepto_client as _zc  # type: ignore[attr-defined]
    _ZEPTO_CLIENT_OK = True
except ImportError:
    try:
        from app import zepto_client as _zc  # type: ignore[attr-defined]
        _ZEPTO_CLIENT_OK = True
    except ImportError:
        _zc = None  # type: ignore[assignment]
        _ZEPTO_CLIENT_OK = False

BASE_DIR = Path(__file__).resolve().parents[1]
load_dotenv(BASE_DIR / ".env")
DATA_DIR = BASE_DIR / "data"
CONFIG_DIR = BASE_DIR / "config"
DATA_DIR.mkdir(parents=True, exist_ok=True)
LOCATIONS_FILE = DATA_DIR / "locations.xlsx"
PRODUCTS_FILE = CONFIG_DIR / "products.json"

API_KEY = os.getenv("API_KEY", "replace-this-with-a-long-random-local-key").strip()
CHECK_MODE = os.getenv("CHECK_MODE", "demo").strip().lower()
CHECK_API_URL = os.getenv("CHECK_API_URL", "").strip()
CHECK_API_BEARER_TOKEN = os.getenv("CHECK_API_BEARER_TOKEN", "").strip()
MAX_CONCURRENCY = max(1, min(12, int(os.getenv("MAX_CONCURRENCY", "6"))))
SCAN_INTERVAL_SECONDS = max(60, int(os.getenv("SCAN_INTERVAL_SECONDS", "180")))
REQUEST_TIMEOUT_SECONDS = max(3, min(60, int(os.getenv("REQUEST_TIMEOUT_SECONDS", "15"))))
BLOCK_COOLDOWN_SECONDS = max(60, min(86400, int(os.getenv("BLOCK_COOLDOWN_SECONDS", "900"))))

if not PRODUCTS_FILE.exists():
    raise RuntimeError(f"Missing product configuration: {PRODUCTS_FILE}")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_products() -> list[dict[str, Any]]:
    return json.loads(PRODUCTS_FILE.read_text(encoding="utf-8"))


def save_products(products: list[dict[str, Any]]) -> None:
    PRODUCTS_FILE.write_text(json.dumps(products, ensure_ascii=False, indent=2), encoding="utf-8")


def _clean(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _find_col(headers: list[str], includes: tuple[str, ...]) -> int | None:
    for idx, header in enumerate(headers):
        h = re.sub(r"[^a-z0-9]+", " ", header.lower()).strip()
        if all(part in h for part in includes):
            return idx
    return None


def read_locations(path: Path) -> list[dict[str, Any]]:
    """Read the store-location sheet without using route/checkpoint seed rows."""
    wb = load_workbook(path, read_only=True, data_only=True)
    try:
        preferred = ["Zepto Store Locations", "ALL_LOCATIONS_PIN_CODES", "ALL_LOCATIONS", "ALL_LOCATIONS_MASTER"]
        sheet = next((wb[name] for name in preferred if name in wb.sheetnames), None)
        if sheet is None:
            sheet = wb[wb.sheetnames[0]]
        raw_rows = sheet.iter_rows(values_only=True)
        first = next(raw_rows, None)
        if not first:
            return []
        headers = [_clean(v) for v in first]
        # Preferred source workbook names.
        mapping = {
            "city": _find_col(headers, ("city", "region")) or _find_col(headers, ("city", "district")) or _find_col(headers, ("region",)),
            "name": _find_col(headers, ("listed", "store")) or _find_col(headers, ("location", "locality")) or _find_col(headers, ("locality", "sector")),
            "locality": _find_col(headers, ("locality", "sector")) or _find_col(headers, ("location", "locality")) or _find_col(headers, ("checkpoint",)),
            "pin": _find_col(headers, ("pin", "code")) or _find_col(headers, ("pin",)),
            "address": _find_col(headers, ("listed", "address")) or _find_col(headers, ("address",)),
            "source": _find_col(headers, ("source", "url")),
            "status": _find_col(headers, ("data", "status")) or _find_col(headers, ("pin", "verification")),
        }
        # The uploaded master uses "City/Region"; fallback for common exact column names.
        if mapping["city"] is None:
            mapping["city"] = next((i for i, h in enumerate(headers) if h.lower() in ("city/region", "region", "city / district", "district / city")), None)
        if mapping["name"] is None:
            mapping["name"] = next((i for i, h in enumerate(headers) if "store/location name" in h.lower() or h.lower() == "location / locality"), None)
        if mapping["locality"] is None:
            mapping["locality"] = next((i for i, h in enumerate(headers) if "locality" in h.lower() or "sector / checkpoint" in h.lower()), None)
        if mapping["pin"] is None:
            mapping["pin"] = next((i for i, h in enumerate(headers) if "pin" in h.lower()), None)

        records: list[dict[str, Any]] = []
        for row_num, row in enumerate(raw_rows, start=2):
            def val(key: str) -> str:
                ix = mapping.get(key)
                return _clean(row[ix]) if ix is not None and ix < len(row) else ""

            raw_name = val("name")
            raw_locality = val("locality")
            raw_pin = val("pin")
            raw_address = val("address")
            if not any((raw_name, raw_locality, raw_pin, raw_address)):
                continue
            city = val("city") or "Unknown"
            name = raw_name or raw_locality or f"Location row {row_num}"
            locality = raw_locality or name
            # Keep each valid six-digit PIN found in the cell, but use the first when a cell lists multiple PINs.
            pin_match = re.search(r"(?<!\d)(\d{6})(?!\d)", raw_pin)
            pin = pin_match.group(1) if pin_match else ""
            address = raw_address or ", ".join(x for x in (locality, city, pin) if x)
            source = val("source")
            status = val("status")
            # Stable row ID means two mapped locations sharing a PIN remain separate targets.
            location_id = f"loc-{len(records) + 1:04d}"
            records.append({
                "id": location_id,
                "city": city,
                "name": name,
                "locality": locality,
                "pin_code": pin,
                "address": address,
                "source_url": source,
                "data_status": status,
                "valid_pin": bool(pin),
            })
        return records
    finally:
        wb.close()


class ProductUpdate(BaseModel):
    products: list[dict[str, Any]]


class LocationCreate(BaseModel):
    city: str
    name: str
    locality: str | None = None
    pin_code: str
    address: str | None = None


class ResumeRequest(BaseModel):
    confirm_authorized: bool = Field(default=False)


class State:
    def __init__(self) -> None:
        self.instance_id = secrets.token_hex(8)
        self.running = False
        self.task: asyncio.Task | None = None
        self.lock = asyncio.Lock()
        self.http: httpx.AsyncClient | None = None
        self.locations: list[dict[str, Any]] = []
        self.events: deque[dict[str, Any]] = deque(maxlen=1000)
        self.next_event_id = 1
        self.current_stock: dict[str, bool] = {}
        self.paused_until = 0.0
        self.pause_reason = ""
        self.phase = "idle"
        self.last_scan_at: str | None = None
        self.last_error = ""
        self.scans_completed = 0
        self.locations_checked = 0
        self.requests_sent = 0
        self.found_total = 0
        self.last_scan_duration_seconds: float | None = None
        self.last_status_code: int | None = None
        self.last_good_response_at: str | None = None
        self.block_count = 0
        self.event_seen = set()

    @property
    def unique_pins(self) -> int:
        return len({x["pin_code"] for x in self.locations if x.get("pin_code")})


state = State()


async def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if not API_KEY or API_KEY == "replace-this-with-a-long-random-local-key":
        # Require the configured default only for local-development; warn loudly in status.
        expected = API_KEY
    else:
        expected = API_KEY
    if not x_api_key or not secrets.compare_digest(x_api_key, expected):
        raise HTTPException(status_code=401, detail="Missing or incorrect X-API-Key. Match the API_KEY value in backend/.env.")


def products_enabled() -> list[dict[str, Any]]:
    return [p for p in load_products() if p.get("enabled", True)]


def _event(product: dict[str, Any], location: dict[str, Any], item: dict[str, Any], demo: bool = False) -> dict[str, Any]:
    event_id = state.next_event_id
    state.next_event_id += 1
    payload = {
        "id": event_id,
        "created_at": utc_now(),
        "product_id": product.get("id", "unknown"),
        "product_name": product.get("name", "Product"),
        "location_id": location.get("id", "demo-location"),
        "location_name": location.get("locality") or location.get("name") or "Unknown locality",
        "city": location.get("city", "Unknown"),
        "pin_code": location.get("pin_code", ""),
        "address": location.get("address", ""),
        "price": item.get("price"),
        "currency": item.get("currency", "INR"),
        "variant": item.get("variant") or item.get("specs") or "Variant not provided by data source",
        "product_url": item.get("product_url") or product.get("search_url") or "https://www.zeptonow.com/",
        "available": True,
        "is_demo": demo,
        "source": "DEMO — simulated event" if demo else "Configured authorised JSON endpoint",
    }
    state.events.append(payload)
    state.found_total += 1
    return payload


async def _trigger_circuit_breaker(code: int, loc: dict[str, Any]) -> None:
    async with state.lock:
        state.last_status_code = code
        state.paused_until = max(state.paused_until, time.time() + BLOCK_COOLDOWN_SECONDS)
        state.pause_reason = f"HTTP {code} received for a location check; scanning paused for {BLOCK_COOLDOWN_SECONDS}s. Check endpoint permission/rules before resuming."
        state.phase = "paused_rate_limit" if code == 429 else "paused_access_denied"
        state.block_count += 1
        state.last_error = state.pause_reason


async def _check_live_location(client: httpx.AsyncClient, location: dict[str, Any], products: list[dict[str, Any]], sem: asyncio.Semaphore) -> None:
    if not CHECK_API_URL:
        state.last_error = "Live mode is enabled but CHECK_API_URL is empty. Configure an authorised endpoint in backend/.env."
        return
    async with sem:
        if state.paused_until > time.time():
            return
        if CHECK_API_BEARER_TOKEN:
            headers = {"Authorization": f"Bearer {CHECK_API_BEARER_TOKEN}"}
        else:
            headers = {}
        payload = {
            "location": {
                "id": location["id"],
                "city": location["city"],
                "locality": location["locality"],
                "pin_code": location["pin_code"],
                "address": location["address"],
            },
            "products": [{"id": p["id"], "name": p["name"], "query": p["query"], "match": p.get("match", {})} for p in products],
        }
        state.requests_sent += 1
        try:
            response = await client.post(CHECK_API_URL, json=payload, headers=headers)
            state.last_status_code = response.status_code
            if response.status_code in (403, 429):
                await _trigger_circuit_breaker(response.status_code, location)
                return
            response.raise_for_status()
            raw = response.json()
            items = raw.get("items", []) if isinstance(raw, dict) else []
            if not isinstance(items, list):
                raise ValueError("Connector response 'items' must be a JSON array")
            products_by_id = {p["id"]: p for p in products}
            found_for_location: dict[str, dict[str, Any]] = {}
            for item in items:
                if not isinstance(item, dict):
                    continue
                pid = str(item.get("product_id") or item.get("id") or "")
                if pid in products_by_id and bool(item.get("available", False)):
                    found_for_location[pid] = item

            async with state.lock:
                state.locations_checked += 1
                for product in products:
                    stock_key = f"{location['id']}::{product['id']}"
                    is_available = product["id"] in found_for_location
                    previously_available = state.current_stock.get(stock_key, False)
                    state.current_stock[stock_key] = is_available
                    if is_available and not previously_available:
                        _event(product, location, found_for_location[product["id"]], demo=False)
                state.last_good_response_at = utc_now()
        except httpx.HTTPStatusError as exc:
            state.last_error = f"Connector returned HTTP {exc.response.status_code}; no anti-bot bypass is attempted."
        except (httpx.TimeoutException, httpx.NetworkError) as exc:
            state.last_error = f"Connector network error: {type(exc).__name__}. The next scan follows the configured interval."
        except (ValueError, json.JSONDecodeError) as exc:
            state.last_error = f"Connector JSON response was not in the documented format: {exc}"
        except Exception as exc:  # keep one bad location from crashing the scanner
            state.last_error = f"Check failed for {location.get('id')}: {type(exc).__name__}: {exc}"


async def _scan_once() -> None:
    if not state.locations:
        state.locations = read_locations(LOCATIONS_FILE) if LOCATIONS_FILE.exists() else []
    locs = list(state.locations)
    enabled_products = products_enabled()
    state.phase = "scanning"
    state.locations_checked = 0
    start = time.monotonic()
    mode = CHECK_MODE
    if mode == "demo":
        # Deliberately do not make external requests in demo mode. Still count the mapped rows as traversed.
        for _ in locs:
            if not state.running:
                break
            state.locations_checked += 1
            await asyncio.sleep(0)
        state.last_error = "Demo mode: no live stock requests are made. Use Test notification to verify alerts."
    elif mode == "http_json":
        if not CHECK_API_URL:
            state.last_error = "Live mode requires CHECK_API_URL in backend/.env; no stock requests were sent."
        elif not enabled_products:
            state.last_error = "No products enabled. Enable at least one product in the app."
        else:
            sem = asyncio.Semaphore(MAX_CONCURRENCY)
            if state.http is None:
                state.http = httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS, follow_redirects=False, headers={"Accept": "application/json", "Content-Type": "application/json", "User-Agent": "myzeptotracker/1.0 (configured connector)"})
            tasks = [_check_live_location(state.http, loc, enabled_products, sem) for loc in locs if loc.get("valid_pin")]
            await asyncio.gather(*tasks, return_exceptions=True)
    elif mode == "zepto_direct":
        if not _ZEPTO_CLIENT_OK:
            state.last_error = "zepto_client.py not found in backend/app/. It should be present – check the file exists."
        elif not enabled_products:
            state.last_error = "No products enabled. Enable at least one product in the app."
        else:
            if state.http is None:
                state.http = httpx.AsyncClient(
                    timeout=REQUEST_TIMEOUT_SECONDS,
                    follow_redirects=True,
                    headers={"Accept": "application/json"},
                )
            sem = asyncio.Semaphore(MAX_CONCURRENCY)

            async def _check_zepto_direct(loc: dict[str, Any]) -> None:
                if not loc.get("valid_pin"):
                    return
                async with sem:
                    if state.paused_until > time.time():
                        return
                    zc_status = _zc.get_status()
                    if zc_status["globally_paused"]:
                        return
                    try:
                        items = await _zc.check_pincode(
                            state.http, loc["pin_code"], enabled_products
                        )
                    except Exception as exc:
                        state.last_error = f"zepto_client error for PIN {loc['pin_code']}: {type(exc).__name__}: {exc}"
                        return
                    state.requests_sent += 1
                    async with state.lock:
                        state.locations_checked += 1
                        for item in items:
                            pid = str(item.get("product_id", ""))
                            prod = next(
                                (p for p in enabled_products if str(p.get("id", "")) == pid),
                                None,
                            )
                            if prod:
                                stock_key = f"{loc['id']}::{pid}"
                                was_available = state.current_stock.get(stock_key, False)
                                state.current_stock[stock_key] = True
                                if not was_available:
                                    _event(prod, loc, item, demo=False)
                        if not items:
                            for prod in enabled_products:
                                stock_key = f"{loc['id']}::{prod['id']}"
                                state.current_stock[stock_key] = False
                        state.last_good_response_at = utc_now()
                    # Sync zepto_client circuit-breaker into our global state
                    zs = _zc.get_status()
                    if zs["globally_paused"] and state.paused_until <= time.time():
                        remain = zs["global_pause_remaining_seconds"]
                        state.paused_until = time.time() + remain
                        state.pause_reason = zs["last_error"]
                        state.phase = "paused_access_denied"
                        state.block_count = zs["block_count"]
                        state.last_error = zs["last_error"]

            tasks = []
            for i, loc in enumerate(locs):
                async def _worker(l=loc, delay=i * 0.4):
                    await asyncio.sleep(delay)
                    await _check_zepto_direct(l)
                tasks.append(_worker())
            await asyncio.gather(*tasks, return_exceptions=True)
    else:
        state.last_error = f"Unsupported CHECK_MODE={mode!r}. Use demo, http_json, or zepto_direct."
    state.last_scan_at = utc_now()
    state.last_scan_duration_seconds = round(time.monotonic() - start, 2)
    state.scans_completed += 1
    if state.paused_until > time.time():
        state.phase = "paused_rate_limit" if state.last_status_code == 429 else "paused_access_denied"
    else:
        state.phase = "running" if state.running else "idle"


async def _monitor_loop() -> None:
    try:
        while state.running:
            if not state.locations:
                try:
                    state.locations = read_locations(LOCATIONS_FILE)
                except Exception as exc:
                    state.last_error = f"Cannot read locations.xlsx: {exc}"
                    state.locations = []
            if state.paused_until > time.time():
                state.phase = "paused_rate_limit" if state.last_status_code == 429 else "paused_access_denied"
                await asyncio.sleep(min(10, max(1, state.paused_until - time.time())))
                continue
            await _scan_once()
            deadline = time.time() + SCAN_INTERVAL_SECONDS
            while state.running and time.time() < deadline:
                if state.paused_until > time.time():
                    break
                await asyncio.sleep(min(1, max(0.1, deadline - time.time())))
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        state.last_error = f"Monitor loop stopped safely after an unexpected error: {type(exc).__name__}: {exc}"
        state.phase = "error"
    finally:
        state.running = False
        if state.phase not in ("paused_rate_limit", "paused_access_denied", "error"):
            state.phase = "idle"


@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        state.locations = read_locations(LOCATIONS_FILE) if LOCATIONS_FILE.exists() else []
    except Exception as exc:
        state.locations = []
        state.last_error = f"Could not load locations.xlsx at startup: {exc}"
    yield
    state.running = False
    if state.task and not state.task.done():
        state.task.cancel()
        try:
            await state.task
        except asyncio.CancelledError:
            pass
    if state.http:
        await state.http.aclose()


app = FastAPI(title="myzeptotracker API", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=False, allow_methods=["GET", "POST", "PUT", "OPTIONS"], allow_headers=["*"])


@app.get("/")
async def root():
    return {"app": "myzeptotracker", "api_version": "1.0.0", "mode": CHECK_MODE, "docs": "/docs", "notice": "Live stock checks require an authorised connector; demo mode never claims real availability."}


@app.get("/health")
async def health():
    return {"ok": True, "time": utc_now(), "mode": CHECK_MODE}


@app.get("/api/status", dependencies=[Depends(require_api_key)])
async def get_status():
    paused = state.paused_until > time.time()
    return {
        "app": "myzeptotracker",
        "server_id": state.instance_id,
        "mode": CHECK_MODE,
        "running": state.running,
        "phase": state.phase,
        "locations_total": len(state.locations),
        "unique_pins": state.unique_pins,
        "invalid_pin_records": sum(1 for x in state.locations if not x.get("valid_pin")),
        "products_enabled": len(products_enabled()),
        "max_concurrency": MAX_CONCURRENCY,
        "scan_interval_seconds": SCAN_INTERVAL_SECONDS,
        "scans_completed": state.scans_completed,
        "locations_checked_last_scan": state.locations_checked,
        "requests_sent": state.requests_sent,
        "found_events": state.found_total,
        "last_scan_at": state.last_scan_at,
        "last_scan_duration_seconds": state.last_scan_duration_seconds,
        "last_good_response_at": state.last_good_response_at,
        "last_status_code": state.last_status_code,
        "blocked_or_rate_limited": paused,
        "pause_reason": state.pause_reason if paused else "",
        "pause_remaining_seconds": max(0, int(state.paused_until - time.time())) if paused else 0,
        "last_error": state.last_error,
        "latest_event_id": state.next_event_id - 1,
        "api_key_configured": bool(API_KEY) and API_KEY != "replace-this-with-a-long-random-local-key",
        "live_endpoint_configured": bool(CHECK_API_URL),
        "zepto_direct_available": _ZEPTO_CLIENT_OK,
        "zepto_direct_status": _zc.get_status() if (_ZEPTO_CLIENT_OK and CHECK_MODE == "zepto_direct") else None,
        "data_note": "Mapped public listings are candidate areas, not official proof of store identity or serviceability.",
    }


@app.get("/api/products", dependencies=[Depends(require_api_key)])
async def get_products():
    return {"products": load_products()}


@app.put("/api/products", dependencies=[Depends(require_api_key)])
async def update_products(body: ProductUpdate):
    current = load_products()
    by_id = {str(x.get("id")): x for x in current}
    for submitted in body.products:
        pid = str(submitted.get("id", ""))
        if pid not in by_id:
            continue
        by_id[pid]["enabled"] = bool(submitted.get("enabled", True))
    save_products(current)
    return {"products": current}


@app.get("/api/locations", dependencies=[Depends(require_api_key)])
async def get_locations(limit: int = 500):
    limit = max(1, min(1000, limit))
    return {"total": len(state.locations), "unique_pins": state.unique_pins, "locations": state.locations[:limit]}


@app.post("/api/locations", dependencies=[Depends(require_api_key)])
async def add_location(loc: LocationCreate):
    pin = loc.pin_code.strip()
    if not re.match(r"^\d{6}$", pin):
        raise HTTPException(status_code=400, detail="Invalid 6-digit PIN code.")

    new_record = {
        "id": f"loc-{len(state.locations) + 1:04d}",
        "city": loc.city.strip() or "Delhi",
        "name": loc.name.strip() or "Custom Store",
        "locality": loc.locality.strip() if loc.locality else (loc.name.strip() or "Area"),
        "pin_code": pin,
        "address": loc.address.strip() if loc.address else f"{loc.name}, {pin}",
        "source_url": "https://www.zepto.com/",
        "data_status": "User Added",
        "valid_pin": True,
    }

    # Add at the beginning of the list for immediate checking
    state.locations.insert(0, new_record)

    # Persist in Excel
    try:
        if LOCATIONS_FILE.exists():
            wb = load_workbook(LOCATIONS_FILE)
            sheet = wb.active
            sheet.insert_rows(2)
            row_data = [
                new_record["city"],
                new_record["name"],
                new_record["locality"],
                new_record["pin_code"],
                new_record["address"],
                new_record["source_url"],
                new_record["data_status"]
            ]
            for col_idx, val in enumerate(row_data, start=1):
                sheet.cell(row=2, column=col_idx, value=val)
            wb.save(LOCATIONS_FILE)
    except Exception as exc:
        pass

    return {"ok": True, "location": new_record, "total": len(state.locations), "unique_pins": state.unique_pins}


@app.post("/api/locations/import", dependencies=[Depends(require_api_key)])
async def import_locations(file: UploadFile = File(...)):
    if not file.filename or Path(file.filename).suffix.lower() not in (".xlsx", ".xlsm"):
        raise HTTPException(status_code=400, detail="Upload an .xlsx or .xlsm workbook. The legacy .xls format is not supported.")
    temp_path = DATA_DIR / f"locations_upload_{int(time.time())}.xlsx"
    try:
        content = await file.read()
        if len(content) > 20 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="Workbook must be 20 MB or smaller.")
        temp_path.write_bytes(content)
        records = read_locations(temp_path)
        if not records:
            raise HTTPException(status_code=400, detail="No location records found. Include a store/locality and a PIN-code column.")
        shutil.move(str(temp_path), str(LOCATIONS_FILE))
        state.locations = records
        return {"ok": True, "total": len(records), "unique_pins": state.unique_pins, "invalid_pin_records": sum(1 for x in records if not x.get("valid_pin")), "message": "Imported location records. Route checkpoint sheet rows are not appended when a preferred location sheet exists."}
    finally:
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)


@app.get("/api/events", dependencies=[Depends(require_api_key)])
async def get_events(after_id: int = 0, limit: int = 100):
    limit = max(1, min(500, limit))
    all_events = list(state.events)
    if after_id > 0:
        chosen = [e for e in all_events if e["id"] > after_id][:limit]
    else:
        chosen = all_events[-limit:]
    return {"events": chosen, "latest_event_id": state.next_event_id - 1, "server_id": state.instance_id}


@app.post("/api/start", dependencies=[Depends(require_api_key)])
async def start_monitoring():
    if state.running and state.task and not state.task.done():
        return {"ok": True, "message": "Monitoring is already running.", "status": await get_status()}
    if state.paused_until > time.time():
        raise HTTPException(status_code=423, detail=f"Circuit breaker is active for {int(state.paused_until - time.time())} more seconds: {state.pause_reason}")
    if CHECK_MODE == "http_json" and not CHECK_API_URL:
        raise HTTPException(status_code=400, detail="Live mode requires CHECK_API_URL in backend/.env. No stock requests were sent.")
    state.running = True
    state.phase = "starting"
    state.task = asyncio.create_task(_monitor_loop())
    return {"ok": True, "message": "Monitoring started.", "mode": CHECK_MODE}


@app.post("/api/stop", dependencies=[Depends(require_api_key)])
async def stop_monitoring():
    state.running = False
    if state.task and not state.task.done():
        state.task.cancel()
        try:
            await state.task
        except asyncio.CancelledError:
            pass
    if state.phase not in ("paused_rate_limit", "paused_access_denied"):
        state.phase = "idle"
    return {"ok": True, "message": "Monitoring stopped."}


@app.post("/api/resume", dependencies=[Depends(require_api_key)])
async def resume_monitoring(body: ResumeRequest):
    if not body.confirm_authorized:
        raise HTTPException(status_code=400, detail="Confirm that you have permission to use the configured endpoint before resuming.")
    if state.paused_until > time.time():
        raise HTTPException(status_code=423, detail=f"Cooldown still active for {int(state.paused_until - time.time())} seconds.")
    state.pause_reason = ""
    state.last_error = ""
    state.phase = "idle"
    return {"ok": True, "message": "Circuit breaker cleared after cooldown. Start monitoring manually when ready."}


@app.post("/api/test-event", dependencies=[Depends(require_api_key)])
async def create_test_event():
    products = load_products()
    product = next((p for p in products if p.get("enabled", True)), products[0] if products else None)
    if not product:
        raise HTTPException(status_code=400, detail="No products configured.")
    location = state.locations[0] if state.locations else {"id": "demo-location", "city": "Demo City", "locality": "Demo Locality", "pin_code": "000000", "address": "Test event only"}
    sample = {"price": 79999, "currency": "INR", "variant": "TEST ONLY • sample 256GB / any colour", "product_url": product.get("search_url")}
    payload = _event(product, location, sample, demo=True)
    return {"ok": True, "event": payload, "message": "Test-only alert created; it is not real inventory."}


@app.get("/api/zepto/status", dependencies=[Depends(require_api_key)])
async def zepto_direct_status():
    """Return zepto_client circuit-breaker state (only relevant when CHECK_MODE=zepto_direct)."""
    if not _ZEPTO_CLIENT_OK:
        raise HTTPException(status_code=404, detail="zepto_client.py not available. CHECK_MODE must be zepto_direct.")
    return {"ok": True, "zepto_client": _zc.get_status(), "check_mode": CHECK_MODE}


@app.post("/api/zepto/reset", dependencies=[Depends(require_api_key)])
async def zepto_reset_circuit_breaker():
    """Clear the zepto_client circuit breaker so scanning resumes immediately."""
    if not _ZEPTO_CLIENT_OK:
        raise HTTPException(status_code=404, detail="zepto_client.py not available.")
    _zc.reset_circuit_breaker()
    # Also clear our own pause state
    state.paused_until = 0.0
    state.pause_reason = ""
    state.last_error = ""
    if state.phase in ("paused_rate_limit", "paused_access_denied"):
        state.phase = "idle" if not state.running else "running"
    return {"ok": True, "message": "zepto_client circuit breaker reset. Scanning will resume on next cycle."}

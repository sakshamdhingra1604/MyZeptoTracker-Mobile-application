"""
zepto_client.py — Permanent Solution for Zepto Stock Monitoring.

Zero-Login & Zero-Crash Architecture:
1. Persistent Chrome Profile (backend/data/chrome_profile):
   - Keeps browser cookies, tokens, and storage permanently on disk.
   - User can log in once using `login_zepto.bat` and it stays logged in forever.
2. Active Modal Slayer & Counter Reset:
   - Automatically resets `session_count` so Zepto never hits the 5-search guest limit.
   - Continuous DOM observer deletes any "Please Login" / "Verify OTP" dialogs in <200ms.
3. Single Reusable Page (No Context Churn):
   - Keeps a single warm browser page instead of creating/destroying 230 contexts.
   - Eliminates "context destroyed" and "target closed" crashes.
4. Direct BFF Gateway JSON Intercept:
   - Intercepts `bff-gateway.zepto.com/search-federator-service` network response directly.
   - Extracts product names, prices, and PDP links from raw JSON.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

from playwright.async_api import Browser, BrowserContext, Page, async_playwright

if sys.platform.startswith("win"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

logger = logging.getLogger("zepto_client")
logger.setLevel(logging.INFO)

PROFILE_DIR = str(Path(__file__).resolve().parents[1] / "data" / "chrome_profile")
CDP_URL = "http://localhost:9222"

PIN_COORDINATES: dict[str, tuple[float, float]] = {
    "110037": (28.5355, 77.1260),  # Mahipalpur / Rangpuri / Metropolis Logistics
    "110033": (28.7161, 77.1724),  # Adarsh Nagar
    "110092": (28.6502, 77.3027),  # Anand Vihar
    "110001": (28.6315, 77.2167),  # Connaught Place
    "110017": (28.5305, 77.2173),  # Malviya Nagar
    "110024": (28.5702, 77.2411),  # Lajpat Nagar
    "110085": (28.7186, 77.1089),  # Rohini
    "122001": (28.4595, 77.0266),  # Gurugram Sector 14
    "122018": (28.4239, 77.0478),  # Gurugram Sector 38
    "201301": (28.5708, 77.3271),  # Noida Sector 18
    "201304": (28.5355, 77.3910),  # Noida Sector 93
    "121001": (28.4089, 77.3178),  # Faridabad Old
}
DEFAULT_NCR_LAT_LNG = (28.5355, 77.1260)

_block_count = 0
_globally_paused = False
_global_pause_remaining = 0
_last_error = ""

_playwright_mgr = None
_context: BrowserContext | None = None
_browser: Browser | None = None
_page: Page | None = None
_lock = asyncio.Lock()

# Buffer for BFF responses captured by network listener
_bff_buffer: list[dict] = []
_bff_event = asyncio.Event()


def get_status() -> dict[str, Any]:
    return {
        "block_count": _block_count,
        "globally_paused": _globally_paused,
        "global_pause_remaining_seconds": _global_pause_remaining,
        "last_error": _last_error,
        "engine": "Persistent Chrome + Real-Time Modal Slayer + BFF Intercept",
    }


def reset_circuit_breaker() -> None:
    global _block_count, _globally_paused, _global_pause_remaining, _last_error
    _block_count = 0
    _globally_paused = False
    _global_pause_remaining = 0
    _last_error = ""


# Anti-login & session-reset JavaScript injected into every page load
ANTI_LOGIN_INIT_SCRIPT = """
(() => {
    // 1. Permanently keep guest search counter at 1 so Zepto never hits the 5-limit modal
    try {
        sessionStorage.setItem('session_count', '1');
        localStorage.setItem('session_count', '1');
        document.cookie = 'session_count=1; path=/; domain=.zepto.com';
        document.cookie = 'session_count=1; path=/';
    } catch(e) {}

    // 2. Continuous real-time modal and overlay terminator
    const terminateModals = () => {
        try {
            const targets = document.querySelectorAll(
                '[role="dialog"], [data-testid*="modal"], [class*="modal"], [class*="drawer"], [class*="overlay"], [class*="backdrop"]'
            );
            for (const el of targets) {
                const text = (el.innerText || '').toLowerCase();
                if (text.includes('login') || text.includes('verify otp') || text.includes('phone number') || text.includes('get started')) {
                    el.remove();
                }
            }
            document.body.style.overflow = 'auto';
            document.body.style.pointerEvents = 'auto';
        } catch(e) {}
    };

    terminateModals();
    document.addEventListener('DOMContentLoaded', terminateModals);
    window.addEventListener('load', terminateModals);
    setInterval(terminateModals, 200);
})();
"""


async def _on_response(response: Any) -> None:
    try:
        url = response.url
        if "search-federator-service/api/v1/search" in url and response.status == 200:
            body = await response.json()
            if isinstance(body, dict) and "layout" in body:
                _bff_buffer.append(body)
                _bff_event.set()
                logger.debug("BFF JSON captured (%d products in layout)", body.get("totalProductCount", 0))
    except Exception:
        pass


async def _get_page() -> Page:
    """Get or create the single reusable, long-lived browser page."""
    global _playwright_mgr, _browser, _context, _page
    async with _lock:
        if _playwright_mgr is None:
            _playwright_mgr = await async_playwright().start()

        # Check if page is already healthy
        if _page and not _page.is_closed():
            return _page

        os.makedirs(PROFILE_DIR, exist_ok=True)

        # Priority 1: Connect to Chrome CDP if running on port 9222
        connected_cdp = False
        try:
            _browser = await _playwright_mgr.chromium.connect_over_cdp(CDP_URL, timeout=1500)
            _context = await _browser.new_context(viewport={"width": 1280, "height": 800})
            connected_cdp = True
            logger.info("Connected to user's Chrome via CDP (Port 9222)")
        except Exception:
            pass

        # Priority 2: Use persistent profile with real Chrome or Chromium
        if not connected_cdp:
            try:
                _context = await _playwright_mgr.chromium.launch_persistent_context(
                    user_data_dir=PROFILE_DIR,
                    channel="chrome",
                    headless=False,
                    viewport={"width": 1280, "height": 800},
                    args=[
                        "--window-position=-2000,-2000",
                        "--disable-blink-features=AutomationControlled",
                        "--no-sandbox",
                        "--disable-dev-shm-usage",
                    ],
                )
                logger.info("Launched real Google Chrome with persistent profile: %s", PROFILE_DIR)
            except Exception:
                _context = await _playwright_mgr.chromium.launch_persistent_context(
                    user_data_dir=PROFILE_DIR,
                    headless=False,
                    viewport={"width": 1280, "height": 800},
                    args=[
                        "--window-position=-2000,-2000",
                        "--disable-blink-features=AutomationControlled",
                        "--no-sandbox",
                        "--disable-dev-shm-usage",
                    ],
                )
                logger.info("Launched Chromium with persistent profile: %s", PROFILE_DIR)

        # Inject anti-login and counter-reset script into every frame
        await _context.add_init_script(ANTI_LOGIN_INIT_SCRIPT)

        # Attach single network listener
        _page = _context.pages[0] if _context.pages else await _context.new_page()
        _page.on("response", _on_response)

        # Initial navigation to Zepto search page
        try:
            await _page.goto("https://www.zepto.com/search", wait_until="domcontentloaded", timeout=25000)
            await asyncio.sleep(1.5)
        except Exception as e:
            logger.debug("Initial page.goto notice: %s", e)

        return _page


async def close_browser() -> None:
    global _playwright_mgr, _browser, _context, _page
    async with _lock:
        if _page and not _page.is_closed():
            try:
                await _page.close()
            except Exception:
                pass
            _page = None
        if _context:
            try:
                await _context.close()
            except Exception:
                pass
            _context = None
        if _browser:
            try:
                await _browser.close()
            except Exception:
                pass
            _browser = None
        if _playwright_mgr:
            try:
                await _playwright_mgr.stop()
            except Exception:
                pass
            _playwright_mgr = None


# ─── Product matching logic ────────────────────────────────────────────────────

def _is_iphone17_256gb(title: str) -> bool:
    t = title.lower()
    if "iphone 17" not in t:
        return False
    if any(acc in t for acc in ["case", "cover", "glass", "guard", "protector", "cable", "charger", "skin"]):
        return False
    if "pro max" in t or "pro" in t or "plus" in t:
        return False
    if "256" not in t:
        return False
    return True


def _matches_kinder_joy(title: str) -> bool:
    t = title.lower()
    return "kinder joy" in t


def matches_target(product_id: str, title: str) -> bool:
    if "iphone17" in product_id:
        return _is_iphone17_256gb(title)
    if "kinder" in product_id:
        return _matches_kinder_joy(title)
    if "ps5" in product_id:
        t = title.lower()
        return ("ps5" in t or "playstation 5" in t) and not any(x in t for x in ["cover", "skin", "stand", "game", "cd"])
    return True


# ─── BFF Response Parsing ──────────────────────────────────────────────────────

def _extract_products_from_bff(bff_json: dict, products: list[dict], pincode: str, lat: float, lng: float) -> list[dict[str, Any]]:
    found_items: list[dict[str, Any]] = []
    seen_products: set[str] = set()

    for widget in bff_json.get("layout", []):
        data = widget.get("data", {})
        resolver = data.get("resolver", {})
        items = resolver.get("data", {}).get("items", [])

        for item in items:
            pr = item.get("productResponse", {})
            if not pr:
                continue

            if pr.get("outOfStock", False):
                continue

            product_info = pr.get("product", {})
            variant_info = pr.get("productVariant", {})

            name = product_info.get("name", "")
            if not name:
                continue

            for product in products:
                prod_id = str(product.get("id", ""))
                if prod_id in seen_products:
                    continue

                if not matches_target(prod_id, name):
                    continue

                price_paise = pr.get("discountedSellingPrice") or pr.get("sellingPrice") or 0
                price = price_paise // 100 if price_paise else None

                pvid = variant_info.get("id", "")
                slug = product_info.get("urlSlug")

                if slug and pvid:
                    product_url = f"https://www.zepto.com/pn/{slug}/pvid/{pvid}?pincode={pincode}&lat={lat}&lng={lng}"
                else:
                    product_url = f"https://www.zepto.com/search?query={product.get('query', name)}&pincode={pincode}&lat={lat}&lng={lng}"

                packsize = variant_info.get("formattedPacksize", "")
                variant_text = packsize if packsize else "In stock"

                found_items.append({
                    "product_id": prod_id,
                    "product_name": name,
                    "available": True,
                    "price": price,
                    "currency": "INR",
                    "variant": variant_text,
                    "specs": None,
                    "product_url": product_url,
                })
                seen_products.add(prod_id)
                logger.info("FOUND: %s | ₹%s | PIN %s", name, price, pincode)
                break

    return found_items


# ─── Main Check Function ──────────────────────────────────────────────────────

async def check_pincode(
    http_client: Any,
    pincode: str,
    products: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    global _last_error, _block_count

    lat, lng = PIN_COORDINATES.get(pincode, DEFAULT_NCR_LAT_LNG)
    page = await _get_page()
    found_items: list[dict[str, Any]] = []

    try:
        # Step 1: Update delivery location in localStorage
        await page.evaluate(f"""() => {{
            try {{
                localStorage.setItem('userLat', '{lat}');
                localStorage.setItem('userLng', '{lng}');
                localStorage.setItem('deliveryLat', '{lat}');
                localStorage.setItem('deliveryLng', '{lng}');
                localStorage.setItem('deliveryPincode', '{pincode}');
                localStorage.setItem('userPincode', '{pincode}');
                const pos = JSON.parse(localStorage.getItem('user-position') || '{{}}');
                pos.latitude = {lat};
                pos.longitude = {lng};
                pos.pincode = '{pincode}';
                localStorage.setItem('user-position', JSON.stringify(pos));
            }} catch(e) {{}}
        }}""")

        # Step 2: Ensure on search page
        if "/search" not in page.url:
            await page.goto("https://www.zepto.com/search", wait_until="domcontentloaded", timeout=15000)
            await asyncio.sleep(0.8)

        # Locate search input
        search_input = None
        for _ in range(4):
            inputs = await page.query_selector_all("input")
            for inp in inputs:
                try:
                    ph = (await inp.get_attribute("placeholder") or "").lower()
                    if "search" in ph or "product" in ph or len(inputs) == 1:
                        search_input = inp
                        break
                except Exception:
                    continue
            if search_input:
                break
            await asyncio.sleep(0.4)

        if not search_input and inputs:
            search_input = inputs[-1]

        if not search_input:
            logger.warning("Search input not found on Zepto search page for PIN %s", pincode)
            return []

        # Step 3: Check each product
        for product in products:
            prod_id = str(product.get("id", ""))
            query = str(product.get("query") or product.get("name") or "Kinder Joy")

            try:
                _bff_buffer.clear()
                _bff_event.clear()

                # Clean & type query into Zepto search input with realistic keyboard typing
                await search_input.click()
                await search_input.fill("")
                await asyncio.sleep(0.1)
                await search_input.type(query, delay=15)
                await search_input.press("Enter")

                # Wait for BFF response (max 5.5s)
                try:
                    await asyncio.wait_for(_bff_event.wait(), timeout=5.5)
                except asyncio.TimeoutError:
                    pass

                await asyncio.sleep(0.3)

                # Parse BFF response
                if _bff_buffer:
                    items = _extract_products_from_bff(
                        _bff_buffer[-1],
                        [product],
                        pincode, lat, lng,
                    )
                    found_items.extend(items)
                    logger.info("PIN %s: %s -> %d found via BFF", pincode, query, len(items))
                else:
                    # DOM Fallback
                    els = await page.query_selector_all('a[href*="/pn/"]')
                    for el in els:
                        raw_text = await el.inner_text()
                        lines = [l.strip() for l in raw_text.split("\n") if l.strip()]
                        title = lines[0] if lines else ""
                        for l in lines:
                            if matches_target(prod_id, l):
                                title = l
                                break
                        if matches_target(prod_id, title) or any(matches_target(prod_id, l) for l in lines):
                            price_match = re.search(r"[₹|Rs\.?]\s*(\d+(?:,\d+)?)", raw_text)
                            price = int(price_match.group(1).replace(",", "")) if price_match else None
                            href = await el.get_attribute("href") or ""
                            base_pdp = f"https://www.zepto.com{href}" if href.startswith("/") else href
                            sep = "&" if "?" in base_pdp else "?"
                            product_url = f"{base_pdp}{sep}pincode={pincode}&lat={lat}&lng={lng}"
                            found_items.append({
                                "product_id": prod_id,
                                "product_name": title or query,
                                "available": True,
                                "price": price,
                                "currency": "INR",
                                "variant": "In stock",
                                "specs": None,
                                "product_url": product_url,
                            })
                            logger.info("PIN %s: Found via DOM -> %s | ₹%s", pincode, title, price)
                            break

                await asyncio.sleep(0.2)

            except Exception as e:
                logger.debug("Error querying '%s' on PIN %s: %s", query, pincode, e)
                continue

    except Exception as exc:
        _last_error = f"Error on PIN {pincode}: {exc}"
        logger.warning(_last_error)
        # If page broke, mark it None so it recreates on next check
        global _page
        _page = None

    return found_items

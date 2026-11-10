# Live connector contract (authorised endpoints only)

`myzeptotracker` does not ship a secret/unofficial Zepto endpoint or attempt to bypass Akamai. The default `CHECK_MODE=demo` makes zero external product-availability requests.

To enable live mode, set `CHECK_MODE=http_json` and `CHECK_API_URL` in `backend/.env` to a **permitted, authorised JSON endpoint** that you control or are allowed to use. If it requires a bearer token, set `CHECK_API_BEARER_TOKEN`. Restart the backend. Do not paste secrets into source control or chat.

## Request

The backend sends one `POST` per valid mapped location record per scan. Concurrency is capped by `MAX_CONCURRENCY` (1–12, default 6); it is not 228 simultaneous outbound connections. Each request contains all currently enabled products, so one location request can check several products at once.

```json
{
  "location": {
    "id": "loc-0001",
    "city": "Delhi",
    "locality": "Adarsh Nagar",
    "pin_code": "110033",
    "address": "Adarsh Nagar, Delhi, Delhi - 110033"
  },
  "products": [
    {"id": "iphone17_256", "name": "iPhone 17 256GB (Any Colour)", "query": "iPhone 17 256GB", "match": {"storage": "256GB", "model": "iPhone 17"}}
  ]
}
```

## Expected response

Return HTTP 200 with JSON `items`. Only include inventory results that were positively matched at that location. The backend treats a missing product as unavailable for that scan; `available` must be an actual boolean.

```json
{
  "items": [
    {
      "product_id": "iphone17_256",
      "available": true,
      "price": 79999,
      "currency": "INR",
      "variant": "256GB • Black",
      "specs": "256GB, Black",
      "product_url": "https://www.zeptonow.com/<actual-product-page>"
    }
  ]
}
```

For PS5 variants, send `variant` such as “Slim Disc Edition” or “Slim Digital Edition”. For Kinder Joy, report `kinder_joy_regular` versus `kinder_joy_special` only when the source has verified that distinction. Do not fabricate a stock result or price. Prefer the direct product page URL returned by the permitted data source; if none is available, the app falls back to a Zepto search URL, which is not guaranteed to be a product detail page.

## Denials and limits

- HTTP 403: stop the current scan and pause all checks for the configured cooldown.
- HTTP 429: same pause; respect `Retry-After` if your connector implements it in a future version. This version deliberately does not loop/retry against a denial.
- Timeout/network error: record the error and move on. The next scan follows the configured interval.
- Do not add IP rotation, CAPTCHA solving, browser impersonation, hidden API reverse-engineering, or challenge evasion. Use a documented or explicitly authorised integration.

This interface is a standard connector contract, not a claim that Zepto exposes an official stock API. If you do not have an approved live endpoint, stay in demo mode or use the Zepto app/site manually via the product search link.

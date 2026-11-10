"""
login_zepto.py — One-time permanent Zepto Login for Zepto Tracker.
Opens the dedicated Chrome profile on your screen so you can log in once.
All cookies and sessions will be saved permanently in backend/data/chrome_profile.
"""
import asyncio
import os
import sys
from pathlib import Path
from playwright.async_api import async_playwright

PROFILE_DIR = str(Path(__file__).resolve().parent / "data" / "chrome_profile")

async def main():
    print("=" * 60)
    print("  ZEPTO ONE-TIME LOGIN SETUP")
    print("=" * 60)
    print(f"Profile Directory: {PROFILE_DIR}")
    print("\nChrome khul raha hai... Zepto par apna number daal kar OTP se login kar lo.")
    print("Jab login ho jaye, is terminal window mein ENTER press karna.\n")

    os.makedirs(PROFILE_DIR, exist_ok=True)

    async with async_playwright() as p:
        # Launch real Chrome with the persistent profile
        try:
            context = await p.chromium.launch_persistent_context(
                user_data_dir=PROFILE_DIR,
                channel="chrome",
                headless=False,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                ]
            )
        except Exception:
            context = await p.chromium.launch_persistent_context(
                user_data_dir=PROFILE_DIR,
                headless=False,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                ]
            )

        page = context.pages[0] if context.pages else await context.new_page()
        await page.goto("https://www.zepto.com/", wait_until="domcontentloaded")

        input(">>> Login hone ke baad yahan ENTER dabao to save & close: ")
        await context.close()
        print("\nSUCCESS! Login session permanently save ho gaya hai.")
        print("Ab backend bina kisi login issue ke chalega!")

if __name__ == "__main__":
    asyncio.run(main())

#!/usr/bin/env python3
"""Empirical proof a worker's headless browser actually works, end to end.

Launches headless chromium via playwright, loads https://example.com, asserts
the title, and exits 0. Anything else raises and exits nonzero — no mocks, no
"probably installed": if this passes on the instance, the browser stack is real.

Run it on a browser worker over SSM (the boot bootstrap runs the same check
inline and logs the result to /var/log/cloud-init-output.log):

    aws ssm start-session --target <instance-id>
    sudo -u fin-agent -H python3 - < browser-smoke.py   # or paste the body

Or anywhere playwright is installed:

    python3 -m pip install playwright && python3 -m playwright install chromium
    python3 browser-smoke.py
"""

from playwright.sync_api import sync_playwright


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            page = browser.new_page()
            page.goto("https://example.com", wait_until="load", timeout=30000)
            title = page.title()
            assert "Example Domain" in title, "unexpected title: " + repr(title)
            print("BROWSER SMOKE OK: headless chromium loaded example.com, title " + repr(title))
        finally:
            browser.close()


if __name__ == "__main__":
    main()

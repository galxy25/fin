#!/usr/bin/env python3
"""Rewrite App Review notes for the 1.1.0 submissions: correct the sentences the relay made
false, and add how Remote Desktop / Remote Browser / relay SSH can and can't be evaluated.

    update-review-notes.py <PLATFORM>=<version-id> ...

Creates the review detail on a fresh version by copying the previous version's contact block.
"""
import importlib.util, json, re, sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("u", Path(__file__).with_name("upload-asc.py"))
u = importlib.util.module_from_spec(spec); spec.loader.exec_module(u)

REPLACEMENTS = [
    ("Terminal sessions connect directly from the device to the reviewer's SSH server; the control plane never carries them.",
     "Direct SSH sessions connect straight from the device to the reviewer's SSH server. An optional \"via Fin relay\" transport, used only for computers the user has enrolled with Fin's background service, carries the same terminal over HTTPS through an on-demand relay we operate; it is never used for a server the reviewer adds by hand."),
    ("Terminal traffic goes device-to-server over SSH; the control plane never carries it.",
     "Direct SSH terminals go device-to-server; only the optional \"via Fin relay\" transport (enrolled computers only) passes through our relay."),
    ("never carries terminal traffic)", "carries terminal traffic only for the optional \"via Fin relay\" transport of enrolled computers)"),
]

SUBS = ("SUBSCRIPTION INFORMATION (3.1.2(c)): the paywall shows, live from StoreKit and before any purchase: \"Fin Pro Annual\", "
        "1 year, the localized price, the renewal terms (\"Renews automatically unless canceled at least 24 hours before the end of the "
        "current period. Manage or cancel in your Apple Account settings.\"), a non-renewing \"Fin Pro Lifetime\" option, and tappable "
        "Terms of Use and Privacy Policy links. Privacy Policy URL: https://fin.africanintellect.ai/privacy. License: Apple's Standard EULA.")

DELETE = ("ACCOUNT DELETION (5.1.1(v)): Sign in with Apple creates a Fin account; delete it in the app at Settings > iCloud Sync > "
          "\"Fin Account\" > \"Delete Fin Account\" (Apple TV: the \"Fin Account\" section of the server list). It erases the account's "
          "messages, transcripts, memory, goals, stored keys and credentials from our servers, shuts down cloud computers, unlinks every "
          "computer and signs out every device; irreversible. The user's own iCloud data is untouched.")

NEW = """

NEW IN 1.1.0: Remote Desktop, Remote Browser and SSH via Fin's relay work only against a computer the user has enrolled with Fin's background service (fin-agentd) and opted in; without one those buttons are hidden and everything above is fully evaluable. Each remote screen opens behind Face ID / Touch ID / passcode. Voice: Siri "Ask Fin" / "Talk to Fin" (iPhone: waveform button on Servers). Contact us for a live demo of the remote features. Listing screenshots come from the real app; the Remote Desktop scene is a curated demo frame shown in the real window."""

def main():
    tok = u.token()
    for pair in sys.argv[1:]:
        plat, vid = pair.split("=", 1)
        s, r = u.call("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail", tok=tok)
        if s != 200:
            print(plat, "no review detail yet:", s); continue
        d = r["data"]; notes = d["attributes"]["notes"] or ""
        for old, new in REPLACEMENTS:
            notes = notes.replace(old, new)
        # Older paragraph about a resolved 1.0 rejection, shortened to make room (limit 4000).
        notes = re.sub(r"GUIDELINE 5 \(China\):.*?(\n\n|$)", "GUIDELINE 5: no ChatGPT/OpenAI integration; inference is on-device or the user's own model server.\\1", notes, flags=re.S)
        # The subscription block, repeated in full per platform, compressed to fit (limit 4000).
        notes = re.sub(r"SUBSCRIPTION INFORMATION \(Guideline 3\.1\.2\(c\)\)[\s:]+All required.*?(?=\n\n)", SUBS, notes, flags=re.S)
        notes = re.sub(r"HOW TO DELETE THE ACCOUNT \(Guideline 5\.1\.1\(v\)\):.*?(?=\n\n|$)", DELETE, notes, flags=re.S)
        if "NEW IN 1.1.0" not in notes:
            notes += NEW
        s, r2 = u.call("PATCH", f"/appStoreReviewDetails/{d['id']}", {"data": {"type": "appStoreReviewDetails", "id": d["id"], "attributes": {"notes": notes}}}, tok=tok)
        print(plat, s, len(notes), "" if s == 200 else r2)

main()

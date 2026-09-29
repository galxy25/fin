#!/usr/bin/env python3
"""Apply docs/app-store/listing-*.json to the en-US localization of App Store Connect versions.

    apply-listing.py <listing.json> <PLATFORM>=<version-id> [...]  [--subtitle]

  PLATFORM  IOS | MAC_OS | VISION_OS | TV_OS   (keys of the listing's descriptions)
  --subtitle also sets the app-level subtitle (appInfoLocalization; shared by all platforms)

Only text is touched — description, keywords, promotionalText, whatsNew. Screenshots go through
upload-asc.py. ASC refuses text edits on a version that is not editable (Ready for Sale, In
Review...), so create the next version first (see create-version in this file's sibling notes).
Credentials and the JWT dance come from upload-asc.py, imported as a module.
"""
import importlib.util
import json
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("u", Path(__file__).with_name("upload-asc.py"))
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)

APP = "6801892480"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    listing = json.loads(Path(args[0]).read_text())
    tok = u.token()
    for pair in args[1:]:
        platform, version_id = pair.split("=", 1)
        s, r = u.call("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations", tok=tok)
        assert s == 200, r
        loc = next(x for x in r["data"] if x["attributes"]["locale"] == "en-US")
        # whatsNew is refused on a version's very first release; only send it when present.
        attrs = {
            "description": listing["descriptions"][platform],
            "keywords": listing["keywords"],
            "promotionalText": listing["promotional"][platform],
        }
        if listing.get("whatsNew"):
            attrs["whatsNew"] = listing["whatsNew"]
        s, r = u.call("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", {
            "data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}}, tok=tok)
        print(platform, version_id, s, "" if s == 200 else r)
    if "--subtitle" in sys.argv:
        s, r = u.call("GET", f"/apps/{APP}/appInfos", tok=tok)
        for info in r["data"]:
            s, l = u.call("GET", f"/appInfos/{info['id']}/appInfoLocalizations", tok=tok)
            for loc in l["data"]:
                if loc["attributes"]["locale"] != "en-US":
                    continue
                s, r2 = u.call("PATCH", f"/appInfoLocalizations/{loc['id']}", {
                    "data": {"type": "appInfoLocalizations", "id": loc["id"],
                             "attributes": {"subtitle": listing["subtitle"]}}}, tok=tok)
                print("subtitle", info["id"], s, "" if s == 200 else r2)


main()

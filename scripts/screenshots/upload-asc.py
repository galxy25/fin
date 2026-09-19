#!/usr/bin/env python3
"""Upload framed screenshots to an App Store Connect version via the ASC API.

    upload-asc.py <version-id> <display-type> <png...> [--replace]

  version-id    an appStoreVersions id (e.g. the macOS 1.0 version)
  display-type  APP_DESKTOP | APP_IPHONE_67 | APP_IPHONE_65 | APP_IPAD_PRO_3GEN_129
                | APP_APPLE_VISION_PRO | APP_APPLE_TV
  --replace     delete the set's existing screenshots first

Order on the store page follows the argument order. Credentials come from
~/.config/pocketdj/asc.env (ASC_KEY_ID, ASC_ISSUER_ID) and the matching .p8 under
~/.appstoreconnect/private_keys — the same team-level key every other ASC script
here uses. The upload dance is Apple's: reserve (fileName + fileSize), PUT each
uploadOperation chunk with the given headers, then commit with the MD5.
"""
import hashlib
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    env = Path.home() / ".config/pocketdj/asc.env"
    for line in env.read_text().splitlines():
        line = line.strip().removeprefix("export ")
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"'))
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    pem = (Path.home() / f".appstoreconnect/private_keys/AuthKey_{key_id}.p8").read_text()
    return jwt.encode(
        {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        pem, algorithm="ES256", headers={"kid": key_id},
    )


def call(method, path, body=None, tok=None):
    req = urllib.request.Request(
        API + path if path.startswith("/") else path,
        data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, (json.load(r) if r.status != 204 else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:600]


def localization(version_id, tok):
    s, r = call("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale", tok=tok)
    assert s == 200, r
    for loc in r["data"]:
        if loc["attributes"]["locale"] == "en-US":
            return loc["id"]
    return r["data"][0]["id"]


def screenshot_set(loc_id, display_type, tok):
    s, r = call("GET", f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?fields[appScreenshotSets]=screenshotDisplayType", tok=tok)
    assert s == 200, r
    for st in r["data"]:
        if st["attributes"]["screenshotDisplayType"] == display_type:
            return st["id"]
    s, r = call("POST", "/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type},
                "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}}, tok=tok)
    assert s == 201, r
    return r["data"]["id"]


def clear_set(set_id, tok):
    s, r = call("GET", f"/appScreenshotSets/{set_id}/appScreenshots?fields[appScreenshots]=fileName", tok=tok)
    assert s == 200, r
    for shot in r["data"]:
        call("DELETE", f"/appScreenshots/{shot['id']}", tok=tok)
        print("deleted", shot["attributes"]["fileName"])


def upload(set_id, png: Path, tok):
    data = png.read_bytes()
    s, r = call("POST", "/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": png.name, "fileSize": len(data)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}}, tok=tok)
    assert s == 201, r
    shot = r["data"]
    for op in shot["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"],
                                     headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        with urllib.request.urlopen(req, timeout=300) as resp:
            assert 200 <= resp.status < 300, resp.status
    s, r = call("PATCH", f"/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}, tok=tok)
    assert s == 200, r
    print("uploaded", png.name, f"({len(data) // 1024} KB)")


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__)
    version_id, display_type = argv[1], argv[2]
    replace = "--replace" in argv
    pngs = [Path(a) for a in argv[3:] if a != "--replace"]
    tok = token()
    loc = localization(version_id, tok)
    set_id = screenshot_set(loc, display_type, tok)
    if replace:
        clear_set(set_id, tok)
    for png in pngs:
        upload(set_id, png, tok)
    print("set", set_id, "now holds", len(pngs), "screenshots" if not replace else "screenshots (replaced)")


if __name__ == "__main__":
    main(sys.argv)

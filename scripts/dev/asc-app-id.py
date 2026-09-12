#!/usr/bin/env python3
"""App ID capabilities and the manual tvOS App Store profile, via the App Store
Connect API — the portal steps a Phase-1 (communication notifications /
SiriKit) capability change needs, scriptable and read-back-able.

    scripts/dev/asc-app-id.py caps [dev.levischoen.fin ...]
    scripts/dev/asc-app-id.py enable dev.levischoen.fin SIRIKIT
    scripts/dev/asc-app-id.py register dev.levischoen.fin.nse "Fin Notifications"
    scripts/dev/asc-app-id.py tvos-profile            # state of the fin-tv profile
    scripts/dev/asc-app-id.py tvos-profile --regen    # recreate + install if INVALID

Why this exists (review finding, 2026-09-12): enabling ANY capability on App ID
dev.levischoen.fin flips the manually-selected tvOS App Store profile
(`PROVISIONING_PROFILE_SPECIFIER` on fin-tv in project.yml, minted by name)
to INVALID, and scripts/testflight-tvos.sh then fails at archive. The fix is
to delete and recreate the profile with the same name / bundle id / cert and
install the new file under ~/Library/MobileDevice/Provisioning Profiles/ —
which is what `tvos-profile --regen` does. Run it AFTER the App ID has stopped
changing and BEFORE the tvOS leg of a ship-all-platforms wave.

Known API gap: `enable` cannot set USERNOTIFICATIONS_COMMUNICATION /
USERNOTIFICATIONS_TIMESENSITIVE — the public API's capabilityType enum does
not include them (409 ENTITY_ERROR.ATTRIBUTE.TYPE). Those two are ticked in
the Developer portal UI (Identifiers > the App ID), or added by Xcode's
automatic signing at archive time; `caps` reads them back either way.

Credentials: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH from the environment
or ~/.config/pocketdj/asc.env (the team-level key scripts/testflight.sh uses).
Nothing here prints the key, the JWT, or a profile's contents."""
import base64
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
PROFILE_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
TVOS_PROFILE_NAME = "Fin tvOS App Store (fin-tv)"


def _credentials():
    env = dict(os.environ)
    env_file = os.path.expanduser("~/.config/pocketdj/asc.env")
    if "ASC_KEY_ID" not in env and os.path.exists(env_file):
        for line in open(env_file):
            line = line.strip()
            if line.startswith("export "):
                line = line[len("export "):]
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                env.setdefault(key.strip(), value.strip().strip('"').strip("'"))
    kid, iss = env.get("ASC_KEY_ID"), env.get("ASC_ISSUER_ID")
    if not kid or not iss:
        sys.exit("set ASC_KEY_ID and ASC_ISSUER_ID (or ~/.config/pocketdj/asc.env)")
    path = env.get("ASC_KEY_PATH") or os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{kid}.p8")
    if not os.path.exists(path):
        sys.exit(f"API key not found at {path}")
    return kid, iss, path


def _token():
    import jwt  # PyJWT, same as scripts/testflight.sh

    kid, iss, path = _credentials()
    now = int(time.time())
    return jwt.encode(
        {"iss": iss, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        open(path).read(), algorithm="ES256", headers={"kid": kid},
    )


_TOKEN = None


def call(method, path, body=None):
    global _TOKEN
    _TOKEN = _TOKEN or _token()
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": "Bearer " + _TOKEN, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        return exc.code, (json.loads(raw) if raw else {})


def bundle_row(identifier):
    _, data = call("GET", f"/v1/bundleIds?filter[identifier]={identifier}")
    rows = [b for b in data.get("data", []) if b["attributes"]["identifier"] == identifier]
    return rows[0] if rows else None


def capabilities(row_id):
    _, data = call("GET", f"/v1/bundleIds/{row_id}/bundleIdCapabilities")
    return sorted(c["attributes"]["capabilityType"] for c in data.get("data", []))


def cmd_caps(identifiers):
    for identifier in identifiers or ["dev.levischoen.fin", "dev.levischoen.fin.nse"]:
        row = bundle_row(identifier)
        if not row:
            print(f"{identifier}: not registered")
            continue
        print(f"{identifier} ({row['id']}, {row['attributes']['platform']}): {capabilities(row['id'])}")


def cmd_enable(identifier, capability):
    row = bundle_row(identifier)
    if not row:
        sys.exit(f"{identifier}: not registered (use `register` first)")
    if capability in capabilities(row["id"]):
        print(f"{identifier}: {capability} already enabled")
        return
    status, data = call("POST", "/v1/bundleIdCapabilities", {"data": {
        "type": "bundleIdCapabilities",
        "attributes": {"capabilityType": capability},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": row["id"]}}},
    }})
    if status != 201:
        sys.exit(f"{identifier}: enable {capability} failed: HTTP {status} "
                 + json.dumps(data.get("errors", data))[:400])
    print(f"{identifier}: {capability} enabled; now {capabilities(row['id'])}")
    if identifier == "dev.levischoen.fin":
        print("NOTE: the tvOS App Store profile is now INVALID; run `tvos-profile --regen` before shipping tvOS.")


def cmd_register(identifier, name):
    if bundle_row(identifier):
        print(f"{identifier}: already registered")
        return
    status, data = call("POST", "/v1/bundleIds", {"data": {
        "type": "bundleIds",
        "attributes": {"identifier": identifier, "name": name, "platform": "UNIVERSAL"},
    }})
    if status != 201:
        sys.exit(f"register {identifier} failed: HTTP {status} " + json.dumps(data.get("errors", data))[:400])
    print(f"{identifier}: registered as {data['data']['id']}")


def tvos_profile():
    _, data = call("GET", "/v1/profiles?filter[profileType]=TVOS_APP_STORE"
                          "&fields[profiles]=name,profileType,profileState,uuid,bundleId,certificates"
                          "&include=bundleId,certificates")
    for profile in data.get("data", []):
        if profile["attributes"]["name"] == TVOS_PROFILE_NAME:
            return profile
    return None


def cmd_tvos_profile(regen):
    profile = tvos_profile()
    if not profile:
        sys.exit(f"no TVOS_APP_STORE profile named {TVOS_PROFILE_NAME!r}; see scripts/testflight-tvos.sh")
    attrs = profile["attributes"]
    print(f"{attrs['name']}: {attrs['profileState']} (uuid {attrs['uuid']})")
    installed = glob.glob(os.path.join(PROFILE_DIR, attrs["uuid"] + ".mobileprovision"))
    print("  installed locally" if installed else "  NOT installed locally")
    if not regen:
        return
    if attrs["profileState"] == "ACTIVE" and installed:
        print("  nothing to do")
        return
    rel = profile["relationships"]
    bundle_id = rel["bundleId"]["data"]["id"]
    cert_ids = [c["id"] for c in rel["certificates"]["data"]]
    if attrs["profileState"] != "ACTIVE":
        status, _ = call("DELETE", f"/v1/profiles/{profile['id']}")
        print(f"  deleted {attrs['profileState']} profile: HTTP {status}")
        status, data = call("POST", "/v1/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": attrs["name"], "profileType": attrs["profileType"]},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": c} for c in cert_ids]},
            },
        }})
        if status != 201:
            sys.exit("  recreate failed: HTTP {} {}".format(status, json.dumps(data.get("errors", data))[:400]))
        attrs = data["data"]["attributes"]
        print(f"  recreated: {attrs['profileState']} (uuid {attrs['uuid']})")
    else:
        _, data = call("GET", f"/v1/profiles/{profile['id']}?fields[profiles]=name,uuid,profileContent")
        attrs = data["data"]["attributes"]
    # Install by uuid (Xcode's own layout); drop any older copy carrying the same name.
    for path in glob.glob(os.path.join(PROFILE_DIR, "*.mobileprovision")):
        if os.path.basename(path) == attrs["uuid"] + ".mobileprovision":
            continue
        try:
            import subprocess
            plist = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
            name = subprocess.run(["plutil", "-extract", "Name", "raw", "-o", "-", "-"], input=plist,
                                  capture_output=True, check=True).stdout.decode().strip()
        except Exception:  # noqa: BLE001 - an unreadable profile is not ours to touch
            continue
        if name == attrs["name"]:
            os.remove(path)
            print(f"  removed stale {os.path.basename(path)}")
    os.makedirs(PROFILE_DIR, exist_ok=True)
    dest = os.path.join(PROFILE_DIR, attrs["uuid"] + ".mobileprovision")
    with open(dest, "wb") as handle:
        handle.write(base64.b64decode(attrs["profileContent"]))
    print(f"  installed {dest}")


def main(argv):
    if not argv:
        sys.exit(__doc__)
    command, args = argv[0], argv[1:]
    if command == "caps":
        cmd_caps(args)
    elif command == "enable" and len(args) == 2:
        cmd_enable(args[0], args[1].upper())
    elif command == "register" and len(args) == 2:
        cmd_register(args[0], args[1])
    elif command == "tvos-profile":
        cmd_tvos_profile(regen="--regen" in args)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

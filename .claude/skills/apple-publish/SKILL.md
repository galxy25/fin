---
name: apple-publish
description: Publish the native Fin iOS app to TestFlight from the command line (local archive → distribution-sign → upload to App Store Connect). Use when asked to "publish to testflight", "ship a testflight build", "upload to testflight", "make a testflight build", "release a beta", or to get a new build onto iPhone/iPad over the air. Sibling of apple-build (which produces local/simulator/device builds); this one does App Store Connect distribution.
---

# Publish Fin to TestFlight (iOS)

This is the **local-archive** path — build on this Mac, then push the signed `.ipa`
straight to App Store Connect. **No Xcode Cloud.** (Xcode Cloud's "Grant Access to
Your Source Code" dialog wants to clone the whole repo through GitHub's App
integration — skip it entirely; nothing here needs it.)

One command does everything — **fully headless: no Xcode GUI, no env vars, no
keychain prompts**, the same pattern already proven out on PocketDJ. Credentials
auto-load from `~/.config/pocketdj/asc.env`; signing uses the shared `pocketdj-ci`
keychain (see "Headless signing" below):

```bash
scripts/testflight.sh
```

`scripts/testflight.sh` runs: `xcodegen generate` → `xcodebuild archive` (Release,
iOS, distribution-signed via cloud signing) → `xcodebuild -exportArchive` with
`destination=upload` to deliver to App Store Connect using the API key. Build number
defaults to a unix timestamp (`CURRENT_PROJECT_VERSION`), so uploads never collide.
Unlike PocketDJ, `project.yml` / `fin.xcodeproj` live at the **repo root**, not under
an `apple/` subdirectory, so the script just `cd`s up to the repo root (one level above
its own `scripts/` directory) — there's no nested Apple-platform folder to step into.

Fin is a plain single-target iOS app (no widget extension, no CarPlay, no macOS or
visionOS target), so there's nothing here beyond this one script — no
`testflight-macos.sh` / `testflight-visionos.sh` siblings, and no extra App ID
capability to enable before archiving.

## Headless signing (the `pocketdj-ci` keychain)

Why: the login keychain's signing keys are ACL'd to require a GUI prompt, so any
detached shell (Claude, cron, CI) dies at archive with `CodeSign failed …
errSecInternalComponent`. The fix is a dedicated keychain the script fully controls:

- `~/Library/Keychains/pocketdj-ci.keychain-db` — holds an **"Apple Development:
  Created via API (C2G2V625FZ)"** identity for team `EC27UF79GL`, minted headlessly via
  the ASC API from a locally generated CSR.
- `~/.config/pocketdj/ci-keychain-pass` (0600) — the keychain's random password;
  `testflight.sh` unlocks the keychain with it at startup (keychains lock on reboot).
- The keychain is first in the user search list (`security list-keychains`), so
  xcodebuild's automatic signing picks its identity over the login-keychain one.
- The ARCHIVE step signs with that local Apple Development identity; the EXPORT step
  re-signs via **cloud signing** (Apple Distribution cert lives Apple-side, no local
  key, no prompt). Nothing ever touches the login keychain.

**This keychain is intentionally shared, not Fin-specific.** It's named `pocketdj-ci`
because PocketDJ's publish setup created it first, but the underlying cert is scoped to
Apple Developer **team** `EC27UF79GL` — Levi's one paid membership — not to any single
app. Fin's `testflight.sh` reuses it as-is (same for `~/.config/pocketdj/asc.env`,
below): don't be alarmed that a project called Fin references a keychain and config
directory named `pocketdj`; that's deliberate reuse of team-level infrastructure, not a
leftover from copy-pasting PocketDJ's script. If this cert is ever revoked/expired and
needs recreating from scratch, that procedure lives in **PocketDJ's own
`apple-publish` skill** (`~/forges/levi/pocketdj/.claude/skills/apple-publish/SKILL.md`)
— it's identical for Fin since it's the same keychain.

## Prerequisites (one-time)

1. **Full Xcode**, not just Command Line Tools. The script checks `xcodebuild -version`
   and errors with the fix if it's pointing at CLT:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. **App Store Connect App record** — Apps → ＋ → New App, bundle id
   `dev.levischoen.fin`. This is separate from the Apple Developer **App ID**
   (`dev.levischoen.fin`, id `L985VYBD9P`), which is already registered — the App
   Store Connect *app record* is a distinct one-time step on the App Store Connect
   side. As of this writing no confirmation exists that this record has been created
   yet (a parallel session was working through it via browser automation); treat it as
   the one remaining manual step if it hasn't landed. `testflight.sh` does **not**
   pre-check for it — same as PocketDJ's script — so if it's missing you'll just see
   Apple's own error at the export/upload step (something like "No suitable
   application records were found" / "app record could not be found for bundle ID
   dev.levischoen.fin"). Finish the App Store Connect step and re-run.
3. **App Store Connect API key — role MUST be `Admin`.** Cloud signing (minting the
   Apple Distribution cert + App Store profile during export) FAILS with an `App
   Manager` key: `error: exportArchive Cloud signing permission error / No profiles
   for 'dev.levischoen.fin' were found`. Fin reuses PocketDJ's existing key rather than
   minting a new one — it's a team-level credential, valid for any app under
   `EC27UF79GL`:
   - **Key ID `C2G2V625FZ`**, **Issuer ID `69a6de86-a921-47e3-e053-5b8c7c11a4d1`**,
     Admin role.
   - `.p8` already at `~/.appstoreconnect/private_keys/AuthKey_C2G2V625FZ.p8`. It's a
     private key — never commit it or paste its contents anywhere; only the Key ID /
     Issuer ID are non-secret.
4. **`~/.config/pocketdj/asc.env`** (0600) exports `ASC_KEY_ID` + `ASC_ISSUER_ID`;
   `testflight.sh` sources it automatically when the vars aren't already set — no
   manual exports, no fish config needed, and **no `fin`-specific `asc.env` to create**
   (see "Headless signing" above for why reusing the PocketDJ one is correct here).

## After upload

- Build processes server-side (~5–15 min); you get an email when it's ready.
- **Export compliance is pre-answered.** `project.yml` sets
  `ITSAppUsesNonExemptEncryption: false` on the target's Info.plist, so builds land as
  **"Ready to Submit"** with no per-build encryption question. This is the same
  standard-encryption exemption category PocketDJ's HTTPS/TLS usage falls under —
  evaluated fresh for Fin rather than copied blindly: Fin only uses standard/exempt
  encryption too (HTTPS during SPM package resolution, and SSH's own standard,
  publicly-available crypto for its core client-server protocol). It's a real export
  -compliance declaration, not just boilerplate, so worth Levi knowing it's there.
- **Internal Testing access is unverified on first run.** PocketDJ auto-distributes to
  a named "Alphas" internal-testing group with Build Distribution set to "Automatic
  for Xcode Builds." Fin has no such group configured yet, and no precedent for
  whether App Store Connect's default Internal Testing (the account holder is
  automatically a member of the team's default internal group) is enough to get a
  single-developer build onto Levi's own device without setting one up explicitly.
  Treat this as something to check after the first successful upload — if the build
  doesn't show up in the TestFlight app, go to App Store Connect → TestFlight →
  Internal Testing and confirm Levi's Apple ID is added as a tester.

## Versioning

- **Build number** auto-increments (unix timestamp) — fine for iterating within a
  version.
- **Marketing version** is `MARKETING_VERSION` in `project.yml` (currently `1.0.0`).
  Bump it when you want a new user-facing version, then run the script.

## Troubleshooting

- **`Cloud signing permission error` / `No profiles for 'dev.levischoen.fin'`** → the
  API key isn't `Admin`. Recreate it with the Admin role (see prereq 3), or confirm
  `C2G2V625FZ` is still Admin under Users and Access → Integrations.
- **`No suitable application records were found` / app record not found for
  `dev.levischoen.fin`** → the App Store Connect app record (prereq 2) doesn't exist
  yet. Create it: Apps → ＋ → New App, bundle id `dev.levischoen.fin`.
- **`accessing build database ...build.db: disk I/O error` / `*.dependency-scan.dia` /
  `fin-dependencies-*.json doesn't exist`** → corrupt DerivedData (often from an
  interrupted prior archive). Clear it and retry:
  ```bash
  rm -rf ~/Library/Developer/Xcode/DerivedData/fin-*
  ```
- **`method` value rejected by `-exportArchive`** → Xcode 26 wants `app-store-connect`
  (already used in the script). On older Xcode change it to `app-store` in
  `testflight.sh`'s ExportOptions heredoc.
- **Exit 0 but it actually failed** → don't pipe the script through `tail` (that masks
  the real exit code). Run it directly; `set -euo pipefail` then surfaces failures.
- **Archive `CodeSign failed … missing Xcode-Username`** → the ARCHIVE step had no API
  key, so `-allowProvisioningUpdates` looked for an Apple ID signed into Xcode (none,
  headless). `testflight.sh` already passes `-authenticationKey{Path,ID,IssuerID}` to
  the archive step too (cloud signing), so this shouldn't recur unless those flags get
  dropped in an edit.
- **Archive `CodeSign failed … errSecInternalComponent`** → codesign can't use the
  signing key non-interactively. Check the `pocketdj-ci` keychain (see "Headless
  signing"): is it in `security list-keychains`? Does `security find-identity -v -p
  codesigning ~/Library/Keychains/pocketdj-ci.keychain-db` show the "Created via API"
  identity as valid? Is `~/.config/pocketdj/ci-keychain-pass` present (the script
  unlocks with it)? This is the same keychain PocketDJ's build uses, so if it's broken
  here it's broken for PocketDJ too — fix it once, both projects benefit.

## Related

- **apple-build** skill — local/simulator/device builds (no distribution).
- `scripts/testflight.sh` — the pipeline itself.
- PocketDJ's **apple-publish** skill — the shared `pocketdj-ci` keychain and
  `~/.config/pocketdj/asc.env` are documented there in full (from-scratch recreation
  steps, etc.); Fin just reuses them.

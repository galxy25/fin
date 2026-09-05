# Fin

**Fin is a terminal agent with a voice interface and resilient distributed
decentralized consensus cloud brain.** The interface pillar is voice AND the
native apps (iOS and macOS; tvOS/visionOS ride along). This is the product
framing for ALL app-submission materials and features — copy, screenshots,
review notes, and feature priorities should reinforce it, not dilute it.
(Standing directive from Levi, 2026-09-05.)

## What that means concretely

- **Terminal agent** — the core loop: an agent that reads terminal output and
  acts on sessions (`fin/Agent/AgentRuntime.swift`, shared with the headless
  `fin-agentd` daemon via `daemon/Sources/FinAgentCore`).
- **Voice interface** — Siri/App Intents deliver dictated messages into the
  agent's inbox (`fin/Intents/`); voice is a first-class input, not a bolt-on.
- **Cloud brain** — the cloud harness + S3 supervision/inbox/transcript channel
  and the Lambda control plane (`scripts/cloud-agent/`), designed to survive
  any single device going away.

## Repo facts that save time

- Project is **XcodeGen-generated**: edit `project.yml`, then `xcodegen
  generate`. Never hand-edit `fin.xcodeproj`.
- Multiplatform target `fin` (iOS 17+/macOS 14+/visionOS) + separate `fin-tv`
  target (vendored headless SwiftTerm engine). macOS builds are
  **arm64-only** (Wax→MetalANNS has no x86_64); use
  `-destination 'platform=macOS,arch=arm64'`, not generic.
- Tracked filename is `fin/finApp.swift` (lowercase f) — case-insensitive
  filesystem will happily read `FinApp.swift`, but `git add` needs the real
  path.
- TestFlight: `scripts/testflight.sh` (iOS), `-tvos.sh`, `-macos.sh`,
  `-visionos.sh`. Build numbers auto-increment from ASC. See the
  `apple-publish` skill for signing/keychain details.
- App Store Connect app id 6801892480, bundle `dev.levischoen.fin` (universal
  purchase, all platforms).
- No pushes or App Store submissions without Levi's explicit word.

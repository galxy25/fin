# Recording the Apple TV demo for App Review

**Update 2026-09-18 (submission `933fad82`, rejected 2.1 + 2.1(b)).** The ask got
sharper. Apple now wants "a demo video that shows a physical Apple device and the
designated hardware pairing together and interacting during the use of the app" —
they read the SSH server (your Mac) as "designated hardware". Concretely:

- The app running on a **physical Apple TV, not a simulator**.
- "The initial pairing process between the app and the designated hardware" — for
  Fin that is: the server appearing in the list (iCloud sync) and the first connect.
- "The entire app workflow with the designated hardware", filmed so **both** the Apple
  TV's screen and the Mac it is driving are visible. A phone-camera video of the room
  (TV on one side, Mac screen on the other) satisfies this literally; a QuickTime
  mirror of the TV alone (Option A below) shows only half of what they asked for.
- Delivery is a **link** in App Review Information (Distribution → tvOS → App Review
  Information → Notes/Attachment), THEN a reply to the message — not a reply
  attachment alone. iCloud Drive share link, unlisted YouTube, or the Attachment field.

The original notes below still apply for what to show and in what order; Option A
remains the easy way to capture the TV half if you want a clean second angle.

Apple asked for "a screen recording captured on a physical device, running the
latest operating system, demonstrating the app's functionality," starting with
launching the app. tvOS has no built-in screen recorder, so the capture happens
on the Mac over the network. Two ways; the first is the one to try.

## Option A — QuickTime Player on the Mac (no cable, no extra software)

The Apple TV must be on the same Wi-Fi as the Mac, and both signed into the
same Apple Account.

1. On the Apple TV: Settings ▸ AirPlay and HomeKit ▸ AirPlay ▸ **on**. Also
   check Settings ▸ AirPlay and HomeKit ▸ Allow Access is "Anyone on the Same
   Network" (or "Everyone") while recording, so the Mac can pair without a
   code dance.
2. On the Mac: open **QuickTime Player** ▸ File ▸ **New Movie Recording**.
   A camera window opens — ignore the picture.
3. Hover the window, click the **∨ chevron next to the red record button**, and
   under *Screen* (or *Camera* on older builds) choose **your Apple TV** by
   name. Under *Microphone* choose None unless you want to narrate.
4. The Mac window now mirrors the TV. If the TV asks for a 4-digit AirPlay
   code, type it into the Mac prompt.
5. Press **record**, drive the TV with the Siri Remote, press **stop**.
6. File ▸ **Save** ▸ name it `fin-tvos-review.mov` and save to **Desktop**.

If the Apple TV does not appear in that menu: restart QuickTime with the TV
already awake, or use Option B.

## Option B — the Apple TV Simulator (fallback only)

Apple explicitly asked for a physical device, so use this only if Option A
cannot be made to work, and say so in the reply.

Run in Terminal:

```sh
xcrun simctl list devices | grep -i "Apple TV"
xcrun simctl boot "Apple TV 4K (3rd generation)"
open -a Simulator
xcrun simctl io booted recordVideo ~/Desktop/fin-tvos-review.mov
# drive the app, then press Ctrl-C in that Terminal window to stop
```

## What to show, in this order

Apple's list, applied to Fin. Aim for 60–120 seconds, no dead air longer than
a couple of seconds.

1. **Launch from the Home screen.** Start with the TV on its Home screen and
   open Fin from the icon, so the recording "begins with launching the app."
2. **The account.** In the Fin Account section, show **Sign in with Apple**
   (or, if already signed in, "Synced with your Fin account: N servers, N
   agents, N keys"). This is the account-registration flow they asked about.
3. **Delete Account.** Move focus to **Delete Fin Account** and open the
   confirmation dialog so the text is readable, then press **Cancel**. Do not
   confirm — this demonstrates Guideline 5.1.1(v) without wiping your account.
4. **The server list synced from iCloud.** Show at least one server appearing
   that you added on the iPhone or Mac.
5. **Connect and use the terminal.** Open a session, let the terminal draw,
   type a visible command (`uname -a`, `ls`, or `top` for motion) with a
   Bluetooth keyboard or the iPhone as keyboard.
6. **The agent view and control strip**, briefly.
7. **No purchase on Apple TV** — nothing to show; the reply already says
   purchases happen on iPhone/iPad/Mac.

There is no user-generated content and no content reporting to show, and no
account registration of our own beyond Sign in with Apple.

## Getting the file to App Review

The recording lands on your Desktop as a `.mov`.

- Keep it under ~50 MB if you can. If QuickTime's file is large, trim dead
  time: open in QuickTime ▸ Edit ▸ Trim, or ask me and I'll compress it with
  `ffmpeg` to a smaller `.mp4`.
- Tell me the path (e.g. `~/Desktop/fin-tvos-review.mov`) and I will attach it
  to the tvOS App Review thread with a short follow-up message, the same way
  the paywall evidence video was attached on 2026-09-11.
- If you would rather attach it yourself: App Store Connect ▸ Fin ▸
  Distribution ▸ App Review ▸ the tvOS submission ▸ **Reply to App Review** ▸
  **Attach File**.

## Note on which submission it goes to

The tvOS submission carrying Apple's Guideline 2.1 message is `7cb34c59`
(our written reply is already on it). Today's resubmission with the
account-deletion build is a new submission, `4d4be311`. Apple sees both in the
app's history; attach the recording to whichever thread has a **Reply to App
Review** button when you get there, and mention the build number
**1789482238** in the message so there is no ambiguity about what was recorded.

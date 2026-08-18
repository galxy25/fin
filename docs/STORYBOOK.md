# Fin

*A storybook walkthrough*

## What Fin is

Fin is a terminal on your phone. Not a file manager with a terminal bolted on, not an IDE, not a system dashboard with graphs and widgets — just a way to SSH into a server and see the same green-on-black screen you'd see at a desk, plus a companion mode for reading and editing a markdown file. It's built for someone who already knows what a terminal is and just wants it in their pocket: an admin checking on a box, a developer tailing logs from the couch, someone reattaching to a `tmux` session they left running.

The whole app is built around one idea: open it and you're back where you were. Not a home screen you have to click through — the actual session or file you were last looking at, already there.

By default the screen is black with green text, the classic terminal look, but every color is yours to change. There's no theme catalog to pick from — just two color wells: background and text.

---

## First run: getting a key in and a server added

The very first time you open Fin, there's nothing to resume to, so you land on the **Home** screen: a segmented control at the top switches between **Terminal** and **Markdown**, and under it — since Terminal is selected by default — an empty list with a plain message: *No Servers. Tap + to add one.*

### Adding a server

Tapping **+** opens a form: **Name**, **Host**, **Port** (pre-filled with `22`), **Username**. Nothing exotic yet — this is the same information you'd put in an `~/.ssh/config` block.

Below that is **Private Key**, with a picker (starting on "None") and a button: **Import Key from Files…**

### Importing a key

Tapping that opens a dedicated import screen. It starts with one button — **Choose from Files / iCloud** — which hands you the standard iOS document picker. You're not limited to a special "keys" folder; you can reach anywhere Files can reach, including iCloud Drive, so if you keep your key synced there, it's right there.

Once you pick a file, Fin reads it as text and tries to parse it as a private key — first as an ed25519 key, then as an RSA key. If it recognizes the format, you'll see a green checkmark and a line like *Detected ed25519 key*, and two more fields appear: a passphrase field (leave it blank if the key isn't encrypted) and a name field, which is pre-filled from the file's name but yours to change.

Here's the real constraint, worth knowing up front rather than discovering it as an error: **Fin only understands the modern OpenSSH private-key format** — the kind that starts with `-----BEGIN OPENSSH PRIVATE KEY-----` — and only for ed25519 or RSA keys. If you generated your key with a recent `ssh-keygen` and didn't do anything special, you're fine. If it's an older-style key (the kind that starts `-----BEGIN RSA PRIVATE KEY-----`), a key in PKCS#8 form, a DSA or ECDSA key, or you accidentally picked the `.pub` public-key file instead of the private one, it won't parse, and you'll see a plain-spoken explanation rather than a code: *"Couldn't read this key. Only OpenSSH-format ed25519/RSA keys are supported — check the passphrase, or the key format."* If your key is passphrase-protected, that same message is also what you'll see if you forgot to type the passphrase first — enter it and tap **Retry with Passphrase** to try again.

Once a key is detected, **Save** stores the raw key (and passphrase, if you gave one) in the iOS Keychain, locked to this device — it doesn't sync via iCloud Keychain, and nothing about it is visible anywhere else in the app once it's saved. You're dropped back on the server form with your new key already selected.

### The Advanced section

Below the key picker is a collapsed **Advanced** disclosure group. Most servers won't need it, which is why it starts closed. Opening it reveals two things:

- **tmux session name** — a plain text field, defaulting to `main`.
- **Connect command** — a free-form, multi-line text field, with a caption underneath explaining what it does: *"Sent as if typed, right after connecting. Leave blank to just open a plain shell — e.g. if the server already auto-attaches tmux/mosh on login."*

That's the whole mechanism: whatever you type there gets typed into the shell, followed by Enter, the instant the connection is live — before you see a single character of output. If you leave it blank, Fin just opens a plain shell and gets out of the way.

When you'd want to leave it blank: your server already drops you into a persistent session automatically — a shell profile that runs `tmux attach` or starts `mosh` on login. In that case, typing anything yourself would just be redundant input the shell has to eat.

When you'd want to fill it in: you want Fin itself to land you in a specific, reattachable `tmux` session every time, regardless of what the server's login profile does. There's a one-tap shortcut for exactly this — a button reading **Use "exec tmux new-session -A -s main"** (using whatever name you put in the field above it) that fills the connect command in for you. `-A` is the important part: it attaches to that session if it already exists, or creates it if it doesn't, so the same button works whether this is your first connection or your fiftieth.

Tap **Save**, and the new server appears in your list with a gray dot next to it — not connected yet. Tap the row, and Fin connects.

Each row also has its own small pencil-in-a-circle button, separate from the row itself — tap it to reopen this same form, pre-filled with that server's current name, host, port, username, key, and Advanced fields, so you can change anything later without deleting and recreating the server. Swipe left on a row to delete it outright.

---

## Being in a session

When you tap a server, or Fin resumes one for you, you land on the terminal screen: a thin control strip along the top, and the terminal filling the rest.

### The control strip

On the left: a status dot — green means connected, yellow means connecting or reconnecting, red means disconnected — and next to it, the server's name. Those stay put no matter what else you do with the strip.

The rest of the strip is a fixed row of five icons — nothing to swipe or page through, they're all there at once:

- **An exit button** — a red X in a circle. This one is worth calling out specifically: it's tappable *at any point*, including in the middle of connecting or reconnecting. A stuck or wrong connection attempt is never a dead end you have to force-quit your way out of; the X always works.
- **A server-switcher icon** (a little rack icon) that opens the same Home screen you saw on first run, as a sheet, right on top of your session. Tap a different server there and you're connected to it — your original session isn't closed, just set aside; switch back to it the same way.
- **A clipboard icon**, opening the clipboard manager (below).
- **A paint-palette icon**, opening theme settings (also below).
- **A lines icon** (three stacked horizontal lines) that opens a small dropdown menu with two options, **Page Up** and **Page Down**. These send the same key codes a physical keyboard's Page Up/Page Down keys would, which makes them useful for scrolling through anything running in the terminal that reads page-navigation keys — `less`, `vim`, a long `man` page, that sort of thing, where swiping or dragging the scrollback doesn't help because the program itself is in control of what's on screen. Tap whichever one you want; the menu closes itself.

### The terminal itself

Below the strip is the actual terminal — a real scrollback buffer, real cursor, rendered in whatever background/text colors you've set. Text output from the remote shell streams in live.

You can select text the normal iOS way — press and hold, drag the handles, and copy. Anything you copy this way is automatically saved into Fin's own clipboard manager under **From** — you don't have to do anything extra to keep it. The same happens for anything a remote program pushes to the system clipboard on its own behalf (for example, a `tmux` copy-mode selection); it lands both on the system pasteboard and in **From**.

### The keyboard accessory row

The row of keys — Ctrl, Esc, Tab, and four arrows — sits directly above your iOS keyboard whenever the terminal has focus, and is present for exactly the reason you'd expect: terminals lean hard on keys the iOS keyboard doesn't have a dedicated button for.

Esc, Tab, and the arrows send their bytes immediately when tapped. **Ctrl** works differently — tap it, and it highlights to show it's armed; the *next* letter you type is sent as a control combination instead of being typed literally. Tap Ctrl, then C, and the terminal receives Ctrl-C, not the letter "c". It covers the standard range of control combinations (Ctrl-A through Ctrl-Z and a few neighbors), and it disarms itself automatically after that one keystroke, so you don't have to remember to turn it back off.

---

## The clipboard manager

Tapping the clipboard icon opens a two-tab view: **To** and **From**.

**From** is where anything copied out of the terminal shows up automatically, newest first — the capture described above. There's no add button on this tab; it fills itself in as you use the terminal.

**To** is the opposite direction: things you want to send *into* the terminal. This tab does have an add button (**+**), which opens a small form — a **Name** field, defaulted to the current timestamp if you don't bother typing one, and a text box for the content itself. Save it, and it joins the **To** list.

In either tab, tapping any saved clipping sends its text straight into the terminal, exactly as if you'd typed it, and closes the clipboard sheet so you're back looking at the result. Swipe left on any entry, in either tab, to delete it.

This is the practical use case: a long, easy-to-mistype command, a path you paste often, a snippet you keep reusing across servers — save it once under **To**, and it's one tap away from then on, instead of retyping it (badly) on a phone keyboard.

---

## Markdown mode

Flip the segmented control on the Home screen from **Terminal** to **Markdown**, and the list underneath changes to your markdown files, sorted by whichever you opened most recently.

### Opening an existing file vs. starting a new one

The **+** button here is a menu with two options:

- **New File** hands you the standard iOS save panel — pick a location (including iCloud Drive), and it defaults to the name `Untitled`. As soon as you confirm, Fin creates the (empty) file, adds it to your list, and — distinctly from opening an existing file — drops you straight into it, already in **edit** mode, cursor ready.
- **Open Existing File…** hands you the standard file picker instead. Any file works, technically, but it's meant for `.md`/text files, since anything that isn't readable as plain text will show a load error later when you try to open it. Picking a file just adds it to your list (or, if you've opened that exact file before, just bumps it back to the top) — it doesn't jump you into it. You tap the row afterward, same as any other file.

Swipe left on any file in the list to remove it — this only drops it from Fin's list, it doesn't delete the actual file.

### Reading vs. editing

Tap into a file and you get a rendered view by default: a pencil icon in the toolbar switches you into a plain text editor; tap the checkmark that takes its place to save and go back to the rendered view. The editor is a real, native text view — the same select, copy, cut, and paste gestures you'd use in any iOS text field work here, not some custom stand-in. Rendering in the non-edit view covers inline styling — **bold**, *italics*, links, `inline code` — but block-level markdown (headers, bulleted lists, fenced code blocks) isn't specially formatted; a line starting with `#` or `-` shows up with that character still visible, rather than turning into a big heading or a bullet. Text is selectable in the rendered view too, the same press-and-hold-to-copy you'd expect. If you navigate away mid-edit without tapping the checkmark — hitting the back button, say — Fin saves for you anyway; nothing is lost to a missed tap.

### The same live color customization

The reader has its own paint-palette icon in the toolbar, opening the identical theme sheet you'd reach from a terminal session — same two color wells, same reset button. Change it here and it applies everywhere, described next.

---

## It remembers where you were

This is the thing you'll notice most: switch away from Fin and back, or force-quit it and relaunch from scratch, and you land exactly where you left off — not a home screen, not a server list, but the actual terminal session or the actual markdown file you were using.

Fin doesn't favor one mode over the other. It genuinely tracks both at once — a terminal session and a markdown file can each be "the thing you were just using" — and shows you whichever of the two you actually touched more recently. Connect to a server, and that claims the spot. Open a file and read or edit it, and *that* claims the spot instead. Bounce back and forth between a session and a file a few times, and Fin always resumes into whichever one you touched last, not whichever one you happened to touch first or use more.

If the thing you land back on is a terminal session, Fin reconnects it for you automatically the moment the app comes back to the foreground — you'll see the status dot flash yellow for a moment, then settle to green, and if your server's connect command reattaches a `tmux` session, you're looking at the same running shell you left, scrollback and all, without touching anything. If it's a markdown file, it's just there, rendered and ready. Switching between two things you're using — say, hopping to a different server via the switcher, or backgrounding the app briefly — is instant on top of that, because a live terminal (scrollback, cursor, everything) is kept alive in memory the whole time you're actively using the app; nothing reloads.

Two things intentionally don't count as "touching" something. Explicitly leaving a session or file — tapping the red exit button, or tapping the list icon on the file screen Fin resumed you into — hands the resume spot back to whatever you were using before, or to the plain Home screen if there's nothing else. (That list icon only shows up on a file reached this way — resumed into as the app's starting screen; a file you tap into from the Markdown list, or the one you're dropped into right after creating it, doesn't have it, since leaving those just means navigating back or dismissing a sheet.) And glancing at a file through the control strip's server-switcher sheet while a session is still going underneath doesn't steal the spot out from under that session, either — a quick peek isn't the same as switching to it.

---

## Theming

One settings sheet, reachable from either the terminal's control strip or the markdown reader's toolbar (same paint-palette icon in both places): a **Background** color well and a **Text** color well, each opening the full iOS color picker — any color you want, not a preset list. A **Reset to Classic Green on Black** button puts it back to the defaults, black and green.

There's only one theme setting for the whole app, not one per server or per file. Change it from inside a terminal session, and the next markdown file you open uses it too, and vice versa — background and text color are shared, live, across both modes.

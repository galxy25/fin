# Xanadu mode

Levi, 2026-11-06: *"a new central landing page, which is just the current
conversation thread … a single pane in the app that I can go to to just have a
conversation … for Siri to have a conversation and to be able to see that
transcript and make a threaded reply or follow-up … display and accept images
and audio and other files … 'hey Siri, share this file with Fin to have it
analyze it and give me a breakdown of cost by quarter' … we can call this the
Xanadu mode, because it's the original version of the worldwide web, where
everything should be a link to a link to a link forward."*

Xanadu is the **landing pane**: one current thread, its whole transcript, a
composer that takes text, photos, files and voice recordings, and Siri as a
peer participant in the same thread. Every item in the transcript is a link
forward — an attachment opens its content, a URL opens the in-app browser,
a thread mention opens that thread.

Decisions (Levi, 2026-11-06):

1. **Default landing** on iPhone, iPad, Mac, Vision Pro. Terminal / Markdown /
   Agents stay one tap away. Siri always lands on the current thread here.
2. **Files go to disk, the agent works them.** An attachment is uploaded to S3,
   the site that claims the message downloads it into a per-thread folder, and
   the turn prompt names the path; Fin uses its terminal tools (python, pandas,
   `pdftotext`, …) on it. Works with any brain. Images additionally ride to the
   model as image parts when the site's config says the model can see
   (`agent.supportsImages`). Audio is transcribed on the device and the
   transcript travels with the file.
3. **Siri AI ships like PocketDJ 1.0.4**: `ToolIntent` conformances compile only
   with the Xcode 27.3 beta SDK (`canImport(AppIntents, _version: 301.2) &&
   !os(tvOS)`), i.e. the internal TestFlight build. The App Store build still
   gets Xanadu, attachments and the thread-aware intents.

## The current thread

`XanaduCurrentThread` (app, shared with intents through the App Group
defaults): the thread id Xanadu is showing, per agent. Rules:

- Opening a thread anywhere in the app makes it current.
- A message sent from Xanadu or by a Siri intent **without an explicit thread**
  goes into the current thread (a follow-up), unless the user asks for a new
  thread ("new thread" button / `StartFinThreadIntent`).
- A brand-new thread's id is its root message id, so the sender knows it
  immediately and makes it current.

## Wire contract

### Upload — `POST /attachments`

Request `{agent, name, mime, size}`; `size` ≤ `MAX_ATTACHMENT_BYTES`
(25 MiB). Response:

```json
{"key": "users/<user>/fin/attachments/<agentSlug>/<uuid>/<safeName>",
 "putUrl": "<presigned PUT>", "headers": {"Content-Type": "<mime>"}}
```

The app PUTs the bytes to `putUrl` with exactly those headers, then sends the
message. `safeName` is `name` reduced to `[A-Za-z0-9._-]`, ≤ 96 chars, never
empty (`file`), extension kept.

### Message — `POST /messages`

Gains an optional `attachments` array (≤ 8 entries):

```json
{"key": "<from POST /attachments>", "name": "Q3 costs.xlsx",
 "mime": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
 "size": 48213, "transcript": "optional, audio only, ≤ 8000 chars"}
```

- `key` must start with `users/<caller>/fin/attachments/` (else 400) and the
  object must exist (HEAD; else 400 "attachment not uploaded").
- `text` may be empty when `attachments` is non-empty.
- Stored on the message row as-is.

### Read — `_public_message` (GET /messages/{id}, GET /threads/{id} messages)

Each stored attachment is returned with a fresh presigned GET: the entry above
plus `"url": "<presigned GET>"`. Rows without attachments return `[]`.

### Heartbeat offer

Each offered message gains `attachments`: the same entries with `url`
(presigned GET). Absent/empty when none.

### Site (fin-agentd)

On claiming a message with attachments, before the turn:

- Download each `url` into
  `<attachmentsRoot>/<threadId-or-messageId>/<safeName>` where
  `attachmentsRoot` defaults to `~/Fin/Attachments` (config
  `agent.attachmentsDirectory`). A name clash in the folder gets ` (2)`, ` (3)`…
- Append to the user turn prompt:

  ```
  Attached files (saved on this machine — work with them using your terminal tools):
  - /Users/…/Fin/Attachments/m-…/Q3_costs.xlsx (spreadsheet, 47 KB)
  - /Users/…/voice-note.m4a (audio, 1.2 MB) — transcript: "…"
  ```

- If `agent.supportsImages` is true, each `image/*` attachment ≤ 5 MiB is also
  sent to the model as an OpenAI-style `image_url` content part (data URL) on
  that user message. History trimming drops image parts before text.
- A download failure does not drop the message: the prompt line says
  `(download failed: <reason>)` so Fin can tell the user.

## Siri

- **Ask Fin / Tell Fin** take an optional thread (`FinThreadEntity`); none ⇒
  the current thread. Replies land in that thread.
- **Share with Fin** (`ShareFilesWithFinIntent`): `files: [IntentFile]` +
  optional request text ("give me a breakdown of cost by quarter"). Uploads,
  sends into the current thread, opens Xanadu.
- **Start a new thread** (`StartFinThreadIntent`).
- **Open Xanadu** (`OpenXanaduIntent`) / Spotlight open of a `FinThreadEntity`.
- `FinThreadEntity` carries title, status, last reply and a recent-transcript
  property so Siri can answer about what's on screen; Xanadu publishes it as
  onscreen context (`NSUserActivity.appEntityIdentifier`) so "reply to this" /
  "what did Fin say" resolve to the visible thread.
- 27.3 SDK only: `ToolIntent` conformances for Ask, Tell, Share, Start Thread;
  `SnippetRepresentableEntity` for `FinThreadEntity`.

## Fin replies with files (v1.1, 2026-11-06)

### Site upload — `POST /sites/{siteId}/attachments`

Site-authenticated (bearer + `X-Fin-Site`, like the heartbeat). Request
`{messageId, name, mime, size}`; the message must be claimed by this site.
Response is the same shape as `POST /attachments` (`key`, `putUrl`,
`headers`), key under the message owner's
`users/<user>/fin/attachments/<agentSlug>/<uuid>/<safeName>`.

### Answered ack

The site's `answered` state update gains optional `replyAttachments` (≤ 8,
entries `{key, name, mime, size}`, same validation as user attachments: owner
prefix + HEAD). Stored on the row as `replyAttachments`.

- `_public_message` returns `replyAttachments` (each with a fresh `url`; `[]`
  when none) beside `attachments`.
- The `message.answered` thread event carries `replyAttachmentCount`.
- The reply push / Live Activity preview appends `📎 <first name>` (+N) when
  the reply text is empty or the reply carries files.

### Daemon

- New tool `attach_file` (`{path, name?}`) available in message turns: queues a
  file on this machine to go back with the reply (≤ 25 MiB, regular file,
  readable; refusal text otherwise). Max 8 per turn.
- On the answered ack: upload each queued file via the site route, include
  `replyAttachments`. An upload failure is reported in the reply text
  (`(couldn't attach <name>: <reason>)`), never drops the reply.
- The cloud transcript's assistant turn gets the same trailing
  `[Attached: <name> (<kind>, <size>), …]` line as user turns.
- System prompt: one line telling Fin it can hand files back with
  `attach_file` (charts, exports, reports).

### App

Xanadu, the remote console and tvOS render `replyAttachments` under Fin's
reply exactly like user attachments (tvOS read-only: images + file rows, no
open/share).

## Orphaned uploads

The sweep deletes objects under `users/*/fin/attachments/` older than
`MESSAGE_RETENTION_DAYS + 1` days (the rows that referenced them are gone by
then; never-sent uploads die the same way). Runs at most once a day.

## Share extension (v1.1)

`fin-share` (iOS + macOS share extension): system share sheet → Fin. Takes
files / images / URLs / text, optional note, sends into the user's current
Xanadu thread through the same upload-then-send flow. Needs the app's
control-plane credentials and the current-thread key shared through an App
Group + shared keychain access group.

## Not in v1

- The app's local (in-process) runtime path: attachments need the control
  plane; Xanadu says so instead of silently dropping them.
- tvOS: attachments read-only, no composer attachments.

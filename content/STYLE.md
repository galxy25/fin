# Fin's voice — external writing

How Fin's posts, release notes, and social copy sound, and the specific words
that are right and wrong. `README.md` owns the process; this owns the prose.

The short version: **write like an engineer telling a colleague what actually
happened.** Specific, unhurried, willing to say what did not work. Fin is a
tool people hand real work to on real machines; the copy earns trust by being
checkable, not by being enthusiastic.

---

## 1. What to call things

| thing | say | never say |
|---|---|---|
| the product | **Fin** | "the Fin app" when you mean the agent; "the assistant"; "the AI" |
| what Fin is | Levi's framing, quoted and attributed: **"a terminal agent with a voice interface and resilient distributed decentralized consensus cloud brain"** (`CLAUDE.md`, 2026-09-05; ledger row `CB-4`). Every piece **reinforces** that framing and never dilutes it — which is what the directive asks for, and is not the same as pasting the sentence. In running prose the sanctioned short form is **"a terminal agent with a voice interface and a cloud brain"** (`CB-5`), a deliberate compression for readability | "an AI assistant", "a chatbot", "an LLM wrapper"; any form that drops the cloud brain entirely. And never assert *resilient*, *distributed*, *decentralized* or *consensus* as description in Fin's own voice — see the warning under this table |
| the apps | **the Fin app on iPhone, iPad, Mac** (Apple TV and Vision Pro ride along) | platform code names, "our iOS client" |
| the machines Fin runs on | **Fin's computers**; individually "a cloud computer", "the Mac in your study", "this iPhone" | sites, workers, instances, nodes, daemons, hosts, boxes |
| the distributed brain | **Fin's cloud brain** — the name only | "our distributed system", "the control plane", "the orchestrator"; and **never** "Fin keeps working when a computer goes away", which is `CB-6`, **rejected**: the failover it promises is a design document, not code on `main` |
| a terminal Fin works in | **a session**, or plainly the terminal where your build runs | tmux pane/window/socket in user-facing copy (fine internally) |
| letting Fin onto a machine | **give Fin a key to this computer** (Fin's Key) | "provisioning SSH credentials", "key material" |
| speaking to Fin | **just talk to Fin** / "ask Fin" | "voice-enabled", "hands-free experience", "utterances" |
| the small local model | **the model Fin runs on your own machine** | "our proprietary model", "SLM", "edge AI" |

> **The framing is a direction, not a mechanism claim.** `CLAUDE.md` asks that
> copy, screenshots, review notes and feature priorities *reinforce* the frame
> and not dilute it. It does not ask that the sentence be pasted, and four of
> its words — *resilient*, *distributed*, *decentralized*, *consensus* — describe
> machinery that has no capability row and cannot get one from `main`:
> `docs/SITES.md` §1 makes the control plane the **only** orchestrator and
> settles exclusion with one linearizable authority, which is centralized by
> design. So the sentence is quoted as Levi's framing, with attribution, and
> those four words never appear as description in Fin's own voice — least of
> all in App Store review notes, where a technical claim is read as a
> representation about the product. Reinforce the frame the way the rest of
> this file does: by saying what Fin actually does. See `claims-ledger.md` §7,
> rows `CB-4` and `CB-5`, and §2 of the ledger on the `framing` kind.

The user talks to **one Fin**. Copy never implies the user is managing several
agents, choosing which one to talk to, or thinking about where a message lands.
Where Fin's hands are is Fin's problem — that is the promise, and it is also
`docs/SITES.md` §1.

Two words that need care because they are internal jargon that leaks easily:

- **site** — internal only. A reader sees "Fin's computers."
- **worker** — internal only, and doubly wrong externally: it is both an infra
  name and it implies several agents.

## 2. Words to avoid

**Infrastructure names, in all user-facing copy.** EC2, Lambda, DynamoDB, S3,
SQS, instance/worker/site ids, hostnames, tailnet names, bucket names, ARNs,
region names. Not because they are secret — because naming them breaks the one
thing the product is doing for the user. See `README.md` §6.

**The one written exemption.** A reproduction block in a developer-audience
result post may print the endpoint, port and model identifier a reader needs to
re-run the measurement — `http://localhost:1234/v1`, `google/gemma-4-e4b`. A
loopback address in a command the reader types on their own machine is not a
name of a machine Fin runs on, and withholding it would make the result
unreproducible, which costs more than it protects. **Nothing else is exempt:**
no tailnet name, no bucket, no account id, no ARN, no instance or site id, in
any piece, in prose or in a code block. `check-claims.py` fails a piece whose
prose carries an account id, an access key id, an ARN, an S3 URI, a tailnet
hostname, a bucket name, an instance id, or a cloud product name; it skips
fenced code blocks, which is exactly the width of this exemption and no wider.
A piece that needs a real hostname to be reproducible is a piece whose
reproduction instructions are not ready to publish.

**"AI-powered", "AI-driven", "powered by AI".** It says nothing; every product
in the category says it; and it points at the machinery instead of at what the
user gets. Say what it does: "Fin reads your terminal and decides where your
message should go."

**Unfalsifiable superlatives.** "Blazing fast", "seamless", "effortless",
"revolutionary", "magical", "world-class", "state of the art", "unmatched",
"enterprise-grade". If a sentence would survive being pasted into a competitor's
page unchanged, delete it.

**Vague quantities.** "Up to", "as much as", "dramatically", "orders of
magnitude", "significantly" (unless it is a statistic and you have the test).
Either give the number with its qualifiers or drop the quantity.

**Anthropomorphic overreach.** "Fin understands you", "Fin knows what you
want", "Fin thinks". Fin routes, decides, asks, refuses, and reports. Those
verbs are true and they are also more interesting.

**Future tense as capability.** "Fin can run on any machine you own" when the
installer ships for one platform is a false claim wearing a capability's
clothes. Roadmap statements are a separate kind in the ledger and are written
as roadmap: "we are building X" or "X is next", never "Fin does X."

**Competitor mentions.** None. We do not name, compare, imply, or subtweet.

## 3. Describing the agent honestly

Fin acts on real terminals on machines people care about. The copy has to leave
a reader with an accurate mental model of what happens when Fin is unsure or
wrong, because that is where trust actually lives.

Write the guardrails as **features, in the user's terms** — and write them as
*decisions Fin makes*, never as mechanisms that make an outcome impossible.
That distinction is the whole difference between honest copy and a promise we
cannot keep:

- **Fin is built to leave unregistered terminals alone.** When a request names a
  terminal that is running on the machine but was never registered with Fin,
  the designed answer is to say what it found and ask you to register it,
  rather than type into it. (This is the `refuse` decision.) Write it as a
  decision — *"Fin asks you to register it instead of typing into it"* — not as
  an interlock: **never** "Fin only touches sessions you registered", "Fin
  cannot type into an unregistered session", or any sentence a reader would
  take as a mechanical guarantee.
- **When it is genuinely ambiguous, Fin asks.** Two sessions could match; Fin
  asks which one instead of guessing. (This is `clarify`, and it is worth
  saying out loud that asking is the designed behavior, not a failure.)
- **When Fin hits a wall it cannot pass — a login, a 2FA prompt, a missing
  credential — it is built to ask you instead of guessing or stalling.** (This
  is the `request_input` tool; "is built to" is load-bearing and stays. The
  tool exists on `main`; no eval measures how reliably the model reaches for
  it. See `CB-10`.)
- **Fin can be wrong.** Say it plainly where it matters, and say what the wrong
  case looks like: a message goes to the wrong session. Describe a recovery —
  seeing where a message went, moving it — only after opening the app and using
  it. As of `main @ 704ab09` there is no per-message session attribution view
  and no move-or-reassign control in the app, so a sentence promising one is
  false today.

> **These sentences are copy, and copy is claims.** This section — and §1's
> **say** column — exist to be lifted verbatim into posts, App Store
> descriptions, and review notes, which makes them simultaneously the
> most-copied and the easiest-to-miss text in the scaffold. Nothing prescribed
> anywhere in this file may be lifted without a row in `claims-ledger.md`
> (§7, "Copy blocks outside a piece"), **re-verified against `main` on the day
> it is used.** A guardrail sentence that was true when this file was written
> and false in the build a reader downloads is the worst copy we can produce.
> Two histories are the reason for the rule. The first bullet read "Fin only
> touches sessions you registered" until 2026-09-06, and the send-path
> enforcement that sentence implied is not on `main` — it is on an unmerged
> branch (`CB-1`). And §1's say column carried a failover promise until the
> same day (`CB-6`), which survived a whole audit because the ledger's scope
> said "§3" and a table did not look like copy.

Never write copy that implies Fin does not make mistakes, that it "always"
routes correctly, or that a guardrail makes an outcome impossible. Where an
edge case is genuinely unresolved and user-visible, we say so — `docs/SITES.md`
does this internally about the at-least-once window ("Stated, not hidden"), and
that is the standard for external writing too when the case can reach a user.

The tone for an error is neither apologetic nor cheerful. State what happened,
state what the user can do, stop.

## 4. How to write a number so it survives scrutiny

A score is a property of **a configuration at a moment**, not of a model, and
not of Fin. Every published number carries four things:

1. **the model** — exact identifier, and whether it is tuned or untuned
   (`google/gemma-4-e4b`, untuned);
2. **the prompt revision** — which prompt produced it (round-3 prompt,
   `evals/tmux-routing/prompts/router.md` at `99ed9d9`);
3. **the corpus** — what it was scored against, by name and size
   (`evals/tmux-routing/scenarios.json`, 51 scenarios);
4. **the tiering** — the split, because a headline hides it
   (26 core / 25 adversarial "hard").

Plus, where they exist: the serving stack and settings that could move the
number (LM Studio, temperature 0, 30-second per-call timeout), and the run
count (one run, unless it was repeated).

**The worked example this repo already contains.** The untuned
`google/gemma-4-e4b` scores **36/51** in
`scripts/model-factory/evals-champions.json` and **49/51** in
`evals/tmux-routing/RESULTS.md`. Same model. Two prompt revisions. Publishing
either number bare would be a true-looking sentence that misleads, and the
qualifier is the whole content of the result.

Write it like this:

> On the 51-scenario routing corpus (26 core, 25 adversarial), the untuned
> `google/gemma-4-e4b` served through LM Studio at temperature 0 scored 36/51
> with the original router prompt and 49/51 with the round-3 prompt — the same
> model, a rewritten prompt.

Not like this:

> Fin's local model routes with 96% accuracy.

**A title is a sentence, and it is the one that travels alone.** Titles,
subheads, pull quotes and image captions get ledger rows exactly like body
text. A title either carries all four qualifiers or **carries no number at
all** — the same hard rule social posts live under (`templates/social-post.md`),
for the same reason: a headline gets screenshotted, quoted, and turned into a
link preview without the paragraph that qualified it.

**Secondary numbers inside a piece.** A number in a results table, or one that
names its round inside a section whose headline sentence already carries the
four qualifiers, does not have to repeat all four — that would be unreadable.
`claims-ledger.md` §4 step 3 is the governing statement of that carve-out, and
this paragraph must not restate it more loosely or more tightly. In its words:
such a number "must still name its tier split **or** its round, and it must
**never** be the piece's most quotable sentence — not the title, not a subhead,
not a pull quote, not the lede." The test is the one in §6: if this line were
the only thing a reader saw, would they believe something false?

**Derived numbers and tables** have their own rules — a computed figure the
artifact does not print gets its own row and says it is arithmetic; a results
table takes one `<!-- table-claims: … -->` declaration rather than a row per
cell. Both are `claims-ledger.md` §4 step 5, and `check-claims.py` enforces the
table half.

Other rules for numbers:

- **Fractions, not just percentages.** "49/51 (96%)" — the denominator is the
  qualifier a percentage deletes, and 51 is a small enough n that the reader
  should see it.
- **One run is one run.** If the number came from a single scored run, say so.
  Do not average silently, do not report a best-of, and do not imply a
  confidence interval that was never computed. **That prohibition includes
  saying which comparisons are safe.** "A 1–2 point difference is within noise,
  but the larger gap survives it" is a variance estimate wearing a caveat's
  clothes, and it is most tempting in the limits section, where it reads as
  candour while licensing the headline. With no repeats, the honest statement
  is that no ordering is established — including the one you like.
- **A number an artifact does not print is a derived number.** Say it is
  arithmetic on the figures you cited, and give it a row. An *interpretation*
  of a number is not a measurement: attribute it to us in the sentence, or cut
  it.
- **Report the flakes.** If some misses were timeouts or infrastructure
  failures rather than wrong answers, that belongs in the same table, marked.
- **Report the regressions.** If an intervention fixed two things and broke
  three, the post says so in the results table, not in a footnote.
- **A number goes stale.** Every published number gets a re-check note in the
  ledger naming what would falsify it (a new prompt, a new model, a corpus
  change). When one of those happens, the row goes `stale` and the sentence is
  either re-measured or pulled.

## 5. Shape and mechanics

- **Sentences do one thing.** Long sentences are fine; sentences carrying three
  claims are not, because the ledger has to quote them.
- **Front-load the finding.** The first paragraph says what happened. The
  method comes after. Nobody has to read to the end to learn the result.
- **The limits section is not a disclaimer.** It is content. Write it as
  "what this does not show", in specifics, and put it before the reproduction
  instructions rather than at the very bottom where it reads as legal text.
- **Code, commands, and identifiers in backticks**, always, including model
  identifiers and scenario ids.
- **Link to artifacts, not to prose.** Cite `evals/tmux-routing/RESULTS.md` at a
  sha, not "our internal testing."
- **First person plural is fine** ("we kept the round-3 prompt"). Fin does not
  narrate its own marketing in first person singular.
- **No emoji** in Fin's external writing.
- **Dates are absolute** (2026-09-05), never "recently" or "last week."

## 6. The one-line test

Before a sentence ships, ask: *if a reader took this literally and checked it,
would they find it exactly true?*

If the honest answer is "true, but they would need to know something the
sentence does not tell them" — that is the failure mode this whole document
exists to prevent, and the fix is to put the missing thing in the sentence.

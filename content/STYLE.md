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
| what Fin is | **a terminal agent with a voice interface and a cloud brain** | "an AI assistant", "a chatbot", "an LLM wrapper" |
| the apps | **the Fin app on iPhone, iPad, Mac** (Apple TV and Vision Pro ride along) | platform code names, "our iOS client" |
| the machines Fin runs on | **Fin's computers**; individually "a cloud computer", "the Mac in your study", "this iPhone" | sites, workers, instances, nodes, daemons, hosts, boxes |
| the distributed brain | **Fin's cloud brain** — "Fin keeps working when a computer goes away" | "our distributed system", "the control plane", "the orchestrator" |
| a terminal Fin works in | **a session**, or plainly "the terminal where your build runs" | tmux pane/window/socket in user-facing copy (fine internally) |
| letting Fin onto a machine | **give Fin a key to this computer** (Fin's Key) | "provisioning SSH credentials", "key material" |
| speaking to Fin | **just talk to Fin** / "ask Fin" | "voice-enabled", "hands-free experience", "utterances" |
| the small local model | **the model Fin runs on your own machine** | "our proprietary model", "SLM", "edge AI" |

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

Write the guardrails as **features, in the user's terms**:

- **Fin only touches sessions you registered.** A terminal that merely exists on
  the machine is invisible to Fin — it will surface it and ask you to register
  it rather than type into it. (This is the `refuse` decision.)
- **When it is genuinely ambiguous, Fin asks.** Two sessions could match; Fin
  asks which one instead of guessing. (This is `clarify`, and it is worth
  saying out loud that asking is the designed behavior, not a failure.)
- **When Fin hits a wall it cannot pass — a login, a 2FA prompt, a missing
  credential — it asks you instead of guessing or stalling.**
- **Fin can be wrong.** Say it plainly where it matters, and say what the wrong
  case looks like: a message lands in the wrong session, and you can see which
  session every message went to and move it.

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

Other rules for numbers:

- **Fractions, not just percentages.** "49/51 (96%)" — the denominator is the
  qualifier a percentage deletes, and 51 is a small enough n that the reader
  should see it.
- **One run is one run.** If the number came from a single scored run, say so.
  Do not average silently, do not report a best-of, and do not imply a
  confidence interval that was never computed.
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

# Answering From Recorded Results

Skill for the moment you are about to state a number, a pass/fail, or "X works" —
and for the moment just after a compaction, when you feel oriented but are not.

The failure this prevents is specific and does not feel like a failure while it is
happening: you answer confidently from a summary of a result rather than from the
result, having lost the qualifiers (which split, which window, against which bar)
that made it true. Nothing about that state feels uncertain. That is the problem —
confidence is not the signal here, so it cannot be your check.

## When to Use

- You are about to quote a metric, benchmark, score, or accuracy figure
- You are about to say something "works", "passes", "beats", "improves", or "is fixed"
- You just came out of a compaction and are resuming substantive work
- You are about to compute a number ad hoc (`python -c`, a scratch script)
- A user asks "how did X do?" or "is X better than Y?"
- You notice you are certain about a figure but cannot name where you read it

## The reflex

### 1. Ask where the number came from — before you say it

For each figure you are about to state, answer: **which entry recorded this, and
what did that entry say the split and criterion were?** If you cannot name the
entry, you do not know the number; you know a residue of it.

Do NOT resolve this by reasoning harder. Reasoning cannot reconstruct a
qualifier that was dropped — it can only invent a plausible one, which is the
failure mode itself, in a form that reads as diligence.

### 2. Re-ground the claims you are carrying

```
session(action='reground', claims="<one claim per line>")
```

Each claim comes back as `candidates` (entries that plausibly source it) or
`unsupported`. Read the two differently:

- **`candidates`** — a pointer to read, NOT a verification. A semantic match means
  the words are similar, not that the entry says what you think it says. Open it.
- **`unsupported`** — treat as **not established**, not as "probably fine but
  unindexed". This is the load-bearing half: a carried claim with no source is
  exactly the artifact of a lossy summary, and it will otherwise propagate with
  full confidence.

### 3. Open the source and read the qualifiers verbatim

```
recall(entry_id='<id>', include_body=true)
```

Take the split, window, and criterion **as the source wrote them**. Never
substitute a synonym: "validation" and "evaluation" read as interchangeable
English but routinely name different periods, and silently bridging them is how a
number ends up quoted against data it was never measured on.

If the entry carries structured `results`, they already state metric, value,
split, window, and criterion. Quote those fields rather than paraphrasing the body.

### 4. Answer with the qualifiers attached

State the number and its conditions in the same sentence, and name the source
entry. `+2.62% active return on the 2019–2024 holdout (expe-a1b2c3d4)` is an
answer; `+2.62%` is a rumor.

## Recording a result

When your work produces a number, record it structurally, not only in prose:

```
record(project="<project>", type="experiment", title="<what was measured>",
       body="<what happened and why it matters>", parent_id="<active phase>",
       files="<paths>",
       results_json='[{"metric":"active_return","value":2.62,"unit":"%",
                       "split":"holdout-2019-2024","window":"6y",
                       "criterion":">=2%","source":"run-114"}]')
```

Prose loses the qualifiers first. A body saying "+2.62%" survives summarization;
"on the 2019–2024 holdout, against a +2% bar" does not — and the stripped number
then reads as unconditional. The `results` block keeps them attached, and lets the
server flag a later record that contradicts this one.

If `record` returns a `contradictions` block, stop and resolve it before moving on.
Both entries may be right (a rerun, a fixed bug, a changed pipeline), but the tree
now asserts two answers to one question. Read the prior entry; if yours supersedes
it, say so with `invalidates=`.

## Computing a number instead of reading one

Sometimes you genuinely need a new measurement. That is fine — but be explicit
about what it is and is not:

- **Check the record first.** `search` before you compute. The number often exists,
  already graded, with qualifiers you would otherwise have to guess.
- **Prefer the project's harness** over a hand-rolled script. A harness result
  carries a criterion; an ad-hoc one carries only a value.
- **Pre-register when it matters.** `experiment(action='run', dry_run=true,
  hypothesis=..., pass_criteria_json=..., null_interpretation=...)` commits to what
  would count *before* you see the number. Then `verify_manifest` returns a verdict
  instead of an interpretation.
- **Never invent a parameter that shapes the answer** — a date range, a split, a
  threshold, a universe. If a parameter is not specified, that is a question for
  the user, not a gap for you to fill plausibly. An invented start date does not
  announce itself in the output.
- **Label it.** Say out loud that the figure is a diagnostic with no pre-registered
  criterion. It will read as authoritative to you a few turns from now if you don't.

## Rules

- Confidence is not evidence of grounding, and after a compaction the two come
  apart completely. Use the source, not the feeling.
- A semantic match is a pointer to read, never a verification.
- Quote splits and windows verbatim; synonyms are how mismatched data gets bridged.
- "Unsupported" means not established. Say so plainly rather than hedging it into
  something that sounds established.
- A number without its qualifiers is not a smaller truth — it is a different claim.
- If a recorded result contradicts what you are about to say, the recorded result
  wins until you have read it and can explain the difference.

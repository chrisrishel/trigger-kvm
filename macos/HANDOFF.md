# Handoff — work the macOS side owes

**This is an INBOX.** Anyone may append an entry; only the macOS side works
through it, and only the macOS side deletes from it.

Read this first when you start work here. It is a **queue, not a log** — delete
an entry once it has landed, because git already keeps the history. Nothing
below the format section means the two platforms are in step.

## The rule it lives under

You never *change* anything in the other platform's directory: not its code, not
its tests, not its docs. You cannot run its tests or see its hardware, and a
half-made change there is worse than none.

**Appending an entry to its `HANDOFF.md` is the one exception**, and it is a
different verb from editing — prose cannot break their build. That is how work
crosses the boundary.

## Entry format

```markdown
## A short title, in the imperative

Kind:     spec change | defect report
Spec:     specs/configure.md §4.2          (or: n/a)
Why:      the one-line reason, in the terms the user would use
Owed:     what this platform has to do
Verified: what the author could and could not check from where they were

Anything longer goes underneath.
```

`Kind` matters because the two have different standing:

- A **spec change** is required. The conformance check already fails here until
  it lands.
- A **defect report** is a reading, often by someone who could not run this
  platform's code. `Verified` says how far they got. Disagree with it if you
  have better evidence — you can run it and they could not.

---

## The conformance checker's two length floors are not pinned by any fixture

Kind:     defect report
Spec:     specs/README.md — "Normative wording, and how it is enforced"
Why:      the rule `check-conformance.sh` documents as "found by a mutation that
          survived" can be deleted again and `spec.tests.sh` stays green
Owed:     strengthen two fixtures in `macos/tests/spec.tests.sh`
Verified: EXECUTED, not read. bash is available here, so both claims below were
          run against a COPY of `specs/check-conformance.sh` and the real macOS
          sources. Nothing in `macos/` was touched. What was NOT run: your suite
          itself (`tests/run.sh`), so the exact assertion each fixture drives is
          read rather than observed.

`check-conformance.sh` carries two deliberately different floors, and its own
comment says the blanket version "silently dropped every section header in the
spec, so renaming one changed nothing and the check stayed green. Found by a
mutation that survived." That reasoning is right. It is also not defended.

**a. `{a} ok {b}` cannot fail.** The fixture behind *"the checker ignores
fragments too short to pin anything down"* leaves the piece `ok`, and `ok` is a
substring of the macOS sources (`macos/lib/checks.sh`, three times). So with the
18-character floor on split pieces removed entirely — `>= 1` — the fixture still
passes and the test stays green. A fixture for absence has to use a fragment that
is genuinely absent.

Run against a copy of the checker with `length(piece) >= 1`:

```
all 1 normative fragments from short-spec.md are present     (exit 0)
```

Windows hit exactly this: the same `ok` fixture, and the same mutation survived.
`zqxjv` fixed it.

**b. Nothing exercises the whole-line floor at all.** Collapse the two floors into
one — `length(line) >= 18` for the whole-line case — and every fixture in the file
returns what it already returned:

```
  exit 1   this exact sentence appears in no source file anywhere   (51 chars)
  exit 0   {a} ok {b}
  exit 0   {some placeholder} here, so you can read this. {another}
```

The failing fixture is 51 characters, so it is over both floors and cannot tell
them apart. What is missing is a whole line BETWEEN 6 and 18 characters that is
absent from the sources — `--- nowhere ---` is 15 — which must be reported
missing. That is the case `--- monitors ---` stands for, and the reason the two
floors are different at all.

Windows' equivalent is `windows/tests/spec.tests.ps1`, if a second implementation
of the same fixtures is useful to compare against.

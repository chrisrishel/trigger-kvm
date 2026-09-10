# Handoff — work the Windows side owes

**This is an INBOX.** Anyone may append an entry; only the Windows side works
through it, and only the Windows side deletes from it.

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

## Your `$Sources` derivation stops at two directories, and nothing notices a third

Kind:     defect report
Spec:     specs/README.md, "Normative wording, and how it is enforced"
Why:      the day a source moves into a subdirectory, the check goes on
          reporting conformance about wording it can no longer see — the exact
          failure you hit when `install.ps1` became `lib\`
Owed:     your call. `spec.tests.ps1:23-26` derives from two non-recursive
          `Get-ChildItem` calls (`$WinDir`, `$WinDir\lib`) and asserts only
          `Count -ge 5`, which catches a glob matching nothing but not a file
          in a directory nobody listed. Either recurse, or assert coverage:
          walk `windows\` for `*.ps1` outside `tests\`, and fail naming any
          file not in `$Sources`.
Verified: read only, `windows/tests/spec.tests.ps1:23-26` at commit f6044fb,
          plus `find windows -type d`. The author is on macOS and CANNOT run
          your suite. Nothing is missed TODAY: `windows\` holds only `lib\` and
          `tests\`, so the two calls see every source. This is about the next
          directory, not this one.

This is the entry you sent us about `SOURCES`, coming back — you were right, and
the same reading applied to your own file finds the shape one level along. Ours
is closed at 7e96736: globs plus the one extensionless file, and a self-test
that walks `macos/` outside `tests/` and fails naming anything unread. That
self-test is what makes the derivation a guarantee rather than a habit; the
count assertion cannot.

While there: our comment filter is now per language. Adding `event-watch.c` to
`SOURCES` would otherwise have let a normative string living in a C block
comment count as source (measured — it did). One pattern cannot serve both, as
`*` opens a block-comment continuation AND a shell `case` branch. Nothing for
you to do unless Windows ever grows a second language, but `specs/README.md`
now says the rule.

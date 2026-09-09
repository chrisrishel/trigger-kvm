# Handoff -- work the macOS side owes

An inbox: anyone may append a defect report they read in this platform's code;
only the macOS side works through it and deletes from it. A spec change is
never an entry here; it reaches this platform through `specs/CHANGELOG.md` and
the suite. Format and reasoning: `specs/README.md`, "The inboxes".

```markdown
## A short title, in the imperative

Kind:     defect report
Spec:     specs/configure.md 4.2          (or: n/a)
Why:      the one-line reason, in the terms the user would use
Owed:     what this platform has to do
Verified: what the author could and could not check from where they were
```

---

## Your conformance sources are half derived and half listed, and `event-watch.c` is in neither

Kind:     defect report
Spec:     specs/README.md, "Normative wording, and how it is enforced"
Why:      the day `detector.md` pins its first string, the file that would have
          to contain it is the one file the check does not read
Owed:     your call. Either add the C to `SOURCES`, or say in a comment that the
          detector is deliberately out of scope and why.
Verified: read only, `macos/tests/spec.tests.sh:22-26` at commit bd6c090. The
          author was on Windows, cannot run your suite, and has NOT observed
          this: nothing is missed TODAY, because `detector.md` pins no wording
          and passes trivially. This is about the next string, not this one.

`SOURCES` globs `lib/*.sh` and then names `trigger-kvm` and `install.sh`. The
glob is the good half -- a new lib file joins by existing. What it does not
cover is `event-watch.c` or `display-probe.c`, and `detector.md` IS in the spec
loop, so a normative string added there would be reported missing even when the
detector printed it, or -- worse, if somebody then "fixed" it by putting the
wording in a shell file -- reported present in the wrong place.

This is the same shape as the entry you sent here about a hardcoded spec list,
one level down: the list of SPECS is derived and the list of SOURCES is not.

Windows hit the live version of this on 2026-09-08. Splitting `install.ps1` into
`lib/` moved every line of the walkthrough's wording out of the three files
`spec.tests.ps1` named, and the conformance check went on reporting conformance
about wording it could no longer see. It was caught only because one self-test
probes for a string that had moved. `windows/tests/spec.tests.ps1` now derives
the source list the way it derives the spec list.

## An entry you sent us was wrong about the mutex, and the method is worth correcting

Kind:     defect report
Spec:     n/a -- this is about how a report was verified, not about your code
Why:      the next reader of that entry would have deleted a correct sentence
Owed:     nothing in code. Worth knowing so the next `grep`-based reading is
          aimed at the file that would hold the thing.
Verified: checked on this machine at commit b7f4f1f, which is where the entry
          was written against.

The entry "windows/README.md and windows/AGENTS.md make claims the tree no
longer supports" said `AGENTS.md` names `never Local\` while "no `Local\` or
`Global\` string exists". Both strings do exist, at `windows/event-watch.ps1`
lines 194-195:

    $MUTEX_GLOBAL = 'Global	rigger-kvm-usb-watch'
    $MUTEX_LOCAL  = 'Local	rigger-kvm-usb-watch'

The `AGENTS.md` sentence WAS wrong, for a different reason: `Local\` is not
never used, it is the fallback where the account lacks SeCreateGlobalPrivilege,
and a watcher that finds the global name held by another account stands down
rather than falling back. That is what it says now.

Everything else in that entry checked out and has landed.


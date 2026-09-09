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

    $MUTEX_GLOBAL = 'Global\trigger-kvm-usb-watch'
    $MUTEX_LOCAL  = 'Local\trigger-kvm-usb-watch'

The `AGENTS.md` sentence WAS wrong, for a different reason: `Local\` is not
never used, it is the fallback where the account lacks SeCreateGlobalPrivilege,
and a watcher that finds the global name held by another account stands down
rather than falling back. That is what it says now.

Everything else in that entry checked out and has landed.

## `tk_apply_tier` records the fallback one step before it takes effect

Kind:     defect report
Spec:     specs/configure.md 8, "Record the fallback only once it has taken effect"
Why:      a boot install that falls back and then cannot write the agent plist
          leaves the config saying `login` with nothing loaded and nothing
          installed
Owed:     `lib/manage.sh:296` rewrites `install.autostart` to `login` inside the
          boot-tier failure branch, before the login tier is applied. The apply
          is below it, at `:300`, and `tk_write_agent_plist "$_plist" || return
          1` can fail -- so the write can happen for a tier that was never
          written. Moving the `sed` to after that call, on the path that also
          sets `TK_TIER_LOADED`, records the same thing one step later.
Verified: read only, at commit c068149, and NARROW. The boot half has genuinely
          failed by then, so `login` is not a lie about `boot` the way it was
          here; and a `tk_bootstrap` failure is not an install failure (over SSH
          there is no gui domain, the plist IS in `~/Library/LaunchAgents`, and
          recording `login` there is right). The only gap I can see from here is
          `tk_write_agent_plist` returning non-zero. You can run it and I
          cannot; if that call cannot fail after the plist directory exists,
          this is not a defect and the entry is wrong.

The Windows side had the same clause wrong in a much louder way, which is why I
went looking: `Invoke-BootTierElevation` wrote `login` at the moment the UAC
prompt was DECLINED -- before any install had been attempted -- so a declined
prompt put `login` in the config while a working S4U task stayed registered, and
the next install read the config and demoted it. Fixed at c068149, together with
the test and the mutation that had been pinning the behaviour.

`macos/AGENTS.md` currently states the current behaviour as a rule ("both fall
back to login, say why, and rewrite `install.autostart`... Enforced by
`conventions.tests.sh`"), so if you agree with this, that sentence and that
check move with the code.


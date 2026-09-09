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

## The first run on a fresh machine cannot finish, and the directory is never created

Kind:     defect report
Spec:     specs/detector.md 4 (listing modes) and specs/configure.md 12
Why:      someone installs on a second Windows PC and cannot get past Triggers;
          if they could, Save would throw
Owed:     make the listing modes independent of the config (revision 14 item 5),
          then create `%LOCALAPPDATA%\trigger-kvm\` before the first
          `Write-ConfigFile`; `Set-Content` (`install.ps1:3532`) does not create
          parents and `$ErrorActionPreference = 'Stop'` (`:128`) makes that fatal
Verified: read only. The reference PC has had that directory since before the
          rename, and every walkthrough test writes under an existing temp dir,
          so neither half has been seen live. A scripted run against a throwaway
          profile from the installed shim would settle both in one go.


## `Dxva.WriteStandardVcp` writes to every physical monitor behind the handle

Kind:     defect report
Spec:     specs/config-format.md, "Both switchers address exactly one display"
Why:      in "Duplicate these displays" one HMONITOR carries two panels and both
          receive the write, while identity was taken from monitor index 0 only
Owed:     `trigger-kvm.ps1:754-768`: refuse unless
          `GetNumberOfPhysicalMonitorsFromHMONITOR` reports exactly one
Verified: read only. Standard channel only, so not a `0x50` hazard.


## The dxva2 adapter counts zero accepted writes as success

Kind:     defect report
Spec:     n/a
Why:      a panel that took none of the writes is logged as switched
Owed:     `trigger-kvm.ps1:988`: `if ($n -gt 0) { 0 } else { $n }` maps both
          outcomes to success; its own comment promises the opposite. The
          failure message on that path (`:900`) names `NvAPI_I2CWrite`.
Verified: read only.


## `restart` and `pause` cannot stand a boot-tier watcher down unelevated, and `restart` reports success from the old watcher's lock

Kind:     defect report
Spec:     specs/configure.md 8 and 11
Why:      the person is told the watcher restarted when the old one is still
          running in session 0
Owed:     `Stop-Watchers` (`install.ps1:542`) filters on `Win32_Process.CommandLine`,
          which reads empty across the session boundary (your own measurement,
          2026-09-02). `restart` then reads the lock the old watcher still holds
          (`:3975-3977`) as success. `Get-WatcherPauseMode` (`:849`) already
          knows when the tier needs elevation; consult it in both verbs and
          either elevate or say plainly that nothing was stood down. macOS
          `pause` now fails when the lock is still held after the bootout.
Verified: read only; the `pause` half is already in `TODO.md` from live
          observation, the `restart` half is new.


## The declined-UAC fallback is recorded before it takes effect, and the suite pins it

Kind:     defect report
Spec:     specs/configure.md 8, "Record the fallback only once it has taken effect"
Why:      a declined prompt writes `login` while the registered task is still S4U,
          and the next `install` demotes a working boot tier (observed live,
          `TODO.md`)
Owed:     delete the early write at `install.ps1:370`; the correct one is at
          `:4629`. `windows/tests/elevation.tests.ps1:107` and the mutation at
          `mutate.ps1:769` assert the early write, so both change with it: an
          assertion change, made deliberately.
Verified: read only against the observation already in `TODO.md`.


## The hard-rule-5 "no other emitter" scan covers one file and one spelling

Kind:     defect report
Spec:     ../AGENTS.md hard rule 5, "each suite asserts, self-testedly, that
          there are no others"
Why:      the gate is sound; the proof that it is the only door is narrower than
          the rule says
Owed:     `conventions.tests.ps1:351-381` scans one here-string in
          `trigger-kvm.ps1`; `nvapi-probe.ps1`, both `Add-Type` blocks in
          `event-watch.ps1` and the one in `install.ps1` are never scanned, and
          the scan keys on the spelling `0x50` and a parameter named `source`.
          Scan the tree with comments stripped, and name the probe in
          `windows/AGENTS.md` as macOS names `intel-ddc-probe`.
Verified: read only.


## `-WhatIf` prints a `0x50` packet for a non-LG panel

Kind:     defect report
Spec:     ../AGENTS.md hard rule 5
Why:      a dry run shows a packet the gate would refuse, so what it shows is not
          what a real run would send
Owed:     put the vendor gate in front of the `-WhatIf` print
          (`trigger-kvm.ps1:873`). macOS now passes the gate inside `ddc_send`
          before printing. Nothing is sent either way.
Verified: read only; carried over from the 2026-08-31 review (M25).


## `configure` from the installed copy copies three scripts onto themselves

Kind:     defect report
Spec:     n/a
Why:      running `trigger-kvm configure` from the shim re-runs `install`, and
          `install.ps1:4281-4283` copy `config.ps1`, `event-watch.ps1` and
          `trigger-kvm.ps1` from `$PSScriptRoot` onto their own paths; only the
          manage script guards its self-copy (`:4287-4289`, whose comment says
          the self-copy throws)
Owed:     one run from the shim settles it: does the log reach `installed
          scripts to`? If it aborts, guard the three as the fourth is guarded.
Verified: read only; the reference desk may never have run `configure` from the
          shim after an install, so this is PLAUSIBLE, not confirmed.


## What was NOT found, so no broad review is owed

Kind:     defect report
Spec:     n/a
Why:      so nobody spends a day re-reading the tree looking for more
Owed:     nothing beyond the entries above
Verified: a full read of `windows/` by two independent reviewers and the author,
          at commit cf149fe: every path, gate, lock, task setting and packet
          value checked was correct. What rots is narrative about what changed.
          The two entries above this block, from an earlier session, are still
          open. One thing worth a single scripted run rather than a review: a
          fresh-profile install from the shim (first entry).

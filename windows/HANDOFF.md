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

## Revision 14 landed; these are the lines in your code each item points at

Kind:     defect report
Spec:     specs/CHANGELOG.md revision 14 (the spec side reaches you through
          your suite; this entry is only the reading of your code)
Why:      every item below was found by reading, and the changelog names the
          symptom without the line
Owed:     implement revision 14; the numbers here are where to look
Verified: read only, at commit 339cab6. The author was on macOS and ran none of it.

| item | where | what was read |
|---|---|---|
| 2, ambiguity as a state | `event-watch.ps1:785` | an ambiguous entry returns `Present = $false`, so unplugging one twin flips it to present and the loop reads an arrival; `:686` counts parsed entries, so an all-ambiguous list still arms |
| 5, listing modes need no config | `event-watch.ps1:499` | `Deny-Startup` on a missing `trigger.device` runs before the `-ListBluetooth` (`:519`) and `-ListUsb` branches, so a fresh machine's walkthrough lists no triggers and Save is refused with `Still needed: Triggers` |
| 6, absent panels kept | `install.ps1:2489-2491`, `:3414` | answers are built from found panels only and carried keys drop unmanaged labels |
| 7, no name filter | `install.ps1:3795-3804` | `hub` / `host controller` / `root complex`; the suite and `mutate.ps1` pin the filter |
| 10, every path through the preamble | `install.ps1:3077-3082` | `Test-OneComputer` -> `Test-DisplayInput` sends immediately when no other computer is configured |
| 11, a pass bound to what was checked | `install.ps1` map edits | the result text is cleared, the pass flag is not, and a one-panel pass authorises a full pull |
| 14, one parse rule | `install.ps1:2704`, `:3917`, `:4116` | the earlier entry above; still open |
| 15, computers in file order | `install.ps1:1624`, `:2058`, `:2071` | `Sort-Object` on keys rebuilds the order from the hex |

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

## `windows/README.md` and `windows/AGENTS.md` make claims the tree no longer supports

Kind:     defect report
Spec:     ../AGENTS.md, "When a doc's claim stops being true, fix it in that commit"
Why:      the next reader acts on them
Owed:     fix or delete each:
          - `README.md:1019` "there is no `dxva2` or `user32` code here any
            more": `dxva2` is a built transport (`docs/decisions/003`)
          - `README.md:1173` "`046d:c547` is a keyboard, wired to the
            motherboard ... always present": both receivers travel through the
            switch (revision 12; `docs/measurements.md`, "Naming a device")
          - `README.md:497` the test "always" brings the panel back: the code
            has a "Yes, but it did not change back" answer
          - `README.md:538` `--add-to-path` on macOS: no such flag
          - `AGENTS.md` names a `setup` verb (`install.ps1:2649`, `:4205`, `:4208`
            still print "trigger-kvm setup"), a `Get-BusReportedName` function
            (the binding is `CM_Get_DevNode_PropertyW` in `event-watch.ps1:291`),
            and "never `Local\`" (no `Local\` or `Global\` string exists)
          - `AGENTS.md:93,97`, `nvapi-probe.ps1:6,44`, `trigger-kvm.ps1:55,235,577`
            point at `ideas/nvapi-transport.md`, which is deleted; the bindings
            and their provenance are `docs/nvapi-bindings.md`
Verified: each claim checked against the tree at 339cab6 by grep; none run.

## Comments describe the code as it is; the history is in git

Kind:     defect report
Spec:     ../AGENTS.md, "Conventions"
Why:      `windows/README.md` and `install.ps1` narrate what changed ("it used
          to", "until 2026-08-30", commit hashes) in something like 40-50 KB of
          prose that a reader has to parse to find what the code does now
Owed:     one sweep: every comment says what and why in about three lines and
          points at the spec, a decision or `docs/measurements.md` for the rest.
          Same for `README.md`, which becomes a user-first operating guide with
          the walkthrough narrated once, in `specs/configure.md`. macOS did this
          in revision 14; `macos/README.md` is the shape.
Verified: sizes measured; nothing run.

## Three facts are kept in two places each, and a scan polices every one

Kind:     defect report
Spec:     ../AGENTS.md, "What does NOT go in a spec" (one home per fact)
Why:      ~250 lines of `conventions.tests.ps1` and ~60 of `mutate.ps1` exist to
          keep copies in step that need not exist
Owed:     the verb table (`install.ps1:3557`) should generate the shim's routing
          table and both `ValidateSet`s; the elevated relaunch should build its
          arguments from `$PSBoundParameters`; the transport list
          (`trigger-kvm.ps1:935`, `:1049`, `install.ps1:715`) belongs once in
          `config.ps1`. Then delete the scans and mutations that policed them.
Verified: read only.

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

## Your conformance checker counts a comment line as source

Kind:     defect report
Spec:     specs/README.md, "What the checks prove"
Why:      a config-file header or a note quoting the spec's words stands in for
          the wording the person sees; macOS caught this by a mutation that
          renamed `--- computers ---` in the walkthrough and stayed green
          because the config writer's comment header carried the substring
Owed:     strip comment lines from the sources before matching, and refuse an
          unreadable spec instead of reporting "all 0 fragments present";
          `specs/check-conformance.sh` now does both and its two self-tests are
          in `macos/tests/spec.tests.sh`
Verified: read only against `windows/tests/check-conformance.ps1`; not run.

## Shape the tree as if it had been written from the specs

Kind:     defect report
Spec:     specs/README.md (what an implementation is built FROM); ../AGENTS.md,
          "Conventions"
Why:      `install.ps1` is one ~4,600-line file holding the menus, the
          walkthrough, the checks, discovery and every host verb, with the
          walkthrough's state in thirteen parallel arrays; a reader cannot tell
          what it does from what it once did, and every rule about it is a scan
Owed:     land revision 14 INSIDE this reshaping, not on top of it. The shape
          `macos/lib` has: `windows/lib/{menu,walkthrough,checks,discover,host}.ps1`
          (about thirty test-import edits, the five copy lines in the installer,
          one glob); one record per panel instead of the parallel `WT_*`-style
          arrays, edited through one setter; one swing primitive that every path
          moving a panel goes through; dead code out (`$carry`,
          `Test-ConfigValueExact`, `Get-EffectiveTier` silently accepting an
          unknown `install.autostart`, the usage text advertising a `-Config`
          the installer lacks, `discover` and `status` telling people to "re-run
          install.ps1"); a decision on the one-machine pre-rename block; then
          the scans and mutations that only policed copies go. Comments say
          what and why in a few lines and point at the spec, a measurement or a
          decision. The test at the end is to read each file fresh and ask
          whether it looks designed this way from the start; where it does not,
          it is not finished.
Verified: sizes and counts measured at cf149fe; the reshaping itself is a
          judgement, made on macOS in 4871fbb, which is the worked example.

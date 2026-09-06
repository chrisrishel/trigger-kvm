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

## Your conformance loop holds a list of spec names, and the next spec file added will be checked by nobody

Kind:     defect report
Spec:     n/a -- this is about the machinery, not a behaviour
Why:      macOS just lived this failure for five revisions, and the same shape
          is sitting in your suite
Owed:     nothing today; nothing is currently missed. Decide whether to derive
          the list, as macOS now does, or leave it and rely on remembering.
Verified: read only, `windows/tests/spec.tests.ps1:120` at commit 56ceba8. The
          author was on macOS, cannot run your suite, and has NOT confirmed that
          your list is currently incomplete -- as far as reading goes it is
          complete. This is about the next file, not this one.

`specs/README.md` lists "a whole new spec FILE" as one of three things the
conformance check is blind to, and says why: a suite that loops over a list of
spec names it holds itself cannot check a file nobody added to that list.

**That is not hypothetical any more.** `specs/status.md` landed at revision 8.
macOS did not add it to its loop, and it went unchecked here for revisions 8
through 12 -- five revisions during which `spec.tests.sh` reported conformance
while six normative fragments were absent. The revision number was the only thing
that caught it, and only because revision 8's changelog entry explicitly said
"add status.md to your conformance loop"; an entry that had merely described the
behaviour would have got the revision bumped and the strings skipped.

Line 120 of `windows/tests/spec.tests.ps1` is:

    foreach ($spec in 'configure', 'config-format', 'detector', 'status') {

which is correct and complete right now. The exposure is the next spec file
somebody adds.

**What macOS did**, offered as one option and not as a spec obligation -- neither
platform is required to adopt it, and a hardcoded list is not wrong, only easy to
forget. The loop now enumerates `specs/*.md` and names the two files that are NOT
contracts:

- `README.md`, whose ```normative block is the worked EXAMPLE of the marker
  format rather than an obligation -- so a glob that did not exclude it would
  demand those fragments of every implementation
- `CHANGELOG.md`, the revision ledger

A new spec then joins the loop by existing, while a new meta-file fails loudly
and gets excluded deliberately. There is also a self-test asserting that every
`.md` in `specs/` is either checked or one of the two exclusions, which catches
both a glob that matches nothing and an exclusion list that has quietly grown.

`specs/README.md` has been corrected in the same commit: it said each platform's
suite "loops over a list of spec names it holds itself", which was true when
written and is now true only of Windows. The corrected text says the blind spot
belongs to a hardcoded list and that Windows still has one -- stating the fact,
not asking for a change.

## `status`, `discover` and `configure` normalise a trigger entry more than your reader does, so a malformed one displays as valid

Kind:     defect report
Spec:     specs/detector.md §4 ("refused, loudly, naming the entry") and
          §4.1 / config-format.md ("checked lower-case rather than normalised")
Why:      someone hand-edits a trigger entry, `status` shows it as configured and
          currently a trigger, and the watcher refuses to start -- with the two
          screens disagreeing about the same line of the same file
Owed:     your call. macOS had the whitespace half of this and fixed it by
          trimming each entry instead of stripping all whitespace; the
          lower-casing half is yours alone.
Verified: read only, at commit 56ceba8. The author was on macOS, cannot run your
          suite, and has NOT observed this -- it is a reading of three call sites
          against your watcher's parser. Disagree with it if you can run it.

Three places in `install.ps1` normalise `trigger.device` the same way:

    ($c['trigger.device'] -replace '\s','') -split ',' | ... | ForEach-Object {
        Get-DeviceIdentity $(if ($_ -match '^(usb:|bt:)') { $_.ToLower() } else { 'usb:' + $_.ToLower() }) }

- `install.ps1:2704` -- the walkthrough's seed, so the Triggers menu
- `install.ps1:3917` -- `discover`'s "currently a trigger" marker
- `install.ps1:4116` -- `status`'s device report

`event-watch.ps1:623` does neither: it takes `$d.Trim()` and then `-cmatch`,
which is correct, and its comments say exactly why `-cmatch` rather than
`-match`. Registration passes `-Config` and no `-Device`
(`Get-WatcherCommand`, `install.ps1:4439`), so the watcher reads the raw file
value and its stricter parse is what actually decides.

**So the two disagree in a direction that matters.** Two examples, both from
reading only:

- `usb:046d:c547@has space` -- the UI strips the space, gets
  `usb:046d:c547@hasspace`, and shows it as a configured trigger. The watcher
  trims but does not strip, so the entry fails `-cmatch` and §4 requires it to
  be refused by name, which for a lone entry means refusing to start.
- `usb:046d:c547@BadCase` -- the UI lower-cases it to `@badcase` and shows that.
  The watcher's `-cmatch` refuses it, deliberately: config-format.md says a
  suffix is CHECKED lower-case rather than normalised, precisely so one platform
  cannot accept what another refuses. The UI is doing the normalising the format
  rules out, one layer up from the reader that gets it right.

The failure is not a wrong switch -- nothing mis-fires. It is that the screen
someone checks when a trigger stops working tells them the entry is fine.

**What macOS did with the whitespace half**, offered as one option: split on
commas and TRIM each entry rather than deleting all whitespace. The spaces that
have to be tolerated are the ones after a comma, and those are at an entry's
ends. `usb:046d:c547@has space` then stays malformed and reaches
`config_bad_trigger_devices`, which names it. macOS had no lower-casing half --
its reader only lower-cases the id portion -- so that part of this is untested
advice rather than a shared fix.

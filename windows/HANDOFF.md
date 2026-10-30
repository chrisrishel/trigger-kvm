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

## Preserve skipped monitor checks as untested

Kind:     defect report
Spec:     specs/configure.md 4.2, 10.1, 10.8, 11
Why:      declining a check can authorize a later real pull with unverified inputs
Owed:     distinguish pass, failure and skipped outcomes; track actual scope
Verified: actual PowerShell functions at 318fc79, exercised with hardware/UI
          stubs under PowerShell 7.6.9 on macOS; Windows 5.1 not run

In `lib/checks.ps1`, `Test-OneComputer` returns true when `Invoke-PanelSwing`
returns null after a declined preamble. With one attached panel mapped only to
`pc`, `Invoke-DisplayTest` returns Ok=true, Text="all responded", and
`Test-PullAllowed` returns true, although `Send-Input` was never called.

A separate path computes `$others` before narrowing the selected scope. Give
panel one only `pc`, panel two `pc` and `mac`, then choose panel one: the check
returns Ok=true without any write or confirmation question. Test both paths,
and ensure a retry or removed mapping cannot manufacture a pass either.

## Restrict watcher cleanup to this installation

Kind:     defect report
Spec:     n/a (process ownership)
Why:      pause, restart or installation can terminate another application's scripts
Owed:     identify exact installed script paths and the intended owner before stopping
Verified: actual `Stop-Watchers` with mocked process enumeration/termination on
          PowerShell 7.6.9; both unrelated fixture processes were selected

`lib/host.ps1` matches any wscript command containing `launcher.vbs` and any
PowerShell command containing `(usb|event)-watch.ps1`. Fixtures under
`C:\UnrelatedApp\launcher.vbs` and `C:\OtherTool\event-watch.ps1` both reached
`Stop-Process -Force`. Include negative tests for unrelated paths, quoted
arguments, and other users; verify the real installed watcher still stops.

## Restore the watcher's prior enabled and running states after a check

Kind:     defect report
Spec:     specs/configure.md 11
Why:      checking a trigger silently restarts a watcher the user deliberately paused
Owed:     preserve prior task enablement and running state on all exits
Verified: actual `Invoke-TriggerTest`, pause-mode and suspend/resume functions,
          with OS calls stubbed under PowerShell 7.6.9 on macOS

Begin with an Interactive task whose state is Disabled and no running watcher.
Let the one-shot time out. The check calls both Enable-ScheduledTask and
Start-ScheduledTask. `Get-WatcherPauseMode` checks ownership, not prior state;
`$paused = Suspend-Watcher` does not record what existed before the check.
Cover enabled/running, enabled/stopped and disabled/stopped, plus timeout,
cancellation and error exits. No native Task Scheduler change was made in review.

## Escape paths inserted into the elevated PowerShell command

Kind:     defect report
Spec:     specs/configure.md 8
Why:      a checkout or temporary directory containing an apostrophe breaks elevation
Owed:     quote the installer and transcript paths as safely as ordinary arguments
Verified: parsing Request-Elevation's captured command with a synthetic
          `C:\Users\O'Brien\...` installer path produced four parser errors;
          no elevated process was launched

`lib/host.ps1` interpolates `$TK_SELF` and `$transcript` into single-quoted
literals without doubling embedded apostrophes. Exercise both paths and the
manually suggested command, then verify native child exit-code propagation.

## Preserve Unicode in generated files and carried configuration

Kind:     defect report
Spec:     specs/config-format.md, "Hand edits survive"; specs/configure.md 8
Why:      an accented profile path breaks startup and saved values become question marks
Owed:     choose encodings supported by each generated file's reader; retain ASCII source
Verified: actual writer and command builder under PowerShell 7.6.9; accented
          monitor name, unknown-key value and launcher path all failed round-trip

`lib/host.ps1` writes `launcher.vbs` with ASCII after embedding full profile
paths. `lib/answers.ps1` writes the config with ASCII, as does `Set-ConfigValue`.
The source-file ASCII rule does not constrain generated user data. Verify with
Windows 5.1 and Windows Script Host, including repeated configuration updates.

## Convert fractional settle seconds to milliseconds

Kind:     defect report
Spec:     specs/detector.md 2 and 4
Why:      a valid fractional settle setting can become no settle at all
Owed:     preserve fractional seconds at the Windows 5.1 sleep boundary
Verified: source review and Microsoft Windows PowerShell 5.1 Start-Sleep
          documentation; integer parameter binding maps 0.75 to 1 and 0.25 to 0

`event-watch.ps1` calls `Start-Sleep -Seconds $Settle`; 5.1's Seconds parameter
is Int32. Test the emitted delay rather than only the configuration parser.
Source: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/start-sleep?view=powershell-5.1

## Restrict NVAPI DLL resolution to the intended system location

Kind:     defect report
Spec:     n/a (library loading)
Why:      listing on a machine without NVIDIA can load a counterfeit DLL from a search directory
Owed:     restrict loading in the shipping transport and the read-only probe
Verified: bare LoadLibrary call and unconditional list-time Init reviewed;
          Windows DLL search order checked; no counterfeit DLL was executed

`trigger-kvm.ps1` and `nvapi-probe.ps1` call LoadLibrary with `nvapi64.dll`
without a path or restricted search flags. Preserve graceful NVAPI absence on
non-NVIDIA systems. Verify the trusted location and failure behavior natively.
Source: https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order

## Discard computer-submenu edits on Escape

Kind:     defect report
Spec:     specs/configure.md 3.3
Why:      Escape promises to change nothing but retains renamed computers and input maps
Owed:     commit submenu edits only on Done, restoring all dependent state on Escape
Verified: actual Read-Computers with scripted selections under PowerShell 7.6.9;
          rename `mac` to `renamed`, then Escape retained both name and map edits

`lib/walkthrough.ps1` edits panel maps in place and handles Done and Escape with
the same break. Cover rename, addition, removal and the associated pass validity.

## Make the Windows installation guide copyable and match its support claims

Kind:     defect report
Spec:     n/a (end-user documentation)
Why:      examples pass prose as arguments and omit first-install bootstrap details
Owed:     correct Windows README examples, prerequisites and verification limits
Verified: documentation read at 318fc79; no fresh Windows installation attempted

Use comments or tables for descriptions beside commands. Explain acquiring the
source, execution policy/download handling without changing machine policy,
PowerShell 5.1, PATH refresh, repair and uninstall. Describe Bluetooth detection
as the implemented event-driven presence sweep, not a periodic poll. Preserve
the local-console requirement for dxva2 and mark real switching unverified until
observed. Review stale references to `ideas/nvapi-transport.md` and the handoff's
own format against `specs/README.md`; spec changes arrive through the revision
ledger, not duplicate inbox entries.

### Publication privacy: device-instance examples in source comments

- **Kind:** defect report
- **Spec:** publication-readiness privacy review in `TODO.md`; no behavior change.
- **Why:** comments near the display identity merge in `trigger-kvm.ps1`
  retain the reference desk's host-specific PnP instance components. Their
  exact bytes are unnecessary to explain why EDID identity survives a cable
  move; the shared measurements now use consistent replacement labels.
- **Owed:** replace those instance components with clearly synthetic examples
  or the labels used in `docs/measurements.md`, retaining the identity comparison.
  Inspect the rest of the Windows source and docs for unnecessary real device
  identifiers. Do not rewrite history or change human author metadata.
- **Verified:** current tracked-file comparison located the two remaining
  instance-component examples in `trigger-kvm.ps1` (near lines 631 and 720).
  No Windows files outside this handoff were edited from macOS.

### Escape audit: nested removal and monitor menus

- **Kind:** defect report
- **Spec:** `specs/configure.md` 3.3 (submenu Escape changes nothing).
- **Why:** the macOS follow-up reproduced the same in-place mutation defect in
  `wt_remove_computer` and `wt_monitors`: remove or edit, then Escape retained
  the modified panel maps. The existing computer-submenu report should include
  these sibling paths on Windows.
- **Owed:** test Escape after a confirmed removal while another computer remains,
  and after completing a panel edit but before Done in the Monitors list.
  Restore submenu-entry state on Escape wherever those cases fail.
- **Verified:** fixture-driven reproductions and fixes on macOS; the corresponding
  Windows sequences still need native execution.

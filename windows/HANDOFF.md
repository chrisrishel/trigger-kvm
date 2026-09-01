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

## Mirror the instruction-file byte check, and re-point what now lives in windows/AGENTS.md

Kind:     defect report
Spec:     n/a -- see docs/decisions/002-instruction-files-for-two-agents.md
Why:      Codex reads at most 32,768 bytes of the AGENTS.md chain and truncates
          the rest silently; the root file was 53 KB, so Codex never saw
          "Build and test" or "Conventions" on either machine
Owed:     (1) add to `windows/tests/conventions.tests.ps1` the check that
          `macos/tests/conventions.tests.sh` now runs -- root `AGENTS.md`
          <= 20480 bytes, `windows/AGENTS.md` <= 10240, their sum <= 30720,
          and every `CLAUDE.md` begins with `@AGENTS.md`. (2) Re-point the
          references that say "see ..\AGENTS.md" for content that has moved:
          `grep -n AGENTS.md windows\*.ps1 windows\README.md` and check each --
          the Bluetooth/presence, abandoned-mutex, phantom-monitor and
          sleep/wake entries are now in `windows/AGENTS.md`, their dated
          evidence in `docs/measurements.md`; hard rules 1-5 are still in the
          root file, so those references are unchanged.
Verified: sizes measured here 2026-08-31 and the macOS suite already enforces
          BOTH chains' budgets, so nothing is unprotected -- what Windows lacks
          is finding out on its own machine. `windows/AGENTS.md` and
          `windows/CLAUDE.md` were created from the root file's Windows-specific
          entries with the user's explicit permission (repo management, not
          Windows development); nothing else under `windows/` was touched. The
          Windows suite was not run from here.

## Record a computer's removal when the row is chosen, not by diffing list positions afterwards

Kind:     defect report
Spec:     specs/configure.md §5.2, §5.3
Why:      "Remove a computer" can be recorded as a RENAME, so the removed
          computer's inputs are handed to whichever computer slid into its slot
Owed:     `Read-Computers` (install.ps1:1279-1284) infers renames by lining the
          old `$Others` up against the new `$rest` by index: any position where
          the names differ and the old name is gone becomes `Renames[old]=new`.
          With this=`mac`, others=`[pc, linux]`, LG on mac/pc/linux and ASUS on
          mac/pc only: remove `pc` -> `Renames['pc']='linux'`, `Removed=@()`
          -> the ASUS map becomes `{mac, linux=0x11}`; `to linux` moves the
          ASUS to the PC's socket, and the confirm text just shown ("Its input
          on every monitor is cleared too") was false. Rename-then-remove in
          one sitting is worse (the case macos/lib/walkthrough.sh:346-350
          comments on and macos/tests/walkthrough.tests.sh:534-553 pins).
          Record the victim and each old->new pair at the moment the row is
          chosen and drop the positional diff. Add a three-computer test with
          one computer absent from a panel, removing the first-listed one; the
          existing removal test (walkthrough.tests.ps1:617-625) removes the
          only other computer, so positions never shift.
Verified: read on a Mac at commit 657e215; traced by hand through the loop at
          :1279-1284 and the consumer at :1939-1948. Suite not run. High
          confidence in the reading; the exact scenario was not executed.

## Stop passing `-Tier` to the elevated relaunch

Kind:     defect report
Spec:     specs/configure.md §8
Why:      the documented recovery from an admin-owned task ("both paths detect
          it and explain", windows/AGENTS.md:93-99) dies at parameter binding
Owed:     install.ps1:3121 builds `$childArgs = @('install', '-Tier',
          $EffectiveTier)` for `Request-Elevation`. The script's `param()`
          (:80-108) declares only `Command, AddToPath, Fresh, NoElevate,
          Relaunched`, under `[CmdletBinding()]`, which throws on an unknown
          named parameter (the hazard windows/AGENTS.md:119-124 records). So
          the user who installed the boot tier, later picks `From login` and
          saves, gets `Unregister-ScheduledTask` denied (:3110), the relaunch
          at :3119-3129, and a binding error in a hidden elevated window; the
          parent prints "the task was left exactly as it was". Fix:
          `$childArgs = @('install')` -- the child re-derives the tier via
          `Get-EffectiveTier` as :2821 and :2844 already do. Add a test that
          every `-X` in a `$childArgs` literal binds against install.ps1's own
          `param()`. windows/README.md:1023 still documents `-Tier s4u`.
Verified: `grep -n -- '-Tier' windows/install.ps1` -> only the
          `Write-ConfigFile` parameter and line 3121; no `$Tier` script
          parameter exists. Read on a Mac; not executed. Very high confidence.

## Make the boot tier work from a standard (non-admin) account, or refuse it there

Kind:     defect report
Spec:     specs/configure.md §8 ("runs as the user"; "falls back to login and
          says so")
Why:      on a family or corporate PC the signed-in user is not an admin, and
          the suggested answer "From boot" then installs for the wrong account
Owed:     `Request-Elevation` (:230-265) relaunches with `-Verb RunAs`. When
          the user is not an admin, Windows elevates a DIFFERENT account; the
          child derives `$DEST`/`$CONFIG` from ITS `$env:LOCALAPPDATA` (:114,
          :158) and the S4U principal from ITS `$env:USERDOMAIN\$env:USERNAME`
          (:3056-3057). Read: the child finds no config, `Test-CanPrompt`
          (:430-434) returns false, it prints "not an interactive terminal"
          and exits 2 -- or, if it proceeds, registers the task under the
          admin's identity and copies to the admin's profile. Either way the
          user's own watcher never starts from boot, and nothing says so.
          This is TODO.md item 1, whose trigger is "before publishing". Fix
          either: pass the resolved paths and target user to the child and
          register the principal as the ORIGINAL user; or detect
          non-membership in Administrators before offering `From boot` and
          disable the row with its detail saying why (§8: drawn, disabled,
          never hidden). Also confirm that an elevated launch of the LOGIN tier
          does not register the task under the admin principal.
Verified: read on a Mac; not executed; no standard-user Windows account was
          available. High confidence in the mechanism (`-Verb RunAs` semantics
          are documented), medium in which branch the child takes.

## Bake the config path into the task action and the switcher spawn

Kind:     defect report
Spec:     specs/config-format.md "Where it lives"; specs/configure.md §8
Why:      an S4U task can start before the user's profile is loaded, and then
          `%LOCALAPPDATA%` is not the user's; the watcher would die silently
          before arming
Owed:     `Get-ConfigPath` (config.ps1:50-52) reads `$env:LOCALAPPDATA` at run
          time. The task action bakes absolute `-Exec` and `-LogFile` but NOT
          `-Config` (install.ps1:3009-3016), and the watcher's spawn of the
          switcher also omits `-Config` (event-watch.ps1:459-462). With no
          profile loaded, `%LOCALAPPDATA%` may be unset or point at the
          Default profile: `Read-Config` returns empty, event-watch throws "no
          trigger.device" (:302-304) into a console-less wscript host, and the
          1-minute self-heal retries forever. Every measured session-0 run so
          far had a live user session (ideas/nvapi-transport.md admits the
          truly-pre-login case is unproven). Fix: resolve the config path at
          registration and pass `-Config <abs>` in the task action and from
          the watcher to the switcher. THEN verify on hardware: cold boot, do
          not log in, flip the switch, log in, read the log.
Verified: read on a Mac; not executed. Medium confidence that the profile is
          unloaded for an S4U at-startup task (it depends on the task's
          settings); high confidence that if it is, this is the failure shape.

## Gate the pre-rename cleanup on this project's own files

Kind:     defect report
Spec:     n/a
Why:      the rename exists because haimgel/display-switch already owns that
          name; the cleanup now deletes anything called that
Owed:     `Remove-LegacyInstall` (install.ps1:344-368), run on every install
          and uninstall, unregisters ANY scheduled task named
          `display-switch` and `Remove-Item -Recurse -Force`s
          `%LOCALAPPDATA%\Programs\display-switch` with no check that it was
          this project's. A user who also has haimgel's tool installed there,
          or a task they named that themselves, loses it on our first run.
          Gate on a marker only our old install wrote (its `launcher.vbs`
          content, its `version.txt`, or the task action pointing at our old
          watcher), and otherwise print a one-line warning and touch nothing.
Verified: read on a Mac; not executed. High confidence in the reading; whether
          haimgel's default install lands in that exact directory was not
          checked.

## Do not pass an undefined `$off` to `Read-Monitors`' menu

Kind:     defect report
Spec:     specs/configure.md §6
Why:      with three or more monitors and `bin\` already on PATH, the Monitors
          list has an unpickable row -- `Done`, or the fifth monitor
Owed:     install.ps1:1676 passes `-Disabled $off`; `$off` is never assigned in
          `Read-Monitors` (1649-1693) and resolves by dynamic scope to
          `Invoke-Configure`'s `$off` (:1859-1860), which is `@(4)` whenever
          the PATH row is disabled. Items are `[d0, d1, d2, '', Done]`, so
          index 4 -- `Done` -- is drawn `--` and skipped; only esc/`q` gets
          out. Two-monitor desks never see it. Delete `-Disabled $off` (no
          Monitors row is ever disabled). Add a three-display, on-PATH test
          that opens Monitors and reaches Done.
Verified: read on a Mac; `grep -n '\$off' windows/install.ps1` shows the only
          assignment is in `Invoke-Configure`. Not executed. High confidence
          (Set-StrictMode does not catch a variable that resolves in a parent
          scope).

## Parse every byte and word in install.ps1 with the switcher's converters

Kind:     defect report
Spec:     specs/config-format.md "Value parsing"; specs/configure.md §6.1
Why:      the walkthrough accepts values the switcher then drops, and drops
          values the switcher accepts, so a saved config is not what was shown
Owed:     Three regexes disagree with `ConvertTo-Byte`/`ConvertTo-Word`
          (trigger-kvm.ps1:143-159): (1) the typed-value check at
          install.ps1:1346 `'^(0[xX])?[0-9A-Fa-f]{1,2}$'` accepts bare hex
          (`d1`) and refuses 3-digit decimals; typing `d1` then running the
          monitor check makes `set -Value d1` refuse inside `Out-Null`, the
          panel does nothing, and the user is offered LG's method for a fault
          that does not exist; saved, `display.lg.input.d1 = mac` is dropped
          by the reader and `pull` refuses. (2) the re-load at :1402 matches
          only `0x[0-9a-f]{1,2}` input keys, so a spec-legal hand edit
          `display.asus.input.17 = pc` is invisible and gone after Save.
          (3) `Get-PriorDisplay` (:1703-1704) compares EDID ids as hex text, so
          a decimal vendor/product makes the panel show as unmanaged. Use the
          converters at all three sites and compare by value. macOS uses
          `config_to_byte`/`config_to_word` at the same three points.
          Related: the typed-value collision check at :1352 compares strings,
          so `17` and `0x11` are not seen as the same socket (macOS has the
          same defect; the spec is silent -- reported separately as a spec
          item).
Verified: read on a Mac; the three regexes quoted from source. Not executed.
          High confidence.

## Pass `-Taken` when re-asking this computer's input after "did not come back"

Kind:     defect report
Spec:     specs/configure.md §6.1 ("Two computers cannot share one input"),
          §10.4 outcome 2
Why:      the outcome-2 repair lets the user pick an input another computer
          already holds; the writer then emits the same key twice and the
          reader keeps one
Owed:     install.ps1:2318-2321 calls `Read-InputValue` without `-Taken`, so
          assigned inputs are neither annotated, disabled nor refused there.
          The §10.5 re-ask at :2383-2386 does pass it; this is one missed
          call site. macOS passes the map (checks.sh:427-430).
Verified: read on a Mac; not executed. High confidence.

## Fall back to login, and say so, when the UAC prompt is declined

Kind:     defect report
Spec:     specs/configure.md §8 ("the boot tier falls back to login and says
          so"), §12 ("then restart the watcher")
Why:      declining the prompt after choosing From boot leaves the config
          saying `boot`, the old watcher running with the OLD trigger devices,
          and a message that says nothing was changed when the config was
Owed:     install.ps1:1980-1982 writes the config, :2635 re-runs `install`,
          :2818-2823 calls `Request-Elevation`; on decline it prints "elevation
          was declined or unavailable; nothing was changed." (:256) and exits
          1: no task re-registration, no watcher restart, `install.autostart =
          boot` left in the file. macOS rewrites the key to `login`, loads the
          agent and says "no password given -- falling back to starting at
          login" (macos/lib/manage.sh:236-244).
Verified: read on a Mac; not executed. High confidence.

## Make the switcher's fail-closed behaviour testable without the reference panels

Kind:     defect report
Spec:     specs/config-format.md ("the property to assert in a test is that
          nothing is sent")
Why:      on every machine but the reference desk, the only tests of the exact
          packets and of every refusal SKIP and the run reports all green
Owed:     resolve.tests.ps1:43-53 exits 0 as SKIPPED when the two panels are
          not attached, and run.ps1:37 counts exit 0 as PASS; types.tests.ps1
          also skips without NVAPI. So the "refuse, never zero" property, the
          ambiguity refusal and the byte-exact packets are exercised by
          nothing for a contributor or CI. `ConvertTo-Byte`/`ConvertTo-Word`
          are pure and can be unit-tested via `Import-Subject` (null not zero;
          `017` -> 17; `0x1FF`, `256`, `-1`, ` 0x11 ` -> null). Make a skip
          print loudly and count separately from PASS. Also note
          windows/README.md:95-108 says the suite is mutation-checked but no
          `windows/tests/mutate.ps1` exists; add one or soften the claim.
Verified: `ls windows/tests` -> no mutate script (fact). Skip logic read from
          source; not executed. High confidence.

## Add the structural "one door" check for I2C source 0x50

Kind:     defect report
Spec:     n/a -- AGENTS.md hard rule 5 ("each suite asserts the gate is the
          only door")
Why:      AGENTS.md states both suites pin this; only macOS does
Owed:     `grep -n '0x50\|WriteLgInput\|LG_I2C_SOURCE' windows/tests/*.ps1`
          returns nothing. macos/tests/conventions.tests.sh:18-37 asserts
          `input-alt` appears in exactly one non-comment line, inside the gate
          function, and that no function takes a source byte. Add the
          equivalent: `LG_I2C_SOURCE` (or the literal) appears only inside
          `NvDdc` at `WriteLgInput`/`PacketForLgInput`, `Send` stays private,
          and no public method takes an I2C address parameter. Self-test the
          check against a throwaway copy with a second emitter, as the
          conformance checker is self-tested.
Verified: grep on a Mac (fact). The gate itself was read and holds
          (trigger-kvm.ps1:533-559).

## Refuse, name the key, and keep running when `trigger.debounce` or `trigger.settle` is malformed

Kind:     defect report
Spec:     specs/config-format.md ("both fail rather than guess or default")
Why:      one bad hand edit (`3 s`, `three`) kills the watcher before it arms,
          in a console-less host, and the self-heal relaunches it every minute
          forever
Owed:     event-watch.ps1:307-312 casts `[double]$cfg['trigger.debounce']`
          under `Set-StrictMode`/`Stop`, before the arm block and outside any
          try/catch. Parse tolerantly, fall back to `$DEFAULT_*`, log a WARN
          naming the key, and arm. (macOS `atof`s to 0.0 silently -- the
          opposite failure; both are being reported.)
Verified: read on a Mac; not executed. High confidence.

## Stand the installed watcher down during "Test the triggers"

Kind:     defect report
Spec:     specs/configure.md §11
Why:      on a re-run, the flip back is seen by BOTH the one-shot and the live
          watcher, and the live one pulls against the SAVED (possibly wrong)
          config last -- so a correct new answer gets blamed on the monitors
Owed:     `Invoke-TriggerTest` (install.ps1:1996-) neither stops nor disables
          the task for the duration (no ScheduledTask cmdlet or mutex check
          inside it). Disable the task and stop the watcher before waiting
          (the same code `pause` uses), restore afterwards -- or at least say
          "the running watcher will also fire" before waiting. macOS has the
          same defect (macos/lib/checks.sh:596-619) and is being fixed there.
Verified: grep of the function body on a Mac; not executed. Medium-high
          confidence.

## Refuse a short name (label) already used by another monitor

Kind:     defect report
Spec:     specs/configure.md §6 ("Short name for it") -- the spec is silent on
          uniqueness; a spec sentence is being proposed separately
Why:      two Dell panels both default to `dell`; accepting both writes
          `display.dell.*` twice and the reader merges them into one panel
          with a union map
Owed:     install.ps1:1503-1505 lowercases and strips the label and falls back
          to the default; nothing compares it against the other answers'
          keys. Refuse with a message and re-ask. (macOS has the same gap,
          macos/lib/walkthrough.sh:650-652.)
Verified: read on a Mac; `grep -n 'already' windows/install.ps1` shows no
          label-uniqueness message. Not executed. High confidence.

## Honour `q` on the top menu in the typed fallback

Kind:     defect report
Spec:     specs/configure.md §3.3, §3.5 ("`q` is the fallback's esc, and only
          where esc is offered")
Why:      esc is offered on the top menu (it moves to Cancel); a scripted or
          redirected-stdin run has no way to express it
Owed:     install.ps1:731-737 honours `q` only with `-Escapable`; with
          `-EscapeTo` it prints "Pick a number from the list." macOS
          (menu.sh:451) moves the default to Cancel. windows/README.md:154
          claims `q` works there. No typed-mode `-EscapeTo` test exists
          (menus.tests.ps1:181-197 are key-driven); add one.
Verified: read on a Mac; not executed. High confidence.

## Refuse "Test the triggers" when no device is chosen

Kind:     defect report
Spec:     specs/configure.md §11
Why:      with nothing chosen the check runs, waits, and then tells the user
          the devices may be wrong
Owed:     install.ps1:1966-1971 runs `Invoke-TriggerTest` regardless; `-Device
          ''` reaches event-watch.ps1:345-347, which skips the empty entry and
          leaves an empty watch list. macOS refuses first ("No trigger
          devices are chosen yet -- pick some first.", row `no devices
          chosen`, macos/lib/checks.sh:572-576). Match it.
Verified: read on a Mac; what `-TestTrigger` does with an empty list was not
          traced further. Medium confidence.

## Read and write the user PATH without expanding other entries

Kind:     defect report
Spec:     specs/configure.md §9
Why:      answering yes to PATH silently rewrites every `%VAR%`-style entry the
          user already had as a literal path
Owed:     install.ps1:272-291 uses `[Environment]::GetEnvironmentVariable
          ('Path','User')`, which returns EXPANDED text, then
          `SetEnvironmentVariable` writes it back as REG_SZ. Read/write the
          `HKCU\Environment\Path` value with `DoNotExpandEnvironmentNames` and
          keep its REG_EXPAND_SZ kind. The add/dedup/removal logic itself is
          correct.
Verified: read on a Mac; not executed. High confidence in the .NET behaviour.

## Catch a failed `Register-ScheduledTask` so a partial install is explained

Kind:     defect report
Spec:     specs/configure.md §4.4 (an interrupted run leaves a working setup
          untouched)
Why:      the old task is unregistered before the new one is registered; a
          throw in between leaves no autostart and no message about it
Owed:     copies (install.ps1:2919-2921) precede Unregister/Register
          (:3107-3143); a non-ownership throw under `Stop` leaves the old task
          gone, the new one absent, `install.autostart` unchanged. Wrap the
          register in try/catch, and on failure say what is left and how to
          recover (`trigger-kvm restart` / re-run).
Verified: read on a Mac; not executed. Medium confidence.

## Bring `status` to parity

Kind:     defect report
Spec:     specs/configure.md §8 ("`status` must say plainly what the installed
          tier covers")
Why:      the two platforms answer "what is configured" differently
Owed:     install.ps1:2678 prints `not installed` and exits 1 before the
          config/displays/computers block; macOS prints everything it can.
          Windows prints no `triggers :` line and no spec revision (the stamp
          at :2989-2994 lacks it); its login-tier text does not say how to get
          the boot tier (macOS manage.sh:296 does). Low priority; align.
Verified: read on a Mac; not executed.

## Delete `Read-ComputerName -AllowBlank` and the test that still asserts blank removes

Kind:     defect report
Spec:     specs/configure.md §5.0 (revision 5: a blank answer keeps the name)
Why:      dead code that implements the behaviour revision 5 removed, with a
          live test asserting it
Owed:     install.ps1:1112,1117 `-AllowBlank` has no callers since revision 5;
          walkthrough.tests.ps1:581-582 still asserts "blank removes, where
          blank is allowed". Remove both.
Verified: `grep -n AllowBlank windows/` on a Mac: definition, one internal
          use, one test. Not executed. High confidence.

## Fix the stale claims in windows/README.md and the Windows script headers

Kind:     defect report
Spec:     n/a (docs)
Why:      a new user is told to run flags that do not exist and is given two
          answers to several questions
Owed:     windows/README.md -- :31 "No admin rights needed" (vs :496); :154
          `q` on the main menu (see the `q` entry above); :245-246 "trigger,
          then monitors" (vs :284 and spec §11: monitors first); :360-364
          typed names "offered ahead ... case preserved" (vs install.ps1:
          1363-1369 and `.ToLower()` at 1082/2447); :474,475,483 literal TABs
          where `\trigger-kvm` was meant (`grep -nP '\t'`); :513 "user
          (default)"; :534 a real account name after `principal=` (use a
          placeholder); :566,577,675 and :119,195 a real Bluetooth address --
          use an obviously fake one; :684-687 "trigger changes need install.ps1
          re-run" (vs :441-446 and the watcher reading the config); :830
          `../macos/usb-watch.c` (file is event-watch.c); :855 "the macOS
          Makefile generates the plist" (lib/manage.sh does); :866,907,1023
          `-Status`, `-Uninstall`, `-Tier s4u` (no such flags); :880-882
          launchd respawn "0.01s" (macos/README.md:380: 0.21 s); :889 mutex
          `Local\` (vs :815 and event-watch.ps1:148); :898 "another usb-watch
          is already running" (text is "another watcher is already running");
          :911-926 the owner's device table; :964-971 "Scope: post-login
          only" and :994-1036 "Still open" (every item is answered; delete
          both); :760,782,1002 "see ../AGENTS.md" for content now in
          windows/AGENTS.md (already queued below). Script headers --
          trigger-kvm.ps1:31-34 (trigger changes need reinstall);
          event-watch.ps1:14,51-53 ("one source -- USB"; Bluetooth is in the
          same file); install.ps1:39-59 (key named `install.start`; the code
          writes `install.autostart`), :2670 (`pause` hint names
          nvapi-probe.ps1, which the installer never copies), :2715-2717
          comment says 5-minute self-heal (registered interval is 1 minute),
          :2956 `TK_DIR=%~dp0..\\` doubled backslash; nvapi-probe.ps1:6,12-16,
          32-34 ("Phase 1"; "nobody has tested it"; "sees 0" -- measured 1
          phantom). One pass; then re-read windows/README.md as a stranger.
Verified: every line number checked on a Mac against commit 657e215 by
          grep/read. Docs only; nothing to execute.

## Check the PC's log for paired arrivals more than 3 s apart

Kind:     defect report
Spec:     n/a -- AGENTS.md "Only one device ever appears in the log"
Why:      on the Mac the two watched devices arrived 6 s apart on one flip and
          `pull` ran twice (two LG re-negotiations); the AGENTS.md claim is
          "usually", not "ever"
Owed:     `Select-String 'arrival' $env:LOCALAPPDATA\trigger-kvm\trigger-kvm.log`
          and look for two `fired:` lines within ~10 s. If it happens here too,
          the fix is shared (a longer same-flip window for OTHER configured
          devices after a fire, keeping 3 s for the same device) and belongs
          in the spec first. Hardware-only; cannot be read from source.
Verified: macOS log evidence 2026-08-31 18:26:52-18:27:03 (two `fired:` lines
          for one flip). Windows log not seen.

## Measure whether a standard-DDC panel can be switched through dxva2 on the onboard Intel GPU

Kind:     measurement brief -- not a defect; work only this platform can do,
          and nothing to implement until the numbers are in
Spec:     n/a -- docs/decisions/001 names this as what would reopen it
Why:      the README turns away everyone without an NVIDIA GPU. Most monitors
          take the standard command, and this PC has an Intel UHD 770 that can
          drive one of the panels, so "any GPU, for standard monitors" can be
          measured here instead of hoped for
Owed:     a measurement, recorded in docs/measurements.md, then a decision
          record (003) -- NOT code. The machine and the panel are the
          instrument; keep every reading in the context it is a claim about
          (see the note at the top of docs/measurements.md).

          Setup (hard rule 4 throughout: the LG stays on the 4090 and stays on
          this PC, so there is always a screen to read):
          1. BIOS: Advanced -> System Agent Configuration -> iGPU Multi-Monitor
             = Enabled. Boot. Confirm "Intel(R) UHD Graphics 770" appears in
             Device Manager; install Intel's driver if Windows did not.
          2. Move ONLY the ASUS's PC cable (HDMI 1 today) from the 4090 to a
             motherboard output (HDMI or DisplayPort). Note which input on the
             ASUS it now occupies -- if it changed, the config's value for this
             computer on the ASUS changes with it; use the walkthrough, do not
             hand-edit.
          3. `trigger-kvm list` and `nvapi-probe.ps1`: NVAPI must now see ONE
             panel (the LG). Record what it says about the ASUS (expected:
             absent -- it is on another adapter). Record what
             `EnumDisplayMonitors` and `Get-CimInstance WmiMonitorID` report
             for both panels (EDID vendor/product for the ASUS from WMI is the
             identity a vendor-neutral transport would need).

          Measurements, each confirmed by looking at the ASUS:
          4. From a NORMAL session: `SetVCPFeature(0x60, 0x0F)` then `(0x60,
             <its new PC input value>)` on the ASUS's physical monitor handle
             (dxva2). The last working implementation of exactly this call is
             the parent of commit 70e5ed4 (`git show 70e5ed4^:windows/trigger-kvm.ps1`);
             lift the call, not the file. Both directions; from an inactive
             link too (switch the ASUS to the Mac first, then pull it back
             over the Intel output). Record: did it move, did it come back,
             how long.
          5. From SESSION 0 (an unelevated S4U on-demand task, the way the
             NVAPI probe was measured): what does `EnumDisplayMonitors`
             return with the ASUS on the Intel output -- the phantom, zero, or
             something new -- and can a physical monitor handle be obtained at
             all. Expected: no usable handle. This is the measurement that
             decides whether a dxva2 panel can ever be covered by the boot
             tier; the answer is probably no, and that goes in the decision
             as a stated limitation, never as a fallback.
          6. Is `WmiMonitorID` (or `Get-PnpDevice` display class) consistent
             with what NVAPI reports for the LG, so one identity key
             (EDID vendor+product) can serve both transports?

          Do NOT: send anything on I2C source 0x50 by any route other than
          `NvDdc.WriteLgInput`; do not attempt Intel's own I2C API (IGCL) --
          that is a third transport and a separate decision; do not sweep
          values -- 0x0F and the ASUS's HDMI value are the only two to send.

          Afterwards: put the ASUS cable back on the 4090 and re-run
          `configure` so the config matches the desk again. Then write
          decision 003 proposing per-panel transport selection at configure
          time (standard panels -> dxva2 where no vendor route exists, login
          tier only, the From boot row disabled with the reason per
          specs/configure.md 8), or recording why not.
Verified: nothing -- this is the brief for taking the measurement. Written on
          the Mac from the repo's own records (decision 001, windows/AGENTS.md
          session-0 findings, the deleted dxva2 code). The BIOS location and
          the iGPU model were reported by the owner from the machine.

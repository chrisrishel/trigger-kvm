# Windows -- agent instructions

Read `..\AGENTS.md` first: the hard safety rules and everything both platforms
share. This file is only what is true of the Windows implementation; the
measurements behind it are in `..\docs\measurements.md`, the file map and how-tos
in `README.md`.

## Hazards learned here

**Hard rule 5's ONLY emitter is `NvDdc.WriteLgInput` in `trigger-kvm.ps1`.** The
source byte is not a parameter of it, and it **throws** unless the target's EDID
manufacturer is GSM (`0x1E6D`). Nothing else here can reach that bus: `Dxva`
cannot express a source byte at all, and `nvapi-probe.ps1` deliberately never
resolves `NvAPI_I2CWrite`, so there is no instrument to gate.
`tests/conventions.tests.ps1` names every embedded native block in the tree,
scans them all, and self-tests the scan.

**A force-killed watcher leaves the mutex ABANDONED, and that is a normal
condition here, not an error.** The installer force-kills it on every install;
so do Task Manager and a crash. .NET signals it by throwing
`AbandonedMutexException` from `WaitOne` **after** handing the lock over;
`event-watch.ps1` catches it and continues, because the alternative is an install
that reports success and leaves nothing watching; `ReleaseMutex()` clears the
abandonment. Do not "simplify" the catch away: uncaught it also strands the lock
when the watcher is run BY HAND, since an aborted script does not end a shell.

**One physical USB plug produces DOZENS of `Win32_DeviceChangeEvent` indications,
each costing a `Win32_PnPEntity` sweep.** The debounce is load-bearing for
ordinary operation and the no-edge branch is the common case by a wide margin,
which is why its line is `Write-Verbose`, not `Write-Log`. `-Verbose` on a
hand-run watcher distinguishes "nothing delivered" from "delivered and correctly
rejected"; `README.md` says how.

**PnP presence means "attached" for USB and "PAIRED" for Bluetooth. Do not
extend the watcher to Bluetooth by widening its match pattern.** A paired device
keeps its node while never connected, so no edge would ever fire -- the worst
failure shape available. Bluetooth is BUILT and matches on CONNECTED
through `bthprops.cpl` by P/Invoke (`BLUETOOTH_DEVICE_INFO.fConnected`, not
`fRemembered`). Three other routes were ruled out and dated in
`..\docs\measurements.md`; do not re-try them. Two constraints easy to undo:
**enumerate Bluetooth ONCE per presence sweep**, not per watched device; and **a
missing or disabled radio must not take the watcher down** -- it is an absence,
and absences never fire.

**But the CANDIDATE LIST offers every PAIRED device, connected or not**: firing
is on connected, offering on paired, because the device disconnected right now is
exactly the one that will produce an arrival. Show the state, do not filter on
it.

**WMI device notifications DO reach session 0.** The watcher uses
`Win32_DeviceChangeEvent`, a WMI extrinsic event from Winmgmt, **not**
`WM_DEVICECHANGE`, a window message that needs a desktop. Do not "simplify" it
onto window messages; that would break the boot tier silently while post-login
kept working.

**Sleep/wake does not fire a spurious switch, tested by hibernate (S4).** The
watcher survives as a live process holding its `$present` map and nothing fires;
a flip made *during* hibernation fires correctly on resume.
`DEVPKEY_Device_LastArrivalDate` does **not** track bus power cycling, so do not
reach for it to answer "did USB come back?" across a resume; it does track a
flip's PnP arrival, which is how you correlate one against the log.

**S3 standby HANGS this machine. Do not test it again; use hibernate.** Nothing
here is implicated; `..\docs\measurements.md` has the evidence, and how to
hibernate from the shell you will be in.

**`user32` REPORTS THE WRONG MONITORS WHEREVER THERE IS NO LOCAL CONSOLE**, and
`dxva2` goes through it. Two measured shapes in `..\docs\measurements.md`: in
session 0 a PHANTOM monitor rather than none, so an identity check trusting it
mis-resolves by PICKING a panel rather than erroring; over RDP the virtual
display and none of the physical panels. The EDID gate turns both into a refusal.
So a `dxva2` panel is LOCAL-SESSION ONLY: `configure` draws the boot row disabled
for it and `status` says which panel it strands. NVAPI is unaffected, is the only
identity source the boot tier may use, and is never correlated against the
Windows display list. Decisions `001` and `003`.

**`$env:SESSIONNAME` is not a remote-session test**: it read `Console` inside an
RDP session (measured). `GetSystemMetrics(SM_REMOTESESSION)` is.

**`Get-PnpDeviceProperty` costs ~200 ms PER CALL**, against 0.14 ms for
`cfgmgr32!CM_Get_DevNode_PropertyW`; the registry copy is unreadable unelevated.
Device properties go through `event-watch.ps1`'s `$DevNameSource` binding. A
per-node loop on the cmdlet is not a slower version of that, it is an unusable
one; do not move back to it.

**Do not gate anything on `NV_GPU_DISPLAYIDS.isActive` (flags bit 2).** It varies
with nothing changing and what it tracks is not established; `isConnected`
(bit 6) was stable in every run and context. Use that.

**Never hand-write NVAPI bindings from memory.** Dispatch uses magic function ids
and size-encoded struct versions; both come from a real source, and the ids in
use are recorded with provenance in `..\docs\nvapi-bindings.md`.

**Elevated registration protects the task definition.** For login/manual,
elevate only old-task removal; the normal parent registers the replacement.
Boot registration and protected-task uninstall still need elevation. Never
elevate the whole user-tier retry: later changes would need admin rights too.

**`-Verb RunAs` from a STANDARD account elevates a DIFFERENT USER, so the child
is TOLD who the install is for** -- `$ME`/`$FORUSER`/`$APPDATA`, resolved once at
the top of `install.ps1`, the only place the environment is read. Three
consequences, all pinned by the suite. Only a process running AS a user may edit
that user's PATH (`HKCU` in the child is the ADMIN's hive), so the PARENT does
it. Its arguments are TEXT and a profile path has spaces, so flags stay bare and
values quoted (`Format-ChildArguments`). And its only voice is the transcript
`Request-Elevation` prints, because `-Verb RunAs` takes no
`-RedirectStandardOutput` and the window is hidden: `*>` around the call drops
the terminating error and flattens the exit code (measured), so the catch goes
INSIDE the redirection.

**Tiers**: `lib/host.ps1` registers S4U for boot. `RunLevel Limited` does NOT
prove an unelevated process token (2026-10-30 measurement); validate the actual
token. `event-watch.ps1` takes a `Global\` mutex so
exclusion covers the computer rather than one session, and falls back to
`Local\` ONLY where the account may not create a global name. A watcher finding
the global name held by ANOTHER ACCOUNT stands down instead of falling back --
that is exactly the two-tiers-two-watchers case the global name prevents.

## PowerShell hazards

**`[Console]::CursorLeft` CLAMPS at `BufferWidth - 1`.** An exactly-full line
reads the same as one a column short. `Write-MenuFrame` erases with RawUI BEFORE
writing, including folded rows, the last column and leftover rows after shrinking.
`Get-MenuWidth` caps the wrapping target at
110, never the text. **Do not infer wrapping from `[Console]::Write`**: it differs
from `Write-Host`. `tests/native-publication.tests.ps1` measures the real host's
cursor and buffer in hidden consoles at widths 24, 60, 80 and 120.

**A SIMPLE PowerShell function SWALLOWS an undeclared named argument into `$args`
without a word**; a `[CmdletBinding()]` function throws. So a caller left on an
old parameter name goes on working and quietly loses what it carried -- twice
now -- and `(Get-Something) -split ';'` without the parentheses hands `-split`
over as a parameter, which is how `$onPath` shipped permanently false.
`Test-DisplayInput`, `Set-PanelAnswer` and their test stubs carry
`[CmdletBinding()]` because each decides something a human is asked or a config
records; prefer it on any future parameter with that property.

**`Import-Subject` in `tests/lib.ps1` takes the FIRST definition of a name, and
PowerShell runs the LAST**, so a duplicate means the suite tests dead code and
passes. Do not make the importer take the last; forbid the duplicate --
`tests/conventions.tests.ps1` walks the AST of every shipped script, `lib/`
included.

**A NAME IS NOT YOURS JUST BECAUSE YOU WROTE IT.** Three shapes, all shipped
here, all silent. Per FILE: `$PSScriptRoot` and `$PSCommandPath` in a function
defined in `lib/` name that lib file, whichever program dot-sourced it, so
`install.ps1` resolves `$TK_HOME` and `$TK_SELF` once and `lib/` reads those
(`Get-Sibling` is the one place falling back to the installed copy). Per
STATEMENT: `$SWITCH` IS `$switch`, the running switch's enumerator, and the verb
dispatch is a switch, so that constant read EMPTY for every verb; `$foreach` and
`$_` are the same. CASE-INSENSITIVE: `$LIBDIR` and `$libDir` were one variable,
pointing the install's destination at the source tree. `tests/lib.ps1` defines
the substitutes, so no behavioural test catches any of it;
`tests/conventions.tests.ps1` bans the first pair under `lib/`, reads every
script-scope name back from inside a switch, a foreach and a pipeline, and groups
them per PROGRAM to catch two spellings of one.

**The harness runs `Set-StrictMode -Version Latest`, because the scripts do.**
Indexing into an empty match, an unset property, an undeclared variable: quiet by
default, terminating under Latest. `@($x | Where-Object ...)[0]` shipped green
and died on the first Monitors selection; use `| Select-Object -First 1`.

Every script must parse clean before running against hardware; `README.md` has
the one-liner.

**`trigger-kvm pause` before running one by hand, never `Stop-ScheduledTask`.**
The watcher is a GRANDCHILD of the task (task -> `wscript.exe` ->
`powershell.exe`), so stopping the task kills the shim and leaves the watcher
holding the mutex -- and the 1-minute self-heal starts it again anyway. `pause`
disables as well as stops; `restart` puts it back. Commands in `README.md`.

# Windows -- agent instructions

Read `..\AGENTS.md` first; it holds the hard safety rules and everything both
platforms share. This file is only what is true of the Windows implementation.
The dated measurements behind it are in `..\docs\measurements.md`.

## Hazards learned here

**Hard rule 5's gate is `NvDdc.WriteLgInput` in `trigger-kvm.ps1`.** It is the
only function that can emit source `0x50`, the source byte is not a parameter,
and it **throws** unless the target's EDID manufacturer is GSM (`0x1E6D`).
Until 2026-08-30 `lg-input-switch.exe` sprayed `SetVCP 0xF4` at every connected
output, so the ASUS received the LG's write too and a `Test-LgBlastRadius` guard
was needed. Both are gone: an aimed write has no blast radius. History in
`README.md`.

**A force-killed watcher leaves the mutex ABANDONED, and that is a normal
condition here, not an error.** `install.ps1` force-kills the watcher on every
install, because stopping the task only kills the `wscript` shim and leaves the
watcher running as its grandchild; Task Manager and a crash do the same. .NET
signals this by throwing `AbandonedMutexException` from `WaitOne` **after** handing
the lock over; `event-watch.ps1` catches it and continues, because the alternative
is an install that reports success and leaves nothing watching. After the catch,
`ReleaseMutex()` succeeds and consumes the abandonment. Do not "simplify" the
catch away: uncaught, it also strands the lock when the watcher is run BY HAND,
because an aborted script does not end an interactive shell.

**One physical USB plug produces DOZENS of `Win32_DeviceChangeEvent` indications,
each costing a `Win32_PnPEntity` query.** So the debounce is
load-bearing for ordinary operation, and the no-edge branch is the common case
by a wide margin -- which is why its line is `Write-Verbose`, not `Write-Log`;
promoting it would bury the log on every plug. Run the watcher by hand with
`-Verbose` to evidence which case happened (`device-change event yielded no
arrival edge (...)`); a quiet log alone cannot distinguish "no event delivered"
from "delivered and correctly rejected".

**PnP presence means "attached" for USB and "PAIRED" for Bluetooth. Do not extend
the watcher to Bluetooth by widening its match pattern.** A paired device keeps
its node for YEARS while never connected, so no edge would ever fire -- the worst
failure shape available. Bluetooth is BUILT and matches on CONNECTED via the
classic `bthprops.cpl` API by P/Invoke (`BLUETOOTH_DEVICE_INFO.fConnected`,
distinct from `fRemembered`). Three other routes were tried first and ruled out:
widening PnP (presence = paired); `Register-ObjectEvent` on WinRT ("Windows
PowerShell cannot subscribe to Windows RT events"); `Add-Type` on a `.winmd`
(0x80131047). Two constraints easy to undo by accident: **enumerate Bluetooth
ONCE per presence sweep**, not per watched device (~32 sweeps per plug); and **a
missing or disabled radio must not take the watcher down** -- it is treated as
"nothing connected", an absence, and absences never fire.

**But the CANDIDATE LIST offers every PAIRED device, connected or not.** Firing is
on connected; *offering* is on paired. The device that is disconnected right now
is exactly the one that will produce an arrival, so filtering the list hid the
choice a user most wants. Show the state; do not filter on it.

**WMI device notifications DO reach session 0.** The watcher uses
`Win32_DeviceChangeEvent`, a WMI extrinsic event from the Winmgmt service, **not**
`WM_DEVICECHANGE`, a window message that needs a desktop. Do not "simplify" the
detector onto window messages; it would break the s4u tier silently while
post-login kept working.

**Sleep/wake does not fire a spurious switch, tested by hibernate (S4).** The
watcher survives it as a live process holding its `$present` map, and nothing
fires; flipping the switch to this PC *while it hibernates* does fire on resume,
correctly. `DEVPKEY_Device_LastArrivalDate` does **not** track bus power cycling
-- do not reach for it to answer "did USB come back?" across a resume. It DOES
track a switch flip's PnP arrival, and since a departure is only
`Write-Verbose`, it is how you correlate a flip against the log.

**S3 standby HANGS this machine. Do not test it again; use hibernate.** Entered
S3 once and never resumed. Nothing in this repo is implicated and the cause is
platform; the evidence is dated in `..\docs\measurements.md`. From a
bash-flavoured shell hibernate is `shutdown -h`, not `/h`, which MSYS rewrites
into a path.

**In session 0, `user32` reports ONE PHANTOM MONITOR, not zero.** "No desktop"
presents as *wrong* monitors, so an identity check trusting `user32` there
MIS-RESOLVES: it fails by picking a panel, not by erroring
(`haimgel/display-switch` #17). `dxva2` goes through `user32`, so a `dxva2` panel
is LOGIN-TIER ONLY -- `configure` draws the boot row disabled for it and `status`
says which panel it strands -- and its EDID gate is what stops session 0 acting
on the phantom. NVAPI is the only identity source the boot tier may use, and is
never correlated against the Windows display list. Decisions `001` and `003`.

**`Get-PnpDeviceProperty` costs ~200 ms PER CALL** -- 70 s for 42 nodes, where
`cfgmgr32!CM_Get_DevNode_PropertyW` reads the same property in 0.14 ms and the
registry copy is unreadable unelevated. Device properties go through
`Get-BusReportedName`. A per-node loop on the cmdlet is not a slower version of
that, it is an unusable one; do not move any of the three back to it.

**Do not gate anything on `NV_GPU_DISPLAYIDS.isActive` (flags bit 2).** It read
`False` and then `True` for both panels in the same interactive session with no
change in between; what it tracks is not established. `isConnected` (bit 6) was
stable across every run and every context. Use that. See `ideas/nvapi-transport.md`.

**Never hand-write NVAPI bindings from memory.** Dispatch uses magic function ids
and size-encoded struct versions; both must come from a real source, and the ids
in use are recorded with provenance in `ideas/nvapi-transport.md`.

**Running `setup` elevated poisons the task for later unelevated runs.** The task
definition under `System32\Tasks` is owned by whoever registered it, so one admin
run -- or installing the s4u tier, which requires elevation -- leaves an ordinary
user with Read only. Every later unelevated `setup` or `uninstall` then fails with
`Access is denied` after the scripts have already been copied. Both paths detect
it and explain; do not simplify those catch blocks away. Recovery: `uninstall`
elevated once, then `setup` normally.

**`-Verb RunAs` from a STANDARD account elevates a DIFFERENT USER, so the child is
TOLD who the install is for** -- `$ME`/`$FORUSER`/`$APPDATA`, resolved once at the
top of `install.ps1`, the only place the environment is read. Two consequences,
both pinned by the suite: only a process running AS a user may edit that user's
PATH (`HKCU` in the child is the ADMIN's hive); and the child's arguments are
TEXT while a profile path has spaces, so flags stay bare and values quoted
(`Format-ChildArguments`).

**Tiers**: the task-registration logic lives in `install.ps1` only. A headless
install defaults to login-start; "from boot" registers an S4U task at the cost of
admin *to register* (it still runs unelevated). `event-watch.ps1` takes a
`Global\` mutex, never `Local\` (per-session), as defence in depth against two
live watchers in different sessions.

## PowerShell hazards

**`[Console]::CursorLeft` CLAMPS at `BufferWidth - 1`, and writing into the last
column WRAPS.** A line that exactly fills the row reads the same as one a column
short, so "fill the rest of the line" from that reading writes one space too many.
`Write-MenuFrame`'s whole contract is returning how many ROWS it drew;
`Clear-ToLineEnd` therefore stops at `BufferWidth - 1`, safe because
`Get-MenuWidth` caps a menu at 110. **Do not conclude anything about wrapping from
`[Console]::Write`** -- it differs from `Write-Host`, which is what the code calls.
The suite has no console, so measure in a real one: sweep widths 60..120 against
line lengths around each fold, comparing rows reported with `CursorTop`.

**A SIMPLE PowerShell function SWALLOWS an undeclared named argument into `$args`
without a word**; a `[CmdletBinding()]` function throws. So a caller left on an
old parameter name goes on working and quietly loses what it carried -- bitten
twice (`-ThisName`, then `-IsMachine` -> `-IsComputer`). `Test-DisplayInput` and
its test stubs carry `[CmdletBinding()]` because that switch decides which
question a human is asked; prefer it on any future parameter with that property.

**`Import-Subject` in `tests/lib.ps1` takes the FIRST definition of a name, and
PowerShell runs the LAST.** A duplicate definition means the suite tests dead
code and passes. Do not make the importer take the last; forbid the duplicate --
`tests/conventions.tests.ps1` walks the AST for two top-level definitions.

**`(Get-Something) -split ';'` needs the parentheses.** Without them `-split` is a
PARAMETER of the function, swallowed into `$args`, and `-contains` silently never
matches; that shipped and made `$onPath` permanently false.

**The harness runs `Set-StrictMode -Version Latest`, because the scripts do.**
Indexing into an empty match, an unset property, an undeclared variable -- quiet
by default, terminating under Latest. `@($x | Where-Object ...)[0]` shipped green
and died on the first Monitors selection; use `| Select-Object -First 1`.

Both scripts must parse clean before running against hardware:

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\trigger-kvm.ps1', [ref]$null, [ref]$e)
$e
```

## Exercising the watcher

**`trigger-kvm pause` before running one by hand, never `Stop-ScheduledTask`.**
Stopping the task kills only the `wscript` shim (task -> `wscript.exe` ->
`powershell.exe`), leaves the watcher holding the mutex, and the 1-minute
self-heal restarts it regardless -- so the task has to be DISABLED, not merely
stopped. `pause` does both; `trigger-kvm restart` puts it back. The commands are
in `README.md`, "Running a watcher by hand".

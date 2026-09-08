# Windows -- agent instructions

Read `..\AGENTS.md` first; it holds the hard safety rules and everything both
platforms share. This file is only what is true of the Windows implementation;
the measurements behind it are in `..\docs\measurements.md`, the file map and
how-tos in `README.md`.

## Hazards learned here

**Hard rule 5's ONLY emitter is `NvDdc.WriteLgInput` in `trigger-kvm.ps1`.** The
source byte is not a parameter of it, and it **throws** unless the target's EDID
manufacturer is GSM (`0x1E6D`). Nothing else in this tree can reach that bus:
`Dxva` cannot express a source byte at all, and `nvapi-probe.ps1` deliberately
never resolves `NvAPI_I2CWrite`, so there is no instrument to gate either.
`tests/conventions.tests.ps1` scans the embedded C# and self-tests the scan.

**A force-killed watcher leaves the mutex ABANDONED, and that is a normal
condition here, not an error.** The installer force-kills the watcher on every
install; Task Manager and a crash do the same. .NET signals it by throwing
`AbandonedMutexException` from `WaitOne` **after** handing the lock over;
`event-watch.ps1` catches it and continues, because the alternative is an install
that reports success and leaves nothing watching, and `ReleaseMutex()` then
consumes the abandonment. Do not "simplify" the catch away: uncaught it also
strands the lock when the watcher is run BY HAND, since an aborted script does
not end an interactive shell.

**One physical USB plug produces DOZENS of `Win32_DeviceChangeEvent` indications,
each costing a `Win32_PnPEntity` query.** The debounce is therefore load-bearing
for ordinary operation, and the no-edge branch is the common case by a wide
margin -- which is why its line is `Write-Verbose`, not `Write-Log`. A quiet log
cannot distinguish "no event delivered" from "delivered and correctly rejected";
`-Verbose` on a hand-run watcher can, and `README.md` says how.

**PnP presence means "attached" for USB and "PAIRED" for Bluetooth. Do not
extend the watcher to Bluetooth by widening its match pattern.** A paired device
keeps its node for YEARS while never connected, so no edge would ever fire --
the worst failure shape available. Bluetooth is BUILT and matches on CONNECTED
through `bthprops.cpl` by P/Invoke (`BLUETOOTH_DEVICE_INFO.fConnected`, not
`fRemembered`). Three other routes were ruled out and are dated in
`..\docs\measurements.md`; do not re-try them. Two constraints easy to undo by
accident: **enumerate Bluetooth ONCE per presence sweep**, not per watched device
(~32 sweeps per plug); and **a missing or disabled radio must not take the
watcher down** -- it is an absence, and absences never fire.

**But the CANDIDATE LIST offers every PAIRED device, connected or not.** Firing
is on connected; *offering* is on paired, because the device that is
disconnected right now is exactly the one that will produce an arrival. Show the
state; do not filter on it.

**WMI device notifications DO reach session 0.** The watcher uses
`Win32_DeviceChangeEvent`, a WMI extrinsic event from Winmgmt, **not**
`WM_DEVICECHANGE`, a window message that needs a desktop. Do not "simplify" it
onto window messages; that would break the boot tier silently while post-login
kept working.

**Sleep/wake does not fire a spurious switch, tested by hibernate (S4).** The
watcher survives as a live process holding its `$present` map, and nothing fires;
flipping the switch to this PC *while it hibernates* does fire on resume,
correctly. `DEVPKEY_Device_LastArrivalDate` does **not** track bus power cycling,
so do not reach for it to answer "did USB come back?" across a resume; it does
track a flip's PnP arrival, which is how you correlate one against the log.

**S3 standby HANGS this machine. Do not test it again; use hibernate.** Nothing
in this repo is implicated; the evidence is dated in `..\docs\measurements.md`.
From a bash-flavoured shell hibernate is `shutdown -h`, not `/h`, which MSYS
rewrites into a path.

**`user32` REPORTS THE WRONG MONITORS WHEREVER THERE IS NO LOCAL CONSOLE**, and
`dxva2` goes through `user32`. Two measured shapes, both in
`../docs/measurements.md`: in session 0 it reports ONE PHANTOM monitor rather
than none, so an identity check trusting it MIS-RESOLVES -- it fails by picking
a panel, not by erroring (`haimgel/display-switch` #17); over Remote Desktop it
reports the RDP virtual display and none of the physical panels, so `dxva2`
identifies nothing and refuses. The EDID gate is what turns both into a refusal.
So a `dxva2` panel is LOCAL-SESSION ONLY: `configure` draws the boot row
disabled for it and `status` says which panel it strands. NVAPI is unaffected by
either, is the only identity source the boot tier may use, and is never
correlated against the Windows display list. Decisions `001` and `003`.

**`$env:SESSIONNAME` is not a remote-session test.** It read `Console` inside an
`rdp-tcp#28` session (measured). `GetSystemMetrics(SM_REMOTESESSION)` is.

**`Get-PnpDeviceProperty` costs ~200 ms PER CALL** -- 70 s for 42 nodes, against
0.14 ms for `cfgmgr32!CM_Get_DevNode_PropertyW`, and the registry copy is
unreadable unelevated. Device properties go through `event-watch.ps1`'s
`$DevNameSource` binding. A per-node loop on the cmdlet is not a slower version
of that, it is an unusable one; do not move back to it.

**Do not gate anything on `NV_GPU_DISPLAYIDS.isActive` (flags bit 2).** It read
`False` then `True` for both panels in one session with nothing changing between;
what it tracks is not established. `isConnected` (bit 6) was stable across every
run and context. Use that.

**Never hand-write NVAPI bindings from memory.** Dispatch uses magic function ids
and size-encoded struct versions; both come from a real source, and the ids in
use are recorded with provenance in `..\docs
vapi-bindings.md`.

**Running the installer elevated poisons the task for later unelevated runs.**
The definition under `System32\Tasks` is owned by whoever registered it, so one
admin run -- or an s4u install, which needs one -- leaves an ordinary user with
Read only, and every later unelevated install or `uninstall` then fails with
`Access is denied` after the scripts are copied. Both paths detect it and
explain; do not simplify those catch blocks away. Recovery: `uninstall` elevated
once, then install normally.

**`-Verb RunAs` from a STANDARD account elevates a DIFFERENT USER, so the child
is TOLD who the install is for** -- `$ME`/`$FORUSER`/`$APPDATA`, resolved once at
the top of `install.ps1`, the only place the environment is read. Two
consequences, both pinned by the suite: only a process running AS a user may edit
that user's PATH (`HKCU` in the child is the ADMIN's hive), so the PARENT does
it; and the child's arguments are TEXT while a profile path has spaces, so flags
stay bare and values quoted (`Format-ChildArguments`).

**Tiers**: the task-registration logic lives in `lib/host.ps1` only. A headless
install defaults to login-start; "from boot" registers an S4U task at the cost of
admin *to register* (it still runs unelevated). `event-watch.ps1` takes a
`Global\` mutex so exclusion covers the computer rather than one session, and
falls back to `Local\` ONLY where the account may not create a global name. A
watcher that finds the global name held by ANOTHER ACCOUNT stands down instead
of falling back -- falling back there is exactly the two-tiers-two-watchers case
the global name exists to prevent.

## PowerShell hazards

**`[Console]::CursorLeft` CLAMPS at `BufferWidth - 1`, and writing into the last
column WRAPS.** An exactly-full line therefore reads the same as one a column
short, and erasing "to the end" from that reading costs a row `Write-MenuFrame`'s
height count knows nothing about. `Clear-ToLineEnd` stops one column short, which
is safe because `Get-MenuWidth` caps a menu at 110. **Do not conclude anything
about wrapping from `[Console]::Write`** -- it differs from `Write-Host`, which
is what the code calls. The suite has no console; measure in a real one, as
`..\docs\measurements.md` records.

**A SIMPLE PowerShell function SWALLOWS an undeclared named argument into `$args`
without a word**; a `[CmdletBinding()]` function throws. So a caller left on an
old parameter name goes on working and quietly loses what it carried -- twice
now. `Test-DisplayInput`, `Set-PanelAnswer` and their test stubs carry
`[CmdletBinding()]` because each decides something a human is asked or a config
records; prefer it on any future parameter with that property.

**`Import-Subject` in `tests/lib.ps1` takes the FIRST definition of a name, and
PowerShell runs the LAST**, so a duplicate means the suite tests dead code and
passes. Do not make the importer take the last; forbid the duplicate --
`tests/conventions.tests.ps1` walks the AST of every shipped script, `lib/`
included.

**`$PSScriptRoot` inside `lib/` is `lib/`.** Everything there reads `$TK_HOME`,
resolved once in `install.ps1`, for where the sibling scripts are; `Get-Sibling`
is the one place that falls back to the installed copy. `tests/lib.ps1` defines
both, so an imported function does not have to be told.

**`(Get-Something) -split ';'` needs the parentheses.** Without them `-split` is
a PARAMETER of the function, swallowed into `$args`, and `-contains` never
matches; that shipped, and made `$onPath` permanently false.

**The harness runs `Set-StrictMode -Version Latest`, because the scripts do.**
Indexing into an empty match, an unset property, an undeclared variable: quiet by
default, terminating under Latest. `@($x | Where-Object ...)[0]` shipped green
and died on the first Monitors selection; use `| Select-Object -First 1`.

Every script must parse clean before running against hardware:

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\trigger-kvm.ps1', [ref]$null, [ref]$e)
$e
```

**`trigger-kvm pause` before running one by hand, never `Stop-ScheduledTask`.**
The watcher is a GRANDCHILD of the task (task -> `wscript.exe` ->
`powershell.exe`), so stopping the task kills the shim and leaves the watcher
holding the mutex -- and the 1-minute self-heal starts it again anyway. `pause`
disables as well as stops; `restart` puts it back. Commands in `README.md`.

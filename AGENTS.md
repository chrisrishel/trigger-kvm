# Agent instructions

Read this before changing anything in this repo. Start with `ARCHITECTURE.md` for
the design and `displays.toml` for the values.

## What this project is

Two machines (Mac Studio, Windows PC) share two monitors with **no KVM in the video
path**. Each machine connects directly to both monitors. A USB switch moves the
peripherals; whichever machine receives them commands both monitors over DDC to
select its own inputs.

Every platform implementation is the same two roles: a **detector** (do I own the
peripherals now?) and a **switcher** (make the monitors show me).

## Hard safety rules

**1. Never sweep or brute-force VCP codes on I2C source address `0x50`.**
That is a service/factory channel. Sweeping it has bricked LG monitors — the
`ddcutil` repo carries an issue titled "Bricked LG Monitor". Use only the values
already documented in `displays.toml`. If you need a value that isn't there, ask;
do not go looking for it experimentally.

**2. Never verify a switch by reading a VCP value back.**
Reads are unreliable on both monitors and *have already produced false negatives*:

- **PG42UQ** returns `0` for luminance, contrast, volume **and** `max luminance` —
  always, whether or not it is the active input. Writes still work perfectly.
- **LG** returns real values on a settled active link, but `-7` while the link is
  inactive or renegotiating. It read `-7` immediately after a switch that had in
  fact succeeded, then recovered to `100` seconds later.

Writes are fire-and-forget. Do not build verify-then-retry loops; they will fire
spurious retries. Do not probe immediately after a switch.

**3. You cannot see the screen. A switch is only confirmed by a human looking at
it.** Never report that a switch worked because a command returned success or a
read looked right — both have lied here. Ask the user to confirm visually, and say
plainly when something is unverified.

**4. Never leave the user without a working display.** Switching both monitors to
the other machine blacks out this one. When testing, move one monitor at a time and
keep the other on the machine running the terminal. Warn before any command that
takes the last remaining display.

Note the corollary from `ARCHITECTURE.md`: because the link stays enumerated, a
window on a monitor you just switched away is still *there*, just invisible. Before
moving the monitor the terminal is on, have the user drag the terminal to the other
one first.

**5. `lg-input-switch` is a shotgun, not a scalpel.**
Its `_i2c_write` loops over every connected output mask and ports 0-7, sending the
packet to all of them. It does not identify the LG. With both monitors on one GPU,
`lg-input-switch dp` therefore also delivers `SetVCP 0xF4` to the **ASUS**.

Confirmed on 2026-08-30: the PG42UQ ignores it, with no flicker or setting change.
Re-confirmed the same day with the ASUS write **isolated out** — a `-Only lg` run,
so the `0xF4` spray was the only traffic on the wire — and observed directly: the LG
flickered, the ASUS did not. Insist on that isolation if you ever re-test. A plain
`switch-displays.ps1 windows` sends the ASUS its own VCP `0x60` write seconds
earlier, so any ASUS flicker in *that* run is unattributable and proves nothing
either way. Treat this as a property of this specific pair of monitors, not a
general licence.

**Expect the LG to flicker briefly on every LG switch, including a re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice by design (the bus is lossy). This is normal and was mistaken for a fault
once already — do not go looking for a bug in it.
Making the LG path selective means sourcing more NVAPI function ids, which the last
bullet under Conventions exists to discourage; the current arrangement is the
accepted trade.

This is now enforced in code rather than left to the reader. `Test-LgBlastRadius`
enumerates every monitor on the NVIDIA adapter before each LG switch and
**refuses** the switch outright if it finds an EDID id outside `$LG_KNOWN_OUTPUTS`
(`GSM9E9D`, `AUS42E0`). It refuses rather than warns because this normally runs from
a background task whose log nobody reads, so a warning there is not a warning.

The check is asymmetric on purpose: an **unknown** panel is the hazard and blocks
the switch, while a **missing** known panel only logs a note, because fewer
recipients is not a hazard and refusing there would break LG switching whenever the
ASUS was merely unplugged. So attaching a third monitor stops LG switching until you
add its id — that is the intended behaviour, not a bug. Confirm the new panel is
unharmed by a `0xF4` write before adding it, and note that "unharmed" cannot be
established by reading anything back (hard rule 2); it means looking at it.

## Known limitations, both platforms

Neither of these is a bug to fix on sight; they are things to know before changing
the detectors, and to reach for first if a spurious switch is ever reported.

**Only one device ever appears in the log, and that is correct.** Both watched
devices arrive together when the USB switch moves. Whichever lands first fires; the
other falls inside the debounce window and is discarded. In practice the Focusrite
wins and the webcam is never logged — observed on both platforms. This is the
debounce working, not the webcam failing to register. Do not "fix" it, and do not
read a single-device log as evidence that the other device is misconfigured.

**Sleep/wake does NOT fire a spurious switch on macOS. Tested 2026-08-30.**
This entry previously predicted the opposite, reasoning that
`kIOFirstMatchNotification` fires on any new matching service and that USB
re-enumerates on wake. A real `pmset sleepnow` / wake cycle produced **zero** log
entries. The premise appears to be wrong on a desktop: the Mac Studio keeps its USB
ports powered through sleep, so the devices are never torn down and no new match
occurs. Do not add edge-tracking to the macOS detector to solve a problem that does
not exist here.

Scope of that result: one cycle, on a desktop with powered USB. A laptop, or a hub
that drops power, could still re-enumerate and fire. Re-test rather than assume if
the hardware changes.

**Sleep/wake does not fire a spurious switch on Windows either. Tested 2026-08-30,
by hibernate (S4)** — see the next entry for why not by S3. The watcher survives
hibernation as a *live process*, so its in-memory `$present` map comes back holding
what it held going down. USB bus power does cycle underneath it — the Focusrite's
relay is audible on the way back — but `Get-PresenceMap` and the restored `$present`
then agree on "present", there is no absent -> present edge, and nothing fires. If
the watcher is restarted across the transition instead, it re-primes at startup and
logs `armed (2 already present, not firing)`. Both paths are safe, and so is the
move in between: flipping the USB switch to this PC *while it is hibernating* does
fire on resume, which is correct — the peripherals really did move here.

**Do not read a quiet log as proof the edge guard rejected anything.**
`usb-watch.ps1` drops a device-change event that yields no edge with a bare
`continue` and no log line. "No arrival logged" therefore cannot distinguish "no
event was delivered" from "an event was delivered and correctly rejected". The
outcome is the same either way; the claim is not. Add a `Write-Verbose` on that
branch before trying to evidence which one happened.

**`DEVPKEY_Device_LastArrivalDate` does not track this.** It read `03:28:57` (boot)
for both watched devices *both before and after* a hibernate cycle in which bus
power demonstrably cycled. It is not a re-enumeration probe — do not reach for it to
answer "did USB come back?", because it will confidently say no.

**S3 standby HANGS this machine. Do not test it again; use hibernate.**
On 2026-08-30 a sleep entered S3 (power light blinking, displays off) and never
resumed: fans spun back up, no video, no keyboard or mouse, no RDP, hard reboot
required. There is no crash dump and no bugcheck — a hang, not a driver fault, so
there is nothing to attribute and nothing to fix from here.

Nothing in this repo is implicated, and the evidence is worth keeping so the
question does not get reopened: the Scheduled Task is `WakeToRun: False`, the
watcher's last activity was three minutes before the attempt, and user-mode DDC
writes can neither block S3 entry (entry succeeded) nor prevent resume. The System
log holds **zero** `Kernel-Power 42` and **zero** `Power-Troubleshooter 1` events
back to 2026-01-25, so no sleep cycle has ever completed on this machine — this is
not a regression from anything built here.

The cause is platform, not project: `powercfg /a` offers only S3 and Hibernate, and
reports Hybrid Sleep unavailable because "the hypervisor does not support this
standby state", with VBS running under HVCI strict mode. Hibernate is both the safer
and the better test anyway, since S4 drops USB bus power where S3 may not.

Running it from a bash-flavoured shell needs `shutdown -h`, not `shutdown /h`: MSYS
path conversion rewrites the lone `/h` into a Windows path, and `shutdown.exe` prints
its usage instead of doing anything.

**What sleep breaks is the monitors, not the detector — and it is a settings
problem, now closed.** During that same cycle the ASUS defected to the Windows PC
on its own: it lost the Mac's signal while asleep and its auto-input feature moved
it to the other live input. Nothing pulled it back, because **wake is not a
trigger** — the watcher fires on USB arrival, and sleep produces no USB event.

Both monitors have since been tested in both states across real sleep cycles:
enabled, the monitor defects; disabled, it holds. The required OSD settings are in
`displays.toml` and `README.md`. They are named differently per vendor — LG *Auto
Input Switch*, ASUS *Auto Input Detection* — and the ASUS one does cover switching
on signal loss despite the "detection" wording.

**Do not replace this with a wake trigger.** The tempting fix is to re-assert the
displays whenever the machine wakes. The blocking objection is macOS **dark wakes**:
Power Nap, Time Machine and network activity wake the machine constantly without the
user present, and each would re-assert. Guarding on "do I currently hold the
peripherals?" removes some but not all of that. Displays that steal themselves at
random is the worst failure this system can have, and one OSD setting per monitor
prevents the whole class.

Known gap, accepted: neither the setting nor a wake trigger covers drift that
happens while the machine is **awake** — a monitor power-cycle or cable reseat
mid-session still strands you until the USB switch next moves.

**In session 0, `user32` reports ONE PHANTOM MONITOR, not zero. Measured
2026-08-30.** Running `nvapi-probe.ps1` as SYSTEM and as an unelevated S4U task, both
in session 0, `EnumDisplayMonitors` returned **1** monitor in each case, while NVAPI
correctly enumerated both real panels with their real EDIDs.

That phantom is not a real display and is not DDC-capable. The trap is that "no
desktop" does not present as "no monitors" -- it presents as *wrong* monitors, so any
identity check that trusts `user32` in a non-interactive context is matching against
a fiction and will silently mis-resolve. It is also the explanation for the failure
in `haimgel/display-switch` issue #17, where a service using `ddc-hi` logged "Did not
detect any DDC-compatible displays": it found the phantom and got no DDC from it.

Consequence for any future session-0 work: **NVAPI must be the sole source of display
identity, never correlated against the Windows display list.** SimpleKVM's
`BuildDisplayMap` does exactly that correlation and would map nothing here -- do not
lift that structure.

**Do not gate anything on `NV_GPU_DISPLAYIDS.isActive` (flags bit 2).** It read
`False` for both panels in an interactive run and `True` for both in session 0
twenty minutes later, with the physical state uncontrolled. Use `isConnected`
(bit 6). See `ideas/nvapi-transport.md`.

**Logs grow without bound on both platforms.** `~/Library/Logs/displayswitch.log`
and `%LOCALAPPDATA%\display-switch\displayswitch.log` are appended to forever, with
no rotation. Output is a few lines per switch so this is slow, but it is unbounded.

**The two switchers differ in blast radius, and the macOS one is the safer.**
`m1ddc display <uuid> set ...` addresses exactly one display. The Windows LG path
cannot: see hard rule 5. Do not assume a technique that is safe on the Mac side
carries over.

**The LG's EDID product id is per-input, so it is not a shared constant.** Three
consecutive values have been measured on the one panel — `0x9e9d` (Windows, DP),
`0x9e9f` (Mac, USB-C), `0x9ea0` (Mac, through the old KVM). Each host sees a stable
value for its own input, so it works as a *local* key, but copying one host's value
to another, or treating `displays.toml`'s field as authoritative, will silently
match nothing. Nothing reads it today; this matters if the pre-login path is ever
built. The ASUS reports `0x42e0` everywhere, which makes the trap easy to walk into.

## Keep the docs current

Documentation is part of the change, not a follow-up. **In the same commit as the
code**, update whichever of these the change affects:

| File | Update when |
|---|---|
| `README.md` | The front door changes — what it does, install, or the top-level gotchas |
| `ARCHITECTURE.md` | The *shape* changes — components, data flow, a design decision or its rationale. Not for detail churn. |
| `displays.toml` | Any monitor, input value, DDC method, or trigger device changes |
| `macos/README.md`, `windows/README.md` | That platform's install, components, or behaviour changes |
| `AGENTS.md` | A new constraint or hazard is discovered that future work must respect |

Two specific obligations:

- **`displays.toml` is a contract across two independent implementations.** Changing
  a value there means changing every implementation to match, in the same commit.
  A value fixed on one machine and not the other produces a half-switching setup
  that presents as a hardware fault.
- **When a doc's claim stops being true, fix it in that commit.** Stale docs here
  are actively dangerous — this repo's docs encode which values are safe to send to
  a service channel.

New docs earn their existence when their job arises, not before. A spec directory
is not warranted yet; `displays.toml` plus `ARCHITECTURE.md` currently carry the
contract. If the map outgrows a single readable file, graduate it to `specs/`.

## Build and test

```sh
cd macos
make                                      # build usb-watch
make plist PLIST=/tmp/t.plist             # generate + lint the LaunchAgent, loads nothing
make install                              # build, install to ~/.local/bin, load the agent
make status / make logs / make uninstall
./switch-displays.sh mac | windows        # manual switch
```

`usb-watch` must compile clean under `-Wall -Wextra`. Verify the plist with
`plutil -lint` before claiming an install path works — a malformed plist fails
silently at load.

To exercise the watcher without installing:

```sh
./usb-watch --exec /bin/echo --arg TEST --device 046d:0843 --verbose
```

It should log `armed ... (N already present, not firing)` and **not** fire for
devices that were already plugged in.

### Windows

```powershell
cd windows
.\install.ps1                              # install, register the logon task, start
.\install.ps1 -Status / -Logs / -Uninstall
.\switch-displays.ps1 windows | mac        # manual switch
.\switch-displays.ps1 windows -Only asus   # one monitor only -- use when testing
```

Both scripts must parse clean before they are run against hardware:

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile('.\switch-displays.ps1', [ref]$null, [ref]$e)
$e
```

The equivalent watcher smoke test, which fires nothing:

```powershell
Stop-ScheduledTask -TaskName display-switch    # the installed watcher holds the mutex
.\usb-watch.ps1 -Exec .\some-harmless-script.ps1 -Arg TEST -Device 046d:c547 -Verbose
```

`046d:c547` is the keyboard, which is always present, so this is the direct check
that already-present devices do not fire. The `Stop-ScheduledTask` matters:
`usb-watch.ps1` is single-instance via a named mutex and will otherwise exit at
once with `another usb-watch is already running`.

## Conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, scoped by
  platform where useful (`feat(macos): ...`).
- Do not hardcode display indices or UUIDs in switching code. Resolve by name at
  runtime — index numbers shift, and index `1` silently becoming the *other*
  monitor would send LG service-channel writes to the ASUS. This is no longer even
  theoretical: on 2026-08-30 the two indices **swapped on this machine**, from
  `DISPLAY1`=ASUS / `DISPLAY2`=LG to `DISPLAY1`=LG / `DISPLAY2`=ASUS, across a hard
  reboot and a hibernate cycle — either could be responsible, they were not
  observed separately. Nothing broke, because the switcher matches the EDID id in
  the PnP interface path. **Do not write a mapping down anywhere and treat it as
  stable**, including in scratch notes; a stale one is worse than none. dxva2 is no
  help either: it reports the LG's description as the generic `Generic PnP
  Monitor`, so neither index nor description is a usable key.
- Keep `.ps1` files ASCII-only. Windows PowerShell 5.1 reads a `.ps1` with no BOM
  as ANSI, so a UTF-8 em dash in a comment surfaces as a parse error at an
  unrelated line. Prose files are unaffected; use ASCII punctuation in scripts.
- Send DDC writes more than once. They are idempotent and the bus is lossy.
- Post-login only, both platforms, as shipped. Do not add pre-login support without
  asking. Note that `ARCHITECTURE.md`'s reasoning is now partly superseded on the
  Windows side: it argued pre-login was blocked because session 0 has no `HMONITOR`,
  which is true of the `dxva2` path but **not** of NVAPI -- measured 2026-08-30,
  NVAPI enumerates and identifies both panels from session 0. Writing over NVAPI from
  there is still untested. macOS is unchanged and still blocked.
- Prefer wrapping a known-working tool over reimplementing a vendor SDK. In
  particular, do not hand-write NVAPI bindings from memory — its dispatch uses
  magic function IDs that must be taken from a real source.

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

**5. The LG service channel may only ever be aimed at the LG.**
I2C source `0x50` carries VCP `0xF4`, and what that means on a non-LG panel is
unknown. The rule is enforced in code, at the transport, not by caller discipline:
`NvDdc.WriteLgInput` in `windows/switch-displays.ps1` is the only function that can
emit source `0x50`, the source byte is not a parameter, and it **throws** unless the
target's EDID manufacturer is GSM (`0x1E6D`). There is no generic "write to source
N" entry point, so no caller can aim it at another vendor's panel, including by
accident. Do not add one.

The switcher also refuses the LG switch unless exactly one enumerated output
identifies as the LG — zero is a refusal, and so is more than one, because an
ambiguous target cannot be aimed at safely.

**Historical, and the reason for the rule's shape.** Until 2026-08-30 the LG was
driven by `lg-input-switch.exe`, whose `_i2c_write` loops over every connected
output mask and ports 0-7, sending the packet to all of them. It did not identify
the LG, so with both monitors on one GPU `lg-input-switch dp` also delivered
`SetVCP 0xF4` to the **ASUS**. A `Test-LgBlastRadius` guard compensated by refusing
whenever any panel outside `GSM9E9D`/`AUS42E0` was attached — which meant attaching
a third monitor stopped LG switching entirely. Both the spray and the guard are gone:
an aimed write has no blast radius, so a third monitor is now simply irrelevant.

The old measurement is still worth keeping, because it is the only evidence anyone
has about what `0xF4` does to a PG42UQ: the ASUS ignored it, with no flicker or
setting change, confirmed with the ASUS write **isolated out** (a `-Only lg` run, so
the spray was the only traffic on the wire). That was a property of that specific
panel, never a general licence — and it is no longer relied upon.

**Expect the LG to flicker briefly on every LG switch, including a re-assert to the
input it is already on.** It is re-negotiating the link, and each write is sent
twice by design (the bus is lossy). This is normal and was mistaken for a fault
once already — do not go looking for a bug in it.

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

**A quiet log is still not proof the edge guard rejected anything — but `-Verbose`
now is.** `usb-watch.ps1` used to drop a no-edge device-change event with a bare
`continue` and no line at all, so "no arrival logged" could not distinguish "no
event was delivered" from "an event was delivered and correctly rejected". It now
emits `device-change event yielded no arrival edge (...)` naming whether a watched
device departed or nothing changed. That is `Write-Verbose`, not `Write-Log`: the
OS delivers these constantly and the steady state is noise, so the installed
watcher does not run with `-Verbose` and its log stays quiet. Run the watcher by
hand with `-Verbose` to evidence which case happened.

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
`False` for both panels at 15:51 and `True` for both at 16:13 **in the same
interactive session**, with no deliberate change in between. So it varies over time
rather than by execution context, and what it actually tracks is not established
here. `isConnected` (bit 6) was stable across every run and every context. Use that.
See `ideas/nvapi-transport.md`.

**Windows rotates its log; macOS still does not.**
`%LOCALAPPDATA%\display-switch\displayswitch.log` is rotated by `usb-watch.ps1` at
startup once it passes `-MaxLogBytes` (default 1MB), keeping one generation as
`.1`. `~/Library/Logs/displayswitch.log` on macOS is still appended to forever.
Output is a few lines per switch so the macOS growth is slow, but it is unbounded.

Rotation happens at watcher startup and nowhere else, for two reasons worth not
undoing: it sits *after* the single-instance mutex, so the installer's 1-minute
self-heal tick never rotates while a watcher is alive; and doing it once per start
rather than per write means the switcher -- a separate process appending to the
same file -- can never race a rename mid-switch.

**Both switchers now address exactly one display.** `m1ddc display <uuid> set ...`
always did; the Windows LG path does since 2026-08-30, by aiming the NVAPI I2C
write at the single output whose EDID identifies it. This entry previously said the
macOS side was the safer of the two and that the asymmetry should not be assumed
away — that gap is closed, and the warning it carried is spent.

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
  observed separately. Nothing broke, because the switcher resolves by EDID.
  **Do not write a mapping down anywhere and treat it as stable**, including in
  scratch notes; a stale one is worse than none. The dxva2 description string is no
  help either: it reports the LG as the generic `Generic PnP Monitor`, so neither
  index nor description is a usable key. The switcher matches the EDID manufacturer
  and product that NVAPI reads off the GPU output — the one identity that is stable,
  aimable, and available with no desktop.
- Keep `.ps1` files ASCII-only. Windows PowerShell 5.1 reads a `.ps1` with no BOM
  as ANSI, so a UTF-8 em dash in a comment surfaces as a parse error at an
  unrelated line. Prose files are unaffected; use ASCII punctuation in scripts.
- Send DDC writes more than once. They are idempotent and the bus is lossy.
- Post-login only, both platforms, as shipped. Do not add pre-login support without
  asking — that is a permissions decision, not a technical one, and it is no longer
  blocked by anything. The old reasoning (session 0 has no `HMONITOR`) was true of
  the `dxva2` path, which no longer exists. Measured 2026-08-30: NVAPI both
  enumerates **and writes** from session 0, an unelevated S4U task moved the LG in
  both directions with no desktop, and the switcher has no desktop dependency left.
  What still stands in the way is that registering such a task needs admin, which
  changes this project's "no admin needed" posture. macOS is unchanged and blocked.
- **Enumerating is not writing. Do not generalise from one to the other.** Phase 1
  proved NVAPI enumerates in session 0 and it was tempting to call pre-login solved;
  it was not, and the write had to be tested separately before anything could be
  claimed. It happened to pass. It could have failed, and the fallback design was
  far more expensive.
- **Never let the switcher trust the Windows display list for identity.** In session
  0 `user32` reports one *phantom* monitor rather than none, so it fails by
  mis-resolving instead of erroring. NVAPI is the sole identity source. This is why
  `dxva2`/`user32` were removed rather than kept as a fallback; see
  `docs/decisions/001-nvapi-as-the-only-windows-transport.md`.
- **Never hand-write NVAPI bindings from memory.** Its dispatch uses magic function
  IDs and size-encoded struct versions; both must come from a real source, and the
  ids in use here are recorded with their provenance in `ideas/nvapi-transport.md`.
  This repo does now bind NVAPI directly rather than wrapping a tool — that was
  earned by sourcing the ids, corroborating them against measured hardware, and
  checking the struct sizes at runtime, not by recalling them.

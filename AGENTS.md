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
Treat that as a property of this specific pair of monitors, not a general licence.
Attach a third monitor and it will receive these writes too -- check before assuming
that is safe. Making the LG path selective means sourcing more NVAPI function ids,
which the last bullet under Conventions exists to discourage; the current
arrangement is the accepted trade.

## Known limitations, both platforms

Neither of these is a bug to fix on sight; they are things to know before changing
the detectors, and to reach for first if a spurious switch is ever reported.

**Sleep/wake may fire a spurious switch on macOS, but probably not on Windows.**
This is reasoned from the two designs and is **UNVERIFIED** — nobody has tested a
sleep cycle on either side.

macOS uses `kIOFirstMatchNotification`, which fires whenever a *new* matching
service appears. USB devices re-enumerate on wake, so that is a fresh match and
`usb-watch` will fire, subject only to the debounce. Windows tracks
absent → present *edges* against a presence map, so a device that was present
before sleep and is present after produces no edge and no fire.

It only ever fires on the machine that already holds the peripherals, so it
re-asserts a state the system already considers correct, which is why it is a
limitation rather than a defect. It does bite in one real case: if you have
deliberately left the displays on one machine while the peripherals sit on the
other, waking the peripheral-holding Mac will yank them back. If that becomes
annoying, the fix is to give the macOS side the same edge-tracking the Windows side
has, not to lengthen the debounce.

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
  runtime — index numbers shift when a display drops, and index `1` silently
  becoming the *other* monitor would send LG service-channel writes to the ASUS.
  This is live on Windows, not hypothetical: `\\.\DISPLAY1` **is** the ASUS there,
  and dxva2 reports the LG's description as the generic `Generic PnP Monitor`, so
  neither index nor description is a usable key. Match the EDID id in the PnP
  interface path.
- Keep `.ps1` files ASCII-only. Windows PowerShell 5.1 reads a `.ps1` with no BOM
  as ANSI, so a UTF-8 em dash in a comment surfaces as a parse error at an
  unrelated line. Prose files are unaffected; use ASCII punctuation in scripts.
- Send DDC writes more than once. They are idempotent and the bus is lossy.
- Post-login only, both platforms. Do not add pre-login support without asking;
  `ARCHITECTURE.md` explains why it is a rewrite rather than a config change.
- Prefer wrapping a known-working tool over reimplementing a vendor SDK. In
  particular, do not hand-write NVAPI bindings from memory — its dispatch uses
  magic function IDs that must be taken from a real source.
